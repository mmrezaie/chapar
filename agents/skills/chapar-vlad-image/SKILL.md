---
name: chapar-vlad-image
description: Modify or debug the vlad Pyxis image pipeline — injecting a promoted vlad release into the digest-locked NVIDIA HPC-benchmarks 26.02 base for x86_64-v4 and aarch64-gb300, the sources lock, site contract, host preflight, or image runner provisioning. Use for containers/envs/vlad/image/, ci/register-vlad-image-runner.sh, ci/install-vlad-image-site-contract.sh, or their tests.
---

# Chapar Vlad Image Pipeline

Use this playbook for everything under `containers/envs/vlad/image/` and the
image-runner provisioning scripts in `ci/`.

## What this pipeline is

Vlad is delivered as self-contained Pyxis images, consumed with
`srun --container-image=<sealed .sqsh>`. The **primary deliverable** is the
NVIDIA HPC-benchmarks 26.02 base (`--base hpl`, the default) built for both
architectures:

- `linux-x86_64-v4` — x86-64-v4 (AVX-512) nodes; runtime preflight demands
  CPUID and ELF `x86-64-v4` evidence.
- `linux-aarch64-gb300` — GB300 (Grace) nodes.

A secondary NeMo/dgxc-exemplar base (`--base nemo`) exists as a fail-closed
slot: it refuses to build until its OCI digests are locked under a
`nvidia_nemo_oci` category in `sources-lock.json`.

`build-image.sh` injects the promoted release's explicit roots plus their
link/run dependency closure at the **same absolute prefixes** they were built
at (Spack embeds absolute RPATHs; padded `__spack_path_placeholder__` chains
are descended automatically). Modulefiles land at
`/opt/chapar/modulefiles/<arch>` and are activated by `module use` only — the
base image's own MPI/HPL/NCCL stack stays first on PATH; the vlad stack is
opt-in via `module load`.

## Files

```text
containers/envs/vlad/image/build-image.sh        # release -> .sqsh injection
containers/envs/vlad/image/preflight.sh          # fail-closed host preflight (build|runtime|publisher)
containers/envs/vlad/image/targets.json          # target registry (arch, spack_target, cuda_arch)
containers/envs/vlad/image/sources-lock.json     # digest lock; status must be "complete" to build
containers/envs/vlad/image/site-contract.*.json  # host-owned roles/partitions schema + example
containers/envs/vlad/image/tests/                # validate-locks.sh, preflight-test.sh
ci/register-vlad-image-runner.sh                 # builder/validator/publisher runner registration
ci/install-vlad-image-site-contract.sh           # installs /etc/chapar/vlad-image/site-contract.{json,sha256}
ci/tests/vlad-image-provisioning-test.sh         # provisioning fixture suite
docs/ci-github-actions.md                        # proposed CI wiring (no workflows exist)
```

## Rules

- **Never pull a base by tag.** Bases resolve to per-platform descriptor
  digests from `sources-lock.json`; the lock's `floating_input_rule` forbids
  tags, branches, and `latest` as locked values. `build-image.sh` refuses to
  run while the lock is `blocked` — do not weaken that gate.
- **Fail closed everywhere.** Preflight, the installer, and the runner scripts
  reject symlinked/writable/unowned inputs before any side effect. Tests
  assert the absence of side effects; keep that property when editing.
- **Injection is path-exact.** Never relocate prefixes, never prune the
  link/run closure, never switch the profile script to a PATH/LD_LIBRARY_PATH
  prepend.
- **Adding a base** = a new `BASES` entry in `build-image.sh` + a new locked
  OCI category in `sources-lock.json` + `validate-locks.sh` category
  allowlist/fixtures + a base-specific in-image verify check.
- **Adding a target** = entries in `targets.json`, `preflight.sh`
  (`EXPECTED_TARGETS`, `X86_ISA_LEVEL` if x86, `RUNTIME_FEATURES`,
  `RUNTIME_DIAGNOSTICS`, `BUILD_TOOLS`), the site-contract schema + example,
  `register-vlad-image-runner.sh` `EXPECTED_TARGETS`, and all three test
  fixtures. Both x86 targets share the single `linux/amd64` descriptor — one
  descriptor per OCI platform, not per target.
- The env build itself must go through `envs/vlad/release.sh build <id>
  [--promote]`; the image build consumes the release's `spack.lock` and
  `metadata.txt`, never a live Spack.

## Validation

Tests need `python3` with `jsonschema`:

```bash
containers/envs/vlad/image/tests/validate-locks.sh --self-test
containers/envs/vlad/image/tests/preflight-test.sh
ci/tests/vlad-image-provisioning-test.sh
```

For `build-image.sh` changes, exercise `--plan-only` against a fixture release
(spack.lock + metadata.txt + store) — it must resolve the closure and refuse
blocked locks, missing prefixes, and unknown targets without touching enroot.

## Known-unverified items

Before first real build, confirm on the builder: the `enroot import` form for
digest-pinned bases (`oci-archive://` vs digest `docker://`), base rootfs glibc
≥ 2.39 (vlad builds on Ubuntu 24.04), and that `module`/`environment-modules`
exists in each base (or add it digest-locked). See `docs/ci-github-actions.md`
open items.
