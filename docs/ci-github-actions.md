# Proposed GitHub Actions CI for Chapar environment builds

**Status: proposal.** This repository carries no `.github/workflows/` today.
The previous Incus-on-Rocky CI was removed with the Ubuntu 24.04 migration, and
how environment builds should run in CI at nscale is an open decision. This
document is the suggested design; nothing below exists until it is agreed and
implemented.

## What CI must produce

The primary deliverable is the vlad release injected into the **NVIDIA
HPC-benchmarks 26.02** base for **both architectures**. A secondary NeMo base
extends the matrix once its digests are locked:

| Base | Image | Target | Runs on |
|------|-------|--------|---------|
| `hpl` (primary) | `nvcr.io/nvidia/hpc-benchmarks:26.02` (digest-locked) | `linux-x86_64-v4` | x86 AVX-512 nodes |
| `hpl` (primary) | same, arm64 descriptor | `linux-aarch64-gb300` | GB300 (Grace) nodes |
| `nemo` (secondary, fail-closed) | NVIDIA NeMo / dgxc-exemplar lineage | `linux-x86_64-v4` | x86 AVX-512 nodes |
| `nemo` (secondary, fail-closed) | same, arm64 descriptor | `linux-aarch64-gb300` | GB300 (Grace) nodes |

Each artifact is a Pyxis image: the promoted vlad release's root specs plus
their runtime closure, injected at build-time absolute paths into the
digest-locked base by `containers/envs/vlad/image/build-image.sh`, consumed via
`srun --container-image=<sealed path>`.

hpcsim stays a plain release-tree build (no image injection); it reuses jobs 1–2
below and stops there.

## Runners

All jobs run on self-hosted runners registered with
`ci/register-vlad-image-runner.sh`, which already defines the role and label
model:

- **builder** (`--role builder --target <target>`) — ephemeral, one-job,
  time-boxed. One registered per target architecture: the x86 builder must be
  x86-64-v4-capable (the vlad env concretizes to `x86_64_v4` with
  `host_compatible: true`, so a non-AVX-512 builder cannot silently produce v4
  binaries); the arm builder is a Grace node. Needs the site NFS roots
  (`/resources`) mounted, enroot + skopeo, and nvcr.io egress.
- **validator** — persistent, submits Slurm jobs (`srun` through Pyxis) on the
  matching hardware class from the host-owned site contract
  (`/etc/chapar/vlad-image/site-contract.json`).
- **publisher** — persistent, the only role with write access to the final
  image root; seals candidates into `<image_root>/<target>/releases/<id>/`.

GitHub-hosted runners are never used for builds: they have no NFS mounts, no
enroot, and builds must not depend on hardware GitHub controls.

## Pipeline shape

One workflow, four stages. Trigger: `workflow_dispatch` with `env_name`,
`release_id`, and `promote` inputs, plus optionally push-to-`envs/<name>/**`
once the flow is trusted.

```
lock-gate ──► build-env (per arch) ──► build-images (per base × arch) ──► validate ──► publish
```

1. **lock-gate** (any runner) — fail fast before consuming builder time:
   - `containers/envs/vlad/image/tests/validate-locks.sh --require-complete`
     — refuses to proceed while `sources-lock.json` is `blocked` or has
     unresolved categories. This is the supply-chain gate: no tag-based pulls,
     ever.
   - `ci/tests/vlad-image-provisioning-test.sh` and
     `containers/envs/vlad/image/tests/preflight-test.sh` as cheap regression
     suites (need `python3` + `jsonschema`).

2. **build-env** — matrix over `target` (2 jobs), each on its arch's builder:
   - `preflight.sh --mode build --target <target> ...` — fail-closed host
     check (pinned tools, NFS, free space, contract identity).
   - `source etc/init.sh && envs/vlad/release.sh build <release-id>` —
     never `spack install` directly. `--promote` only when the `promote`
     input is true (vlad policy: promote every successful build; hpcsim:
     operator-explicit only).
   - `ENV_NAME=vlad ./validation/run integrity-test` — release is not
     production-ready until this passes.
   - `PUBLISH_BUILDCACHE=true` so the second arch and later rebuilds reuse
     binaries.

3. **build-images** — matrix over `base × target` (4 jobs), each on its arch's
   builder:
   - `build-image.sh --base <hpl|nemo> --target <target> --release-dir
     <promoted release> --image-id <id> --candidate-root <candidates>` —
     resolves the base by digest from the lock, injects the runtime closure,
     verifies in-rootfs, exports `vlad-<base>+<tag>-<target>.sqsh` plus its
     `.sha256` into the candidate root.

4. **validate** — matrix over `base × target`, on the validator runner:
   - `preflight.sh --mode runtime --sha256 <artifact sha>` — for x86-v4 this
     enforces CPUID and ELF `x86-64-v4` evidence on the actual node class.
   - An `srun --container-image=<candidate .sqsh>` smoke job: `module use
     /opt/chapar/modulefiles/<arch>`, load each root module, run its
     `--version` check — the in-container analogue of the integrity test.
     For the `hpl` base additionally run the NVIDIA `/workspace` HPL
     entrypoint in a one-node dry-run; for `nemo`, import the training stack.

5. **publish** — on the publisher runner, per artifact that validated:
   - `preflight.sh --mode publisher --sha256 <sha>` then an atomic move of the
     sealed candidate into `<image_root>/<target>/releases/<release-id>/`.
   - Optionally mirror to the S3 image store the fleet-manager way
     (`publish_sqsh_to_s3.py` equivalent) if clusters install images from
     object storage rather than NFS.

## Secrets and trust boundaries

- Runner registration/removal tokens are files on the runner hosts
  (root-owned, 0600), never workflow secrets — `register-vlad-image-runner.sh`
  already enforces this.
- The site contract and its expected hash live only at
  `/etc/chapar/vlad-image/` on the hosts (installed by
  `ci/install-vlad-image-site-contract.sh`); workflows never supply them.
- nvcr.io pull credentials (if the NeMo lineage needs NGC auth) belong in the
  builder host's enroot/skopeo credential store, not in GitHub secrets.

## Open items before implementation

1. Resolve `sources-lock.json` to `complete`: lock the hpc-benchmarks 26.02
   index/descriptor digests (skopeo on a builder), and add + lock the
   `nvidia_nemo_oci` category for the NeMo base (also extend
   `validate-locks.sh`'s category allowlist and fixtures).
2. Confirm `enroot import` accepts the `oci-archive://` (or digest `docker://`)
   form used by `build-image.sh` on the builder's enroot version.
3. Confirm base-image glibc compatibility: vlad builds on Ubuntu 24.04 /
   glibc 2.39; each base's rootfs must be ≥ that (`/etc/os-release` in the
   base).
4. Ensure `environment-modules` (or Lmod) is present in each base or added as a
   digest-locked package, otherwise the injected modulefiles are inert.
5. Decide artifact retention: candidate roots are scratch; sealed releases are
   immutable; how many image releases to keep per target.
