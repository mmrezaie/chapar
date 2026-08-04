# Chapar Environment Containers

This directory holds container image pipelines for Chapar environments,
organized as `envs/<environment>/` so future environments can be added without
overloading any single environment's paths.

Today it contains one pipeline: the **vlad Pyxis images**. A promoted vlad
release is layered into a digest-locked NVIDIA base so the artifact is
self-contained and needs no NFS mount at run time. The primary deliverable is
the **NVIDIA HPC-benchmarks 26.02** base (`hpl`, the default) built for both
architectures — `linux-x86_64-v4` and `linux-aarch64-gb300`. A secondary
NeMo/dgxc-exemplar lineage (`nemo`) exists as a fail-closed slot for the same
two architectures.

hpcsim has no container recipe here; it deploys as a plain release tree on NFS
(the legacy Rocky 9 Apptainer/Packer wrapper was removed with the Ubuntu 24.04
migration).

## Layout

- `envs/vlad/image/`: Pyxis/Enroot image pipeline — `build-image.sh` (layers a
  promoted vlad release into a digest-locked NVIDIA base), the fail-closed host
  `preflight.sh`, the target registry (`targets.json`), the pinned
  `sources-lock.json`, the site-contract schema, and `tests/`.

## Vlad Pyxis images

`envs/vlad/image/build-image.sh` layers a promoted vlad release into a
digest-locked NVIDIA base (`--base hpl` for HPC-benchmarks 26.02, `--base nemo`
for the NeMo/dgxc-exemplar lineage — the latter fails closed until its OCI
digests are locked) and exports an Enroot squashfs that Pyxis consumes with
`srun --container-image=<path>`. It follows the same Enroot conventions as
fleet-manager's `images/build.sh` — `enroot import` /
`create` / `start --root --rw` / `export`, atomic `.partial.$$` writes, and
`ENROOT_*` paths under one build root — with three deliberate differences:

1. **Digest, not tag.** fleet-manager imports `hpc-benchmarks:26.02` by tag.
   Chapar's `sources-lock.json` `floating_input_rule` forbids tags as locked
   values, so the base is resolved to its per-platform descriptor digest from the
   lock and copied with `skopeo` before import. The script refuses to run while
   the lock is `blocked`.
2. **Target-tagged artifacts.** fleet-manager's `.sqsh` names carry no
   architecture, which its own runbook flags as a footgun requiring a per-arch
   `--cache-dir`. Chapar names by target ID
   (`vlad-hpl+26.02-linux-x86_64-v4.sqsh`), so an x86 and an arm artifact can
   never overwrite each other.
3. **Runtime closure only.** Only the explicit root specs and their transitive
   link/run dependency closure are injected, each at the *same absolute prefix*
   it was built at — Spack embeds absolute RPATHs, so a relocated prefix would
   not resolve. Build-only dependencies are excluded.

Modulefiles land at `/opt/chapar/modulefiles/<arch>` and are activated by
`module use` only. The base image's MPI stays first on PATH so the NVIDIA HPL and
NCCL entrypoints under `/workspace` keep working; the vlad stack is opt-in via
`module load`.

```bash
# Inspect what would be built -- resolves nothing remote, mutates nothing.
containers/envs/vlad/image/build-image.sh \
  --target linux-x86_64-v4 \
  --release-dir /resources/chapar/vlad/ubuntu24.04/<arch>/current \
  --image-id vlad-hpl --plan-only

# Real build, on an Enroot host of the target architecture.
containers/envs/vlad/image/build-image.sh \
  --target linux-x86_64-v4 \
  --release-dir /resources/chapar/vlad/ubuntu24.04/<arch>/current \
  --image-id vlad-hpl \
  --candidate-root /resources/chapar/vlad-image/candidates
```

Run each command once per target on a builder of that architecture (two
primary artifacts per release); `--base nemo` extends this once its digests
are locked.

The build writes into the candidate root; sealing it into
`<image_root>/<target>/releases/<release-id>/` is the publisher role's job, gated
by `preflight.sh --mode publisher`. How these steps chain together in CI is
proposed in `docs/ci-github-actions.md`.

Tests for this pipeline need `python3` with `jsonschema`:

```bash
containers/envs/vlad/image/tests/validate-locks.sh --self-test
containers/envs/vlad/image/tests/preflight-test.sh
ci/tests/vlad-image-provisioning-test.sh
```
