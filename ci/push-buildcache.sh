#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/push-buildcache.sh --env-path PATH --os rocky9|rocky10 [options]

Options:
  --hpcsim-root PATH          hpcsim release root; defaults from envs/hpcsim/hpcsim-site.env
  --buildcache-root PATH      Shared buildcache root; defaults from envs/hpcsim/hpcsim-site.env
  --buildcache-dir PATH      Override destination buildcache directory
  -h, --help                 Show this help
USAGE
}

ENV_PATH=""
OS_NAME=""
HPCSIM_ROOT="${HPCSIM_ROOT:-}"
CHAPAR_BUILDCACHE_ROOT="${CHAPAR_BUILDCACHE_ROOT:-}"
CHAPAR_INSTALL_TREE_ROOT="${CHAPAR_INSTALL_TREE_ROOT:-}"
BUILDCACHE_DIR=""
SCOPE_DIR=""
INSTALL_TREE_PADDED_LENGTH="256"
BUILDCACHE_LAYOUT_VERSION="install-tree-padded-${INSTALL_TREE_PADDED_LENGTH}"
BUILDCACHE_LAYOUT_MARKER=".chapar-buildcache-layout"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAPAR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
site_config="${CHAPAR_SITE_CONFIG:-${CHAPAR_ROOT}/envs/hpcsim/hpcsim-site.env}"
if [ -r "${site_config}" ]; then
    # shellcheck disable=SC1090
    . "${site_config}"
fi

: "${CHAPAR_INSTALL_MODE:=home}"
: "${CHAPAR_HOME_ROOT:=${HOME}/.spack/chapar}"
: "${HPCSIM_HOME_ROOT:=${CHAPAR_HOME_ROOT}/envs/hpcsim}"
: "${HPCSIM_PUBLIC_ROOT:=}"
: "${CHAPAR_SHARED_CACHE_ROOT:=${CHAPAR_HOME_ROOT}/cache}"
: "${CHAPAR_BUILDCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/buildcache}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --env-path) ENV_PATH="$2"; shift 2 ;;
        --os) OS_NAME="$2"; shift 2 ;;
        --hpcsim-root) HPCSIM_ROOT="$2"; shift 2 ;;
        --buildcache-root) CHAPAR_BUILDCACHE_ROOT="$2"; shift 2 ;;
        --buildcache-dir) BUILDCACHE_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "${ENV_PATH}" ] || [ -z "${OS_NAME}" ]; then
    usage >&2
    exit 1
fi

case "${OS_NAME}" in
    rocky9|rocky10) ;;
    *) echo "ERROR: --os must be rocky9 or rocky10" >&2; exit 1 ;;
esac

if [ -z "${HPCSIM_ROOT}" ]; then
    case "${CHAPAR_INSTALL_MODE}" in
        home) HPCSIM_ROOT="${HPCSIM_HOME_ROOT}" ;;
        public)
            [ -n "${HPCSIM_PUBLIC_ROOT}" ] || { echo "ERROR: HPCSIM_PUBLIC_ROOT is required when CHAPAR_INSTALL_MODE=public" >&2; exit 1; }
            HPCSIM_ROOT="${HPCSIM_PUBLIC_ROOT}"
            ;;
        *) echo "ERROR: CHAPAR_INSTALL_MODE must be home or public, got ${CHAPAR_INSTALL_MODE}" >&2; exit 1 ;;
    esac
fi

if [ -z "${BUILDCACHE_DIR}" ]; then
    BUILDCACHE_DIR="${CHAPAR_BUILDCACHE_ROOT}/${OS_NAME}"
fi

OS_ROOT="${HPCSIM_ROOT}/${OS_NAME}"
# Match release.sh: when the shared cross-environment install tree is
# configured, the store lives under <root>/<arch-triplet>, not <os>/store.
if [ -n "${CHAPAR_INSTALL_TREE_ROOT:-}" ]; then
    arch_triplet="$(spack arch 2>/dev/null || true)"
    [ -n "${arch_triplet}" ] || { echo "ERROR: spack arch failed; cannot resolve shared install tree under ${CHAPAR_INSTALL_TREE_ROOT}" >&2; exit 1; }
    STORE_ROOT="${CHAPAR_INSTALL_TREE_ROOT}/${arch_triplet}"
else
    STORE_ROOT="${OS_ROOT}/store"
fi
SCOPE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hpcsim-buildcache-scope.XXXXXX")"
trap 'rm -rf "${SCOPE_DIR}"' EXIT

cat > "${SCOPE_DIR}/config.yaml" <<EOF
config:
  install_tree:
    root: ${STORE_ROOT}
    padded_length: ${INSTALL_TREE_PADDED_LENGTH}
    projections:
      all: "{name}-{version}-{hash}"
EOF

mkdir -p "${BUILDCACHE_DIR}"

echo "==> Pushing Chapar buildcache"
echo "    env:        ${ENV_PATH}"
echo "    cache root: ${CHAPAR_BUILDCACHE_ROOT}"
echo "    buildcache: ${BUILDCACHE_DIR}"

spack -e "${ENV_PATH}" -C "${SCOPE_DIR}" buildcache push \
    --unsigned \
    --update-index \
    "file://${BUILDCACHE_DIR}"

{
    printf 'layout: %s\n' "${BUILDCACHE_LAYOUT_VERSION}"
    printf 'install_tree_padded_length: %s\n' "${INSTALL_TREE_PADDED_LENGTH}"
    printf 'updated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${BUILDCACHE_DIR}/${BUILDCACHE_LAYOUT_MARKER}"
