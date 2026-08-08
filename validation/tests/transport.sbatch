#!/bin/bash
# DESCRIPTION: Transport path validation (UCX, Open MPI, libfabric, NCCL debug)
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --time=00:30:00
#SBATCH --gres=gpu:1
#SBATCH -J vlad-transport
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
RESULTS_DIR="${RESULTS_ROOT}/transport/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Runtime knobs ──────────────────────────────────────────────
: "${EXTERNAL_UCX_PERFTEST:=external/ucx-perftest/ucx_perftest}"
: "${EXTERNAL_PERFTEST:=external/perftest/ib_write_bw}"
: "${NCCL_DEBUG:=INFO}"

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_OPENMPI:-openmpi/5}" \
    "${CHAPAR_MODULE_CUDA:-cuda/13}" \
    "${CHAPAR_MODULE_UCX:-ucx}" \
    "${CHAPAR_MODULE_LIBFABRIC:-libfabric}" \
    "${CHAPAR_MODULE_HWLOC:-hwloc}" \
    "${CHAPAR_MODULE_NCCL_TESTS:-nccl-tests}" \
    "${CHAPAR_MODULE_NCCL:-nccl}"

# ── UCX device and transport listing ───────────────────────────
echo "=== ucx_info devices ===" >&2
ucx_info -d > "${RESULTS_DIR}/ucx_devices.txt" 2>&1

echo "=== ucx_info transports ===" >&2
ucx_info -t > "${RESULTS_DIR}/ucx_tls.txt" 2>&1

# ── Open MPI MCA parameter dump ────────────────────────────────
echo "=== ompi_info params ===" >&2
ompi_info --param all all > "${RESULTS_DIR}/ompi_params.txt" 2>&1

# ── libfabric provider listing ─────────────────────────────────
echo "=== fi_info ===" >&2
fi_info -d > "${RESULTS_DIR}/libfabric_providers.txt" 2>&1

# ── External UCX perftest — validates CUDA transport selection ─
if [ -x "${VALIDATION_DIR}/${EXTERNAL_UCX_PERFTEST}" ]; then
    echo "=== ucx_perftest CUDA tag_lat ===" >&2
    srun -n 2 --ntasks-per-node=1 \
        "${VALIDATION_DIR}/${EXTERNAL_UCX_PERFTEST}" \
        -c 0 -t tag_lat -n 10000 -b cuda \
        > "${RESULTS_DIR}/ucx_perftest.log" 2>&1 || true
else
    echo "WARNING: ucx_perftest not found — skipping CUDA transport validation" >&2
fi

# ── External perftest — raw verbs bandwidth ────────────────────
if [ -x "${VALIDATION_DIR}/${EXTERNAL_PERFTEST}" ]; then
    echo "=== ib_write_bw ===" >&2
    srun -n 2 --ntasks-per-node=1 \
        "${VALIDATION_DIR}/${EXTERNAL_PERFTEST}" \
        -d mlx5_0 --report_gbits \
        > "${RESULTS_DIR}/ib_write_bw.log" 2>&1 || true
else
    echo "WARNING: ib_write_bw not found — skipping raw verbs probe" >&2
fi

# ── NCCL transport selection probe ─────────────────────────────
echo "=== NCCL all_reduce (transport probe) ===" >&2
NCCL_DEBUG="${NCCL_DEBUG}" srun -n 2 --ntasks-per-node=1 \
    "$(find "$(spack location -i nccl-tests 2>/dev/null || echo /usr)" \
        -name all_reduce_perf -print -quit)" \
    -b 8 -e 128M -f 2 -g 1 \
    > "${RESULTS_DIR}/nccl_transport.txt" 2>&1 || true

echo "Transport probe results written to ${RESULTS_DIR}" >&2
