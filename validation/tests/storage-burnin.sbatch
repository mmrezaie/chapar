#!/usr/bin/env bash
# DESCRIPTION: Bounded allowlisted storage burn-in with sentinel-owned cleanup
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:20:00
#SBATCH --job-name=storage-burnin

set -euo pipefail

usage() {
    printf '%s\n' 'Usage: storage-burnin.sbatch [--fixture invalid-target|controlled-smoke]'
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

require_uint() {
    local name="$1" maximum="$2" value="${!1}"
    if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( 10#${value} > maximum )); then
        fail "${name} must be an integer no greater than ${maximum}"
    fi
}

canonical_directory() {
    local directory="$1" canonical
    [ -n "${directory}" ] || fail 'directory is empty'
    [[ "${directory}" = /* ]] || fail "directory is not absolute: ${directory}"
    [ ! -L "${directory}" ] || fail "directory is a symlink: ${directory}"
    [ -d "${directory}" ] || fail "directory does not exist: ${directory}"
    [ -w "${directory}" ] || fail "directory is not writable: ${directory}"
    canonical="$(cd -P -- "${directory}" && pwd -P)"
    [ "${directory}" = "${canonical}" ] || fail "directory must not traverse symlinks: ${directory}"
    printf '%s\n' "${canonical}"
}

validate_target() {
    case "${STORAGE_BURNIN_TARGET:-}" in job-scratch) ;; *) fail 'STORAGE_BURNIN_TARGET must be the allowlisted logical target job-scratch'; return ;; esac
    [ "${VALIDATION_STORAGE_RESOLVED_TARGET:-}" = "${STORAGE_BURNIN_TARGET}" ] || { fail 'runner did not resolve STORAGE_BURNIN_TARGET through validation policy'; return; }
    [ "${VALIDATION_STORAGE_POLICY_RESOLVED:-}" = 1 ] || { fail 'runner storage-policy resolution marker is missing'; return; }
    [ "${VALIDATION_STORAGE_RESULTS_TARGET:-}" = managed-results ] || { fail 'runner must declare managed-results as the distinct result target'; return; }
    TARGET_ROOT="$(canonical_directory "${STORAGE_BURNIN_TARGET_ROOT:-}")" || return
    RESULTS_STORAGE_ROOT="$(canonical_directory "${VALIDATION_STORAGE_RESULTS_ROOT:-}")" || return
    RESULTS_ROOT_CANONICAL="$(canonical_directory "${RESULTS_ROOT}")" || return
    case "${TARGET_ROOT}/" in "${RESULTS_STORAGE_ROOT}/"*|"${RESULTS_ROOT_CANONICAL}/"*) fail 'benchmark target must not be inside results storage'; return ;; esac
    case "${RESULTS_STORAGE_ROOT}/" in "${TARGET_ROOT}/"*) fail 'results storage must not be inside benchmark target'; return ;; esac
}

load_limits() {
    STORAGE_BURNIN_MAX_BYTES="${STORAGE_BURNIN_MAX_BYTES:-536870912}"
    STORAGE_BURNIN_MIN_FREE_BYTES="${STORAGE_BURNIN_MIN_FREE_BYTES:-1073741824}"
    STORAGE_BURNIN_IOR_RANKS="${STORAGE_BURNIN_IOR_RANKS:-1}"
    STORAGE_BURNIN_IOR_BLOCK_BYTES="${STORAGE_BURNIN_IOR_BLOCK_BYTES:-67108864}"
    STORAGE_BURNIN_IOR_TRANSFER_BYTES="${STORAGE_BURNIN_IOR_TRANSFER_BYTES:-1048576}"
    STORAGE_BURNIN_MDTEST_FILES="${STORAGE_BURNIN_MDTEST_FILES:-1000}"
    STORAGE_BURNIN_FIO_BYTES="${STORAGE_BURNIN_FIO_BYTES:-67108864}"
    STORAGE_BURNIN_H5BENCH_BYTES="${STORAGE_BURNIN_H5BENCH_BYTES:-33554432}"
    require_uint STORAGE_BURNIN_MAX_BYTES 1099511627776
    require_uint STORAGE_BURNIN_MIN_FREE_BYTES 1099511627776
    require_uint STORAGE_BURNIN_IOR_RANKS 4
    require_uint STORAGE_BURNIN_IOR_BLOCK_BYTES 536870912
    require_uint STORAGE_BURNIN_IOR_TRANSFER_BYTES 67108864
    require_uint STORAGE_BURNIN_MDTEST_FILES 10000
    require_uint STORAGE_BURNIN_FIO_BYTES 536870912
    require_uint STORAGE_BURNIN_H5BENCH_BYTES 536870912
    (( STORAGE_BURNIN_IOR_RANKS >= 1 )) || fail 'STORAGE_BURNIN_IOR_RANKS must be at least one'
    (( STORAGE_BURNIN_IOR_TRANSFER_BYTES >= 1 && STORAGE_BURNIN_IOR_TRANSFER_BYTES <= STORAGE_BURNIN_IOR_BLOCK_BYTES )) || { fail 'IOR transfer bytes must be positive and no greater than the IOR block size'; return; }
    PLANNED_BYTES=$((2 * STORAGE_BURNIN_IOR_RANKS * STORAGE_BURNIN_IOR_BLOCK_BYTES + STORAGE_BURNIN_FIO_BYTES + STORAGE_BURNIN_H5BENCH_BYTES))
    (( PLANNED_BYTES <= STORAGE_BURNIN_MAX_BYTES )) || { fail "planned aggregate bytes ${PLANNED_BYTES} exceed STORAGE_BURNIN_MAX_BYTES"; return; }
    read -r TARGET_TOTAL_BYTES TARGET_FREE_BYTES < <(df -Pk -- "${TARGET_ROOT}" | awk 'NR == 2 {print $2 * 1024, $4 * 1024}')
    [[ "${TARGET_TOTAL_BYTES:-}" =~ ^[0-9]+$ && "${TARGET_FREE_BYTES:-}" =~ ^[0-9]+$ ]] || { fail 'cannot determine free space for benchmark target'; return; }
    (( TARGET_FREE_BYTES >= STORAGE_BURNIN_MIN_FREE_BYTES + PLANNED_BYTES )) || { fail 'benchmark target has insufficient free space for the bounded workload'; return; }
    TARGET_FILESYSTEM_TYPE="$(findmnt -n -o FSTYPE -T "${TARGET_ROOT}" 2>/dev/null || stat -f %T "${TARGET_ROOT}")"
    STORAGE_BURNIN_BASELINE_VERDICT="${STORAGE_BURNIN_BASELINE_VERDICT:-NOT_EVALUATED}"
    case "${STORAGE_BURNIN_BASELINE_VERDICT}" in PASS|WARN|FAIL|NOT_EVALUATED) ;; *) fail 'STORAGE_BURNIN_BASELINE_VERDICT must be PASS, WARN, FAIL, or NOT_EVALUATED' ;; esac
}

create_work_directory() {
    STORAGE_BURNIN_WORK_DIR="$(mktemp -d "${TARGET_ROOT}/chapar-storage-burnin.XXXXXX")"
    chmod 700 "${STORAGE_BURNIN_WORK_DIR}"
    [ ! -L "${STORAGE_BURNIN_WORK_DIR}" ] || fail 'generated benchmark directory is a symlink'
    [ "$(cd -P -- "$(dirname "${STORAGE_BURNIN_WORK_DIR}")" && pwd -P)" = "${TARGET_ROOT}" ] || { fail 'generated benchmark directory escaped the validated target root'; return; }
    STORAGE_BURNIN_SENTINEL="${STORAGE_BURNIN_WORK_DIR}/.chapar-storage-burnin-sentinel"
    STORAGE_BURNIN_SENTINEL_TOKEN="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    umask 077
    printf '%s\n' "${STORAGE_BURNIN_SENTINEL_TOKEN}" > "${STORAGE_BURNIN_SENTINEL}"
    [ -O "${STORAGE_BURNIN_SENTINEL}" ] || fail 'benchmark sentinel is not owned by the validation user'
}

cleanup_work_directory() {
    [ -n "${STORAGE_BURNIN_WORK_DIR:-}" ] || return 0
    [ -n "${TARGET_ROOT:-}" ] || return 1
    [ -d "${STORAGE_BURNIN_WORK_DIR}" ] && [ ! -L "${STORAGE_BURNIN_WORK_DIR}" ] || return 1
    [[ "$(basename "${STORAGE_BURNIN_WORK_DIR}")" = chapar-storage-burnin.* ]] || return 1
    [ "$(cd -P -- "$(dirname "${STORAGE_BURNIN_WORK_DIR}")" && pwd -P)" = "${TARGET_ROOT}" ] || return 1
    [ -f "${STORAGE_BURNIN_SENTINEL:-}" ] && [ ! -L "${STORAGE_BURNIN_SENTINEL}" ] && [ -O "${STORAGE_BURNIN_SENTINEL}" ] || return 1
    [ "$(<"${STORAGE_BURNIN_SENTINEL}")" = "${STORAGE_BURNIN_SENTINEL_TOKEN:-}" ] || return 1
    rm -rf -- "${STORAGE_BURNIN_WORK_DIR}"
    STORAGE_BURNIN_WORK_DIR=""
}

finalize_with_cleanup() {
    local status="$1"
    trap - EXIT
    if ! cleanup_work_directory; then status=1; validation_set_verdict FAIL 'guarded cleanup refused the generated benchmark directory'; fi
    validation_result_finalize "${status}"
}

stage_h5bench_config() {
    local template="${STORAGE_BURNIN_H5BENCH_CONFIG_TEMPLATE:-}"
    [ -n "${template}" ] || fail 'STORAGE_BURNIN_H5BENCH_CONFIG_TEMPLATE is required for bounded h5bench'
    [ -f "${template}" ] && [ ! -L "${template}" ] || fail 'h5bench config template must be a regular non-symlink file'
    STORAGE_BURNIN_H5BENCH_CONFIG="${STORAGE_BURNIN_WORK_DIR}/h5bench.conf"
    python3 - "${template}" "${STORAGE_BURNIN_H5BENCH_CONFIG}" "${STORAGE_BURNIN_WORK_DIR}" "${STORAGE_BURNIN_H5BENCH_BYTES}" <<'PY'
from pathlib import Path
import sys

template = Path(sys.argv[1])
destination = Path(sys.argv[2])
work_dir = sys.argv[3]
max_bytes = sys.argv[4]
text = template.read_text(encoding="utf-8")
if "@WORK_DIR@" not in text or "@MAX_BYTES@" not in text:
    raise SystemExit("h5bench template must contain @WORK_DIR@ and @MAX_BYTES@ placeholders")
if ".." in text:
    raise SystemExit("h5bench template may not contain parent-directory traversal")
destination.write_text(text.replace("@WORK_DIR@", work_dir).replace("@MAX_BYTES@", max_bytes), encoding="utf-8")
PY
    [ ! -L "${STORAGE_BURNIN_H5BENCH_CONFIG}" ] || fail 'staged h5bench config became a symlink'
}

run_benchmarks() {
    local command
    for command in mpirun ior mdtest h5bench fio; do command -v "${command}" >/dev/null || validation_resource_unavailable "required command is unavailable: ${command}" mandatory; done
    : > "${STORAGE_BURNIN_IO_SENTINEL:-/dev/null}"
    stage_h5bench_config
    mpirun -np "${STORAGE_BURNIN_IOR_RANKS}" ior -a POSIX -w -r -t "${STORAGE_BURNIN_IOR_TRANSFER_BYTES}" -b "${STORAGE_BURNIN_IOR_BLOCK_BYTES}" -o "${STORAGE_BURNIN_WORK_DIR}/ior-posix" > "${RESULTS_DIR}/ior-posix.log" 2>&1
    mpirun -np "${STORAGE_BURNIN_IOR_RANKS}" ior -a MPIIO -w -r -t "${STORAGE_BURNIN_IOR_TRANSFER_BYTES}" -b "${STORAGE_BURNIN_IOR_BLOCK_BYTES}" -o "${STORAGE_BURNIN_WORK_DIR}/ior-mpiio" > "${RESULTS_DIR}/ior-mpiio.log" 2>&1
    mpirun -np "${STORAGE_BURNIN_IOR_RANKS}" mdtest -n "${STORAGE_BURNIN_MDTEST_FILES}" -i 1 -d "${STORAGE_BURNIN_WORK_DIR}/mdtest" > "${RESULTS_DIR}/mdtest.log" 2>&1
    (cd -- "${STORAGE_BURNIN_WORK_DIR}"; h5bench --date "${STORAGE_BURNIN_H5BENCH_CONFIG}") > "${RESULTS_DIR}/h5bench.log" 2>&1
    mkdir -p "${STORAGE_BURNIN_WORK_DIR}/fio"
    fio --name=bounded-write --rw=write --bs=1m --iodepth=4 --direct=1 --size="${STORAGE_BURNIN_FIO_BYTES}" --verify=crc32c --do_verify=1 --directory="${STORAGE_BURNIN_WORK_DIR}/fio" --output-format=json > "${RESULTS_DIR}/fio.json" 2>&1
    case "${STORAGE_BURNIN_ELBENCHO_MODE:-optional}" in
        disabled) ;;
        optional) command -v elbencho >/dev/null && elbencho --version > "${RESULTS_DIR}/elbencho.log" 2>&1 || true ;;
        mandatory) command -v elbencho >/dev/null || validation_resource_unavailable 'site declared Elbencho mandatory but it is unavailable' mandatory; elbencho --version > "${RESULTS_DIR}/elbencho.log" 2>&1 ;;
        *) fail 'STORAGE_BURNIN_ELBENCHO_MODE must be disabled, optional, or mandatory' ;;
    esac
}

write_evidence() {
    export STORAGE_BURNIN_EVIDENCE_TARGET="${STORAGE_BURNIN_TARGET}" STORAGE_BURNIN_EVIDENCE_FILESYSTEM="${TARGET_FILESYSTEM_TYPE}" STORAGE_BURNIN_EVIDENCE_TOTAL_BYTES="${TARGET_TOTAL_BYTES}" STORAGE_BURNIN_EVIDENCE_FREE_BYTES="${TARGET_FREE_BYTES}" STORAGE_BURNIN_EVIDENCE_PLANNED_BYTES="${PLANNED_BYTES}" STORAGE_BURNIN_EVIDENCE_MDTEST_FILES="${STORAGE_BURNIN_MDTEST_FILES}" STORAGE_BURNIN_EVIDENCE_RESULTS_DIR="${RESULTS_DIR}" STORAGE_BURNIN_EVIDENCE_NODE="${node}" STORAGE_BURNIN_EVIDENCE_BASELINE="${STORAGE_BURNIN_BASELINE_VERDICT}"
    python3 - <<'PY'
import json, os, re
from pathlib import Path

results = Path(os.environ["STORAGE_BURNIN_EVIDENCE_RESULTS_DIR"])
def ior_mibps(name):
    values = [float(value) for value in re.findall(r"(?:Max Write|Max Read):\s*([0-9.]+)\s+MiB", (results / name).read_text(encoding="utf-8", errors="replace"))]
    return max(values, default=0.0)
def mdtest_ops():
    values = [float(value) for value in re.findall(r"([0-9.]+)\s+(?:ops|items)/sec", (results / "mdtest.log").read_text(encoding="utf-8", errors="replace"))]
    return max(values, default=0.0)
def fio_mibps():
    payload = json.loads((results / "fio.json").read_text(encoding="utf-8"))
    return max((job.get(operation, {}).get("bw_bytes", 0) for job in payload.get("jobs", []) for operation in ("read", "write")), default=0) / (1024 * 1024)
payload = {"target": os.environ["STORAGE_BURNIN_EVIDENCE_TARGET"], "node": os.environ["STORAGE_BURNIN_EVIDENCE_NODE"], "filesystem_type": os.environ["STORAGE_BURNIN_EVIDENCE_FILESYSTEM"], "target_total_bytes": int(os.environ["STORAGE_BURNIN_EVIDENCE_TOTAL_BYTES"]), "target_free_bytes": int(os.environ["STORAGE_BURNIN_EVIDENCE_FREE_BYTES"]), "planned_aggregate_bytes": int(os.environ["STORAGE_BURNIN_EVIDENCE_PLANNED_BYTES"]), "mdtest_files": int(os.environ["STORAGE_BURNIN_EVIDENCE_MDTEST_FILES"]), "baseline_verdict": os.environ["STORAGE_BURNIN_EVIDENCE_BASELINE"], "ior_posix_mibps": ior_mibps("ior-posix.log"), "ior_mpiio_mibps": ior_mibps("ior-mpiio.log"), "mdtest_ops_per_second": mdtest_ops(), "fio_mibps": fio_mibps(), "elbencho": "present" if (results / "elbencho.log").exists() else "not-run"}
(results / "storage-burnin.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
lines = ["# HELP chapar_storage_burnin_target_free_bytes Free bytes before bounded storage validation", "# TYPE chapar_storage_burnin_target_free_bytes gauge", f'chapar_storage_burnin_target_free_bytes{{target="{payload["target"]}"}} {payload["target_free_bytes"]}', "# HELP chapar_storage_burnin_target_total_bytes Total bytes at the benchmark target", "# TYPE chapar_storage_burnin_target_total_bytes gauge", f'chapar_storage_burnin_target_total_bytes{{target="{payload["target"]}"}} {payload["target_total_bytes"]}']
for metric in ("ior_posix_mibps", "ior_mpiio_mibps", "mdtest_ops_per_second", "fio_mibps"):
    lines.extend((f"# TYPE chapar_storage_burnin_{metric} gauge", f'chapar_storage_burnin_{metric}{{target="{payload["target"]}",node="{payload["node"]}"}} {payload[metric]}'))
baseline_code = {"PASS": 0, "WARN": 1, "FAIL": 2, "NOT_EVALUATED": -1}[payload["baseline_verdict"]]
lines.extend(("# TYPE chapar_storage_burnin_baseline_verdict gauge", f'chapar_storage_burnin_baseline_verdict{{target="{payload["target"]}"}} {baseline_code}'))
(results / "storage-burnin.prom").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

run_fixture() {
    local fixture="$1" temporary target_root results_root keep_file io_marker work_directory
    temporary="$(mktemp -d)"
    trap "rm -rf -- \"${temporary}\"" EXIT
    target_root="${temporary}/job-scratch"
    results_root="${temporary}/managed-results"
    mkdir -p "${target_root}" "${results_root}"
    case "${fixture}" in
        invalid-target)
            io_marker="${temporary}/io-attempted"
            if STORAGE_BURNIN_TARGET=managed-results VALIDATION_STORAGE_RESOLVED_TARGET=managed-results VALIDATION_STORAGE_POLICY_RESOLVED=1 VALIDATION_STORAGE_RESULTS_TARGET=managed-results STORAGE_BURNIN_TARGET_ROOT="${target_root}" VALIDATION_STORAGE_RESULTS_ROOT="${results_root}" RESULTS_ROOT="${results_root}" STORAGE_BURNIN_IO_SENTINEL="${io_marker}" validate_target; then fail 'fixture accepted a non-allowlisted storage target'; fi
            [ ! -e "${io_marker}" ] || fail 'fixture reached benchmark I/O after target validation failed'
            printf '%s\n' 'fixture invalid-target: rejected before I/O'
            ;;
        controlled-smoke)
            keep_file="${target_root}/keep"
            printf '%s\n' keep > "${keep_file}"
            STORAGE_BURNIN_TARGET=job-scratch
            VALIDATION_STORAGE_RESOLVED_TARGET=job-scratch
            VALIDATION_STORAGE_POLICY_RESOLVED=1
            VALIDATION_STORAGE_RESULTS_TARGET=managed-results
            STORAGE_BURNIN_TARGET_ROOT="${target_root}"
            VALIDATION_STORAGE_RESULTS_ROOT="${results_root}"
            RESULTS_ROOT="${results_root}"
            validate_target
            create_work_directory
            printf '%s\n' payload > "${STORAGE_BURNIN_WORK_DIR}/payload"
            work_directory="${STORAGE_BURNIN_WORK_DIR}"
            cleanup_work_directory
            [ -e "${keep_file}" ] || fail 'fixture cleanup removed content outside its sentinel-owned directory'
            [ ! -e "${work_directory}" ] || fail 'fixture cleanup retained its sentinel-owned directory'
            printf '%s\n' 'fixture controlled-smoke: removed only sentinel-owned directory'
            ;;
        *) usage; return 2 ;;
    esac
}

if [ "${1:-}" = --fixture ]; then
    [ "$#" = 2 ] || { usage; exit 2; }
    run_fixture "$2"
    exit 0
fi
[ "$#" = 0 ] || { usage; exit 2; }

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node="${SLURM_NODELIST:-$(hostname -s)}"
RESULTS_ROOT="${RESULTS_ROOT:-${validation_dir}/results}"
source "${validation_dir}/lib/verdict.sh"
source "${validation_dir}/lib/result-manifest.sh"
validation_result_init storage-burnin "${RESULTS_ROOT}" "${node}"
RESULTS_DIR="${VALIDATION_NODE_DIR}"
validate_target
load_limits
create_work_directory
trap 'finalize_with_cleanup "$?"' EXIT
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then module purge; fi
module load "${CHAPAR_MODULE_OPENMPI:-openmpi/5}" "${CHAPAR_MODULE_IOR:-ior}" "${CHAPAR_MODULE_MDTEST:-mdtest}" "${CHAPAR_MODULE_H5BENCH:-h5bench}" "${CHAPAR_MODULE_FIO:-fio}"
run_benchmarks
write_evidence
case "${STORAGE_BURNIN_BASELINE_VERDICT}" in
    WARN) validation_set_verdict WARN 'configured storage baseline is warning' ;;
    FAIL) validation_threshold_violation 'configured storage baseline failed' ;;
esac
printf 'Storage burn-in evidence written to %s\n' "${RESULTS_DIR}" >&2
