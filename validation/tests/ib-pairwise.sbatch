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
node="${SLURM_NODELIST:-$(hostname -s)}"
source "${VALIDATION_DIR}/lib/verdict.sh"
source "${VALIDATION_DIR}/lib/result-manifest.sh"
source "${VALIDATION_DIR}/lib/rdma-device.sh"
validation_result_init ib-pairwise "${RESULTS_ROOT}" "${node}"
RESULTS_DIR="${VALIDATION_NODE_DIR}"

if [ ! -d /sys/class/infiniband ] || [ -z "$(ls -A /sys/class/infiniband 2>/dev/null)" ]; then
    validation_resource_unavailable "no InfiniBand HCA" mandatory
fi

# ── Runtime knobs ──────────────────────────────────────────────
: "${MPI_RDMA_BYTES:=8388608}"
: "${EXTERNAL_PERFTEST:=external/perftest/ib_write_bw}"
RDMA_BENCHMARK_MAX_EDGES="$(rdma_benchmark_edge_limit)"

case "${RDMA_BENCHMARK_MAX_EDGES}" in
    ''|*[!0-9]*) printf 'RDMA_BENCHMARK_MAX_EDGES must be a positive integer\n' >&2; exit 2 ;;
esac
[ "${RDMA_BENCHMARK_MAX_EDGES}" -gt 0 ] || { printf 'RDMA_BENCHMARK_MAX_EDGES must be positive\n' >&2; exit 2; }
RDMA_HCA="$(rdma_selected_hca)" || validation_resource_unavailable "no discovered/profile-selected InfiniBand HCA" mandatory
export RDMA_HCA

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
        "${VALIDATION_DIR}/${EXTERNAL_PERFTEST}" -a -d "${RDMA_HCA}" --report_gbits \
        > "${RESULTS_DIR}/ib_write_bw.log"
fi

python3 - "${RESULTS_DIR}/edge-coverage.json" "${nodes[0]}" "${nodes[1]}" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump({"benchmark_edge_count": 1, "endpoints": [sys.argv[2], sys.argv[3]]}, stream, sort_keys=True)
    stream.write("\n")
PY

echo "IB-pairwise results written to ${RESULTS_DIR}" >&2
