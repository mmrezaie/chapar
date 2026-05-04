#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="${ENV_PATH:-${SCRIPT_DIR}}"
HPCSIM_ROOT="${HPCSIM_ROOT:-/resources/share/hpcsim}"
SPACK_INSTALL_ARGS="${SPACK_INSTALL_ARGS:-}"
PUBLISH_BUILDCACHE="${PUBLISH_BUILDCACHE:-false}"
BUILD_SCOPE_DIR=""
REFRESH_BUILDCACHE_ON_EXIT="false"

usage() {
    cat <<'EOF'
Usage:
  release.sh build <release-id> [--promote]
  release.sh promote <release-id>
  release.sh module-use [release-id]
  release.sh status

Environment:
  ENV_PATH             Spack environment path. Default: envs/hpcsim
  HPCSIM_ROOT          Shared root. Default: /resources/share/hpcsim
  OS_NAME              rocky8, rocky9, or macos. Auto-detected when unset.
  SPACK_INSTALL_ARGS   Extra arguments passed to spack install.

Release layout:
  /resources/share/hpcsim/<os>/store
  /resources/share/hpcsim/<os>/releases/<release-id>
  /resources/share/hpcsim/<os>/current -> releases/<release-id>
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

ensure_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found"
}

detect_os() {
    local detected="${OS_NAME:-}"

    if [ -z "${detected}" ]; then
        case "$(uname -s)" in
            Darwin)
                detected="macos"
                ;;
            Linux)
                if [ -r /etc/os-release ]; then
                    # shellcheck disable=SC1091
                    . /etc/os-release
                    case "${ID:-}:${VERSION_ID%%.*}" in
                        rocky:8|rhel:8|almalinux:8|centos:8) detected="rocky8" ;;
                        rocky:9|rhel:9|almalinux:9|centos:9) detected="rocky9" ;;
                    esac
                fi
                ;;
        esac
    fi

    case "${detected}" in
        rocky8|rocky9|macos) printf '%s\n' "${detected}" ;;
        "") die "could not detect OS_NAME; set OS_NAME=rocky8, rocky9, or macos" ;;
        *) die "unsupported OS_NAME: ${detected}" ;;
    esac
}

set_paths() {
    OS_NAME="$(detect_os)"
    OS_ROOT="${HPCSIM_ROOT}/${OS_NAME}"
    STORE_ROOT="${OS_ROOT}/store"
    RELEASES_ROOT="${OS_ROOT}/releases"
    CURRENT_LINK="${OS_ROOT}/current"
    BUILDCACHE_ROOT="${OS_ROOT}/buildcache"
}

make_scope() {
    local module_root="$1"
    local scope_dir
    scope_dir="$(mktemp -d "${TMPDIR:-/tmp}/hpcsim-release-scope.XXXXXX")"

    cat > "${scope_dir}/config.yaml" <<EOF
config:
  install_tree:
    root: ${STORE_ROOT}
    projections:
      all: "{name}-{version}-{hash}"
  template_dirs:
  - ${OS_ROOT}/templates
  license_dir: ${OS_ROOT}/licenses
  build_stage:
  - \$tempdir/\$user/hpcsim-stage
  - \$user_cache_path/hpcsim/stage
  test_stage: \$user_cache_path/hpcsim/test
  source_cache: \$user_cache_path/source
  misc_cache: \$user_cache_path/cache
  install_missing: true
  binary_index_ttl: 0
EOF

    cat > "${scope_dir}/mirrors.yaml" <<EOF
mirrors:
  hpcsim-${OS_NAME}:
    url: file://${BUILDCACHE_ROOT}
    source: false
    binary: true
    signed: false
    autopush: ${PUBLISH_BUILDCACHE}
EOF

    cat > "${scope_dir}/modules.yaml" <<EOF
modules:
  default:
    roots:
      tcl: ${module_root}/modulefiles
      lmod: ${module_root}/lmods
EOF

    printf '%s\n' "${scope_dir}"
}

refresh_buildcache_index() {
    [ "${PUBLISH_BUILDCACHE}" = "true" ] || return 0
    [ -n "${BUILD_SCOPE_DIR}" ] || return 0
    [ -d "${BUILD_SCOPE_DIR}" ] || return 0

    echo "==> Updating hpcsim buildcache index"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    if ! spack -C "${BUILD_SCOPE_DIR}" buildcache update-index "file://${BUILDCACHE_ROOT}"; then
        echo "WARNING: failed to update hpcsim buildcache index: ${BUILDCACHE_ROOT}" >&2
    fi
}

cleanup_build() {
    local status="$?"

    if [ "${REFRESH_BUILDCACHE_ON_EXIT}" = "true" ]; then
        refresh_buildcache_index || true
    fi

    if [ -n "${BUILD_SCOPE_DIR}" ] && [ -d "${BUILD_SCOPE_DIR}" ]; then
        rm -rf "${BUILD_SCOPE_DIR}"
    fi

    exit "${status}"
}

copy_manifest() {
    local release_dir="$1"

    cp "${ENV_PATH}/spack.yaml" "${release_dir}/spack.yaml"
    if [ -f "${ENV_PATH}/spack.lock" ]; then
        cp "${ENV_PATH}/spack.lock" "${release_dir}/spack.lock"
    fi

    {
        printf 'release_id: %s\n' "${RELEASE_ID}"
        printf 'os: %s\n' "${OS_NAME}"
        printf 'built_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'env_path: %s\n' "${ENV_PATH}"
        printf 'store: %s\n' "${STORE_ROOT}"
    } > "${release_dir}/metadata.txt"
}

resolve_release_dir() {
    local release_id="${1:-}"
    local release_dir

    set_paths
    if [ -n "${release_id}" ]; then
        release_dir="${RELEASES_ROOT}/${release_id}"
    else
        release_dir="${CURRENT_LINK}"
    fi

    [ -d "${release_dir}" ] || die "missing release directory: ${release_dir}"
    (cd -P "${release_dir}" && pwd)
}

cmd_build() {
    RELEASE_ID="${1:-}"
    local promote="${2:-}"
    local staging_dir
    local final_dir
    local scope_dir
    local arch_triplet

    [ -n "${RELEASE_ID}" ] || die "release-id is required for build"
    case "${promote}" in
        ""|--promote) ;;
        *) die "unknown build option: ${promote}" ;;
    esac
    case "${PUBLISH_BUILDCACHE}" in
        true|false) ;;
        *) die "PUBLISH_BUILDCACHE must be true or false" ;;
    esac

    ensure_cmd spack
    set_paths

    final_dir="${RELEASES_ROOT}/${RELEASE_ID}"
    staging_dir="${RELEASES_ROOT}/.${RELEASE_ID}.staging.$$"
    [ ! -e "${final_dir}" ] || die "release already exists: ${final_dir}"
    [ ! -e "${staging_dir}" ] || die "staging path already exists: ${staging_dir}"

    mkdir -p "${STORE_ROOT}" "${RELEASES_ROOT}" "${BUILDCACHE_ROOT}" "${staging_dir}/logs"
    scope_dir="$(make_scope "${staging_dir}")"
    BUILD_SCOPE_DIR="${scope_dir}"
    REFRESH_BUILDCACHE_ON_EXIT="${PUBLISH_BUILDCACHE}"
    trap cleanup_build EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    echo "==> Building hpcsim release"
    echo "    os:       ${OS_NAME}"
    echo "    release:  ${RELEASE_ID}"
    echo "    env:      ${ENV_PATH}"
    echo "    store:    ${STORE_ROOT}"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    echo "    staging:  ${staging_dir}"

    read -r -a install_args <<< "${SPACK_INSTALL_ARGS}"
    spack -C "${scope_dir}" buildcache update-index "file://${BUILDCACHE_ROOT}" || true
    spack -e "${ENV_PATH}" -C "${scope_dir}" concretize -f
    spack -e "${ENV_PATH}" -C "${scope_dir}" install "${install_args[@]}"
    spack -e "${ENV_PATH}" -C "${scope_dir}" module tcl refresh -y

    arch_triplet="$(spack -e "${ENV_PATH}" -C "${scope_dir}" arch)"
    copy_manifest "${staging_dir}"

    mv "${staging_dir}" "${final_dir}"
    echo "==> Release build complete"
    echo "    release: ${final_dir}"
    echo "    module:  ${final_dir}/modulefiles/${arch_triplet}"

    if [ "${promote}" = "--promote" ]; then
        cmd_promote "${RELEASE_ID}"
    fi
}

cmd_promote() {
    local release_id="${1:-}"
    local release_dir
    local tmp_link

    [ -n "${release_id}" ] || die "release-id is required for promote"
    set_paths
    release_dir="${RELEASES_ROOT}/${release_id}"
    [ -d "${release_dir}" ] || die "missing release directory: ${release_dir}"
    ensure_cmd perl

    mkdir -p "${OS_ROOT}"
    if [ -e "${CURRENT_LINK}" ] && [ ! -L "${CURRENT_LINK}" ]; then
        die "current exists and is not a symlink: ${CURRENT_LINK}"
    fi

    tmp_link="${OS_ROOT}/.current.$$"
    rm -f "${tmp_link}"
    ln -s "releases/${release_id}" "${tmp_link}"
    perl -e 'rename $ARGV[0], $ARGV[1] or die "$!\n"' "${tmp_link}" "${CURRENT_LINK}"

    echo "==> Promoted hpcsim release"
    echo "    os:      ${OS_NAME}"
    echo "    current: ${CURRENT_LINK} -> releases/${release_id}"
}

cmd_module_use() {
    local release_id="${1:-}"
    local release_dir
    local module_root
    local module_dir

    release_dir="$(resolve_release_dir "${release_id}")"
    module_root="${release_dir}/modulefiles"

    [ -d "${module_root}" ] || die "missing modulefiles directory: ${module_root}"

    for module_dir in "${module_root}"/*; do
        [ -d "${module_dir}" ] || continue
        case "$(basename "${module_dir}")" in
            *-*-*) printf 'module use %s\n' "${module_dir}" ;;
        esac
    done

    cat <<EOF
module avail
EOF
}

cmd_status() {
    set_paths
    echo "hpcsim root: ${HPCSIM_ROOT}"
    echo "os root:     ${OS_ROOT}"
    echo "store:       ${STORE_ROOT}"
    echo "releases:    ${RELEASES_ROOT}"
    if [ -L "${CURRENT_LINK}" ]; then
        echo "current:     ${CURRENT_LINK} -> $(readlink "${CURRENT_LINK}")"
    elif [ -e "${CURRENT_LINK}" ]; then
        echo "current:     ${CURRENT_LINK} (not a symlink)"
    else
        echo "current:     (none)"
    fi
}

main() {
    local cmd="${1:-}"
    case "${cmd}" in
        build)
            shift
            cmd_build "$@"
            ;;
        promote)
            shift
            cmd_promote "$@"
            ;;
        module-use)
            shift
            cmd_module_use "$@"
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
