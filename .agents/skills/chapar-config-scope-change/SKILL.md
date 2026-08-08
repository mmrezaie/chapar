---
name: chapar-config-scope-change
description: Modify Chapar persistent Spack scopes under etc/system or etc/user while preserving selection and data-center authority boundaries.
---

# Chapar configuration scope change

Persistent scopes own shared/OS bootstrap policy and externals. Software roots
and package policy belong in `envs/software/spack.yaml`; target facts belong in
the target registry; paths, Slurm placement, roles, sharing, and publication
belong in reviewed `datacenters/<id>` contracts.

Do not turn a site file, ambient variable, profile, or command-line override
into selection authority. Keep OS overrides conditional, avoid ordinary
link-time libraries as externals, and preserve Spack-built CUDA/Intel/MPI policy.

Validate YAML and offline resolver fixtures. Config-blame and native
concretization are deferred target-platform gates requiring explicit approval.
Offline contract and selection behavior is verified; target-platform behavior
not validated.
