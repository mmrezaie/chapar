#!/bin/bash
# DESCRIPTION: 2-node InfiniBand pair validation (OSU latency/bandwidth, qperf, ib_write_bw)
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --time=00:30:00
#SBATCH -J vlad-ib-pairwise
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
RESULTS_DIR="${RESULTS_ROOT}/ib-pairwise/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Runtime knobs ──────────────────────────────────────────────
: "${MPI_RDMA_BYTES:=8388608}"
: "${EXTERNAL_PERFTEST:=external/perftest/ib_write_bw}"

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_OPENMPI:-openmpi/5}" \
    "${CHAPAR_MODULE_CUDA:-cuda/13}" \
    "${CHAPAR_MODULE_OSU_MICRO_BENCHMARKS:-osu-micro-benchmarks}" \
    "${CHAPAR_MODULE_QPERF:-qperf}"

# ── OSU benchmarks ─────────────────────────────────────────────
srun -n 2 --ntasks-per-node=1 osu_latency > "${RESULTS_DIR}/osu_latency.log"
srun -n 2 --ntasks-per-node=1 osu_bw > "${RESULTS_DIR}/osu_bw.log"
srun -n 2 --ntasks-per-node=1 osu_bibw > "${RESULTS_DIR}/osu_bibw.log"

# ── qperf ──────────────────────────────────────────────────────
nodes=($(scontrol show hostnames "${SLURM_NODELIST}"))
srun -n 2 --ntasks-per-node=1 bash -c "
    if [ \$SLURM_NODEID -eq 0 ]; then
        peer='${nodes[1]}'
    else
        peer='${nodes[0]}'
    fi
    qperf --verbose \"\$peer\" rc_bw rc_lat
" > "${RESULTS_DIR}/qperf.log"

# ── Optional ib_write_bw ───────────────────────────────────────
if [ -x "${VALIDATION_DIR}/${EXTERNAL_PERFTEST}" ]; then
    srun -n 2 --ntasks-per-node=1 \
        "${VALIDATION_DIR}/${EXTERNAL_PERFTEST}" -a -d mlx5_0 --report_gbits \
        > "${RESULTS_DIR}/ib_write_bw.log"
fi

echo "IB-pairwise results written to ${RESULTS_DIR}" >&2
