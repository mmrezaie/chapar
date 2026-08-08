#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/submit-env-build.sh --datacenter ID --software-set ID --target ID \
  --release-id ID --run-id ID --selection PATH --selection-digest SHA256 [--dry-run]

The selection and its exact digest are required. Partition, constraint, paths,
publication policy, and selected containers come only from its verified target contract.
Legacy --env-name, --env-path, --env-root, and --partition options are no longer supported.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAPAR_ROOT="${CHAPAR_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
case "${CHAPAR_ROOT}" in
    /*) ;;
    *) echo "ERROR: CHAPAR_ROOT must be an absolute path" >&2; exit 2 ;;
esac
case "${CHAPAR_ROOT}" in
    *,*|*[[:space:]]*) echo "ERROR: CHAPAR_ROOT cannot contain commas or whitespace" >&2; exit 2 ;;
esac
DATACENTER=""
SOFTWARE_SET=""
TARGET=""
RELEASE_ID=""
RUN_ID=""
SELECTION=""
SELECTION_DIGEST=""
DRY_RUN=false
declare -A SEEN=()

require_value() {
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: $1 requires a value" >&2
        exit 2
    fi
}

set_once() {
    local option="$1"
    local value="$2"
    if [ -n "${SEEN[${option}]:-}" ]; then
        echo "ERROR: duplicate identity selector: ${option}" >&2
        exit 2
    fi
    SEEN["${option}"]=1
    printf -v "$3" '%s' "${value}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --datacenter|--software-set|--target|--release-id|--run-id|--selection|--selection-digest)
            require_value "$@"
            case "$1" in
                --datacenter) set_once "$1" "$2" DATACENTER ;;
                --software-set) set_once "$1" "$2" SOFTWARE_SET ;;
                --target) set_once "$1" "$2" TARGET ;;
                --release-id) set_once "$1" "$2" RELEASE_ID ;;
                --run-id) set_once "$1" "$2" RUN_ID ;;
                --selection) set_once "$1" "$2" SELECTION ;;
                --selection-digest) set_once "$1" "$2" SELECTION_DIGEST ;;
            esac
            shift 2
            ;;
        --dry-run) DRY_RUN=true; shift ;;
        --env-name|--env-path|--env-root|--partition|--os|--action|--mode|--publish-current|--publish-modules)
            echo "ERROR: $1 is no longer supported; migrate to a resolved selection." >&2
            exit 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

for required in DATACENTER SOFTWARE_SET TARGET RELEASE_ID RUN_ID SELECTION SELECTION_DIGEST; do
    if [ -z "${!required}" ]; then
        echo "ERROR: ${required,,} is required; provide the complete resolved invocation." >&2
        exit 2
    fi
done

case "${SELECTION}" in
    /*) ;;
    *) echo "ERROR: selection must be an absolute path" >&2; exit 2 ;;
esac
case "${SELECTION}" in
    *,*|*[[:space:]]*) echo "ERROR: selection cannot contain commas or whitespace" >&2; exit 2 ;;
esac
CONTRACT="${CHAPAR_ROOT}/datacenters/${DATACENTER}/targets/${TARGET}/contract.json"
PLANNER="${SCRIPT_DIR}/selection-plan.py"
[ -x "${PLANNER}" ] || { echo "ERROR: missing selection planner: ${PLANNER}" >&2; exit 2; }

mapfile -t PLAN < <("${PLANNER}" --selection "${SELECTION}" --selection-digest "${SELECTION_DIGEST}" --contract "${CONTRACT}" --datacenter "${DATACENTER}" --software-set "${SOFTWARE_SET}" --target "${TARGET}" --release-id "${RELEASE_ID}" --run-id "${RUN_ID}")
if [ "${#PLAN[@]}" -eq 0 ]; then
    echo "ERROR: selection verification failed before submission" >&2
    exit 2
fi
declare -A VALUES=()
for item in "${PLAN[@]}"; do
    IFS=$'\t' read -r key value <<<"${item}"
    case "${key}" in
        tuple_id|selection|selection_digest|contract|partition|constraint|account|qos|containers|release_final|release_staging|modulefiles|install_tree|writable_buildcache|ccache|spack_build_stage|publish_buildcache|publish_modules|publish_containers|promote_current)
            VALUES["${key}"]="${value}"
            ;;
        *) echo "ERROR: selection planner emitted an unknown field" >&2; exit 2 ;;
    esac
done

for required in tuple_id selection selection_digest partition constraint account qos release_final release_staging modulefiles install_tree writable_buildcache ccache spack_build_stage publish_buildcache publish_modules publish_containers promote_current; do
    [ -n "${VALUES[${required}]:-}" ] || { echo "ERROR: selection planner omitted ${required}" >&2; exit 2; }
done

echo "canonical tuple: ${VALUES[tuple_id]}"
echo "canonical selection: ${VALUES[selection]}"
echo "release id: ${RELEASE_ID}"
echo "run id: ${RUN_ID}"
echo "selection digest: ${VALUES[selection_digest]}"
echo "contract: ${VALUES[contract]}"
echo "partition: ${VALUES[partition]}"
echo "constraint: ${VALUES[constraint]}"
echo "account: ${VALUES[account]}"
echo "qos: ${VALUES[qos]}"
echo "containers: ${VALUES[containers]:-none}"
echo "release final: ${VALUES[release_final]}"
echo "release staging: ${VALUES[release_staging]}"
echo "modulefiles: ${VALUES[modulefiles]}"
echo "install tree: ${VALUES[install_tree]}"
echo "writable buildcache: ${VALUES[writable_buildcache]}"
echo "ccache: ${VALUES[ccache]}"
echo "Spack build stage: ${VALUES[spack_build_stage]}"
echo "publication: buildcache=${VALUES[publish_buildcache]} modules=${VALUES[publish_modules]} containers=${VALUES[publish_containers]} promote=${VALUES[promote_current]}"

if "${DRY_RUN}"; then
    echo "dry-run: verified plan only; no sbatch submission or filesystem creation"
    exit 0
fi

WRAPPER="${CHAPAR_ROOT}/ci/sbatch-env-build.sh"
[ -x "${WRAPPER}" ] || { echo "ERROR: missing sbatch wrapper: ${WRAPPER}" >&2; exit 2; }
EXPORTS="NONE,CHAPAR_ROOT=${CHAPAR_ROOT},CHAPAR_DATACENTER=${DATACENTER},CHAPAR_SOFTWARE_SET=${SOFTWARE_SET},CHAPAR_TARGET=${TARGET},CHAPAR_RELEASE_ID=${RELEASE_ID},CHAPAR_RUN_ID=${RUN_ID},CHAPAR_SELECTION=${SELECTION},CHAPAR_SELECTION_DIGEST=${SELECTION_DIGEST}"
sbatch --chdir "${CHAPAR_ROOT}" --partition "${VALUES[partition]}" --constraint "${VALUES[constraint]}" --account "${VALUES[account]}" --qos "${VALUES[qos]}" --export "${EXPORTS}" "${WRAPPER}"
