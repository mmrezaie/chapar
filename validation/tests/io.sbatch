#!/bin/bash
# DESCRIPTION: POSIX and MPI-IO I/O validation (IOR, mdtest, h5bench, fio)
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=4
#SBATCH --time=01:00:00
#SBATCH -J vlad-io
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
source "${VALIDATION_DIR}/lib/verdict.sh"
source "${VALIDATION_DIR}/lib/result-manifest.sh"
validation_result_init io "${RESULTS_ROOT}" "${node}"
RESULTS_DIR="${VALIDATION_NODE_DIR}"

# ── Runtime knobs ──────────────────────────────────────────────
: "${IO_TEST_DIR:=${SCRATCH:-}}"
: "${IOR_BLOCK:=32g}"
: "${IOR_XFER:=4m}"
: "${MDTEST_FILES:=100000}"
H5BENCH_CFG="${H5BENCH_CFG:-}"
FIO_CFG="${FIO_CFG:-}"

if [ -z "${IO_TEST_DIR}" ]; then
    echo "ERROR: IO_TEST_DIR is empty and \$SCRATCH is not set" >&2
    validation_resource_unavailable "IO_TEST_DIR is empty and SCRATCH is not set" mandatory
fi

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_OPENMPI:-openmpi/5}" \
    "${CHAPAR_MODULE_IOR:-ior}" \
    "${CHAPAR_MODULE_MDTEST:-mdtest}" \
    "${CHAPAR_MODULE_H5BENCH:-h5bench}" \
    "${CHAPAR_MODULE_FIO:-fio}"

# ── IOR POSIX ──────────────────────────────────────────────────
echo "=== IOR POSIX ===" >&2
mpirun ior -a POSIX -w -r \
    -t "${IOR_XFER}" \
    -b "${IOR_BLOCK}" \
    -o "${RESULTS_DIR}/ior_posix.log"

# ── IOR MPI-IO ─────────────────────────────────────────────────
echo "=== IOR MPI-IO ===" >&2
mpirun ior -a MPIIO -w -r \
    -t "${IOR_XFER}" \
    -b "${IOR_BLOCK}" \
    -o "${RESULTS_DIR}/ior_mpiio.log"

# ── mdtest ─────────────────────────────────────────────────────
echo "=== mdtest ===" >&2
mpirun mdtest -n "${MDTEST_FILES}" -i 3 \
    -d "${IO_TEST_DIR}/mdtest_run" \
    > "${RESULTS_DIR}/mdtest.log"

# ── h5bench (optional) ─────────────────────────────────────────
if [ -n "${H5BENCH_CFG:-}" ]; then
    echo "=== h5bench ===" >&2
    h5bench "${H5BENCH_CFG}" > "${RESULTS_DIR}/h5bench.log" 2>&1
else
    echo "H5BENCH_CFG not set — skipping h5bench" >&2
fi

# ── fio ────────────────────────────────────────────────────────
echo "=== fio ===" >&2
fio --direct=1 \
    --name=test \
    --rw=randread \
    --bs=4k \
    --iodepth=64 \
    --size=1G \
    --loop=3 \
    --directory="${IO_TEST_DIR}" \
    > "${RESULTS_DIR}/fio.log" 2>&1

echo "I/O results written to ${RESULTS_DIR}" >&2
