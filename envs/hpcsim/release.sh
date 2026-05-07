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

validate_release_id() {
    local release_id="$1"

    case "${release_id}" in
        ""|.|..|*/*|*[!A-Za-z0-9._-]*)
            die "release-id must match [A-Za-z0-9._-]+ and cannot be '.' or '..': ${release_id}"
            ;;
    esac
}

validate_hpcsim_root() {
    local home_root="${HOME}/resources/share/hpcsim"

    case "${HPCSIM_ROOT}" in
        /*) ;;
        *) die "HPCSIM_ROOT must be an absolute path: ${HPCSIM_ROOT}" ;;
    esac

    case "${HPCSIM_ROOT}" in
        /|*'/../'*|*/..|*'/./'*|*/.|*[!A-Za-z0-9._/+-]*)
            die "HPCSIM_ROOT is not an approved simple shared hpcsim path: ${HPCSIM_ROOT}"
            ;;
    esac

    case "${HPCSIM_ROOT}" in
        /resources/share/hpcsim|/resources/share/hpcsim/*|/resources/chapar/hpcsim|/resources/chapar/hpcsim/*|"${home_root}"|"${home_root}"/*)
            ;;
        *)
            if [ "${CHAPAR_ALLOW_UNSAFE_HPCSIM_ROOT:-false}" != "true" ]; then
                die "HPCSIM_ROOT must be under /resources/share/hpcsim, /resources/chapar/hpcsim, or ${home_root}; set CHAPAR_ALLOW_UNSAFE_HPCSIM_ROOT=true for local testing"
            fi
            ;;
    esac
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
    validate_hpcsim_root
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
  binary_index_ttl: 600
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
    tcl:
      exclude_implicits: false
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

trust_buildcache_keys() {
    if ! spack -C "${BUILD_SCOPE_DIR}" buildcache keys --install --trust; then
        echo "WARNING: failed to install buildcache keys; signed online caches may be skipped" >&2
    fi
}

cuda_target_root() {
    local cuda_prefix="$1"
    local candidate

    for candidate in "${cuda_prefix}"/targets/*-linux; do
        [ -d "${candidate}" ] || continue
        [ -r "${candidate}/include/cuda_runtime.h" ] || continue
        compgen -G "${candidate}/lib/libcudart.so*" >/dev/null || continue
        printf '%s\n' "${candidate}"
        return 0
    done

    return 1
}

install_cuda_libfabric_specs() {
    local install_args_ref=("$@")
    local cuda_prefix
    local cuda_root
    local spec_line
    local spec_hash
    local spec_hashes=()
    local missing_hashes=()
    local seen_hashes=()
    local saved_cpath="${CPATH:-}"
    local saved_library_path="${LIBRARY_PATH:-}"

    case "${OS_NAME}" in
        rocky8|rocky9) ;;
        *) return 0 ;;
    esac

    while IFS= read -r spec_line; do
        case "${spec_line}" in
            *libfabric*+cuda*HASH=/*) ;;
            *) continue ;;
        esac
        spec_hash="${spec_line##*HASH=}"
        [ -n "${spec_hash}" ] || continue
        case " ${seen_hashes[*]} " in
            *" ${spec_hash} "*) continue ;;
        esac
        seen_hashes+=("${spec_hash}")
        spec_hashes+=("${spec_hash}")
    done < <(spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" find -c -d --no-groups --format "{name} {variants} HASH={/hash}")

    [ "${#spec_hashes[@]}" -gt 0 ] || return 0

    for spec_hash in "${spec_hashes[@]}"; do
        if spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" location -i "${spec_hash}" >/dev/null 2>&1; then
            continue
        fi
        missing_hashes+=("${spec_hash}")
    done

    if [ "${#missing_hashes[@]}" -eq 0 ]; then
        echo "==> CUDA-aware libfabric specs already installed"
        echo "    count: ${#spec_hashes[@]}"
        return 0
    fi

    echo "==> Preinstalling CUDA-aware libfabric specs"
    echo "    missing: ${#missing_hashes[@]} of ${#spec_hashes[@]}"

    for spec_hash in "${missing_hashes[@]}"; do
        spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" install --only-concrete "${install_args_ref[@]}" --only dependencies "${spec_hash}"
    done
    cuda_prefix="$(spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" location -i "cuda@13.0.2")"
    cuda_root="$(cuda_target_root "${cuda_prefix}")" || die "could not locate CUDA target runtime under ${cuda_prefix}"
    [ -d "${cuda_root}/lib/stubs" ] || die "could not locate CUDA driver stubs under ${cuda_root}/lib/stubs"

    export CPATH="${cuda_root}/include${saved_cpath:+:${saved_cpath}}"
    export LIBRARY_PATH="${cuda_root}/lib:${cuda_root}/lib/stubs${saved_library_path:+:${saved_library_path}}"
    for spec_hash in "${missing_hashes[@]}"; do
        spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" install --only-concrete --dirty "${install_args_ref[@]}" --only package "${spec_hash}"
    done
    export CPATH="${saved_cpath}"
    export LIBRARY_PATH="${saved_library_path}"
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

write_root_module_specs() {
    local output_file="$1"

    spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" python -c \
        'exec("import spack.environment as ev\nimport sys\nenv = ev.active_environment()\nif env is None:\n    sys.exit(\"no active Spack environment\")\nfor spec in env.concrete_roots():\n    print(\"{} {}/{}\".format(spec.dag_hash(), spec.name, spec.version))")' \
        > "${output_file}"
}

validate_root_module_names() {
    local root_specs_file="$1"
    local names_file
    local duplicates_file
    local module_name

    names_file="${BUILD_SCOPE_DIR}/root-module-names.txt"
    duplicates_file="${BUILD_SCOPE_DIR}/duplicate-root-module-names.txt"

    while read -r _ module_name; do
        [ -n "${module_name}" ] || continue
        printf '%s\n' "${module_name}"
    done < "${root_specs_file}" > "${names_file}"
    sort "${names_file}" | uniq -d > "${duplicates_file}"

    if [ -s "${duplicates_file}" ]; then
        echo "ERROR: hpcsim root module names must be unique because module hashes are disabled." >&2
        echo "Duplicate root module names:" >&2
        while IFS= read -r module_name; do
            echo "  ${module_name}" >&2
        done < "${duplicates_file}"
        echo "Fix the root specs instead of adding hash suffixes to module names." >&2
        return 1
    fi
}

refresh_root_modules() {
    local root_specs_file
    local root_hash
    local module_name
    local root_hashes=()

    root_specs_file="${BUILD_SCOPE_DIR}/root-module-specs.txt"
    write_root_module_specs "${root_specs_file}"
    validate_root_module_names "${root_specs_file}"

    while read -r root_hash module_name; do
        [ -n "${root_hash}" ] || continue
        [ -n "${module_name}" ] || continue
        root_hashes+=("/${root_hash}")
    done < "${root_specs_file}"

    [ "${#root_hashes[@]}" -gt 0 ] || die "no hpcsim root specs found for module generation"
    spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" module tcl refresh -y "${root_hashes[@]}"
}

resolve_release_dir() {
    local release_id="${1:-}"
    local release_dir

    set_paths
    if [ -n "${release_id}" ]; then
        validate_release_id "${release_id}"
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
    validate_release_id "${RELEASE_ID}"
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
    trust_buildcache_keys
    case "${OS_NAME}" in
        rocky8)
            # Rocky 8's system GCC is too old for Node 24 and CUDA 13 host builds.
            spack -C "${scope_dir}" install "${install_args[@]}" "gcc@15+profiled %gcc"
            ;;
        rocky9)
            # Node 24 needs a newer C++ toolchain than Rocky 9's system GCC 11.
            spack -C "${scope_dir}" install "${install_args[@]}" "gcc@15+profiled %gcc"
            ;;
    esac

    spack -e "${ENV_PATH}" -C "${scope_dir}" concretize -f
    install_cuda_libfabric_specs "${install_args[@]}"
    spack -e "${ENV_PATH}" -C "${scope_dir}" install --only-concrete "${install_args[@]}"
    refresh_root_modules

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
    validate_release_id "${release_id}"
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
