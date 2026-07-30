#!/bin/bash
# DESCRIPTION: Intel MPI CPU RDMA ring test - host-buffer MPI Sendrecv
#SBATCH -N 2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:10:00
#SBATCH -J hpcsim-impi-cpu-rdma
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MPI_RDMA_TEST_DIR="${VALIDATION_DIR}/mpi-rdma"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
RESULTS_DIR="${RESULTS_ROOT}/intelmpi-cpu/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Runtime knobs ──────────────────────────────────────────────
: "${MPI_RDMA_BYTES:=8388608}"
: "${MPI_RDMA_ITERS:=100}"
: "${MPI_RANKS:=${SLURM_NTASKS:-${SLURM_NNODES:-2}}}"
: "${MPI_LAUNCHER:=mpirun}"
if [ "${MPI_LAUNCHER_ARGS+x}" != x ]; then
    case "${MPI_LAUNCHER}" in
        srun) MPI_LAUNCHER_ARGS="-n ${MPI_RANKS} --cpu-bind=none" ;;
        *) MPI_LAUNCHER_ARGS="-bootstrap slurm -np ${MPI_RANKS} -ppn 1" ;;
    esac
fi
: "${MPI_RDMA_CPU_EXE:=mpi_rdma_cpu.intelmpi}"

source "${VALIDATION_DIR}/lib/intelmpi-pmi.sh"

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_INTEL_ONEAPI_MPI:-intel-oneapi-mpi}" \
    "${CHAPAR_MODULE_CUDA:-cuda/13}"

if [ ! -e /dev/nvidiactl ] && [ ! -e /proc/driver/nvidia/version ] && command -v fi_info >/dev/null 2>&1; then
    if ! fi_info_output="$(fi_info -l 2>&1 >/dev/null)"; then
        case "${fi_info_output}" in
            *libcuda.so.1*)
                echo "CUDA-enabled libfabric cannot load on this non-GPU node because libcuda.so.1 is unavailable." >&2
                echo "Verify the release was built with CUDA driver-stub module policy and that intel-oneapi-mpi/libfabric modules came from that release." >&2
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
configure_intelmpi_srun_pmi

${MPI_LAUNCHER} ${MPI_LAUNCHER_ARGS} "${MPI_RDMA_TEST_DIR}/${MPI_RDMA_CPU_EXE}"
