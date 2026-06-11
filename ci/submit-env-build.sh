#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/submit-env-build.sh [options]

Options:
  --env-name NAME                Chapar environment name (default: hpcsim)
  --env-path PATH                Spack environment path (default: envs/<env-name>)
  --os NAME                      Target OS name, for example rocky9 or rocky10
  --env-root PATH                Optional shared environment output root
  --action concretize|build      Run only concretization or full build (default: build)
  --mode auto|release|spack      Use env release helper or direct Spack (default: auto)
  --partition NAME               Slurm partition to submit to
  --cores N                      Slurm CPUs per task for the build node
  --release-id ID                Release/run ID (default: <env>-<os>-YYYYMMDD)
  --publish-current true|false   Promote current after a successful release build (default: false)
  --dry-run                      Print the sbatch command without submitting
  -h, --help                     Show this help

Missing values are prompted for when stdin is interactive. Command-line sbatch
options override the #SBATCH defaults in ci/sbatch-env-build.sh.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAPAR_ROOT="${CHAPAR_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
ENV_NAME="${ENV_NAME:-hpcsim}"
ENV_PATH="${ENV_PATH:-}"
OS_NAME="${OS_NAME:-}"
CHAPAR_ENV_ROOT="${CHAPAR_ENV_ROOT:-}"
CHAPAR_ENV_ACTION="${CHAPAR_ENV_ACTION:-build}"
CHAPAR_ENV_BUILD_MODE="${CHAPAR_ENV_BUILD_MODE:-auto}"
PARTITION=""
CORES=""
RELEASE_ID="${RELEASE_ID:-}"
PUBLISH_CURRENT="${PUBLISH_CURRENT:-}"
DRY_RUN="false"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env-name) ENV_NAME="$2"; shift 2 ;;
        --env-path) ENV_PATH="$2"; shift 2 ;;
        --os) OS_NAME="$2"; shift 2 ;;
        --env-root) CHAPAR_ENV_ROOT="$2"; shift 2 ;;
        --action) CHAPAR_ENV_ACTION="$2"; shift 2 ;;
        --mode) CHAPAR_ENV_BUILD_MODE="$2"; shift 2 ;;
        --partition) PARTITION="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --release-id) RELEASE_ID="$2"; shift 2 ;;
        --publish-current) PUBLISH_CURRENT="$2"; shift 2 ;;
        --dry-run) DRY_RUN="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
done

is_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

prompt_value() {
    local name="$1"
    local prompt="$2"
    local default_value="${3:-}"
    local value=""

    if ! is_interactive; then
        echo "ERROR: ${name} is required in non-interactive mode" >&2
        exit 1
    fi

    if [ -n "${default_value}" ]; then
        read -r -p "${prompt} [${default_value}]: " value
        printf '%s\n' "${value:-${default_value}}"
    else
        while [ -z "${value}" ]; do
            read -r -p "${prompt}: " value
        done
        printf '%s\n' "${value}"
    fi
}

validate_simple_id() {
    local label="$1"
    local value="$2"
    case "${value}" in
        ""|.|..|*/*|*[!A-Za-z0-9._-]*)
            echo "ERROR: ${label} must match [A-Za-z0-9._-]+ and cannot be '.' or '..': ${value}" >&2
            exit 1
            ;;
    esac
}

validate_simple_id ENV_NAME "${ENV_NAME}"
if [ -z "${ENV_PATH}" ]; then
    ENV_PATH="envs/${ENV_NAME}"
fi
case "${ENV_PATH}" in
    envs/*) ;;
    *) echo "ERROR: --env-path must be under envs/: ${ENV_PATH}" >&2; exit 1 ;;
esac

if [ -z "${OS_NAME}" ]; then
    OS_NAME="$(prompt_value OS_NAME 'Target OS name' rocky9)"
fi
validate_simple_id OS_NAME "${OS_NAME}"

if [ -n "${CHAPAR_ENV_ROOT}" ]; then
    case "${CHAPAR_ENV_ROOT}" in
        /*) ;;
        *) echo "ERROR: --env-root must be an absolute path: ${CHAPAR_ENV_ROOT}" >&2; exit 1 ;;
    esac
fi

case "${CHAPAR_ENV_ACTION}" in
    concretize|build) ;;
    *) echo "ERROR: --action must be concretize or build, got ${CHAPAR_ENV_ACTION}" >&2; exit 1 ;;
esac

case "${CHAPAR_ENV_BUILD_MODE}" in
    auto|release|spack) ;;
    *) echo "ERROR: --mode must be auto, release, or spack, got ${CHAPAR_ENV_BUILD_MODE}" >&2; exit 1 ;;
esac

if [ -z "${PARTITION}" ]; then
    PARTITION="$(prompt_value PARTITION 'Slurm partition')"
fi
case "${PARTITION}" in
    ""|*[!A-Za-z0-9._,+-]*)
        echo "ERROR: partition contains unsupported characters: ${PARTITION}" >&2
        exit 1
        ;;
esac

if [ -z "${CORES}" ]; then
    CORES="$(prompt_value CORES 'Usable CPU cores on the build node' "${SLURM_CPUS_PER_TASK:-128}")"
fi
case "${CORES}" in
    ""|*[!0-9]*) echo "ERROR: --cores must be a positive integer, got ${CORES}" >&2; exit 1 ;;
    0) echo "ERROR: --cores must be greater than zero" >&2; exit 1 ;;
esac

if [ -z "${RELEASE_ID}" ]; then
    default_release_id="${ENV_NAME}-${OS_NAME}-$(date -u +%Y%m%d)"
    if is_interactive; then
        RELEASE_ID="$(prompt_value RELEASE_ID 'Release/run ID' "${default_release_id}")"
    else
        RELEASE_ID="${default_release_id}"
    fi
fi
validate_simple_id RELEASE_ID "${RELEASE_ID}"

if [ -z "${PUBLISH_CURRENT}" ]; then
    if is_interactive; then
        PUBLISH_CURRENT="$(prompt_value PUBLISH_CURRENT 'Promote current after success? true or false' false)"
    else
        PUBLISH_CURRENT="false"
    fi
fi
case "${PUBLISH_CURRENT}" in
    true|false) ;;
    *) echo "ERROR: --publish-current must be true or false, got ${PUBLISH_CURRENT}" >&2; exit 1 ;;
esac

wrapper="${CHAPAR_ROOT}/ci/sbatch-env-build.sh"
[ -r "${wrapper}" ] || { echo "ERROR: missing sbatch wrapper: ${wrapper}" >&2; exit 1; }

mkdir -p "${CHAPAR_ROOT}/slogs"

sbatch_args=(
    --chdir "${CHAPAR_ROOT}"
    --partition "${PARTITION}"
    --cpus-per-task "${CORES}"
    --export "ALL,CHAPAR_ROOT=${CHAPAR_ROOT},ENV_NAME=${ENV_NAME},ENV_PATH=${ENV_PATH},CHAPAR_ENV_ROOT=${CHAPAR_ENV_ROOT},OS_NAME=${OS_NAME},CHAPAR_ENV_ACTION=${CHAPAR_ENV_ACTION},CHAPAR_ENV_BUILD_MODE=${CHAPAR_ENV_BUILD_MODE},RELEASE_ID=${RELEASE_ID},PUBLISH_CURRENT=${PUBLISH_CURRENT}"
    "${wrapper}"
)

echo "Submitting Chapar environment build"
echo "  env name:        ${ENV_NAME}"
echo "  env path:        ${ENV_PATH}"
echo "  env root:        ${CHAPAR_ENV_ROOT:-default}"
echo "  os:              ${OS_NAME}"
echo "  action:          ${CHAPAR_ENV_ACTION}"
echo "  mode:            ${CHAPAR_ENV_BUILD_MODE}"
echo "  partition:       ${PARTITION}"
echo "  cpus per task:   ${CORES}"
echo "  release/run id:  ${RELEASE_ID}"
echo "  publish current: ${PUBLISH_CURRENT}"
echo "  chapar root:     ${CHAPAR_ROOT}"

if [ "${DRY_RUN}" = "true" ]; then
    printf 'sbatch'
    printf ' %q' "${sbatch_args[@]}"
    printf '\n'
    exit 0
fi

sbatch "${sbatch_args[@]}"
