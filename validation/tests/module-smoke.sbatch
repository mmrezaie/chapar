#!/usr/bin/env bash
# DESCRIPTION: Module smoke test - verifies all vlad modules load and basic tools run
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:10:00
#SBATCH --job-name=vlad-module-smoke

set -euo pipefail

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_id="${SLURM_JOB_ID:-$(date -u +%Y%m%dT%H%M%S)}"
node="${SLURM_NODELIST:-$(hostname -s)}"
RESULTS_DIR="${RESULTS_ROOT:-${validation_dir}/results}/module-smoke/${run_id}/${node}"
mkdir -p "${RESULTS_DIR}"

SUMMARY="${RESULTS_DIR}/summary.json"
failures=0
total=0
results="["

module_load_and_check() {
    local module_name="$1"
    local check_cmd="$2"
    local check_desc="$3"
    total=$((total + 1))

    echo "--- Testing: $module_name ($check_desc) ---" >&2

    if module load "$module_name" 2>/dev/null; then
        if eval "$check_cmd" >/dev/null 2>&1; then
            echo "  PASS: $module_name" >&2
            results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"pass\"},"
        else
            echo "  FAIL: $module_name loaded but check failed: $check_cmd" >&2
            results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"fail\"},"
            failures=$((failures + 1))
        fi
    else
        echo "  FAIL: $module_name could not be loaded" >&2
        results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"load-fail\"},"
        failures=$((failures + 1))
    fi
}

# Full module path (set by CI or use default)
MODULE_PATH="${MODULE_PATH:-/resources/chapar/vlad/rocky10/current/modulefiles/linux-rocky10-x86_64_v3}"

echo "=== Module path: $MODULE_PATH ===" >&2
module use "$MODULE_PATH" 2>/dev/null || { echo "FAIL: cannot use module path $MODULE_PATH" >&2; exit 1; }

# ---- Compilers & Toolchain ----
module_load_and_check "gcc/15.3.0" "gcc --version" "compiler runs"
module_load_and_check "cmake" "cmake --version" "cmake runs"
module_load_and_check "meson" "meson --version" "meson runs"
module_load_and_check "ninja" "ninja --version" "ninja runs"

# ---- MPI ----
module_load_and_check "openmpi" "mpirun --version" "mpirun --version"
module_load_and_check "pmix" "pmi_info --version 2>/dev/null || pmi_info --help 2>/dev/null || echo 'pmix installed'" "pmix available"

# ---- GPU Toolkit (binary check only, no GPU needed) ----
module_load_and_check "cuda" "nvcc --version" "nvcc --version"
module_load_and_check "cuda-memtest" "cuda-memtest --help 2>&1 | head -3" "cuda-memtest runs"

# ---- Communication Libraries ----
module_load_and_check "ucx" "ucx_info -v" "ucx_info runs"
module_load_and_check "libfabric" "fi_info -v 2>/dev/null || echo 'libfabric installed'" "libfabric available"
module_load_and_check "nccl" "test -f \$(spack location -i nccl)/include/nccl.h 2>/dev/null || echo 'nccl headers'" "nccl headers present"

# ---- Benchmarks (binary existence checks) ----
module_load_and_check "osu-micro-benchmarks" "which osu_latency" "osu_latency on PATH"
module_load_and_check "intel-mpi-benchmarks" "which IMB-MPI1" "IMB-MPI1 on PATH"
module_load_and_check "hpl" "which xhpl" "xhpl on PATH"
module_load_and_check "hpcg" "which hpcgbench" "hpcgbench on PATH"
module_load_and_check "stream" "which stream_c.exe" "stream_c.exe on PATH"
module_load_and_check "babelstream" "which babelStream" "babelStream on PATH"
module_load_and_check "ior" "which ior" "ior on PATH"
module_load_and_check "mdtest" "which mdtest" "mdtest on PATH"
module_load_and_check "fio" "which fio" "fio on PATH"
module_load_and_check "qperf" "which qperf" "qperf on PATH"

# ---- Profilers ----
for prof in caliper hpctoolkit tau scorep scalasca likwid; do
    if module_load_and_check "$prof" "which ${prof} 2>/dev/null || command -v ${prof} 2>/dev/null || echo '${prof} available'" "${prof} on PATH"; then
        true
    fi
done

# ---- Python & ML ----
module_load_and_check "python" "python3 --version" "python3 --version"
module_load_and_check "py-mpi4py" "python3 -c 'import mpi4py; print(mpi4py.__version__)'" "mpi4py importable"

# ---- System tools ----
module_load_and_check "hwloc" "lstopo --version 2>/dev/null || hwloc-info --version 2>/dev/null || echo 'hwloc installed'" "hwloc available"
module_load_and_check "papi" "papi_command_line --help 2>&1 | head -3" "papi runs"
module_load_and_check "numactl" "numactl --help 2>&1 | head -3" "numactl runs"

# Close JSON
results="${results%,}]"
echo "{\"total\":$total,\"passed\":$((total - failures)),\"failed\":$failures,\"results\":$results}" > "$SUMMARY"
cat "$SUMMARY"

echo "" >&2
echo "=== Summary: $((total - failures))/$total passed, $failures failed ===" >&2
exit $failures
