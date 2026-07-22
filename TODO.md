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

## Detailed Sweep Findings (2026-07-22)

- **vlad release.sh**: `envs/vlad/release.sh` does not exist. The vlad environment has no release helper; a separate planning exercise is needed to create one following hpcsim's pattern.
- **Rocky 10 container recipes**: No `containers/envs/hpcsim/rocky10/` directory exists. Only Rocky 9 container recipes are defined. Rocky 10 support needs container build scripts, Packer HCL, Apptainer def, and Slurm wrappers.
- **vlad CI workflow**: No `.github/workflows/` entry for vlad. The vlad environment can only be built manually or via the generic sbatch-env-build.sh; no automated CI pipeline exists.
- **chapar_plus overlay**: The `spack_repo/chapar_plus/` namespace contains only skeleton example packages (`chapar_source_example`, `chapar_binary_only_example`). No real overlay packages have been added yet.
- **Disabled hpcsim specs**: ~15-20 root specs are commented out in `envs/hpcsim/spack.yaml`, including the visualization stack (Paraview, VisIt, VTK, VTK-m), Catalyst, older MPI implementations, and Python 3.13/3.14. These are intentionally parked but should be reviewed periodically.
