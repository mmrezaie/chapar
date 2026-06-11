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
Intel MPI together. The Slurm wrappers rebuild provider-specific binaries by
default so Open MPI and Intel MPI tests cannot accidentally reuse each other's
executables.

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

The Open MPI Slurm examples default to `mpirun` because some Slurm/PMIx
integrations launch singleton Open MPI ranks with bare `srun` or hang with
`srun --mpi=pmix`. The wrappers locate Open MPI 5's `prted` daemon from the
loaded release tree, add its directory to `PATH`, and pass `--cpu-bind=none` to
PRRTE's Slurm daemon launch.

Generated hpcsim modulefiles handle CUDA-aware MPI on CPU and GPU nodes. On
non-GPU nodes, Open MPI hides harmless CUDA plugin load warnings, and Intel
MPI/libfabric get a release-local CUDA driver-stub path so CPU-only MPI commands
can start even though the real NVIDIA driver library is absent. GPU nodes keep
using the real NVIDIA driver library.

Runtime knobs:

- `MPI_RDMA_TEST_DIR`: path to this directory. Defaults to `validation/mpi-rdma`
  or `mpi-rdma` below the Slurm submission directory, so wrappers work from the
  repository root or `validation/`.
- `MPI_RDMA_BYTES`: message size in bytes. Defaults to `8388608`.
- `MPI_RDMA_ITERS`: ring iterations. Defaults to `100`.
- `MPI_RANKS`: total rank count. Defaults to `SLURM_NTASKS` or `SLURM_NNODES`.
- `MPI_LAUNCHER`: launcher command. Defaults to `mpirun` for Open MPI and Intel
  MPI wrappers.
- `MPI_LAUNCHER_ARGS`: launcher arguments. Open MPI wrappers default to
  `-np ${MPI_RANKS} --bind-to none --map-by ppr:1:node --prtemca prte_launch_agent ${HPCSIM_PRTED}`.
  Intel MPI wrappers default to `-bootstrap slurm -np ${MPI_RANKS} -ppn 1`.
- `HPCSIM_PRTED`: Open MPI 5 `prted` path. Open MPI wrappers auto-detect it
  from the loaded Open MPI prefix or a sibling `prrte-*` install.
- `HPCSIM_PRTE_SLURM_ARGS`: Slurm arguments for PRRTE daemon launch. Defaults to
  `--cpu-bind=none --export=ALL`.
- `MPI_RDMA_CPU_EXE` / `MPI_RDMA_GPU_EXE`: test binary names. Wrappers default to
  MPI-specific names such as `mpi_rdma_cpu.openmpi` and
  `mpi_rdma_cuda.intelmpi`.

The GPU Open MPI example keeps `gdr_copy` in `UCX_TLS` to validate the intended
CUDA/GDR-capable stack. UCX only exposes the `gdr_copy` transport when the
GDRCopy user library is available and the host kernel driver is loaded on the GPU
node. Check for `/dev/gdrdrv` or `/sys/module/gdrdrv` if UCX warns that
`gdr_copy` is unavailable. CUDA-buffer MPI can still pass via `cuda_copy`,
`cuda_ipc`, and IB/RC transports when the GDRCopy driver is missing.

The Intel MPI examples default to `FI_PROVIDER=verbs;ofi_rxm` because this
cluster exposes raw verbs endpoints but not the `mlx` provider. They also set
`I_MPI_FABRICS=shm:ofi`, `I_MPI_OFI_PROVIDER=verbs`, and `I_MPI_OFFLOAD=0` for
CPU or `1` for GPU. The hpcsim libfabric build must include the `rxm` utility
provider for these examples to start through Intel MPI's OFI path. Override
`I_MPI_OFI_PROVIDER` and `FI_PROVIDER` together when testing another provider.

If Intel MPI fails on a non-GPU node because `libcuda.so.1` or
`libnvidia-ml.so.1` is missing, first verify that the loaded `intel-oneapi-mpi`
and `libfabric` modules come from the generated hpcsim release. Those modulefiles
should add the release-local CUDA driver-stub directory on CPU-only nodes.

Use provider-specific counters or cluster telemetry alongside these tests when
you need proof that traffic used the expected HCA and GPUDirect path.
