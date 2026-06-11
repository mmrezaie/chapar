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
if [ "${MPI_LAUNCHER_ARGS+x}" != x ]; then
    case "${MPI_LAUNCHER}" in
        srun) MPI_LAUNCHER_ARGS="-n ${MPI_RANKS} --cpu-bind=none" ;;
        *) MPI_LAUNCHER_ARGS="-bootstrap slurm -np ${MPI_RANKS} -ppn 1" ;;
    esac
fi
: "${HPCSIM_INTELMPI_MODULE:=intel-oneapi-mpi}"
: "${MPI_RDMA_CPU_EXE:=mpi_rdma_cpu.intelmpi}"

configure_intelmpi_srun_pmi() {
    local candidate
    local line

    [ "${MPI_LAUNCHER}" = srun ] || return 0
    [ -z "${I_MPI_PMI_LIBRARY:-}" ] || return 0

    for candidate in \
        /usr/lib64/libpmi2.so \
        /usr/lib64/slurm/libpmi2.so \
        /usr/lib/x86_64-linux-gnu/libpmi2.so \
        /usr/lib64/libpmi.so \
        /usr/lib64/slurm/libpmi.so \
        /usr/lib/x86_64-linux-gnu/libpmi.so; do
        if [ -r "${candidate}" ]; then
            export I_MPI_PMI_LIBRARY="${candidate}"
            return 0
        fi
    done

    if command -v ldconfig >/dev/null 2>&1; then
        while read -r line; do
            case "${line}" in
                *libpmi2.so*'=> '*) candidate="${line##* => }" ;;
                *libpmi.so*'=> '*) candidate="${line##* => }" ;;
                *) candidate="" ;;
            esac
            if [ -n "${candidate}" ] && [ -r "${candidate}" ]; then
                export I_MPI_PMI_LIBRARY="${candidate}"
                return 0
            fi
        done < <(ldconfig -p 2>/dev/null || true)
    fi

    echo "WARNING: MPI_LAUNCHER=srun but I_MPI_PMI_LIBRARY was not set and no PMI library was auto-detected." >&2
    echo "WARNING: If Intel MPI reports 'PMI server not found', use MPI_LAUNCHER=mpirun or set I_MPI_PMI_LIBRARY." >&2
}

module purge
module load "${HPCSIM_INTELMPI_MODULE}"

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
