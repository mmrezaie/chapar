#!/bin/bash
#SBATCH -N 2
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:10:00
#SBATCH -J hpcsim-ompi-gpu-rdma
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MPI_RDMA_TEST_DIR:=$(cd "${SCRIPT_DIR}/.." && pwd)}"
: "${MPI_RDMA_BYTES:=8388608}"
: "${MPI_RDMA_ITERS:=100}"
: "${MPI_RANKS:=${SLURM_NTASKS:-${SLURM_NNODES:-2}}}"
: "${MPI_LAUNCHER:=mpirun}"
: "${HPCSIM_OPENMPI_MODULE:=openmpi}"
: "${HPCSIM_CUDA_MODULE:=cuda}"
: "${HPCSIM_PRTED:=}"
: "${HPCSIM_PRTE_SLURM_ARGS:=--cpu-bind=none --export=ALL}"
: "${MPI_RDMA_GPU_EXE:=mpi_rdma_cuda.openmpi}"

module purge
module load "${HPCSIM_OPENMPI_MODULE}"
module load "${HPCSIM_CUDA_MODULE}"

if [ "${MPI_LAUNCHER}" = "mpirun" ]; then
    if [ -z "${HPCSIM_PRTED}" ]; then
        if command -v prted >/dev/null 2>&1; then
            HPCSIM_PRTED="$(command -v prted)"
        else
            mpirun_path="$(command -v mpirun)"
            mpirun_prefix="$(dirname "$(dirname "${mpirun_path}")")"
            store_root="$(dirname "${mpirun_prefix}")"
            for candidate in "${mpirun_prefix}/bin/prted" "${store_root}"/prrte-*/bin/prted; do
                if [ -x "${candidate}" ]; then
                    HPCSIM_PRTED="${candidate}"
                    break
                fi
            done
        fi
    fi

    if [ -z "${HPCSIM_PRTED}" ] || [ ! -x "${HPCSIM_PRTED}" ]; then
        echo "could not locate executable prted for ${HPCSIM_OPENMPI_MODULE}; set HPCSIM_PRTED" >&2
        exit 2
    fi

    export PATH="$(dirname "${HPCSIM_PRTED}"):${PATH}"
    export PRTE_MCA_plm_slurm_args="${PRTE_MCA_plm_slurm_args:-${HPCSIM_PRTE_SLURM_ARGS}}"
    export OMPI_MCA_plm_slurm_args="${OMPI_MCA_plm_slurm_args:-${HPCSIM_PRTE_SLURM_ARGS}}"
    : "${MPI_LAUNCHER_ARGS:=-np ${MPI_RANKS} --bind-to none --map-by ppr:1:node --prtemca prte_launch_agent ${HPCSIM_PRTED}}"
else
    : "${MPI_LAUNCHER_ARGS:=-n ${MPI_RANKS} --cpu-bind=none}"
fi

make -B -C "${MPI_RDMA_TEST_DIR}" GPU_EXE="${MPI_RDMA_GPU_EXE}" gpu

export MPI_RDMA_BYTES MPI_RDMA_ITERS
export OMPI_MCA_pml=ucx
export OMPI_MCA_osc=ucx
export UCX_TLS=rc,ud,sm,self,cuda_copy,cuda_ipc,gdr_copy
export UCX_MEMTYPE_CACHE=y

${MPI_LAUNCHER} ${MPI_LAUNCHER_ARGS} "${MPI_RDMA_TEST_DIR}/${MPI_RDMA_GPU_EXE}"
