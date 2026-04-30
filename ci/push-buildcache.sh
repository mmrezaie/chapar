#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/push-buildcache.sh --env-path PATH --os rocky8|rocky9|macos --flavor canary|prod [options]

Options:
  --resources-root PATH        CI output root inside the container (default: /resources/chapar)
  --buildcache-dir PATH        Override destination buildcache directory
  -h, --help                   Show this help
USAGE
}

ENV_PATH=""
OS_NAME=""
FLAVOR=""
RESOURCES_ROOT="${RESOURCES_ROOT:-/resources/chapar}"
BUILDCACHE_DIR=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env-path) ENV_PATH="$2"; shift 2 ;;
        --os) OS_NAME="$2"; shift 2 ;;
        --flavor) FLAVOR="$2"; shift 2 ;;
        --resources-root) RESOURCES_ROOT="$2"; shift 2 ;;
        --buildcache-dir) BUILDCACHE_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "${ENV_PATH}" ] || [ -z "${OS_NAME}" ] || [ -z "${FLAVOR}" ]; then
    usage >&2
    exit 1
fi

case "${OS_NAME}" in
    rocky8|rocky9|macos) ;;
    *) echo "ERROR: --os must be rocky8, rocky9, or macos" >&2; exit 1 ;;
esac

case "${FLAVOR}" in
    canary|prod) ;;
    *) echo "ERROR: --flavor must be canary or prod" >&2; exit 1 ;;
esac

if [ -z "${BUILDCACHE_DIR}" ]; then
    BUILDCACHE_DIR="${RESOURCES_ROOT}/buildcache/${OS_NAME}/${FLAVOR}"
fi

mkdir -p "${BUILDCACHE_DIR}"

echo "==> Pushing buildcache"
echo "    env:        ${ENV_PATH}"
echo "    buildcache: ${BUILDCACHE_DIR}"

spack -e "${ENV_PATH}" buildcache push \
    --unsigned \
    --update-index \
    "file://${BUILDCACHE_DIR}"
