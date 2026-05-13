# Future Work

## Distribution

- Publish packages, module files, and containers through CVMFS, similar to EESSI.
- Evaluate Apptainer support, potentially using it to update build caches.
- Run CI/CD from a Slurm login node and build on Slurm compute nodes.

## Operating system support

- Finish Rocky 8 testing and start preparing for Rocky 10 support. InfiniBand is not working yet, but the rest of the stack can be prepared.
- Add equivalent support for AlmaLinux releases.
- Continue reducing OS-specific assumptions.

## Architecture support

- Move toward architecture-specific builds, including ARM.

## Package set and workflow

- Remove example packages.
- Build Slurm through this workflow and make the full stack work end to end.
