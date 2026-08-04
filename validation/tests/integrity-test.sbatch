#!/usr/bin/env bash
# DESCRIPTION: Integrity validation - verify all modules load and basic tools run (env-agnostic)
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:10:00
#SBATCH --job-name=integrity-test

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
    OS_NAME="${OS_NAME:-$(. /etc/os-release 2>/dev/null && echo "${ID}${VERSION_ID%%.*}")}"
    case "$ENV_NAME" in
        vlad|hpcsim)
            BASE="/resources/chapar/${ENV_NAME}/${OS_NAME:-ubuntu24.04}"
            # New layout: <base>/<arch>/current -> releases/<id>; the highest
            # promoted arch wins. Fall back to the legacy <base>/current, then
            # to the newest unpromoted release in either layout.
            for arch_root in "$BASE"/linux-*; do
                [ -e "$arch_root/current/modulefiles" ] && MODULE_PATH="$arch_root/current/modulefiles"
            done
            if [ -z "$MODULE_PATH" ] && [ -L "$BASE/current" ]; then
                MODULE_PATH="$BASE/current/modulefiles"
            fi
            if [ -z "$MODULE_PATH" ]; then
                latest=$(ls -td "$BASE"/linux-*/releases/*/ "$BASE"/releases/*/ 2>/dev/null | head -1)
                [ -n "$latest" ] && MODULE_PATH="${latest%/}/modulefiles"
            fi
            if [ -n "$MODULE_PATH" ] && [ -d "$MODULE_PATH" ]; then
                # Pick the highest architecture module dir (matches release.sh
                # multi-arch promotion behavior); do not assume a fixed target.
                # Directories only: modulefiles/ also holds files such as
                # module-index.yaml.
                arch_dir=$(find "$MODULE_PATH/" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' -printf '%f\n' 2>/dev/null | sort | tail -1)
                if [ -z "$arch_dir" ]; then
                    arch_dir=$(find "$MODULE_PATH/" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -1)
                fi
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
        check "gcc"               "gcc --version"            "compiler runs"
        check "cmake"             "cmake --version"          "cmake runs"
        check "openmpi"           "mpirun --version"         "mpirun --version"
        check "cuda"              "nvcc --version"           "nvcc --version"
        check "cuda-memtest"      "which cuda_memtest"       "cuda_memtest on PATH"
        check "ucx"               "ucx_info -v"              "ucx_info runs"
        check "libfabric"         "command -v fi_info"   "libfabric available"
        check "nccl"              "bash -c 'IFS=:; for d in \${CMAKE_PREFIX_PATH:-}; do compgen -G \"\$d/lib*/libnccl.so*\" >/dev/null && exit 0; done; exit 1'" "libnccl under module prefix"
        check "osu-micro-benchmarks" "which osu_latency"     "osu_latency on PATH"
        check "hpl"               "which xhpl"               "xhpl on PATH"
        check "hpcg"              "which hpcg 2>/dev/null || which xhpcg 2>/dev/null || which hpcgbench" "hpcg binary"
        check "stream"            "which stream_c.exe"       "stream on PATH"
        check "babelstream"       "module show babelstream 2>/dev/null || module show babelStream 2>/dev/null" "babelstream module"
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
        check "libfabric"         "command -v fi_info"   "libfabric available"
        check "osu-micro-benchmarks" "which osu_latency"     "osu_latency on PATH"
        check "hpl"               "which xhpl"               "xhpl on PATH"
        check "hpcg"              "which hpcg 2>/dev/null || which xhpcg" "hpcg binary"
        check "stream"            "which stream_c.exe"       "stream on PATH"
        check "babelstream"       "module show babelstream 2>/dev/null || module show babelStream 2>/dev/null" "babelstream module"
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
