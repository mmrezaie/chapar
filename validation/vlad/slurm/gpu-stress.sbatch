#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --time=08:00:00
#SBATCH -J vlad-gpu-stress
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

source validation/harness/resolve_test_dir.sh

# ── Runtime knobs ──────────────────────────────────────────────
: "${CUDA_MEMTEST_PASSES:=10}"
: "${VLAD_TEST_DIR:=$(resolve_test_dir "${SLURM_SUBMIT_DIR:-$PWD}" "validation/vlad" "vlad")}"

RESULTS_DIR="${VLAD_TEST_DIR}/results/gpu-stress/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Environment ────────────────────────────────────────────────
source validation/harness/load_env.sh
load_env_from_config validation/config/vlad.yaml --needs cuda cuda-memtest

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
if [ -x external/gpu-burn/gpu-burn ]; then
    echo "=== gpu-burn ===" >&2
    ./external/gpu-burn/gpu-burn -d 28800 \
        > "${RESULTS_DIR}/gpu-burn.log" 2>&1
else
    echo "WARNING: gpu-burn not found at external/gpu-burn/gpu-burn — skipping" >&2
fi

echo "GPU stress results written to ${RESULTS_DIR}" >&2
