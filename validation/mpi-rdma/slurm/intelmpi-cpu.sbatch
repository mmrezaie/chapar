#!/bin/bash
#SBATCH -N 2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:10:00
#SBATCH -J hpcsim-impi-cpu-rdma
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

: "${MPI_RDMA_TEST_DIR:=${SLURM_SUBMIT_DIR:-$PWD}/validation/mpi-rdma}"
: "${MPI_RDMA_BYTES:=8388608}"
: "${MPI_RDMA_ITERS:=100}"
: "${MPI_RANKS:=${SLURM_NTASKS:-${SLURM_NNODES:-2}}}"
: "${MPI_LAUNCHER:=srun}"
: "${MPI_LAUNCHER_ARGS:=-n ${MPI_RANKS}}"
: "${HPCSIM_INTELMPI_MODULE:=intel-oneapi-mpi}"

module purge
module load "${HPCSIM_INTELMPI_MODULE}"

make -C "${MPI_RDMA_TEST_DIR}" cpu

export MPI_RDMA_BYTES MPI_RDMA_ITERS
export I_MPI_FABRICS=shm:ofi
export I_MPI_OFI_PROVIDER=verbs
export FI_PROVIDER=verbs
unset I_MPI_OFFLOAD

${MPI_LAUNCHER} ${MPI_LAUNCHER_ARGS} "${MPI_RDMA_TEST_DIR}/mpi_rdma_cpu"
