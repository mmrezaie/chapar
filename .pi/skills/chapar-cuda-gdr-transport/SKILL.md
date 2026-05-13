---
name: chapar-cuda-gdr-transport
description: Handle Chapar CUDA/GDR-capable transport issues in UCX, Open MPI, libfabric, GDRCopy, CUDA, NCCL, NVSHMEM, and related hpcsim Linux packages. Use when build failures involve CUDA-aware MPI, GPUDirect, UCX, Open MPI, libfabric, or GDRCopy.
---

# Chapar CUDA/GDR Transport

Use this playbook for Linux GPU transport stack work.

## Policy

- Do not disable CUDA/GDR transport support to work around downstream failures.
- Keep UCX, Open MPI, and libfabric CUDA-aware with GDRCopy where supported.
- Prefer build-order, compiler, provider, or CUDA target/stub fixes over removing variants.
- For LLVM 15+, do not add obsolete `+cuda`; use NVPTX targets/offload variants as needed.
- Keep CUDA constraints at major-version policy level where possible (`cuda@13`, not minor/patch), unless the user explicitly asks.

## Key Specs and Files

```text
envs/hpcsim/linux/definitions.yaml
envs/hpcsim/rocky8/definitions.yaml
envs/hpcsim/rocky9/definitions.yaml
envs/hpcsim/linux/packages.yaml
envs/hpcsim/rocky8/packages.yaml
envs/hpcsim/rocky9/packages.yaml
envs/hpcsim/release.sh
```

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
spack -e envs/hpcsim spec ucx
spack -e envs/hpcsim spec libfabric
spack -e envs/hpcsim spec openmpi
spack -e envs/hpcsim config blame packages
```

For release-helper CUDA libfabric workaround, inspect:

```text
cuda_target_root
install_cuda_libfabric_specs
```

The workaround installs libfabric dependencies first, locates the selected CUDA major runtime/stubs, and builds missing CUDA-aware libfabric specs with `CPATH`/`LIBRARY_PATH` set.

## Acceptable Fixes

- Add compiler/provider requirements in OS-specific packages scopes.
- Add missing CUDA target/stub include/library path handling.
- Adjust build ordering in release helper.
- Constrain unsupported package variants in the narrowest scope.

## Unacceptable Fixes Without Explicit User Approval

- Removing `+cuda` from UCX/Open MPI/libfabric to make builds pass.
- Removing GDRCopy support where supported.
- Downgrading LLVM/CUDA/MPI solely to satisfy obsolete variants.
- Adding package recipes to `spack_repo/` unless explicitly requested.
