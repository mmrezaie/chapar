#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:N
#SBATCH --time=08:00:00
#SBATCH -J vlad-gpu-stress
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

resolve_vlad_test_dir() {
    local submit_dir="${SLURM_SUBMIT_DIR:-$PWD}"
    local candidate

    for candidate in "${submit_dir}/validation/vlad" "${submit_dir}/vlad"; do
        [ -d "${candidate}" ] || continue
        printf '%s\n' "${candidate}"
        return 0
    done

    echo "could not locate validation/vlad; set VLAD_TEST_DIR" >&2
    return 1
}

# ── Runtime knobs ──────────────────────────────────────────────
: "${CUDA_MEMTEST_PASSES:=10}"
: "${VLAD_RESULTS_DIR:=${SLURM_SUBMIT_DIR:-$PWD}/vlad_results/gpu-stress_${SLURM_JOB_ID:-$$}}"

mkdir -p "${VLAD_RESULTS_DIR}"

# ── Environment ────────────────────────────────────────────────
module purge
module load cuda cuda-memtest

# ── Per-GPU cuda-memtest ───────────────────────────────────────
echo "=== cuda-memtest (per GPU) ===" >&2
for g in $(seq 0 $((SLURM_GPUS_ON_NODE - 1))); do
    echo "  GPU ${g} …" >&2
    CUDA_VISIBLE_DEVICES="${g}" \
        cuda-memtest --report-mem-errors \
        --num-passes="${CUDA_MEMTEST_PASSES}" \
        > "${VLAD_RESULTS_DIR}/cuda_memtest_gpu${g}.log"
done

# ── Optional gpu-burn ──────────────────────────────────────────
if [ -x external/gpu-burn/gpu-burn ]; then
    echo "=== gpu-burn ===" >&2
    ./external/gpu-burn/gpu-burn -d 28800 \
        > "${VLAD_RESULTS_DIR}/gpu-burn.log" 2>&1
else
    echo "WARNING: gpu-burn not found at external/gpu-burn/gpu-burn — skipping" >&2
fi

echo "GPU stress results written to ${VLAD_RESULTS_DIR}" >&2
