#!/usr/bin/env bash
# DESCRIPTION: Runner-resolved mounted-filesystem identity and cross-rank correctness before bounded storage burn-in
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:25:00
#SBATCH --job-name=vast-validation

set -euo pipefail

usage() {
    printf '%s\n' 'Usage: vast.sbatch [--fixture validation/fixtures/storage/<case>]'
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
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
    case "${VAST_STORAGE_TARGET:-}" in job-scratch) ;; *) fail 'VAST_STORAGE_TARGET must be the allowlisted logical target job-scratch'; return ;; esac
    [ "${VALIDATION_STORAGE_RESOLVED_TARGET:-}" = "${VAST_STORAGE_TARGET}" ] || { fail 'runner did not resolve VAST_STORAGE_TARGET through validation policy'; return; }
    [ "${VALIDATION_STORAGE_POLICY_RESOLVED:-}" = 1 ] || { fail 'runner storage-policy resolution marker is missing'; return; }
    [ "${VALIDATION_STORAGE_RESULTS_TARGET:-}" = managed-results ] || { fail 'runner must declare managed-results as the distinct result target'; return; }
    TARGET_ROOT="$(canonical_directory "${VAST_STORAGE_TARGET_ROOT:-}")" || return
    RESULTS_STORAGE_ROOT="$(canonical_directory "${VALIDATION_STORAGE_RESULTS_ROOT:-}")" || return
    RESULTS_ROOT_CANONICAL="$(canonical_directory "${RESULTS_ROOT}")" || return
    case "${TARGET_ROOT}/" in "${RESULTS_STORAGE_ROOT}/"*|"${RESULTS_ROOT_CANONICAL}/"*) fail 'mounted-filesystem target must not be inside results storage'; return ;; esac
    case "${RESULTS_STORAGE_ROOT}/" in "${TARGET_ROOT}/"*) fail 'results storage must not be inside mounted-filesystem target'; return ;; esac
}

create_work_directory() {
    VAST_WORK_DIR="$(mktemp -d "${TARGET_ROOT}/chapar-vast.XXXXXX")"
    chmod 700 "${VAST_WORK_DIR}"
    [ ! -L "${VAST_WORK_DIR}" ] || fail 'generated VAST directory is a symlink'
    [ "$(cd -P -- "$(dirname "${VAST_WORK_DIR}")" && pwd -P)" = "${TARGET_ROOT}" ] || { fail 'generated VAST directory escaped the validated target root'; return; }
    VAST_SENTINEL="${VAST_WORK_DIR}/.chapar-vast-sentinel"
    VAST_SENTINEL_TOKEN="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    umask 077
    printf '%s\n' "${VAST_SENTINEL_TOKEN}" > "${VAST_SENTINEL}"
    [ -O "${VAST_SENTINEL}" ] || fail 'VAST sentinel is not owned by the validation user'
}

cleanup_work_directory() {
    [ -n "${VAST_WORK_DIR:-}" ] || return 0
    [ -n "${TARGET_ROOT:-}" ] || return 1
    [ -d "${VAST_WORK_DIR}" ] && [ ! -L "${VAST_WORK_DIR}" ] || return 1
    [[ "$(basename "${VAST_WORK_DIR}")" = chapar-vast.* ]] || return 1
    [ "$(cd -P -- "$(dirname "${VAST_WORK_DIR}")" && pwd -P)" = "${TARGET_ROOT}" ] || return 1
    [ -f "${VAST_SENTINEL:-}" ] && [ ! -L "${VAST_SENTINEL}" ] && [ -O "${VAST_SENTINEL}" ] || return 1
    [ "$(<"${VAST_SENTINEL}")" = "${VAST_SENTINEL_TOKEN:-}" ] || return 1
    rm -rf -- "${VAST_WORK_DIR}"
    VAST_WORK_DIR=""
}

finalize_with_cleanup() {
    local status="$1"
    trap - EXIT
    if ! cleanup_work_directory; then status=1; validation_set_verdict FAIL 'guarded cleanup refused the generated VAST directory'; fi
    validation_result_finalize "${status}"
}

rank_check() {
    local work_dir="$1" rank="${SLURM_PROCID:?SLURM_PROCID is required for rank check}" total="${VAST_RANKS:?VAST_RANKS is required for rank check}" marker="${work_dir}/namespace-marker" deadline
    [ -d "${work_dir}" ] && [ ! -L "${work_dir}" ] || fail 'rank check work directory is invalid'
    deadline=$(( $(date +%s) + 30 ))
    while [ ! -f "${marker}" ]; do
        (( $(date +%s) < deadline )) || fail 'shared namespace marker did not become visible'
        sleep 1
    done
    [ "$(<"${marker}")" = "${VAST_SENTINEL_TOKEN:?VAST_SENTINEL_TOKEN is required for rank check}" ] || fail 'shared namespace marker content mismatch'
    printf 'token=%s rank=%s\n' "${VAST_SENTINEL_TOKEN}" "${rank}" > "${work_dir}/rank-${rank}.payload"
    sha256sum "${work_dir}/rank-${rank}.payload" > "${work_dir}/rank-${rank}.sha256"
    while [ "$(command ls "${work_dir}"/rank-*.sha256 2>/dev/null | wc -l)" -lt "${total}" ]; do
        (( $(date +%s) < deadline )) || fail 'cross-rank checksum files did not become visible'
        sleep 1
    done
    if [ "${rank}" = 0 ]; then
        (cd -- "${work_dir}" && sha256sum -c rank-*.sha256)
        printf '%s\n' "${VAST_SENTINEL_TOKEN}" > "${work_dir}/rename-source"
        mv -- "${work_dir}/rename-source" "${work_dir}/rename-destination"
        [ -f "${work_dir}/rename-destination" ] || fail 'cross-rank rename did not produce destination'
        rm -- "${work_dir}/rename-destination"
        [ ! -e "${work_dir}/rename-destination" ] || fail 'cross-rank delete did not remove destination'
        printf '%s\n' complete > "${work_dir}/cross-rank-complete"
    else
        while [ ! -f "${work_dir}/cross-rank-complete" ]; do
            (( $(date +%s) < deadline )) || fail 'cross-rank rename/delete completion did not become visible'
            sleep 1
        done
        [ ! -e "${work_dir}/rename-destination" ] || fail 'cross-rank delete is not visible'
    fi
}

run_cross_rank_correctness() {
    VAST_RANKS="${VAST_RANKS:-${SLURM_JOB_NUM_NODES:-2}}"
    [[ "${VAST_RANKS}" =~ ^([2-9]|1[0-6])$ ]] || fail 'VAST_RANKS must be an integer from 2 through 16'
    command -v srun >/dev/null || validation_resource_unavailable 'srun is required for cross-rank mounted-filesystem validation' mandatory
    command -v sha256sum >/dev/null || validation_resource_unavailable 'sha256sum is required for cross-rank mounted-filesystem validation' mandatory
    printf '%s\n' "${VAST_SENTINEL_TOKEN}" > "${VAST_WORK_DIR}/namespace-marker"
    export VAST_RANKS VAST_SENTINEL_TOKEN
    srun --nodes="${VAST_RANKS}" --ntasks="${VAST_RANKS}" --ntasks-per-node=1 "${BASH_SOURCE[0]}" --rank-check "${VAST_WORK_DIR}"
}

write_live_mount_observation() {
    command -v findmnt >/dev/null || validation_resource_unavailable 'findmnt is required to validate mounted filesystem identity' mandatory
    command -v stat >/dev/null || validation_resource_unavailable 'stat is required to validate mounted filesystem identity' mandatory
    [ -n "${VAST_EXPECTED_FILESYSTEM_CLASS:-}" ] || fail 'runner must declare VAST_EXPECTED_FILESYSTEM_CLASS as vast, nfs, or generic'
    [ -n "${VAST_EXPECTED_MOUNT_SOURCE:-}" ] || fail 'runner must declare VAST_EXPECTED_MOUNT_SOURCE'
    [ -n "${VAST_EXPECTED_FILESYSTEM_TYPES:-}" ] || fail 'runner must declare VAST_EXPECTED_FILESYSTEM_TYPES'
    findmnt -n -T "${TARGET_ROOT}" -o SOURCE,FSTYPE,OPTIONS > "${RESULTS_DIR}/mount.findmnt"
    stat -f -c '%T' "${TARGET_ROOT}" > "${RESULTS_DIR}/mount.statfs"
    if grep -Eq '^[^[:space:]]+[[:space:]]+nfs' "${RESULTS_DIR}/mount.findmnt"; then
        if command -v nfsstat >/dev/null; then nfsstat -m > "${RESULTS_DIR}/mount.nfsstat" 2>&1 || true; fi
    fi
    export VAST_MOUNT_FIXTURE='' VAST_MOUNT_EXPECTED_CLASS="${VAST_EXPECTED_FILESYSTEM_CLASS}" VAST_MOUNT_EXPECTED_SOURCE="${VAST_EXPECTED_MOUNT_SOURCE}" VAST_MOUNT_EXPECTED_TYPES="${VAST_EXPECTED_FILESYSTEM_TYPES}" VAST_MOUNT_REQUIRED_OPTIONS="${VAST_REQUIRED_MOUNT_OPTIONS:-}" VAST_MOUNT_FINDMNT="${RESULTS_DIR}/mount.findmnt" VAST_MOUNT_STATFS="${RESULTS_DIR}/mount.statfs" VAST_MOUNT_NFSSTAT="${RESULTS_DIR}/mount.nfsstat"
}

validate_mount_identity() {
    local source filesystem_type options option
    read -r source filesystem_type options < "${RESULTS_DIR}/mount.findmnt"
    case "${VAST_EXPECTED_FILESYSTEM_CLASS}" in vast|nfs|generic) ;; *) fail 'VAST_EXPECTED_FILESYSTEM_CLASS must be vast, nfs, or generic'; return ;; esac
    [ "${source}" = "${VAST_EXPECTED_MOUNT_SOURCE}" ] || { fail 'mounted source identity does not match runner configuration'; return; }
    case ",${VAST_EXPECTED_FILESYSTEM_TYPES}," in *,"${filesystem_type}",*) ;; *) fail 'mounted filesystem type does not match runner configuration'; return ;; esac
    IFS=',' read -r -a required_options <<< "${VAST_REQUIRED_MOUNT_OPTIONS:-}"
    for option in "${required_options[@]}"; do
        [ -z "${option}" ] || case ",${options}," in *,"${option}",*) ;; *) fail "mounted filesystem is missing required option ${option}"; return ;; esac
    done
}

evaluate_mount() {
    export VAST_MOUNT_RESULT="${RESULTS_DIR}/vast_mount.json" VAST_MOUNT_PROM="${RESULTS_DIR}/vast_mount.prom"
    python3 <<'PY'
import json
import os
from pathlib import Path

fixture = os.environ["VAST_MOUNT_FIXTURE"]
if fixture:
    data = json.loads((Path(fixture) / "manifest.json").read_text(encoding="utf-8"))
    expected = data["mount_expectation"]
    observed = data["mount_observed"]
    namespace = data["namespace"]
    checksums = data["checksums"]
else:
    source, filesystem_type, options = Path(os.environ["VAST_MOUNT_FINDMNT"]).read_text(encoding="utf-8").strip().split(None, 2)
    expected = {
        "filesystem_class": os.environ["VAST_MOUNT_EXPECTED_CLASS"],
        "source_identity": os.environ["VAST_MOUNT_EXPECTED_SOURCE"],
        "filesystem_types": [item for item in os.environ["VAST_MOUNT_EXPECTED_TYPES"].split(",") if item],
        "required_options": [item for item in os.environ["VAST_MOUNT_REQUIRED_OPTIONS"].split(",") if item],
    }
    observed = {
        "source_identity": source,
        "filesystem_type": filesystem_type,
        "options": options.split(","),
        "statfs_type": Path(os.environ["VAST_MOUNT_STATFS"]).read_text(encoding="utf-8").strip(),
        "nfs_client_available": Path(os.environ["VAST_MOUNT_NFSSTAT"]).is_file(),
    }
    namespace = {"marker_visible_to_all_ranks": True, "rename_visible_to_all_ranks": True, "delete_visible_to_all_ranks": True}
    checksums = {"all_rank_writes_verified": True}

errors = []
if expected["filesystem_class"] not in {"vast", "nfs", "generic"}:
    errors.append("configured filesystem class is invalid")
if observed["source_identity"] != expected["source_identity"]:
    errors.append("mounted source identity does not match runner configuration")
if observed["filesystem_type"] not in expected["filesystem_types"]:
    errors.append("mounted filesystem type does not match runner configuration")
for option in expected["required_options"]:
    if option not in observed["options"]:
        errors.append(f"mounted filesystem is missing required option {option}")
for name, value in namespace.items():
    if not value:
        errors.append(f"cross-rank namespace check failed: {name}")
if not checksums["all_rank_writes_verified"]:
    errors.append("cross-rank payload checksum verification failed")
verdict = "FAIL" if errors else "PASS"
declared = data.get("verdicts", {}).get("vast") if fixture else None
if declared and declared != verdict:
    errors.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {
    "fixture": bool(fixture), "filesystem_class": expected["filesystem_class"],
    "source_identity_match": observed["source_identity"] == expected["source_identity"],
    "filesystem_type": observed["filesystem_type"], "statfs_type": observed.get("statfs_type", ""),
    "nfs_client_available": observed["nfs_client_available"], "namespace": namespace,
    "checksums": checksums, "verdict": verdict, "failures": errors,
}
Path(os.environ["VAST_MOUNT_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
Path(os.environ["VAST_MOUNT_PROM"]).write_text(
    "# TYPE chapar_vast_mount_identity_match gauge\n"
    f"chapar_vast_mount_identity_match {int(payload['source_identity_match'])}\n"
    "# TYPE chapar_vast_cross_rank_checksum_verified gauge\n"
    f"chapar_vast_cross_rank_checksum_verified {int(payload['checksums']['all_rank_writes_verified'])}\n",
    encoding="utf-8",
)
PY
}

run_bounded_burnin() {
    local burnin="${script_dir}/storage-burnin.sbatch"
    VAST_BURNIN_IOR_RANKS="${VAST_BURNIN_IOR_RANKS:-${VAST_RANKS}}"
    STORAGE_BURNIN_TARGET="${VAST_STORAGE_TARGET}" \
    STORAGE_BURNIN_TARGET_ROOT="${VAST_STORAGE_TARGET_ROOT}" \
    STORAGE_BURNIN_IOR_RANKS="${VAST_BURNIN_IOR_RANKS}" \
    RESULTS_ROOT="${RESULTS_ROOT}" \
    bash "${burnin}"
}

if [ "${1:-}" = --rank-check ]; then
    [ "$#" = 2 ] || { usage; exit 2; }
    rank_check "$2"
    exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
fixture=""
if [ "${1:-}" = --fixture ]; then
    [ "$#" = 2 ] || { usage; exit 2; }
    fixture="$2"
    [ -f "${fixture}/manifest.json" ] || { printf 'storage fixture manifest is missing: %s\n' "${fixture}" >&2; exit 2; }
elif [ "$#" -ne 0 ]; then
    usage
    exit 2
fi

source "${validation_dir}/lib/verdict.sh"
source "${validation_dir}/lib/result-manifest.sh"
validation_result_init vast "${RESULTS_ROOT}" "${node}"
RESULTS_DIR="${VALIDATION_NODE_DIR}"

if [ -n "${fixture}" ]; then
    export VAST_MOUNT_FIXTURE="${fixture}"
    evaluate_mount
else
    validate_target
    write_live_mount_observation
    validate_mount_identity
    create_work_directory
    trap 'finalize_with_cleanup "$?"' EXIT
    run_cross_rank_correctness
    cleanup_work_directory
    evaluate_mount
fi

verdict="$(python3 -c "import json; print(json.load(open('${RESULTS_DIR}/vast_mount.json'))['verdict'])")"
reason="$(python3 -c "import json; data=json.load(open('${RESULTS_DIR}/vast_mount.json')); print('; '.join(data['failures']))")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    PASS) ;;
    *) fail "unexpected VAST fixture verdict: ${verdict}" ;;
esac
if [ -n "${fixture}" ]; then
    exit 0
fi
run_bounded_burnin
printf 'Mounted-filesystem evidence written to %s\n' "${RESULTS_DIR}" >&2
