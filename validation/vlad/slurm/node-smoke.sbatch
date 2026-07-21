#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:15:00
#SBATCH --gres=gpu:1
#SBATCH -J vlad-node-smoke
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
: "${VLAD_TEST_DIR:=$(resolve_vlad_test_dir)}"

# ── Runtime knobs ──────────────────────────────────────────────
# SBATCH_PARTITION: set via sbatch --export=ALL,SBATCH_PARTITION=<name>
#   or in the site sbatch wrapper; not hard-coded here.
: "${SBATCH_PARTITION:=}"

RESULTS_DIR="${VLAD_TEST_DIR}/results/node-smoke/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Environment ────────────────────────────────────────────────
module purge
module load likwid papi cuda nvbandwidth cuda-memtest hwloc

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
