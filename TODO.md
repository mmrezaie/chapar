# Future Work

## Distribution

- Publish packages, module files, and containers through CVMFS, similar to EESSI.
- Evaluate Apptainer support, potentially using it to update build caches.
- Run CI/CD from a Slurm login node and build on Slurm compute nodes.

## Operating system support

- Validate Rocky 9 and Rocky 10 hpcsim builds on the target clusters. InfiniBand is not working yet, but the rest of the stack can be prepared.
- Add equivalent support for AlmaLinux releases.
- Continue reducing OS-specific assumptions.

## Architecture support

- Move toward architecture-specific builds, including ARM.

## Package set and workflow

- Remove example packages.
- Build Slurm through this workflow and make the full stack work end to end.

## Detailed Sweep Findings (updated 2026-07-28)

- **Rocky 10 container recipes**: No `containers/envs/hpcsim/rocky10/` directory exists. Only Rocky 9 container recipes are defined, while CI now defaults to Rocky 10. Rocky 10 support needs container build scripts, Packer HCL, Apptainer def, and Slurm wrappers.
- **chapar_plus overlay**: Contains one real overlay package (`perl_module_build_tiny`, the `#!perl` shebang fix) plus the skeleton examples (`chapar_source_example`, `chapar_binary_only_example`), which are still slated for removal.
- **Disabled hpcsim specs**: ~15-20 root specs are commented out in `envs/hpcsim/spack.yaml`, including the visualization stack (Paraview, VisIt, VTK, VTK-m), Catalyst, older MPI implementations, and Python 3.13/3.14. These are intentionally parked but should be reviewed periodically.
- **release.sh drift**: `envs/hpcsim/release.sh` and `envs/vlad/release.sh` are hand-synced copies that have already diverged (root-privilege fallback, module spec formats, multi-arch promotion, failure-handling strictness, hardcoded rocky10 paths in vlad's `cmd_build`). Extract the shared logic into a sourced library before adding a third environment.
