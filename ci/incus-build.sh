#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/incus-build.sh [options]

Options:
  --os rocky8|rocky9|all          Target container OS (default: rocky9)
  --release-id ID                 hpcsim release ID (default: run ID)
  --git-ref REF                   Git branch/tag/SHA to build (default: current branch)
  --repo-url URL                  Repository URL to clone inside container
  --incus-remote REMOTE           Incus remote name; empty means default local remote
  --resources-source PATH         Incus host path for resources export (default: /resources)
  --hpcsim-root PATH              Path inside container for hpcsim output (default: /resources/share/hpcsim)
  --repo-dir PATH                 Repo clone path inside container (default: /root/workspace/chapar)
  --run-id ID                     Output run identifier (default: GitHub run ID or timestamp)
  --publish-current true|false    Update current symlink after build (default: false)
  --publish-buildcache true|false Push Spack buildcache after build (default: true)
  --spack-install-args ARGS       Extra args for spack install (default: -p 1)
  --keep-running                  Leave container running instead of stopping it
  -h, --help                      Show this help
USAGE
}

OS_NAME="rocky9"
GIT_REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '%s' main)"
REPO_URL="${REPO_URL:-https://github.com/mmrezaie/chapar.git}"
INCUS_REMOTE="${INCUS_REMOTE:-}"
RESOURCES_SOURCE="${RESOURCES_SOURCE:-/resources}"
HPCSIM_ROOT="${HPCSIM_ROOT:-/resources/share/hpcsim}"
REPO_DIR="${REPO_DIR:-/root/workspace/chapar}"
PUBLISH_CURRENT="${PUBLISH_CURRENT:-false}"
PUBLISH_BUILDCACHE="${PUBLISH_BUILDCACHE:-true}"
SPACK_INSTALL_ARGS="${SPACK_INSTALL_ARGS:-}"
if [ -z "${SPACK_INSTALL_ARGS}" ]; then
    SPACK_INSTALL_ARGS="-p 1"
fi
KEEP_RUNNING="false"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-chapar}"
RUN_ID="${GITHUB_RUN_ID:-manual-$(date +%Y%m%d%H%M%S)}"
RELEASE_ID="${RELEASE_ID:-${RUN_ID}}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --os) OS_NAME="$2"; shift 2 ;;
        --release-id) RELEASE_ID="$2"; shift 2 ;;
        --git-ref) GIT_REF="$2"; shift 2 ;;
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --incus-remote) INCUS_REMOTE="$2"; shift 2 ;;
        --resources-source) RESOURCES_SOURCE="$2"; shift 2 ;;
        --hpcsim-root) HPCSIM_ROOT="$2"; shift 2 ;;
        --repo-dir) REPO_DIR="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --publish-current) PUBLISH_CURRENT="$2"; shift 2 ;;
        --publish-buildcache) PUBLISH_BUILDCACHE="$2"; shift 2 ;;
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
            --release-id "${RELEASE_ID}" \
            --git-ref "${GIT_REF}" \
            --repo-url "${REPO_URL}" \
            --incus-remote "${INCUS_REMOTE}" \
            --resources-source "${RESOURCES_SOURCE}" \
            --hpcsim-root "${HPCSIM_ROOT}" \
            --repo-dir "${REPO_DIR}" \
            --run-id "${RUN_ID}" \
            --publish-current "${PUBLISH_CURRENT}" \
            --publish-buildcache "${PUBLISH_BUILDCACHE}" \
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

case "${PUBLISH_CURRENT}" in
    true|false) ;;
    *) echo "ERROR: --publish-current must be true or false" >&2; exit 1 ;;
esac

case "${PUBLISH_BUILDCACHE}" in
    true|false) ;;
    *) echo "ERROR: --publish-buildcache must be true or false" >&2; exit 1 ;;
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
    /tmp/chapar-prepare-hpcsim-root.sh \
    /tmp/chapar-push-buildcache.sh

incus file push ci/bootstrap-rocky.sh "${INSTANCE}/tmp/chapar-bootstrap-rocky.sh"
incus file push ci/container-build.sh "${INSTANCE}/tmp/chapar-container-build.sh"
incus file push ci/prepare-hpcsim-root.sh "${INSTANCE}/tmp/chapar-prepare-hpcsim-root.sh"
incus file push ci/push-buildcache.sh "${INSTANCE}/tmp/chapar-push-buildcache.sh"

incus exec "${INSTANCE}" -- bash /tmp/chapar-bootstrap-rocky.sh

incus exec "${INSTANCE}" \
    --env "REPO_URL=${REPO_URL}" \
    --env "GIT_REF=${GIT_REF}" \
    --env "REPO_DIR=${REPO_DIR}" \
    --env "OS_NAME=${OS_NAME}" \
    --env "HPCSIM_ROOT=${HPCSIM_ROOT}" \
    --env "RUN_ID=${RUN_ID}" \
    --env "RELEASE_ID=${RELEASE_ID}" \
    --env "PUBLISH_CURRENT=${PUBLISH_CURRENT}" \
    --env "PUBLISH_BUILDCACHE=${PUBLISH_BUILDCACHE}" \
    --env "PREPARE_HPCSIM_ROOT_SCRIPT=/tmp/chapar-prepare-hpcsim-root.sh" \
    --env "PUSH_BUILDCACHE_SCRIPT=/tmp/chapar-push-buildcache.sh" \
    --env "SPACK_INSTALL_ARGS=${SPACK_INSTALL_ARGS}" \
    -- bash /tmp/chapar-container-build.sh
