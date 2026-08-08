#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/submit-hpcsim-release.sh [options]

Options:
  --os rocky9|rocky10             Target release OS
  --partition NAME                Slurm partition to submit to
  --cores N                       Optional Slurm CPUs per task; omit to use the full exclusive node
  --release-id ID                 Release ID (default: <os>-YYYYMMDDHHMMSS)
  --publish-current true|false    Promote current after a successful build (default: false)
  --publish-modules true|false    Publish shared module-root symlink without promoting current (default: true)
  --dry-run                       Print the sbatch command without submitting
  -h, --help                      Show this help

Missing values are prompted for when stdin is interactive. Command-line sbatch
options override the #SBATCH defaults in the OS-specific wrapper scripts.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAPAR_ROOT="${CHAPAR_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
OS_NAME=""
PARTITION=""
CORES=""
RELEASE_ID="${RELEASE_ID:-}"
PUBLISH_CURRENT="${PUBLISH_CURRENT:-}"
PUBLISH_MODULES="${PUBLISH_MODULES:-}"
DRY_RUN="false"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --os) OS_NAME="$2"; shift 2 ;;
        --partition) PARTITION="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --release-id) RELEASE_ID="$2"; shift 2 ;;
        --publish-current) PUBLISH_CURRENT="$2"; shift 2 ;;
        --publish-modules) PUBLISH_MODULES="$2"; shift 2 ;;
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

validate_release_id() {
    case "$1" in
        ""|.|..|*/*|*[!A-Za-z0-9._-]*)
            echo "ERROR: release ID must match [A-Za-z0-9._-]+ and cannot be '.' or '..': $1" >&2
            exit 1
            ;;
    esac
}

if [ -z "${OS_NAME}" ]; then
    OS_NAME="$(prompt_value OS_NAME 'Target OS (rocky9 or rocky10)' rocky9)"
fi

case "${OS_NAME}" in
    rocky9|rocky10) ;;
    *) echo "ERROR: --os must be rocky9 or rocky10, got ${OS_NAME}" >&2; exit 1 ;;
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

if [ -n "${CORES}" ]; then
    case "${CORES}" in
        *[!0-9]*) echo "ERROR: --cores must be a positive integer, got ${CORES}" >&2; exit 1 ;;
        0) echo "ERROR: --cores must be greater than zero" >&2; exit 1 ;;
    esac
fi

if [ -z "${RELEASE_ID}" ]; then
    default_release_id="${OS_NAME}-$(date +%Y%m%d%H%M%S)"
    if is_interactive; then
        RELEASE_ID="$(prompt_value RELEASE_ID 'Release ID' "${default_release_id}")"
    else
        RELEASE_ID="${default_release_id}"
    fi
fi
validate_release_id "${RELEASE_ID}"

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

if [ -z "${PUBLISH_MODULES}" ]; then
    if is_interactive; then
        PUBLISH_MODULES="$(prompt_value PUBLISH_MODULES 'Publish shared module root after success? true or false' true)"
    else
        PUBLISH_MODULES="true"
    fi
fi
case "${PUBLISH_MODULES}" in
    true|false) ;;
    *) echo "ERROR: --publish-modules must be true or false, got ${PUBLISH_MODULES}" >&2; exit 1 ;;
esac

wrapper="${CHAPAR_ROOT}/ci/sbatch-hpcsim-release-${OS_NAME}.sh"
[ -r "${wrapper}" ] || { echo "ERROR: missing sbatch wrapper: ${wrapper}" >&2; exit 1; }

mkdir -p "${CHAPAR_ROOT}/slogs"

sbatch_args=(
    --chdir "${CHAPAR_ROOT}"
    --partition "${PARTITION}"
    --export "ALL,CHAPAR_ROOT=${CHAPAR_ROOT},RELEASE_ID=${RELEASE_ID},PUBLISH_CURRENT=${PUBLISH_CURRENT},PUBLISH_MODULES=${PUBLISH_MODULES}"
    "${wrapper}"
)
if [ -n "${CORES}" ]; then
    sbatch_args=(--cpus-per-task "${CORES}" "${sbatch_args[@]}")
fi

echo "Submitting hpcsim release build"
echo "  os:              ${OS_NAME}"
echo "  partition:       ${PARTITION}"
echo "  cpus per task:   ${CORES:-full exclusive node}"
echo "  release id:      ${RELEASE_ID}"
echo "  publish current: ${PUBLISH_CURRENT}"
echo "  publish modules: ${PUBLISH_MODULES}"
echo "  chapar root:     ${CHAPAR_ROOT}"

if [ "${DRY_RUN}" = "true" ]; then
    printf 'sbatch'
    printf ' %q' "${sbatch_args[@]}"
    printf '\n'
    exit 0
fi

sbatch "${sbatch_args[@]}"
