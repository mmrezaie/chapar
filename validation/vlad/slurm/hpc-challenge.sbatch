#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=04:00:00
#SBATCH -J vlad-hpc-challenge
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

# ── resolve VLAD test directory ──────────────────────────────────────────

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

# ── runtime knobs ────────────────────────────────────────────────────────
#
# HPL_DAT_FILE     user-provided HPL / HPL-AI input deck (required)
# HPCG_NX          local grid X dimension (default 104)
# HPCG_NY          local grid Y dimension (default 104)
# HPCG_NZ          local grid Z dimension (default 104)
# HPCG_TIME        HPCG run time in seconds  (default 60)
# HPLAI_DAT_FILE   HPL-AI input deck (defaults to HPL_DAT_FILE when unset)

: "${HPL_DAT_FILE:=${SLURM_SUBMIT_DIR:-$PWD}/validation/vlad/hpl.dat}"
: "${HPCG_NX:=104}"
: "${HPCG_NY:=104}"
: "${HPCG_NZ:=104}"
: "${HPCG_TIME:=60}"
: "${HPLAI_DAT_FILE:=${HPL_DAT_FILE}}"

# ── guard: hpl.dat is user-provided, never vendored ──────────────────────

if [ ! -f "${HPL_DAT_FILE}" ]; then
    echo "HPL_DAT_FILE not found: ${HPL_DAT_FILE}" >&2
    echo "Provide an hpl.dat input deck before submitting this job." >&2
    echo "Example: sbatch --export=ALL,HPL_DAT_FILE=/path/to/hpl.dat ..." >&2
    exit 2
fi

# ── results directory ────────────────────────────────────────────────────

RESULTS_DIR="${VLAD_TEST_DIR}/results/hpc-challenge/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── modules ──────────────────────────────────────────────────────────────

module purge
module load openmpi openblas hpl hpcg stream babelstream

# ── HPL: High-Performance LINPACK ────────────────────────────────────────

xhpl < "${HPL_DAT_FILE}" > "${RESULTS_DIR}/hpl.log" 2>&1

# ── HPCG: High-Performance Conjugate Gradient ────────────────────────────

hpcgbench \
    --nx="${HPCG_NX:-104}" \
    --ny="${HPCG_NY:-104}" \
    --nz="${HPCG_NZ:-104}" \
    --time="${HPCG_TIME:-60}" \
    > "${RESULTS_DIR}/hpcg.log" 2>&1

# ── STREAM: memory bandwidth ─────────────────────────────────────────────

stream_c.exe > "${RESULTS_DIR}/stream.log" 2>&1

# ── HPL-AI: mixed-precision LINPACK ──────────────────────────────────────



# ── BabelStream: multi-language memory bandwidth ─────────────────────────

babelStream > "${RESULTS_DIR}/babelstream.log" 2>&1
