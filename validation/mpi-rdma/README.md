# hpcsim MPI/RDMA Validation

This directory contains small runtime checks for the hpcsim MPI transport stack.
They are intended for real multi-node Slurm allocations after a release has been
built and the hpcsim modules are visible.

The tests validate application behavior. The selected InfiniBand, UCX, libfabric,
or CUDA RDMA transport is controlled by the module set and environment variables
in the Slurm examples.

## Tests

- `mpi_rdma_cpu`: host-buffer MPI `Sendrecv` ring test.
- `mpi_rdma_cuda`: CUDA device-buffer MPI `Sendrecv` ring test. This fails when
  the selected MPI is not CUDA-aware.

Both tests require at least two MPI ranks and print the participating host count.
For RDMA validation, run across at least two nodes.

## Build

Load exactly one MPI implementation before building. Do not load Open MPI and
Intel MPI together.

```bash
module purge
module load openmpi cuda
make -C validation/mpi-rdma cpu gpu
```

For Intel MPI:

```bash
module purge
module load intel-oneapi-mpi cuda
make -C validation/mpi-rdma cpu gpu
```

If the CUDA module does not set `CUDA_HOME`, set one of `CUDA_HOME`, `CUDA_ROOT`,
or `CUDA_PATH` before building the GPU test.

## Slurm Examples

The examples default to two nodes with one rank per node:

```bash
sbatch validation/mpi-rdma/slurm/openmpi-cpu.sbatch
sbatch validation/mpi-rdma/slurm/openmpi-gpu.sbatch
sbatch validation/mpi-rdma/slurm/intelmpi-cpu.sbatch
sbatch validation/mpi-rdma/slurm/intelmpi-gpu.sbatch
```

Common overrides:

```bash
sbatch --export=ALL,HPCSIM_OPENMPI_MODULE=openmpi/5.0.8 validation/mpi-rdma/slurm/openmpi-cpu.sbatch
sbatch --export=ALL,HPCSIM_INTELMPI_MODULE=intel-oneapi-mpi/2021.17.0 validation/mpi-rdma/slurm/intelmpi-gpu.sbatch
```

Runtime knobs:

- `MPI_RDMA_TEST_DIR`: path to this directory. Defaults to the submission working directory.
- `MPI_RDMA_BYTES`: message size in bytes. Defaults to `8388608`.
- `MPI_RDMA_ITERS`: ring iterations. Defaults to `100`.
- `MPI_RANKS`: total rank count. Defaults to `SLURM_NTASKS` or `SLURM_NNODES`.
- `MPI_LAUNCHER`: launcher command. Defaults to `srun`.
- `MPI_LAUNCHER_ARGS`: launcher arguments. Defaults to `-n ${MPI_RANKS}`.

Use provider-specific counters or cluster telemetry alongside these tests when
you need proof that traffic used the expected HCA and GPUDirect path.
