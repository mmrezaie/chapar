---
name: chapar-spack-solve-debug
description: Diagnose Chapar Spack solver failures for a resolver-produced software selection. Use for concretization timeouts, provider conflicts, variants, target policy, or configuration layering.
---

# Chapar solve debugging

Start from the exact resolver artifact set: `selection.json`,
`selection.sha256`, effective `spack.yaml`, and `target-policy.yaml`. Verify its
data-center/software-set/target and release/run identity before reasoning about
a failure. The source catalog is `envs/software/spack.yaml`; target facts and
site policy remain in their registries/contracts.

Do not substitute a historical environment path, ambient profile, site file,
or checkout lock. Use disposable resolver fixtures for offline diagnosis. A
native concretization or config-blame investigation is a deferred target gate
and requires explicit approval on the matching Ubuntu 24.04 builder.

Preserve latest compiler/MPI/LLVM policy and CUDA/GDR transport requirements.
Do not weaken constraints solely to make a solve pass. Record whether evidence
is offline resolver evidence or native Spack evidence. Offline contract and
selection behavior is verified; target-platform behavior not validated.
