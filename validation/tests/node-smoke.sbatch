#!/bin/bash
# DESCRIPTION: Per-node hardware smoke test (memory bandwidth, GPU P2P, PAPI counters, cuda-memtest, topology)
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:15:00
#SBATCH --gres=gpu:1
#SBATCH -J vlad-node-smoke
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
RESULTS_DIR="${RESULTS_ROOT}/node-smoke/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST:-$(hostname)}"
mkdir -p "${RESULTS_DIR}"

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_LIKWID:-likwid}" \
    "${CHAPAR_MODULE_PAPI:-papi}" \
    "${CHAPAR_MODULE_CUDA:-cuda/13}" \
    "${CHAPAR_MODULE_NVBANDWIDTH:-nvbandwidth}" \
    "${CHAPAR_MODULE_CUDA_MEMTEST:-cuda-memtest}" \
    "${CHAPAR_MODULE_HWLOC:-hwloc}"

# ── likwid memory bandwidth ────────────────────────────────────
echo "=== likwid MEM_DP ===" >&2
likwid-perfctr -C 0 -g MEM_DP -O "${RESULTS_DIR}/likwid_mem.csv" likwid-bench

# ── nvbandwidth memcpy + P2P ───────────────────────────────────
echo "=== nvbandwidth memcpy + p2p ===" >&2
nvbandwidth --test=memcpy --test=p2p --mode=aggregate \
    -o "${RESULTS_DIR}/nvbw.csv"

# ── PAPI counter availability ──────────────────────────────────
echo "=== PAPI L2_TCM ===" >&2
papi_command_line -e PAPI_L2_TCM > "${RESULTS_DIR}/papi_l2.txt"

# ── Per-GPU cuda-memtest ───────────────────────────────────────
echo "=== cuda-memtest (per GPU) ===" >&2
for g in $(seq 0 $((SLURM_GPUS_ON_NODE - 1))); do
    echo "  GPU ${g} …" >&2
    CUDA_VISIBLE_DEVICES="${g}" \
        cuda-memtest --report-mem-errors \
        --num-passes=1 \
        > "${RESULTS_DIR}/cuda_memtest_gpu${g}.log"
done

# ── Topology reports ───────────────────────────────────────────
echo "=== hwloc topology ===" >&2
srun -n 1 --ntasks=1 hwloc-info --topology \
    > "${RESULTS_DIR}/hwloc_topology.txt"

echo "=== lscpu ===" >&2
srun -n 1 --ntasks=1 lscpu > "${RESULTS_DIR}/lscpu.txt"

echo "Node-smoke results written to ${RESULTS_DIR}" >&2
