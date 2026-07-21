#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=4
#SBATCH --time=01:00:00
#SBATCH -J vlad-io
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
: "${IO_TEST_DIR:=${SCRATCH:-}}"
: "${IOR_BLOCK:=32g}"
: "${IOR_XFER:=4m}"
: "${MDTEST_FILES:=100000}"
H5BENCH_CFG="${H5BENCH_CFG:-}"
FIO_CFG="${FIO_CFG:-}"
: "${VLAD_RESULTS_DIR:=${SLURM_SUBMIT_DIR:-$PWD}/vlad_results/io_${SLURM_JOB_ID:-$$}}"

if [ -z "${IO_TEST_DIR}" ]; then
    echo "ERROR: IO_TEST_DIR is empty and \$SCRATCH is not set" >&2
    exit 1
fi

mkdir -p "${VLAD_RESULTS_DIR}"

# ── Environment ────────────────────────────────────────────────
module purge
module load openmpi ior mdtest h5bench fio

# ── IOR POSIX ──────────────────────────────────────────────────
echo "=== IOR POSIX ===" >&2
mpirun ior -a POSIX -w -r \
    -t "${IOR_XFER}" \
    -b "${IOR_BLOCK}" \
    -o "${VLAD_RESULTS_DIR}/ior_posix.log"

# ── IOR MPI-IO ─────────────────────────────────────────────────
echo "=== IOR MPI-IO ===" >&2
mpirun ior -a MPIIO -w -r \
    -t "${IOR_XFER}" \
    -b "${IOR_BLOCK}" \
    -o "${VLAD_RESULTS_DIR}/ior_mpiio.log"

# ── mdtest ─────────────────────────────────────────────────────
echo "=== mdtest ===" >&2
mpirun mdtest -n "${MDTEST_FILES}" -i 3 \
    -d "${IO_TEST_DIR}/mdtest_run" \
    > "${VLAD_RESULTS_DIR}/mdtest.log"

# ── h5bench (optional) ─────────────────────────────────────────
if [ -n "${H5BENCH_CFG:-}" ]; then
    echo "=== h5bench ===" >&2
    h5bench "${H5BENCH_CFG}" > "${VLAD_RESULTS_DIR}/h5bench.log" 2>&1
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
    > "${VLAD_RESULTS_DIR}/fio.log" 2>&1

echo "I/O results written to ${VLAD_RESULTS_DIR}" >&2
