#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/push-buildcache.sh --selection PATH --selection-sha256 SHA256 --contract PATH [--plan|--execute]
       ci/push-buildcache.sh --selection PATH --selection-sha256 SHA256 --contract PATH --plan-migration SOURCE

--plan is the default and performs no filesystem or cache command.
--execute requires a digest-verified selection whose target contract permits publication.
Migration is intentionally plan-only: future execution must remain copy-only,
non-overwriting, and non-deleting and requires separate operator approval.
USAGE
}

SELECTION_PATH=""
SELECTION_SHA256=""
CONTRACT_PATH=""
MODE="plan"
MIGRATION_SOURCE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --selection) SELECTION_PATH="$2"; shift 2 ;;
        --selection-sha256) SELECTION_SHA256="$2"; shift 2 ;;
        --contract) CONTRACT_PATH="$2"; shift 2 ;;
        --plan) MODE="plan"; shift ;;
        --execute) MODE="execute"; shift ;;
        --plan-migration) MODE="migration-plan"; MIGRATION_SOURCE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "${SELECTION_PATH}" ] || [ -z "${SELECTION_SHA256}" ] || [ -z "${CONTRACT_PATH}" ]; then
    usage >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAPAR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SELECTION_HELPER="${CHAPAR_ROOT}/etc/chapar-selection.sh"
SELECTION_EXPORTS="$("${SELECTION_HELPER}" exports "${SELECTION_PATH}" "${SELECTION_SHA256}" "${CONTRACT_PATH}")"
eval "${SELECTION_EXPORTS}"

[ "${CHAPAR_PUBLISH_BUILDCACHE}" = "true" ] || { echo "ERROR: target contract forbids buildcache publication" >&2; exit 1; }

printf 'selection: %s\n' "${SELECTION_SHA256}"
printf 'tuple: %s/%s/%s\n' "${CHAPAR_DATACENTER}" "${CHAPAR_SOFTWARE_SET}" "${CHAPAR_TARGET}"
printf 'writable buildcache: %s\n' "${CHAPAR_BUILDCACHE_DIR}"

if [ "${MODE}" = "migration-plan" ]; then
    [ -n "${MIGRATION_SOURCE}" ] && [[ "${MIGRATION_SOURCE}" = /* ]] || { echo "ERROR: migration source must be absolute" >&2; exit 1; }
    printf 'migration source: %s\n' "${MIGRATION_SOURCE}"
    echo "migration policy: copy-only, non-overwriting, non-deleting; execution disabled"
    exit 0
fi

if [ "${MODE}" = "plan" ]; then
    echo "action: plan only; no cache command or filesystem mutation"
    exit 0
fi

exec "${SELECTION_HELPER}" buildcache-push "${SELECTION_PATH}" "${SELECTION_SHA256}" "${CONTRACT_PATH}"
