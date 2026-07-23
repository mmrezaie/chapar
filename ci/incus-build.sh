#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/incus-build.sh [options]

Options:
  --os rocky9|rocky10|all         Target container OS (default: rocky9)
  --env-name NAME                 Chapar environment name (default: hpcsim)
  --env-path PATH                 Spack environment path (default: envs/<env-name>)
  --build-action concretize|build  CI action to run (default: build)
  --build-mode auto|release|spack  Use env release helper or direct Spack (default: auto)
  --release-id ID                 Release/run ID (default: run ID)
  --git-ref REF                   Git branch/tag/SHA to build (default: current branch)
  --repo-url URL                  Repository URL to clone inside container
  --incus-remote REMOTE           Incus remote name; empty means default local remote
  --resources-source PATH         Incus host path for resources export (default: /resources)
  --bootstrap-script PATH         Bootstrap script pushed into the container
  --env-root PATH                 Path inside container for environment output (default: /resources/chapar/<env-name>)
  --hpcsim-root PATH              Compatibility alias for --env-root when --env-name=hpcsim
  --buildcache-root PATH          Path inside container for shared binary cache (default: /resources/chapar/cache/buildcache)
  --ccache-root PATH              Path inside container for shared compiler ccache (default: /resources/chapar/cache/ccache)
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
ENV_NAME="${ENV_NAME:-hpcsim}"
ENV_PATH="${ENV_PATH:-}"
CHAPAR_ENV_ACTION="${CHAPAR_ENV_ACTION:-build}"
CHAPAR_ENV_BUILD_MODE="${CHAPAR_ENV_BUILD_MODE:-auto}"
GIT_REF="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '%s' main)"
REPO_URL="${REPO_URL:-https://github.com/mmrezaie/chapar.git}"
INCUS_REMOTE="${INCUS_REMOTE:-}"
RESOURCES_SOURCE="${RESOURCES_SOURCE:-/resources}"
BOOTSTRAP_SCRIPT="${CHAPAR_BOOTSTRAP_SCRIPT:-}"
CHAPAR_ENV_ROOT="${CHAPAR_ENV_ROOT:-}"
HPCSIM_ROOT="${HPCSIM_ROOT:-}"
CHAPAR_BUILDCACHE_ROOT="${CHAPAR_BUILDCACHE_ROOT:-/resources/chapar/cache/buildcache}"
CHAPAR_CCACHE_ROOT="${CHAPAR_CCACHE_ROOT:-/resources/chapar/cache/ccache}"
CHAPAR_INSTALL_MODE="${CHAPAR_INSTALL_MODE:-}"
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
        --env-name) ENV_NAME="$2"; shift 2 ;;
        --env-path) ENV_PATH="$2"; shift 2 ;;
        --build-action) CHAPAR_ENV_ACTION="$2"; shift 2 ;;
        --build-mode) CHAPAR_ENV_BUILD_MODE="$2"; shift 2 ;;
        --release-id) RELEASE_ID="$2"; shift 2 ;;
        --git-ref) GIT_REF="$2"; shift 2 ;;
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --incus-remote) INCUS_REMOTE="$2"; shift 2 ;;
        --resources-source) RESOURCES_SOURCE="$2"; shift 2 ;;
        --bootstrap-script) BOOTSTRAP_SCRIPT="$2"; shift 2 ;;
        --env-root) CHAPAR_ENV_ROOT="$2"; shift 2 ;;
        --hpcsim-root) HPCSIM_ROOT="$2"; shift 2 ;;
        --buildcache-root) CHAPAR_BUILDCACHE_ROOT="$2"; shift 2 ;;
        --ccache-root) CHAPAR_CCACHE_ROOT="$2"; shift 2 ;;
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

    for one_os in rocky9 rocky10; do
        "$0" \
            --os "${one_os}" \
            --env-name "${ENV_NAME}" \
            --env-path "${ENV_PATH}" \
            --build-action "${CHAPAR_ENV_ACTION}" \
            --build-mode "${CHAPAR_ENV_BUILD_MODE}" \
            --release-id "${RELEASE_ID}" \
            --git-ref "${GIT_REF}" \
            --repo-url "${REPO_URL}" \
            --incus-remote "${INCUS_REMOTE}" \
            --resources-source "${RESOURCES_SOURCE}" \
            --bootstrap-script "${BOOTSTRAP_SCRIPT}" \
            --env-root "${CHAPAR_ENV_ROOT}" \
            --hpcsim-root "${HPCSIM_ROOT}" \
            --buildcache-root "${CHAPAR_BUILDCACHE_ROOT}" \
            --ccache-root "${CHAPAR_CCACHE_ROOT}" \
            --repo-dir "${REPO_DIR}" \
            --run-id "${RUN_ID}" \
            --publish-current "${PUBLISH_CURRENT}" \
            --publish-buildcache "${PUBLISH_BUILDCACHE}" \
            --spack-install-args "${SPACK_INSTALL_ARGS}" \
            "${extra_args[@]}"
    done
    exit 0
fi

case "${ENV_NAME}" in
    ""|.|..|*/*|*[!A-Za-z0-9._-]*) echo "ERROR: --env-name must match [A-Za-z0-9._-]+, got ${ENV_NAME}" >&2; exit 1 ;;
esac

if [ -z "${ENV_PATH}" ]; then
    ENV_PATH="envs/${ENV_NAME}"
fi
case "${ENV_PATH}" in
    envs/*) ;;
    *) echo "ERROR: --env-path must be under envs/: ${ENV_PATH}" >&2; exit 1 ;;
esac

case "${CHAPAR_ENV_ACTION}" in
    concretize|build) ;;
    *) echo "ERROR: --build-action must be concretize or build, got ${CHAPAR_ENV_ACTION}" >&2; exit 1 ;;
esac

case "${CHAPAR_ENV_BUILD_MODE}" in
    auto|release|spack) ;;
    *) echo "ERROR: --build-mode must be auto, release, or spack, got ${CHAPAR_ENV_BUILD_MODE}" >&2; exit 1 ;;
esac

if [ -z "${CHAPAR_ENV_ROOT}" ]; then
    if [ -n "${HPCSIM_ROOT}" ]; then
        CHAPAR_ENV_ROOT="${HPCSIM_ROOT}"
    else
        CHAPAR_ENV_ROOT="/resources/chapar/${ENV_NAME}"
    fi
fi
if [ "${ENV_NAME}" = "hpcsim" ]; then
    HPCSIM_ROOT="${CHAPAR_ENV_ROOT}"
fi

if [ -z "${CHAPAR_INSTALL_MODE}" ]; then
    if [ -n "${CHAPAR_ENV_ROOT}" ]; then
        CHAPAR_INSTALL_MODE="public"
    else
        CHAPAR_INSTALL_MODE="home"
    fi
fi

case "${OS_NAME}" in
    rocky9) IMAGE="${ROCKY9_IMAGE:-images:rockylinux/9}" ;;
    rocky10) IMAGE="${ROCKY10_IMAGE:-images:rockylinux/10}" ;;
    ubuntu*) IMAGE="${UBUNTU_IMAGE:-images:ubuntu/${OS_NAME#ubuntu}}" ;;
    almalinux*) IMAGE="${ALMA_IMAGE:-images:almalinux/${OS_NAME#almalinux}}" ;;
    *) echo "ERROR: --os must be rocky9, rocky10, ubuntu<version>, almalinux<version>, or all" >&2; exit 1 ;;
esac

if [ -z "${BOOTSTRAP_SCRIPT}" ]; then
    case "${OS_NAME}" in
        rocky9|rocky10|almalinux*) BOOTSTRAP_SCRIPT="ci/bootstrap-rocky.sh" ;;
        *) echo "ERROR: no default bootstrap script for ${OS_NAME}; pass --bootstrap-script" >&2; exit 1 ;;
    esac
fi
[ -r "${BOOTSTRAP_SCRIPT}" ] || { echo "ERROR: missing bootstrap script: ${BOOTSTRAP_SCRIPT}" >&2; exit 1; }

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
incus exec "${INSTANCE}" -- rm -rf /tmp/chapar-bootstrap
incus exec "${INSTANCE}" -- mkdir -p /tmp/chapar-bootstrap/ci /tmp/chapar-bootstrap/etc/profile.d

incus file push "${BOOTSTRAP_SCRIPT}" "${INSTANCE}/tmp/chapar-bootstrap/ci/bootstrap.sh"
incus file push etc/profile.d/zz-chapar-hpcsim.sh "${INSTANCE}/tmp/chapar-bootstrap/etc/profile.d/zz-chapar-hpcsim.sh"
incus file push ci/container-build.sh "${INSTANCE}/tmp/chapar-container-build.sh"
incus file push ci/prepare-hpcsim-root.sh "${INSTANCE}/tmp/chapar-prepare-hpcsim-root.sh"
incus file push ci/push-buildcache.sh "${INSTANCE}/tmp/chapar-push-buildcache.sh"

if [ "${ENV_NAME}" = "vlad" ]; then
    incus exec "${INSTANCE}" -- bash -lc "cat > /tmp/chapar-env-site.env <<'EOF'
CHAPAR_INSTALL_MODE=public
VLAD_PUBLIC_ROOT=${CHAPAR_ENV_ROOT}
CHAPAR_ENV_ROOT=${CHAPAR_ENV_ROOT}
CHAPAR_BUILDCACHE_ROOT=${CHAPAR_BUILDCACHE_ROOT}
CHAPAR_CCACHE_ROOT=${CHAPAR_CCACHE_ROOT}
CHAPAR_MODULE_ROOT=/resources/chapar/vlad/modulefiles
PUBLISH_BUILDCACHE=true
PUBLISH_CURRENT=${PUBLISH_CURRENT}
EOF"
elif [ "${ENV_NAME}" = "hpcsim" ]; then
    incus exec "${INSTANCE}" -- bash -lc "cat > /tmp/chapar-env-site.env <<'EOF'
CHAPAR_INSTALL_MODE=${CHAPAR_INSTALL_MODE}
HPCSIM_PUBLIC_ROOT=${HPCSIM_ROOT}
CHAPAR_ENV_ROOT=${CHAPAR_ENV_ROOT}
CHAPAR_BUILDCACHE_ROOT=${CHAPAR_BUILDCACHE_ROOT}
CHAPAR_CCACHE_ROOT=${CHAPAR_CCACHE_ROOT}
PUBLISH_BUILDCACHE=${PUBLISH_BUILDCACHE}
PUBLISH_CURRENT=${PUBLISH_CURRENT}
EOF"
else
    incus exec "${INSTANCE}" -- bash -lc "cat > /tmp/chapar-env-site.env <<'EOF'
CHAPAR_INSTALL_MODE=${CHAPAR_INSTALL_MODE}
HPCSIM_PUBLIC_ROOT=${HPCSIM_ROOT}
CHAPAR_ENV_ROOT=${CHAPAR_ENV_ROOT}
CHAPAR_BUILDCACHE_ROOT=${CHAPAR_BUILDCACHE_ROOT}
CHAPAR_CCACHE_ROOT=${CHAPAR_CCACHE_ROOT}
PUBLISH_BUILDCACHE=${PUBLISH_BUILDCACHE}
PUBLISH_CURRENT=${PUBLISH_CURRENT}
EOF"
fi

incus exec "${INSTANCE}" -- bash -lc 'cd /tmp/chapar-bootstrap && bash ci/bootstrap.sh'

incus exec "${INSTANCE}" \
    --env "REPO_URL=${REPO_URL}" \
    --env "GIT_REF=${GIT_REF}" \
    --env "REPO_DIR=${REPO_DIR}" \
    --env "OS_NAME=${OS_NAME}" \
    --env "ENV_NAME=${ENV_NAME}" \
    --env "ENV_PATH=${ENV_PATH}" \
    --env "CHAPAR_ENV_ROOT=${CHAPAR_ENV_ROOT}" \
    --env "CHAPAR_ENV_ACTION=${CHAPAR_ENV_ACTION}" \
    --env "CHAPAR_ENV_BUILD_MODE=${CHAPAR_ENV_BUILD_MODE}" \
    --env "HPCSIM_ROOT=${HPCSIM_ROOT}" \
    --env "CHAPAR_BUILDCACHE_ROOT=${CHAPAR_BUILDCACHE_ROOT}" \
    --env "CHAPAR_CCACHE_ROOT=${CHAPAR_CCACHE_ROOT}" \
    --env "CHAPAR_SITE_CONFIG=/tmp/chapar-env-site.env" \
    --env "RUN_ID=${RUN_ID}" \
    --env "RELEASE_ID=${RELEASE_ID}" \
    --env "PUBLISH_CURRENT=${PUBLISH_CURRENT}" \
    --env "PUBLISH_BUILDCACHE=${PUBLISH_BUILDCACHE}" \
    --env "PREPARE_HPCSIM_ROOT_SCRIPT=/tmp/chapar-prepare-hpcsim-root.sh" \
    --env "PUSH_BUILDCACHE_SCRIPT=/tmp/chapar-push-buildcache.sh" \
    --env "SPACK_INSTALL_ARGS=${SPACK_INSTALL_ARGS}" \
    -- bash /tmp/chapar-container-build.sh
