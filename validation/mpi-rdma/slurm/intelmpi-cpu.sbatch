#!/bin/bash
#SBATCH -N 2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:10:00
#SBATCH -J hpcsim-impi-cpu-rdma
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

resolve_mpi_rdma_test_dir() {
    local submit_dir="${SLURM_SUBMIT_DIR:-$PWD}"
    local candidate

    for candidate in "${submit_dir}/validation/mpi-rdma" "${submit_dir}/mpi-rdma"; do
        [ -f "${candidate}/Makefile" ] || continue
        [ -f "${candidate}/mpi_rdma_cpu.cpp" ] || continue
        printf '%s\n' "${candidate}"
        return 0
    done

    echo "could not locate validation/mpi-rdma; set MPI_RDMA_TEST_DIR" >&2
    return 1
}
: "${MPI_RDMA_TEST_DIR:=$(resolve_mpi_rdma_test_dir)}"
: "${MPI_RDMA_BYTES:=8388608}"
: "${MPI_RDMA_ITERS:=100}"
: "${MPI_RANKS:=${SLURM_NTASKS:-${SLURM_NNODES:-2}}}"
: "${MPI_LAUNCHER:=mpirun}"
: "${MPI_LAUNCHER_ARGS:=-bootstrap slurm -np ${MPI_RANKS} -ppn 1}"
: "${HPCSIM_INTELMPI_MODULE:=intel-oneapi-mpi}"
: "${MPI_RDMA_CPU_EXE:=mpi_rdma_cpu.intelmpi}"

module purge
module load "${HPCSIM_INTELMPI_MODULE}"

if [ ! -e /dev/nvidiactl ] && [ ! -e /proc/driver/nvidia/version ] && command -v fi_info >/dev/null 2>&1; then
    if ! fi_info_output="$(fi_info -l 2>&1 >/dev/null)"; then
        case "${fi_info_output}" in
            *libcuda.so.1*)
                echo "CUDA-enabled libfabric cannot load on this non-GPU node because libcuda.so.1 is unavailable." >&2
                echo "Run Intel MPI validation on GPU-driver nodes or provide a site-supported CUDA driver compatibility library." >&2
                exit 2
                ;;
        esac
    fi
fi

make -B -C "${MPI_RDMA_TEST_DIR}" CPU_EXE="${MPI_RDMA_CPU_EXE}" cpu

export MPI_RDMA_BYTES MPI_RDMA_ITERS
export I_MPI_FABRICS="${I_MPI_FABRICS:-shm:ofi}"
export I_MPI_OFI_PROVIDER="${I_MPI_OFI_PROVIDER:-verbs}"
export FI_PROVIDER="${FI_PROVIDER:-verbs;ofi_rxm}"
export I_MPI_OFFLOAD="${I_MPI_OFFLOAD:-0}"

${MPI_LAUNCHER} ${MPI_LAUNCHER_ARGS} "${MPI_RDMA_TEST_DIR}/${MPI_RDMA_CPU_EXE}"
