---
name: chapar-cuda-gdr-transport
description: Change or diagnose CUDA/GDR-aware UCX, Open MPI, libfabric, GDRCopy, NCCL, or NVSHMEM policy in the Chapar software catalog and selected manifests.
---

# Chapar CUDA/GDR transport

Edit shared/root policy only in `envs/software/spack.yaml`. Target-specific
CUDA architecture and native target facts come from
`containers/images/targets.json` and are applied by the resolver. Preserve
CUDA/GDR-aware UCX, Open MPI, libfabric, GDRCopy, NCCL, and NVSHMEM support; do
not disable transport features to bypass a downstream failure.

Use catalog/resolver tests and inspect the generated effective manifest for
each affected allowed tuple. Native concretization, compiler/link checks,
drivers, InfiniBand, multi-node MPI, NCCL, and performance tests are deferred
target-platform gates. Offline contract and selection behavior is verified;
target-platform behavior not validated.
