#!/usr/bin/env bash
# DESCRIPTION: Integrity validation - verify all modules load and basic tools run (env-agnostic)
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:10:00
#SBATCH --job-name=integrity-${ENV_NAME:-unknown}

set -euo pipefail

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${ENV_NAME:-}"
MODULE_PATH="${MODULE_PATH:-}"
run_id="${SLURM_JOB_ID:-$(date -u +%Y%m%dT%H%M%S)}"
node="${SLURM_NODELIST:-$(hostname -s)}"
RESULTS_DIR="${RESULTS_ROOT:-${validation_dir}/results}/integrity-${ENV_NAME}/${run_id}/${node}"
mkdir -p "${RESULTS_DIR}"

SUMMARY="${RESULTS_DIR}/summary.json"
failures=0
total=0
results="["

# ---- Resolve module path ----
if [ -z "$MODULE_PATH" ]; then
    case "$ENV_NAME" in
        vlad|hpcsim)
            BASE="/resources/chapar/${ENV_NAME}/rocky10"
            if [ -L "$BASE/current" ]; then
                MODULE_PATH="$BASE/current/modulefiles"
            elif [ -d "$BASE/releases" ]; then
                latest=$(ls -t "$BASE/releases" 2>/dev/null | head -1)
                [ -n "$latest" ] && MODULE_PATH="$BASE/releases/$latest/modulefiles"
            fi
            if [ -n "$MODULE_PATH" ] && [ -d "$MODULE_PATH" ]; then
                arch_dir=$(ls "$MODULE_PATH" 2>/dev/null | grep "x86_64_v3" | head -1)
                [ -n "$arch_dir" ] && MODULE_PATH="$MODULE_PATH/$arch_dir"
            fi
            ;;
        *)
            echo "ERROR: Unknown env '$ENV_NAME'. Set MODULE_PATH or ENV_NAME." >&2
            exit 1
            ;;
    esac
fi

if [ ! -d "${MODULE_PATH:-}" ]; then
    echo "FAIL: Module path not found: $MODULE_PATH" >&2
    exit 1
fi

module use "$MODULE_PATH"
echo "=== $ENV_NAME integrity validation ===" >&2
echo "Module path: $MODULE_PATH" >&2

check() {
    local module_name="$1"
    local check_cmd="$2"
    local check_desc="$3"
    total=$((total + 1))

    echo -n "  $module_name ... " >&2
    if module load "$module_name" 2>/dev/null; then
        if eval "$check_cmd" >/dev/null 2>&1; then
            echo "PASS" >&2
            results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"pass\"},"
        else
            echo "FAIL (check: $check_cmd)" >&2
            results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"fail\"},"
            failures=$((failures + 1))
        fi
    else
        echo "FAIL (load failed)" >&2
        results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"load-fail\"},"
        failures=$((failures + 1))
    fi
}

# ---- Tests by environment ----
case "$ENV_NAME" in
    vlad)
        check "gcc/15.3.0"       "gcc --version"            "compiler runs"
        check "cmake"             "cmake --version"          "cmake runs"
        check "openmpi"           "mpirun --version"         "mpirun --version"
        check "cuda"              "nvcc --version"           "nvcc --version"
        check "cuda-memtest"      "which cuda_memtest"       "cuda_memtest on PATH"
        check "ucx"               "ucx_info -v"              "ucx_info runs"
        check "libfabric"         "fi_info --version 2>/dev/null || fi_info -v 2>/dev/null"   "libfabric available"
        check "nccl"              "test -f \$(spack location -i nccl)/include/nccl.h 2>/dev/null || echo nccl" "nccl headers"
        check "osu-micro-benchmarks" "which osu_latency"     "osu_latency on PATH"
        check "hpl"               "which xhpl"               "xhpl on PATH"
        check "hpcg"              "which hpcg 2>/dev/null || which xhpcg 2>/dev/null || which hpcgbench" "hpcg binary"
        check "stream"            "which stream_c.exe"       "stream on PATH"
        check "babelstream"       "which babelStream 2>/dev/null || which babelstream 2>/dev/null || which BabelStream 2>/dev/null" "babelstream on PATH"
        check "ior"               "which ior"               "ior on PATH"
        check "mdtest"            "which mdtest"             "mdtest on PATH"
        check "fio"               "which fio"                "fio on PATH"
        check "qperf"             "which qperf"              "qperf on PATH"
        check "python"            "python3 --version"        "python3 --version"
        check "py-mpi4py"         "python3 -c 'import mpi4py; print(mpi4py.__version__)'" "mpi4py importable"
        check "hwloc"             "lstopo --version 2>/dev/null || hwloc-info --version" "hwloc available"
        check "papi"              "which papi_command_line"  "papi on PATH"
        check "numactl"           "which numactl"            "numactl on PATH"
        check "likwid"            "which likwid-perfctr"     "likwid on PATH"
        check "caliper"           "which cali-query 2>/dev/null" "caliper on PATH"
        check "hpctoolkit"        "which hpcrun 2>/dev/null"     "hpctoolkit on PATH"
        check "tau"               "which tau_exec 2>/dev/null"   "tau on PATH"
        check "scalasca"          "which scalasca 2>/dev/null || which scout 2>/dev/null" "scalasca on PATH"
        ;;
    hpcsim)
        check "gcc"               "gcc --version"            "compiler runs"
        check "cmake"             "cmake --version"          "cmake runs"
        check "openmpi"           "mpirun --version"         "mpirun --version"
        check "cuda"              "nvcc --version"           "nvcc --version"
        check "ucx"               "ucx_info -v"              "ucx_info runs"
        check "libfabric"         "fi_info --version 2>/dev/null || fi_info -v 2>/dev/null"   "libfabric available"
        check "osu-micro-benchmarks" "which osu_latency"     "osu_latency on PATH"
        check "hpl"               "which xhpl"               "xhpl on PATH"
        check "hpcg"              "which hpcg 2>/dev/null || which xhpcg" "hpcg binary"
        check "stream"            "which stream_c.exe"       "stream on PATH"
        check "babelstream"       "which babelStream 2>/dev/null || which babelstream 2>/dev/null || which BabelStream 2>/dev/null" "babelstream on PATH"
        check "ior"               "which ior"                "ior on PATH"
        check "mdtest"            "which mdtest"             "mdtest on PATH"
        check "fio"               "which fio"                "fio on PATH"
        check "python"            "python3 --version"        "python3 --version"
        check "hwloc"             "lstopo --version 2>/dev/null || hwloc-info --version" "hwloc"
        check "numactl"           "which numactl"            "numactl on PATH"
        check "caliper"           "which cali-query 2>/dev/null" "caliper on PATH"
        check "hpctoolkit"        "which hpcrun 2>/dev/null"     "hpctoolkit on PATH"
        check "tau"               "which tau_exec 2>/dev/null"   "tau on PATH"
        ;;
esac

results="${results%,}]"
echo "{\"env\":\"$ENV_NAME\",\"total\":$total,\"passed\":$((total - failures)),\"failed\":$failures,\"results\":$results}" > "$SUMMARY"
cat "$SUMMARY"

echo "" >&2
echo "=== $ENV_NAME integrity: $((total - failures))/$total passed, $failures failed ===" >&2
exit $failures
