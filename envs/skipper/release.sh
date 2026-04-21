#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="${ENV_PATH:-${SCRIPT_DIR}}"

BASE_ROOT="${BASE_ROOT:-/share/base}"
RELEASES_ROOT="${RELEASES_ROOT:-${BASE_ROOT}/releases}"
CURRENT_LINK="${CURRENT_LINK:-${BASE_ROOT}/current}"

usage() {
    cat <<'EOF'
Usage:
  release.sh build <release-id>
  release.sh test-hints <release-id>
  release.sh promote <release-id> --yes
  release.sh status

Environment variables:
  ENV_PATH       Spack environment path (default: envs/skipper)
  BASE_ROOT      Root for production links (default: /share/base)
  RELEASES_ROOT  Root for release installs (default: /share/base/releases)
  CURRENT_LINK   Symlink used as active release (default: /share/base/current)

What it does:
  build       Builds skipper specs into an isolated release install tree
              without touching production paths.
  test-hints  Prints module-use commands for release validation.
  promote     Atomically switches current release symlink and updates
              compatibility links (/share/base/bin, modulefiles, lmods).
  status      Shows available releases and active symlink target.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

ensure_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found"
}

release_paths() {
    local release_id="$1"
    RELEASE_DIR="${RELEASES_ROOT}/${release_id}"
    RELEASE_BIN="${RELEASE_DIR}/bin"
    RELEASE_MODULES="${RELEASE_DIR}/modulefiles"
    RELEASE_LMODS="${RELEASE_DIR}/lmods"
}

make_override_scope() {
    local release_id="$1"
    local scope_dir
    scope_dir="$(mktemp -d "${TMPDIR:-/tmp}/skipper-release-scope.XXXXXX")"
    release_paths "${release_id}"

    cat > "${scope_dir}/config.yaml" <<EOF
config:
  install_tree:
    root: ${RELEASE_BIN}
EOF

    cat > "${scope_dir}/modules.yaml" <<EOF
modules:
  default:
    roots:
      tcl: ${RELEASE_MODULES}
      lmod: ${RELEASE_LMODS}
EOF

    echo "${scope_dir}"
}

replace_with_symlink() {
    local link_path="$1"
    local target_path="$2"
    local backup=""
    local ts

    [ -e "${target_path}" ] || die "target path does not exist: ${target_path}"

    if [ -L "${link_path}" ]; then
        ln -sfn "${target_path}" "${link_path}"
        return 0
    fi

    if [ -e "${link_path}" ]; then
        ts="$(date +%Y%m%d%H%M%S)"
        backup="${link_path}.bak.${ts}"
        mv "${link_path}" "${backup}"
        echo "Backed up ${link_path} -> ${backup}"
    fi

    ln -s "${target_path}" "${link_path}"
}

cmd_build() {
    local release_id="${1:-}"
    local scope_dir=""
    local arch_triplet=""

    [ -n "${release_id}" ] || die "release-id is required for build"

    ensure_cmd spack
    mkdir -p "${RELEASES_ROOT}"
    scope_dir="$(make_override_scope "${release_id}")"
    trap 'rm -rf "'"${scope_dir}"'"' EXIT

    echo "Building release ${release_id}"
    echo "  env:      ${ENV_PATH}"
    echo "  install:  ${RELEASE_BIN}"
    echo "  modules:  ${RELEASE_MODULES}"

    spack -e "${ENV_PATH}" -C "${scope_dir}" concretize -f
    spack -e "${ENV_PATH}" -C "${scope_dir}" install --fail-fast
    spack -e "${ENV_PATH}" -C "${scope_dir}" module tcl refresh -y

    arch_triplet="$(spack -e "${ENV_PATH}" -C "${scope_dir}" arch)"
    cat <<EOF
Release build complete.
Test with:
  module use ${RELEASE_MODULES}/${arch_triplet}
  module --ignore_cache avail
EOF
}

cmd_test_hints() {
    local release_id="${1:-}"
    local arch_triplet=""

    [ -n "${release_id}" ] || die "release-id is required for test-hints"
    ensure_cmd spack
    release_paths "${release_id}"

    arch_triplet="$(spack arch)"
    cat <<EOF
Canary validation commands:
  module use ${RELEASE_MODULES}/${arch_triplet}
  module --ignore_cache avail
  # run application smoke tests here
  module purge
EOF
}

cmd_promote() {
    local release_id="${1:-}"
    local confirm="${2:-}"

    [ -n "${release_id}" ] || die "release-id is required for promote"
    [ "${confirm}" = "--yes" ] || die "promote is destructive; pass --yes"

    release_paths "${release_id}"
    [ -d "${RELEASE_BIN}" ] || die "missing release install tree: ${RELEASE_BIN}"
    [ -d "${RELEASE_MODULES}" ] || die "missing release modules tree: ${RELEASE_MODULES}"
    mkdir -p "${BASE_ROOT}"

    replace_with_symlink "${CURRENT_LINK}" "${RELEASE_DIR}"
    replace_with_symlink "${BASE_ROOT}/bin" "${CURRENT_LINK}/bin"
    replace_with_symlink "${BASE_ROOT}/modulefiles" "${CURRENT_LINK}/modulefiles"
    replace_with_symlink "${BASE_ROOT}/lmods" "${CURRENT_LINK}/lmods"

    echo "Promoted release ${release_id}"
    echo "  current: $(readlink "${CURRENT_LINK}" 2>/dev/null || echo "${CURRENT_LINK}")"
}

cmd_status() {
    echo "Releases root: ${RELEASES_ROOT}"
    if [ -d "${RELEASES_ROOT}" ]; then
        ls -1 "${RELEASES_ROOT}"
    else
        echo "(none)"
    fi
    echo
    if [ -L "${CURRENT_LINK}" ]; then
        echo "Current: ${CURRENT_LINK} -> $(readlink "${CURRENT_LINK}")"
    else
        echo "Current: ${CURRENT_LINK} (not a symlink)"
    fi
}

main() {
    local cmd="${1:-}"
    case "${cmd}" in
        build)
            shift
            cmd_build "$@"
            ;;
        test-hints)
            shift
            cmd_test_hints "$@"
            ;;
        promote)
            shift
            cmd_promote "$@"
            ;;
        status)
            shift
            cmd_status "$@"
            ;;
        -h|--help|help|"")
            usage
            ;;
        *)
            die "unknown command: ${cmd}"
            ;;
    esac
}

main "$@"
