#!/bin/bash
#SBATCH -N 2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:10:00
#SBATCH -J hpcsim-ompi-cpu-rdma
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

: "${MPI_RDMA_TEST_DIR:=${SLURM_SUBMIT_DIR:-$PWD}/tests/mpi-rdma}"
: "${MPI_RDMA_BYTES:=8388608}"
: "${MPI_RDMA_ITERS:=100}"
: "${MPI_RANKS:=${SLURM_NTASKS:-${SLURM_NNODES:-2}}}"
: "${MPI_LAUNCHER:=srun}"
: "${MPI_LAUNCHER_ARGS:=-n ${MPI_RANKS}}"
: "${HPCSIM_OPENMPI_MODULE:=openmpi}"

module purge
module load "${HPCSIM_OPENMPI_MODULE}"

make -C "${MPI_RDMA_TEST_DIR}" cpu

export MPI_RDMA_BYTES MPI_RDMA_ITERS
export OMPI_MCA_pml=ucx
export OMPI_MCA_osc=ucx
export UCX_TLS=rc,ud,sm,self
export UCX_MEMTYPE_CACHE=n

${MPI_LAUNCHER} ${MPI_LAUNCHER_ARGS} "${MPI_RDMA_TEST_DIR}/mpi_rdma_cpu"
