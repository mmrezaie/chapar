#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/incus-build.sh [options]

Options:
  --os rocky8|rocky9|all          Target container OS (default: rocky9)
  --flavor canary|prod            Environment flavor (default: canary)
  --section SECTION               all, full, or one section (default: all)
  --git-ref REF                   Git branch/tag/SHA to build (default: current branch)
  --repo-url URL                  Repository URL to clone inside container
  --incus-remote REMOTE           Incus remote name; empty means default local remote
  --resources-source PATH         Incus host path for NAS resources export (default: /resources)
  --resources-root PATH           Path inside container for CI output (default: /resources/chapar)
  --repo-dir PATH                 Repo clone path inside container (default: /root/workspace/chapar)
  --run-id ID                     Output run identifier (default: GitHub run ID or timestamp)
  --push-buildcache true|false    Push Spack buildcache after build (default: true)
  --spack-install-args ARGS       Extra args for spack install (default: -p 1 --fail-fast)
  --keep-running                  Leave container running instead of stopping it
  -h, --help                      Show this help
USAGE
}

OS_NAME="rocky9"
FLAVOR="canary"
SECTION="all"
GIT_REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '%s' main)"
REPO_URL="${REPO_URL:-https://github.com/mmrezaie/chapar.git}"
INCUS_REMOTE="${INCUS_REMOTE:-}"
RESOURCES_SOURCE="${RESOURCES_SOURCE:-/resources}"
RESOURCES_ROOT="${RESOURCES_ROOT:-/resources/chapar}"
REPO_DIR="${REPO_DIR:-/root/workspace/chapar}"
PUSH_BUILDCACHE="${PUSH_BUILDCACHE:-true}"
SPACK_INSTALL_ARGS="${SPACK_INSTALL_ARGS:--p 1 --fail-fast}"
KEEP_RUNNING="false"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-chapar}"
RUN_ID="${GITHUB_RUN_ID:-manual-$(date +%Y%m%d%H%M%S)}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --os) OS_NAME="$2"; shift 2 ;;
        --flavor) FLAVOR="$2"; shift 2 ;;
        --section) SECTION="$2"; shift 2 ;;
        --git-ref) GIT_REF="$2"; shift 2 ;;
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --incus-remote) INCUS_REMOTE="$2"; shift 2 ;;
        --resources-source) RESOURCES_SOURCE="$2"; shift 2 ;;
        --resources-root) RESOURCES_ROOT="$2"; shift 2 ;;
        --repo-dir) REPO_DIR="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --push-buildcache) PUSH_BUILDCACHE="$2"; shift 2 ;;
        --spack-install-args) SPACK_INSTALL_ARGS="$2"; shift 2 ;;
        --keep-running) KEEP_RUNNING="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ "${OS_NAME}" = "all" ]; then
    extra_args=()
    if [ "${KEEP_RUNNING}" = "true" ]; then
        extra_args+=(--keep-running)
    fi

    for one_os in rocky8 rocky9; do
        "$0" \
            --os "${one_os}" \
            --flavor "${FLAVOR}" \
            --section "${SECTION}" \
            --git-ref "${GIT_REF}" \
            --repo-url "${REPO_URL}" \
            --incus-remote "${INCUS_REMOTE}" \
            --resources-source "${RESOURCES_SOURCE}" \
            --resources-root "${RESOURCES_ROOT}" \
            --repo-dir "${REPO_DIR}" \
            --run-id "${RUN_ID}" \
            --push-buildcache "${PUSH_BUILDCACHE}" \
            --spack-install-args "${SPACK_INSTALL_ARGS}" \
            "${extra_args[@]}"
    done
    exit 0
fi

case "${OS_NAME}" in
    rocky8) IMAGE="${ROCKY8_IMAGE:-images:rockylinux/8}" ;;
    rocky9) IMAGE="${ROCKY9_IMAGE:-images:rockylinux/9}" ;;
    *) echo "ERROR: --os must be rocky8, rocky9, or all" >&2; exit 1 ;;
esac

case "${FLAVOR}" in
    canary|prod) ;;
    *) echo "ERROR: --flavor must be canary or prod" >&2; exit 1 ;;
esac

CONTAINER="${CONTAINER_PREFIX}-${OS_NAME}-builder"
if [ -n "${INCUS_REMOTE}" ]; then
    INSTANCE="${INCUS_REMOTE}:${CONTAINER}"
else
    INSTANCE="${CONTAINER}"
fi

if ! incus info "${INSTANCE}" >/dev/null 2>&1; then
    incus launch "${IMAGE}" "${INSTANCE}"
fi

incus config device add "${INSTANCE}" resources disk \
    source="${RESOURCES_SOURCE}" \
    path=/resources >/dev/null 2>&1 || true
incus config device set "${INSTANCE}" resources source "${RESOURCES_SOURCE}" >/dev/null 2>&1 || true
incus config device set "${INSTANCE}" resources path /resources >/dev/null 2>&1 || true

incus start "${INSTANCE}" >/dev/null 2>&1 || true

stop_container() {
    if [ "${KEEP_RUNNING}" != "true" ]; then
        incus stop "${INSTANCE}" >/dev/null 2>&1 || true
    fi
}
trap stop_container EXIT

incus exec "${INSTANCE}" -- rm -f \
    /tmp/chapar-bootstrap-rocky.sh \
    /tmp/chapar-container-build.sh \
    /tmp/chapar-push-buildcache.sh

incus file push ci/bootstrap-rocky.sh "${INSTANCE}/tmp/chapar-bootstrap-rocky.sh"
incus file push ci/container-build.sh "${INSTANCE}/tmp/chapar-container-build.sh"
incus file push ci/push-buildcache.sh "${INSTANCE}/tmp/chapar-push-buildcache.sh"

incus exec "${INSTANCE}" -- bash /tmp/chapar-bootstrap-rocky.sh

incus exec "${INSTANCE}" \
    --env "REPO_URL=${REPO_URL}" \
    --env "GIT_REF=${GIT_REF}" \
    --env "REPO_DIR=${REPO_DIR}" \
    --env "FLAVOR=${FLAVOR}" \
    --env "SECTION=${SECTION}" \
    --env "OS_NAME=${OS_NAME}" \
    --env "PUSH_BUILDCACHE=${PUSH_BUILDCACHE}" \
    --env "PUSH_BUILDCACHE_SCRIPT=/tmp/chapar-push-buildcache.sh" \
    --env "SPACK_INSTALL_ARGS=${SPACK_INSTALL_ARGS}" \
    --env "RESOURCES_ROOT=${RESOURCES_ROOT}" \
    --env "RUN_ID=${RUN_ID}" \
    -- bash /tmp/chapar-container-build.sh
