---
name: chapar-cuda-gdr-transport
description: Handle Chapar CUDA/GDR-capable transport issues in GPU-enabled Spack environments, especially hpcsim. Use when build failures involve CUDA-aware MPI, GPUDirect, UCX, Open MPI, libfabric, GDRCopy, NCCL, or NVSHMEM.
---

# Chapar CUDA/GDR Transport

Use this playbook for Linux GPU transport stack work in any Chapar environment
that requires CUDA/GDR-capable communication. hpcsim is the current primary user,
but future environments may need the same transport policy.

## Policy

- Do not disable CUDA/GDR transport support to work around downstream failures.
- Keep UCX, Open MPI, and libfabric CUDA-aware with GDRCopy where supported.
- Prefer build-order, compiler, provider, or CUDA target/stub fixes over removing
  variants.
- For LLVM 15+, do not add obsolete `+cuda`; use NVPTX targets/offload variants
  as needed.
- Keep CUDA constraints at major-version policy level where possible (`cuda@13`,
  not minor/patch), unless the user explicitly asks.

## Identify the Environment

```bash
ENV_PATH=envs/hpcsim        # or envs/<future-gpu-env>
```

Do not assume every future environment requires CUDA/GDR. Apply this playbook
only when the environment or user request requires GPU-aware transports.

## Key Specs and Files

For hpcsim today:

```text
envs/hpcsim/spack.yaml
envs/hpcsim/release.sh
```

For future environments, inspect their own manifest and included scopes before
assuming the hpcsim layout.

Common specs:

```text
ucx +cuda +gdrcopy
libfabric +cuda +gdrcopy
openmpi +cuda fabrics=verbs,ucx
intel-oneapi-mpi +external-libfabric
nccl
nvshmem
nvbandwidth
caliper +cuda
scorep +cuda
papi +cuda
hwloc +cuda ~nvml
```

## Debugging Commands

```bash
source ./etc/init.sh
spack -e "${ENV_PATH}" spec ucx
spack -e "${ENV_PATH}" spec libfabric
spack -e "${ENV_PATH}" spec openmpi
spack -e "${ENV_PATH}" config blame packages
```

For hpcsim release-helper CUDA libfabric workaround, inspect:

```text
cuda_target_root
install_cuda_libfabric_specs
```

The workaround installs libfabric dependencies first, locates the selected CUDA
major runtime/stubs, and builds missing CUDA-aware libfabric specs with
`CPATH`/`LIBRARY_PATH` set.

## Acceptable Fixes

- Add compiler/provider requirements in OS-specific package scopes.
- Add missing CUDA target/stub include/library path handling.
- Adjust build ordering in a release/build helper.
- Constrain unsupported package variants in the narrowest scope.

## Unacceptable Fixes Without Explicit User Approval

- Removing `+cuda` from UCX/Open MPI/libfabric to make builds pass.
- Removing GDRCopy support where supported.
- Downgrading LLVM/CUDA/MPI solely to satisfy obsolete variants.
- Adding package recipes to `spack_repo/` unless explicitly requested.
