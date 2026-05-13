# hpcsim Containers

This directory contains the initial Apptainer workflow for running the Chapar
`hpcsim` environment on Rocky Linux 9.

The image is intentionally a runtime wrapper around the existing Chapar release
layout. It does not embed the Spack install tree. At runtime, bind the site
resources tree so the container sees the promoted release at
`/resources/share/hpcsim/rocky9/current`.

## Layout

- `rocky9/packages.txt`: Rocky 9 RPMs needed by the hpcsim runtime/build base.
- `rocky9/provision-rocky9.sh`: Rocky 9 package and repository bootstrap.
- `rocky9/packer/`: Packer recipe for the reusable Rocky 9 base image.
- `rocky9/apptainer/`: Apptainer definition that converts the Packer base to a SIF.
- `rocky9/slurm/`: Slurm launch examples.
- `common/bin/`: Runtime helper shared by image recipes.

## Build

Build on a Linux machine with Docker, Packer, and Apptainer available. The local
macOS checkout can edit these recipes, but it cannot validate Apptainer builds
without Apptainer installed.

```bash
containers/hpcsim/rocky9/build.sh
```

The script runs:

```bash
packer init containers/hpcsim/rocky9/packer
packer -chdir=containers/hpcsim/rocky9/packer build .
apptainer build containers/out/hpcsim-rocky9.sif \
  containers/hpcsim/rocky9/apptainer/hpcsim-rocky9.def
```

The Packer image is tagged in the local Docker daemon as
`chapar/hpcsim-rocky9-base:latest` and saved to
`containers/out/hpcsim-rocky9-base.tar`. The Apptainer definition consumes that
archive with the `docker-archive` bootstrap so SIF creation does not need to read
from the Docker daemon directly.

Useful build overrides:

```bash
CHAPAR_APPTAINER_BUILD_ARGS='--fakeroot --force' \
CHAPAR_CONTAINER_OUT_DIR=/scratch/chapar-containers \
containers/hpcsim/rocky9/build.sh
```

## Runtime

Before running the image, build and promote a Rocky 9 hpcsim release with the
existing Chapar release workflow. The default runtime root is
`/resources/share/hpcsim`; set `CHAPAR_HPCSIM_ROOT` if you are using the CI tree
at `/resources/chapar/hpcsim` or another approved root.

The SIF expects the hpcsim release tree to be visible at the same absolute path
used by Chapar modules:

```text
/resources/share/hpcsim/rocky9/current
```

Run a quick module discovery check:

```bash
apptainer exec \
  --bind /resources:/resources \
  containers/out/hpcsim-rocky9.sif \
  bash --login -c 'module avail'
```

Use `--nv` when running on GPU nodes:

```bash
apptainer exec --nv \
  --bind /resources:/resources \
  containers/out/hpcsim-rocky9.sif \
  bash --login -c 'module avail'
```

## Slurm

Submit the example batch job from the repository root:

```bash
sbatch containers/hpcsim/rocky9/slurm/hpcsim.sbatch
```

Useful overrides:

```bash
CHAPAR_HPCSIM_IMAGE=/path/to/hpcsim-rocky9.sif \
CHAPAR_HPCSIM_ROOT=/resources/share/hpcsim \
CHAPAR_HPCSIM_COMMAND='module avail' \
sbatch containers/hpcsim/rocky9/slurm/hpcsim.sbatch
```

The example uses Slurm to launch Apptainer and is intended as a module/runtime
smoke test. It does not install Slurm inside the image, because Slurm, PMIx, and
MPI process-manager integration are usually cluster-specific ABI decisions.
Validate multi-node MPI launches separately on the target cluster.
