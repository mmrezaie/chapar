#!/bin/bash
# DESCRIPTION: Per-GPU memory and compute stress test
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --time=08:00:00
#SBATCH -J vlad-gpu-stress
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
RESULTS_DIR="${RESULTS_ROOT}/gpu-stress/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Runtime knobs ──────────────────────────────────────────────
: "${CUDA_MEMTEST_PASSES:=10}"

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_CUDA:-cuda/13}" \
    "${CHAPAR_MODULE_CUDA_MEMTEST:-cuda-memtest}"

# ── Per-GPU cuda-memtest ───────────────────────────────────────
echo "=== cuda-memtest (per GPU) ===" >&2
for g in $(seq 0 $((SLURM_GPUS_ON_NODE - 1))); do
    echo "  GPU ${g} …" >&2
    CUDA_VISIBLE_DEVICES="${g}" \
        cuda-memtest --report-mem-errors \
        --num-passes="${CUDA_MEMTEST_PASSES}" \
        > "${RESULTS_DIR}/cuda_memtest_gpu${g}.log"
done

# ── Optional gpu-burn ──────────────────────────────────────────
if [ -x "${VALIDATION_DIR}/external/gpu-burn/gpu-burn" ]; then
    echo "=== gpu-burn ===" >&2
    "${VALIDATION_DIR}/external/gpu-burn/gpu-burn" -d 28800 \
        > "${RESULTS_DIR}/gpu-burn.log" 2>&1
else
    echo "WARNING: gpu-burn not found at external/gpu-burn/gpu-burn — skipping" >&2
fi

echo "GPU stress results written to ${RESULTS_DIR}" >&2
