#!/usr/bin/env bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --hint=nomultithread
#SBATCH -J chapar-software-build
#SBATCH -o slogs/%x_%j.out
#SBATCH -e slogs/%x_%j.err

set -euo pipefail

for required in CHAPAR_ROOT CHAPAR_DATACENTER CHAPAR_SOFTWARE_SET CHAPAR_TARGET CHAPAR_RELEASE_ID CHAPAR_RUN_ID CHAPAR_SELECTION CHAPAR_SELECTION_DIGEST; do
    [ -n "${!required:-}" ] || { echo "ERROR: ${required} is required from the explicit submission export" >&2; exit 2; }
done
case "${CHAPAR_ROOT}" in
    /*) ;;
    *) echo "ERROR: CHAPAR_ROOT must be an absolute path" >&2; exit 2 ;;
esac
case "${CHAPAR_ROOT}" in
    *,*|*[[:space:]]*) echo "ERROR: CHAPAR_ROOT cannot contain commas or whitespace" >&2; exit 2 ;;
esac

PLANNER="${CHAPAR_ROOT}/ci/selection-plan.py"
CONTRACT="${CHAPAR_ROOT}/datacenters/${CHAPAR_DATACENTER}/targets/${CHAPAR_TARGET}/contract.json"
[ -x "${PLANNER}" ] || { echo "ERROR: missing selection planner: ${PLANNER}" >&2; exit 2; }
mapfile -t PLAN < <("${PLANNER}" --selection "${CHAPAR_SELECTION}" --selection-digest "${CHAPAR_SELECTION_DIGEST}" --contract "${CONTRACT}" --datacenter "${CHAPAR_DATACENTER}" --software-set "${CHAPAR_SOFTWARE_SET}" --target "${CHAPAR_TARGET}" --release-id "${CHAPAR_RELEASE_ID}" --run-id "${CHAPAR_RUN_ID}")
[ "${#PLAN[@]}" -gt 0 ] || { echo "ERROR: selection verification failed before release execution" >&2; exit 2; }
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
for required in tuple_id release_final release_staging modulefiles install_tree writable_buildcache ccache spack_build_stage publish_buildcache publish_modules publish_containers promote_current; do
    [ -n "${VALUES[${required}]:-}" ] || { echo "ERROR: selection planner omitted ${required}" >&2; exit 2; }
done

RELEASE_HELPER="${CHAPAR_ROOT}/envs/software/release.sh"
[ -x "${RELEASE_HELPER}" ] || { echo "ERROR: missing tuple-bound release helper: ${RELEASE_HELPER}" >&2; exit 2; }
export CHAPAR_PUBLISH_BUILDCACHE="${VALUES[publish_buildcache]}"
export CHAPAR_PUBLISH_MODULES="${VALUES[publish_modules]}"
export CHAPAR_PUBLISH_CONTAINERS="${VALUES[publish_containers]}"
export CHAPAR_PROMOTE_CURRENT="${VALUES[promote_current]}"
echo "canonical tuple: ${VALUES[tuple_id]}"
echo "selection digest: ${VALUES[selection_digest]}"
echo "release final: ${VALUES[release_final]}"
echo "release staging: ${VALUES[release_staging]}"
echo "modulefiles: ${VALUES[modulefiles]}"
echo "install tree: ${VALUES[install_tree]}"
echo "writable buildcache: ${VALUES[writable_buildcache]}"
echo "containers: ${VALUES[containers]:-none}"
echo "publication: buildcache=${CHAPAR_PUBLISH_BUILDCACHE} modules=${CHAPAR_PUBLISH_MODULES} containers=${CHAPAR_PUBLISH_CONTAINERS} promote=${CHAPAR_PROMOTE_CURRENT}"
exec bash "${RELEASE_HELPER}" build --selection "${CHAPAR_SELECTION}" --selection-digest "${CHAPAR_SELECTION_DIGEST}"
