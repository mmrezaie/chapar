#!/bin/bash
# DESCRIPTION: Full HPC benchmark sweep (HPL, HPCG, STREAM, BabelStream)
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=04:00:00
#SBATCH -J vlad-hpc-challenge
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
RESULTS_DIR="${RESULTS_ROOT}/hpc-challenge/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Runtime knobs ──────────────────────────────────────────────
: "${HPL_DAT_FILE:=${VALIDATION_DIR}/vlad/hpl.dat}"
: "${HPCG_NX:=104}"
: "${HPCG_NY:=104}"
: "${HPCG_NZ:=104}"
: "${HPCG_TIME:=60}"
: "${HPLAI_DAT_FILE:=${HPL_DAT_FILE}}"

# ── Guard: hpl.dat is user-provided, never vendored ────────────
if [ ! -f "${HPL_DAT_FILE}" ]; then
    echo "HPL_DAT_FILE not found: ${HPL_DAT_FILE}" >&2
    echo "Provide an hpl.dat input deck before submitting this job." >&2
    echo "Example: sbatch --export=ALL,HPL_DAT_FILE=/path/to/hpl.dat ..." >&2
    exit 2
fi

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_OPENMPI:-openmpi/5}" \
    "${CHAPAR_MODULE_OPENBLAS:-openblas}" \
    "${CHAPAR_MODULE_HPL:-hpl}" \
    "${CHAPAR_MODULE_HPCG:-hpcg}" \
    "${CHAPAR_MODULE_STREAM:-stream}" \
    "${CHAPAR_MODULE_BABELSTREAM:-babelstream}"

# ── HPL: High-Performance LINPACK ──────────────────────────────
xhpl < "${HPL_DAT_FILE}" > "${RESULTS_DIR}/hpl.log" 2>&1

# ── HPCG: High-Performance Conjugate Gradient ──────────────────
hpcgbench \
    --nx="${HPCG_NX:-104}" \
    --ny="${HPCG_NY:-104}" \
    --nz="${HPCG_NZ:-104}" \
    --time="${HPCG_TIME:-60}" \
    > "${RESULTS_DIR}/hpcg.log" 2>&1

# ── STREAM: memory bandwidth ───────────────────────────────────
stream_c.exe > "${RESULTS_DIR}/stream.log" 2>&1

# ── HPL-AI: mixed-precision LINPACK ────────────────────────────

# ── BabelStream: multi-language memory bandwidth ───────────────
babelStream > "${RESULTS_DIR}/babelstream.log" 2>&1

echo "HPC-challenge results written to ${RESULTS_DIR}" >&2
