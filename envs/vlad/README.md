# Vlad

Vlad is a focused HPC and AI cluster validation environment. Its portable root
set provides Open MPI as the sole MPI runtime.

## MPI and GPU transport

The Open MPI root is CUDA aware and uses the verbs and UCX fabric layers. Vlad
keeps the GPU transport path enabled through CUDA aware UCX and libfabric,
including GDRCopy where supported. The environment also retains its CUDA,
NCCL, and GPU architecture policy for validation tools.

Intel MPI and Intel MPI Benchmarks are intentionally absent from Vlad's
portable root set. This keeps the environment's MPI contract centered on the
Open MPI runtime and avoids presenting Intel MPI modules or benchmark roots as
available Vlad components.

## Microarchitecture target

Vlad targets `x86_64_v4` (AVX-512F/BW/CD/DQ/VL) on x86 builders. Two settings in
`spack.yaml` carry this, both scoped to the environment so no other environment
re-concretizes:

- `packages: all: target: [x86_64_v4]` — **not yet validated on an aarch64
  builder.** If Spack treats this list as a hard constraint rather than a
  preference, a Grace build for the `linux-aarch64-gb300` image target will fail
  to concretize and this needs an arch-guarded require instead. Confirm with
  `spack -e envs/vlad config blame packages` and a concretize on each builder.
- `concretizer: targets: granularity: microarchitecture` — overrides
  `etc/system/base/concretizer.yaml`, which keeps `generic` for everything else.
  `host_compatible` stays `true`, so a builder that cannot execute v4 cannot
  silently emit v4 binaries.

The matching image target is `linux-x86_64-v4` in
`containers/envs/vlad/image/targets.json`; its runtime preflight requires CPUID and
ELF `x86-64-v4` evidence. The portable `linux-x86_64-generic` target and its
`x86-64-v1` contract are unchanged.

## Container delivery

Vlad is delivered as Pyxis images, not only as an NFS release tree: the
promoted release's runtime closure is injected into a digest-locked NVIDIA
base. The primary deliverable is the NVIDIA HPC-benchmarks 26.02 base built for
both architectures; a secondary NeMo lineage is a fail-closed slot:

| Base | Lineage | Targets | Status |
|------|---------|---------|--------|
| `hpl` (default) | NVIDIA HPC-benchmarks 26.02 | `linux-x86_64-v4`, `linux-aarch64-gb300` | primary |
| `nemo` | NVIDIA NeMo / dgxc-exemplar training image | `linux-x86_64-v4`, `linux-aarch64-gb300` | fails closed until digests are locked |

Build with `containers/envs/vlad/image/build-image.sh --base <hpl|nemo> --target
<target> ...` on a builder of the matching architecture. The `nemo` base fails
closed until its OCI digests are added to
`containers/envs/vlad/image/sources-lock.json`. The proposed CI wiring is in
`docs/ci-github-actions.md`.

## Building Vlad

Build and publish Vlad releases only through the release helper:

```bash
envs/vlad/release.sh build <id> [--promote]
```

The helper assembles a release in staging, generates its release-local module
files, and promotes it only when `--promote` is requested. Use the helper's
`status`, `module-use`, `promote`, and `publish-modules` commands for the
corresponding release operations. Do not install the environment through a
separate Spack command, because that bypasses the versioned release workflow.

Site paths, cache roots, and publication settings belong in a local
`envs/vlad/vlad-site.env`, copied from `vlad-site.env.example`.
