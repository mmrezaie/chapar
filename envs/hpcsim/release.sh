#!/usr/bin/env bash
set -euo pipefail

# hpcsim release driver.
#
# This script is intentionally more than a thin `spack install` wrapper. A
# shared hpcsim deployment has a few invariants that are easy to violate when
# debugging CI failures or doing emergency cache repairs:
#
# - The Spack install tree is shared, but module trees are release-local until
#   promotion. A new build may add packages to the shared store, but it must not
#   rewrite the module tree used by running jobs.
# - A release is assembled in `releases/.<id>.staging.<pid>` and moved into place
#   only after installation, module generation, and manifest writing succeed.
#   Promotion is a separate atomic symlink swap of `<os>/current`; when configured,
#   it also atomically updates shared module-root symlinks per architecture.
# - Release builds use a temporary command-line Spack scope. That scope points at
#   the shared install tree, release module root, and per-OS binary buildcache
#   without changing repository, system, or user Spack config.
# - Linux buildcaches must match the current padded install-tree layout. Older
#   unpadded cache entries can fail relocation with `CannotGrowString`, so this
#   script quarantines unmarked destination payloads and only migrates legacy
#   caches after an explicit operator action.
# - hpcsim modules are user-facing and hashless (`{name}/{version}`). The script
#   refreshes modules only for explicit environment roots and fails if two roots
#   would collide on the same visible module name.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAPAR_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHAPAR_SITE_CONFIG_LOADED="false"
ENV_PATH="${ENV_PATH:-${SCRIPT_DIR}}"
HPCSIM_ROOT="${HPCSIM_ROOT:-}"
CHAPAR_BUILDCACHE_ROOT="${CHAPAR_BUILDCACHE_ROOT:-}"
CHAPAR_CCACHE_ROOT="${CHAPAR_CCACHE_ROOT:-}"
CHAPAR_INSTALL_TREE_ROOT="${CHAPAR_INSTALL_TREE_ROOT:-}"
CHAPAR_INSTALL_TREE_PROJECTION="${CHAPAR_INSTALL_TREE_PROJECTION:-}"
CHAPAR_MODULE_ROOT="${CHAPAR_MODULE_ROOT:-}"
SPACK_INSTALL_ARGS="${SPACK_INSTALL_ARGS:-}"
PUBLISH_BUILDCACHE="${PUBLISH_BUILDCACHE:-}"
CHAPAR_CONCRETIZE_TIMEOUT="${CHAPAR_CONCRETIZE_TIMEOUT:-}"
BUILD_SCOPE_DIR=""
BUILD_STAGING_DIR=""
BUILDCACHE_MIGRATION_LOCK_DIR=""
PROMOTE_MODULE_LINK=""
PROMOTE_MODULE_TMP_LINK=""
PROMOTE_MODULE_TARGET=""
REFRESH_BUILDCACHE_ON_EXIT="false"
CCACHE_ROOT=""
# Keep this as a major version to follow Chapar policy: dependency constraints
# may select the latest CUDA 13 patch release, but release helper code should not
# bake in a minor/patch CUDA toolkit version.
CUDA_MAJOR_VERSION="13"
INSTALL_TREE_PADDED_LENGTH="256"
BUILDCACHE_LAYOUT_VERSION="install-tree-padded-${INSTALL_TREE_PADDED_LENGTH}"
BUILDCACHE_LAYOUT_MARKER=".chapar-buildcache-layout"

load_site_config() {
    local site_config
    local env_hpcsim_root="${HPCSIM_ROOT:-}"
    local env_buildcache_root="${CHAPAR_BUILDCACHE_ROOT:-}"
    local env_ccache_root="${CHAPAR_CCACHE_ROOT:-}"
    local env_install_tree_root="${CHAPAR_INSTALL_TREE_ROOT:-}"
    local env_install_tree_projection="${CHAPAR_INSTALL_TREE_PROJECTION:-}"
    local env_module_root="${CHAPAR_MODULE_ROOT:-}"
    local env_install_mode="${CHAPAR_INSTALL_MODE:-}"
    local env_publish_buildcache="${PUBLISH_BUILDCACHE:-}"

    site_config="${CHAPAR_SITE_CONFIG:-${SCRIPT_DIR}/hpcsim-site.env}"
    if [ -r "${site_config}" ]; then
        # shellcheck disable=SC1090
        . "${site_config}"
        CHAPAR_SITE_CONFIG_LOADED="true"
    fi

    # Environment variables passed to one command should still be able to override
    # the local site file.
    [ -n "${env_hpcsim_root}" ] && HPCSIM_ROOT="${env_hpcsim_root}"
    [ -n "${env_buildcache_root}" ] && CHAPAR_BUILDCACHE_ROOT="${env_buildcache_root}"
    [ -n "${env_ccache_root}" ] && CHAPAR_CCACHE_ROOT="${env_ccache_root}"
    [ -n "${env_install_tree_root}" ] && CHAPAR_INSTALL_TREE_ROOT="${env_install_tree_root}"
    [ -n "${env_install_tree_projection}" ] && CHAPAR_INSTALL_TREE_PROJECTION="${env_install_tree_projection}"
    [ -n "${env_module_root}" ] && CHAPAR_MODULE_ROOT="${env_module_root}"
    [ -n "${env_install_mode}" ] && CHAPAR_INSTALL_MODE="${env_install_mode}"
    [ -n "${env_publish_buildcache}" ] && PUBLISH_BUILDCACHE="${env_publish_buildcache}"

    : "${CHAPAR_INSTALL_MODE:=home}"
    : "${CHAPAR_HOME_ROOT:=${HOME}/.spack/chapar}"
    : "${HPCSIM_HOME_ROOT:=${CHAPAR_HOME_ROOT}/envs/hpcsim}"
    : "${HPCSIM_PUBLIC_ROOT:=}"
    : "${CHAPAR_SHARED_CACHE_ROOT:=${CHAPAR_HOME_ROOT}/cache}"
    : "${CHAPAR_BUILDCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/buildcache}"
    : "${CHAPAR_CCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/ccache}"
    : "${CHAPAR_SHARED_GROUP:=}"
    : "${CHAPAR_SHARED_DIR_MODE:=2775}"
    : "${CHAPAR_CCACHE_COMPILERCHECK:=content}"
    : "${PUBLISH_BUILDCACHE:=false}"
    if [ -z "${CHAPAR_INSTALL_TREE_PROJECTION}" ]; then
        if [ -n "${CHAPAR_INSTALL_TREE_ROOT}" ]; then
            CHAPAR_INSTALL_TREE_PROJECTION='{architecture}/{compiler.name}-{compiler.version}/{name}-{version}-{hash}'
        else
            CHAPAR_INSTALL_TREE_PROJECTION='{name}-{version}-{hash}'
        fi
    fi
}

load_site_config

# User-facing CLI help. Keep the usage text focused on operator commands; the
# policy details live in the header above and docs/buildcache.md.
usage() {
    cat <<'EOF'
Usage:
  release.sh build <release-id> [--promote]
  release.sh migrate-buildcache [--force]
  release.sh promote <release-id>
  release.sh publish-modules <release-id>
  release.sh module-use [release-id]
  release.sh status

Environment:
  ENV_PATH             Spack environment path. Default: envs/hpcsim
  HPCSIM_ROOT          Release root. Default comes from envs/hpcsim/hpcsim-site.env:
                       HPCSIM_HOME_ROOT when CHAPAR_INSTALL_MODE=home, or
                       HPCSIM_PUBLIC_ROOT when CHAPAR_INSTALL_MODE=public.
  CHAPAR_HOME_ROOT     Default private root for local Chapar outputs:
                       ~/.spack/chapar.
  CHAPAR_BUILDCACHE_ROOT
                       Shared binary cache root. Default comes from
                       CHAPAR_SHARED_CACHE_ROOT/buildcache.
  CHAPAR_CCACHE_ROOT   Shared compiler ccache root. Default comes from
                        CHAPAR_SHARED_CACHE_ROOT/ccache.
  CHAPAR_INSTALL_TREE_ROOT
                        Optional Spack install tree root. Empty means
                        ${HPCSIM_ROOT}/<os>/store.
  CHAPAR_INSTALL_TREE_PROJECTION
                        Spack install-tree projection. Defaults to package-hash
                        directories, or architecture/compiler directories when
                        CHAPAR_INSTALL_TREE_ROOT is set.
  CHAPAR_MODULE_ROOT   Optional shared module root. Promotion and publish-modules
                        atomically update <arch> symlinks below this root.
  OS_NAME              rocky9 or rocky10. Auto-detected when unset.
  SPACK_INSTALL_ARGS   Extra arguments passed to spack install.
  CHAPAR_CONCRETIZE_TIMEOUT
                       Optional timeout in seconds for final environment
                       concretization. Empty means no timeout.
  CHAPAR_ALLOW_UNMARKED_BUILDCACHE_MIGRATION
                       Set true only after validating a legacy cache was built
                       with the current padded install-tree layout.

Release layout:
  ${CHAPAR_INSTALL_TREE_ROOT:-${HPCSIM_ROOT}/<os>/store}
  ${HPCSIM_ROOT}/<os>/releases/<release-id>
  ${HPCSIM_ROOT}/<os>/current -> releases/<release-id>
  ${CHAPAR_MODULE_ROOT}/<arch> -> release modulefiles, when publish-modules or
                                   promote is used with CHAPAR_MODULE_ROOT set
  ${CHAPAR_BUILDCACHE_ROOT}/<os>
  ${CHAPAR_CCACHE_ROOT}/<os>

Legacy buildcache migration is explicit and one-shot. Run migrate-buildcache
when intentionally retiring old per-release cache directories.
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

# Site roots must be absolute simple paths. Non-home paths are accepted only via
# envs/hpcsim/hpcsim-site.env so datacenter-specific filesystem policy stays outside Git.
validate_simple_absolute_path() {
    local name="$1"
    local value="$2"

    [ -n "${value}" ] || die "${name} is required"
    case "${value}" in
        /*) ;;
        *) die "${name} must be an absolute path: ${value}" ;;
    esac

    case "${value}" in
        /|*'/../'*|*/..|*'/./'*|*/.|*[!A-Za-z0-9._/+-]*)
            die "${name} is not an approved simple path: ${value}"
            ;;
    esac
}

validate_site_backed_path() {
    local name="$1"
    local value="$2"
    local home_prefix="${HOME}/"

    validate_simple_absolute_path "${name}" "${value}"
    case "${value}" in
        "${home_prefix}"*) ;;
        *)
            if [ "${CHAPAR_SITE_CONFIG_LOADED}" != "true" ]; then
                die "${name} points outside HOME but no envs/hpcsim/hpcsim-site.env was loaded: ${value}"
            fi
            ;;
    esac
}

validate_optional_site_backed_path() {
    local name="$1"
    local value="$2"

    [ -n "${value}" ] || return 0
    validate_site_backed_path "${name}" "${value}"
}

validate_install_tree_projection() {
    local value="${CHAPAR_INSTALL_TREE_PROJECTION}"

    [ -n "${value}" ] || die "CHAPAR_INSTALL_TREE_PROJECTION is required"
    case "${value}" in
        /*|.|..|*'/../'*|*/..|*'/./'*|*/.|*[!A-Za-z0-9._{}:/+-]*)
            die "CHAPAR_INSTALL_TREE_PROJECTION is not an approved relative projection: ${value}"
            ;;
    esac
}

resolve_hpcsim_root() {
    if [ -n "${HPCSIM_ROOT}" ]; then
        return 0
    fi

    case "${CHAPAR_INSTALL_MODE}" in
        home)
            HPCSIM_ROOT="${HPCSIM_HOME_ROOT}"
            ;;
        public)
            [ -n "${HPCSIM_PUBLIC_ROOT}" ] || die "HPCSIM_PUBLIC_ROOT is required when CHAPAR_INSTALL_MODE=public"
            HPCSIM_ROOT="${HPCSIM_PUBLIC_ROOT}"
            ;;
        *)
            die "CHAPAR_INSTALL_MODE must be home or public, got ${CHAPAR_INSTALL_MODE}"
            ;;
    esac
}

validate_hpcsim_root() {
    resolve_hpcsim_root
    validate_site_backed_path HPCSIM_ROOT "${HPCSIM_ROOT}"
}

# The buildcache root is separate from HPCSIM_ROOT so binary artifacts can be
# shared across home test releases and public releases at the same site.
validate_buildcache_root() {
    validate_site_backed_path CHAPAR_BUILDCACHE_ROOT "${CHAPAR_BUILDCACHE_ROOT}"
}

validate_ccache_root() {
    validate_site_backed_path CHAPAR_CCACHE_ROOT "${CHAPAR_CCACHE_ROOT}"
}

validate_install_tree_root() {
    validate_optional_site_backed_path CHAPAR_INSTALL_TREE_ROOT "${CHAPAR_INSTALL_TREE_ROOT}"
    validate_install_tree_projection
}

validate_module_root() {
    validate_optional_site_backed_path CHAPAR_MODULE_ROOT "${CHAPAR_MODULE_ROOT}"
}

# OS_NAME controls all per-OS paths and conditional hpcsim specs. CI can set it
# explicitly; interactive use usually relies on auto-detection.
detect_os() {
    local detected="${OS_NAME:-}"

    if [ -z "${detected}" ]; then
        case "$(uname -s)" in
            Darwin)
                detected=""
                ;;
            Linux)
                if [ -r /etc/os-release ]; then
                    # shellcheck disable=SC1091
                    . /etc/os-release
                    case "${ID:-}:${VERSION_ID%%.*}" in
                        rocky:9|rhel:9|almalinux:9|centos:9) detected="rocky9" ;;
                        rocky:10|rhel:10|almalinux:10|centos:10) detected="rocky10" ;;
                    esac
                fi
                ;;
        esac
    fi

    case "${detected}" in
        rocky9|rocky10) printf '%s\n' "${detected}" ;;
        "") die "could not detect OS_NAME; set OS_NAME=rocky9 or rocky10" ;;
        *) die "unsupported OS_NAME: ${detected}" ;;
    esac
}

# Derive all path globals from the validated roots and selected OS. Keeping the
# path calculation in one place avoids accidentally mixing Rocky 9/Rocky 10 stores
# or caches in migration and promotion commands.
set_paths() {
    OS_NAME="$(detect_os)"
    validate_hpcsim_root
    validate_buildcache_root
    validate_ccache_root
    validate_install_tree_root
    validate_module_root
    OS_ROOT="${HPCSIM_ROOT}/${OS_NAME}"
    STORE_ROOT="${CHAPAR_INSTALL_TREE_ROOT:-${OS_ROOT}/store}"
    RELEASES_ROOT="${OS_ROOT}/releases"
    CURRENT_LINK="${OS_ROOT}/current"
    BUILDCACHE_ROOT="${CHAPAR_BUILDCACHE_ROOT}/${OS_NAME}"
    CCACHE_ROOT="${CHAPAR_CCACHE_ROOT}/${OS_NAME}"
}

prepare_shared_directory() {
    local path="$1"
    local label="$2"
    local current_group

    mkdir -p "${path}" || die "could not create ${label}: ${path}"

    if [ -n "${CHAPAR_SHARED_GROUP}" ]; then
        current_group="$(stat -c '%G' "${path}" 2>/dev/null || stat -f '%Sg' "${path}" 2>/dev/null || true)"
        if [ "${current_group}" != "${CHAPAR_SHARED_GROUP}" ]; then
            chgrp "${CHAPAR_SHARED_GROUP}" "${path}" || die "could not set group ${CHAPAR_SHARED_GROUP} on ${label}: ${path}"
        fi
    fi

    chmod "${CHAPAR_SHARED_DIR_MODE}" "${path}" || die "could not set mode ${CHAPAR_SHARED_DIR_MODE} on ${label}: ${path}"
}

configure_ccache() {
    local ccache_tmp

    prepare_shared_directory "${CHAPAR_CCACHE_ROOT}" "shared ccache root"
    prepare_shared_directory "${CCACHE_ROOT}" "${OS_NAME} ccache root"

    ccache_tmp="${CCACHE_TEMPDIR:-${TMPDIR:-/tmp}/${USER}/hpcsim-ccache-tmp/${OS_NAME}}"
    mkdir -p "${ccache_tmp}" || die "could not create ccache temp directory: ${ccache_tmp}"

    export CCACHE_DIR="${CCACHE_ROOT}"
    export CCACHE_TEMPDIR="${ccache_tmp}"
    export CCACHE_UMASK="${CCACHE_UMASK:-002}"
    export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-${CHAPAR_CCACHE_COMPILERCHECK}}"
    if [ -n "${CHAPAR_CCACHE_MAXSIZE:-}" ]; then
        export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-${CHAPAR_CCACHE_MAXSIZE}}"
    fi

    if command -v ccache >/dev/null 2>&1 && [ -n "${CHAPAR_CCACHE_MAXSIZE:-}" ]; then
        ccache --max-size "${CHAPAR_CCACHE_MAXSIZE}" >/dev/null || die "could not set ccache max size: ${CHAPAR_CCACHE_MAXSIZE}"
    fi
}

prepare_release_roots() {
    umask 0002
    prepare_shared_directory "${HPCSIM_ROOT}" "hpcsim release root"
    prepare_shared_directory "${OS_ROOT}" "${OS_NAME} hpcsim root"
    prepare_shared_directory "${STORE_ROOT}" "${OS_NAME} Spack install tree"
    prepare_shared_directory "${RELEASES_ROOT}" "${OS_NAME} releases root"
    if [ -n "${CHAPAR_MODULE_ROOT}" ]; then
        prepare_shared_directory "${CHAPAR_MODULE_ROOT}" "shared module root"
    fi
    prepare_shared_directory "${CHAPAR_BUILDCACHE_ROOT}" "shared buildcache root"
    prepare_shared_directory "${BUILDCACHE_ROOT}" "${OS_NAME} buildcache root"
    configure_ccache
}

# Create a temporary Spack scope for this one release command. The generated
# scope has higher precedence than system/user scopes, which lets CI control
# install_tree, module roots, and buildcache autopush without mutating persistent
# Chapar config.
make_scope() {
    local module_root="$1"
    local scope_dir
    scope_dir="$(mktemp -d "${TMPDIR:-/tmp}/hpcsim-release-scope.XXXXXX")"

    cat > "${scope_dir}/config.yaml" <<EOF
config:
  install_tree:
    root: ${STORE_ROOT}
    padded_length: ${INSTALL_TREE_PADDED_LENGTH}
    projections:
      all: "${CHAPAR_INSTALL_TREE_PROJECTION}"
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

    # Use the same mirror name as the persistent Chapar scopes so this temporary
    # scope overrides autopush while still targeting the shared per-OS cache.
    cat > "${scope_dir}/mirrors.yaml" <<EOF
mirrors:
  chapar-buildcache:
    url: file://${BUILDCACHE_ROOT}
    source: false
    binary: true
    signed: false
    autopush: ${PUBLISH_BUILDCACHE}
EOF

    # Modules are written under the staging release until the build succeeds.
    # That prevents failed builds from modifying the active module tree.
    cat > "${scope_dir}/modules.yaml" <<EOF
modules:
  default:
    roots:
      tcl: ${module_root}/modulefiles
      lmod: ${module_root}/lmods
    tcl:
      exclude_implicits: false
      # Release modules are generated only for root specs. Do not emit module-load
      # statements for dependencies such as external glibc that have no modulefile.
      all:
        autoload: none
EOF

    printf '%s\n' "${scope_dir}"
}

# Buildcache migration/quarantine helpers. The lock uses atomic directory create,
# which is portable enough for the shared NFS resources tree used by CI.
release_buildcache_migration_lock() {
    if [ -n "${BUILDCACHE_MIGRATION_LOCK_DIR}" ] && [ -d "${BUILDCACHE_MIGRATION_LOCK_DIR}" ]; then
        rmdir "${BUILDCACHE_MIGRATION_LOCK_DIR}" 2>/dev/null || true
    fi
    BUILDCACHE_MIGRATION_LOCK_DIR=""
}

acquire_buildcache_migration_lock() {
    local lock_dir="${BUILDCACHE_ROOT}.migration.lock"
    local waited=0

    while ! mkdir "${lock_dir}" 2>/dev/null; do
        if [ "${waited}" -ge 600 ]; then
            echo "WARNING: timed out waiting for buildcache migration lock: ${lock_dir}" >&2
            return 1
        fi
        echo "==> Waiting for buildcache migration lock"
        echo "    lock: ${lock_dir}"
        sleep 5
        waited=$((waited + 5))
    done

    BUILDCACHE_MIGRATION_LOCK_DIR="${lock_dir}"
}

legacy_buildcache_sources() {
    local candidate
    local seen=""
    local candidates=(
        "${OS_ROOT}/buildcache"
    )

    for candidate in "${candidates[@]}"; do
        [ -d "${candidate}" ] || continue
        [ "${candidate}" != "${BUILDCACHE_ROOT}" ] || continue
        case "${seen}" in
            *"|${candidate}|"*) continue ;;
        esac
        seen="${seen}|${candidate}|"
        printf '%s\n' "${candidate}"
    done
}

# The migration sentinel records that the selected legacy source set was handled.
# It prevents normal repeat invocations from quietly re-copying retired caches.
legacy_buildcache_migration_sentinel() {
    printf '%s\n' "${BUILDCACHE_ROOT}/.legacy-buildcache-migration-complete"
}

write_legacy_buildcache_migration_sentinel() {
    local sentinel="$1"
    shift
    local source_dir

    {
        printf 'completed_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'destination: %s\n' "${BUILDCACHE_ROOT}"
        printf 'sources:\n'
        for source_dir in "$@"; do
            printf '  - %s\n' "${source_dir}"
        done
    } > "${sentinel}"
}

buildcache_layout_marker() {
    printf '%s\n' "${BUILDCACHE_ROOT}/${BUILDCACHE_LAYOUT_MARKER}"
}

# Layout markers are the guardrail between the current padded store and older
# unpadded caches. Do not treat an unmarked cache as safe unless an operator has
# validated it and set the explicit migration override.
buildcache_layout_is_current() {
    local marker="${1:-}"

    [ -n "${marker}" ] || marker="$(buildcache_layout_marker)"
    [ -r "${marker}" ] || return 1
    grep -qx "layout: ${BUILDCACHE_LAYOUT_VERSION}" "${marker}" || return 1
    grep -qx "install_tree_padded_length: ${INSTALL_TREE_PADDED_LENGTH}" "${marker}"
}

write_buildcache_layout_marker() {
    local marker

    marker="$(buildcache_layout_marker)"
    {
        printf 'layout: %s\n' "${BUILDCACHE_LAYOUT_VERSION}"
        printf 'install_tree_padded_length: %s\n' "${INSTALL_TREE_PADDED_LENGTH}"
        printf 'updated_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${marker}"
}

buildcache_has_payload() {
    [ -d "${BUILDCACHE_ROOT}/blobs" ] || [ -d "${BUILDCACHE_ROOT}/v3" ] || [ -d "${BUILDCACHE_ROOT}/build_cache" ]
}

buildcache_index_exists() {
    [ -r "${BUILDCACHE_ROOT}/v3/manifests/index/index.manifest.json" ]
}

# Prepare the destination cache before any concretization can reuse binaries.
# If payloads exist without the current layout marker, quarantine them instead of
# letting Spack consider binaries that may not relocate into the padded store.
prepare_buildcache_root() {
    local archive_dir
    local entry
    local source_path

    mkdir -p "${BUILDCACHE_ROOT}"

    if buildcache_layout_is_current; then
        return 0
    fi

    if ! buildcache_has_payload; then
        write_buildcache_layout_marker
        return 0
    fi

    if [ "${CHAPAR_QUARANTINE_INCOMPATIBLE_BUILDCACHE:-true}" != "true" ]; then
        die "buildcache is unmarked for ${BUILDCACHE_LAYOUT_VERSION}: ${BUILDCACHE_ROOT}"
    fi

    echo "==> Quarantining unmarked buildcache contents"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    echo "    reason: old cache entries may not relocate into the padded install tree"

    acquire_buildcache_migration_lock || die "could not acquire buildcache quarantine lock"
    if buildcache_layout_is_current; then
        release_buildcache_migration_lock
        return 0
    fi

    archive_dir="${BUILDCACHE_ROOT}/.incompatible-${BUILDCACHE_LAYOUT_VERSION}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "${archive_dir}"
    for entry in blobs v3 build_cache index.json .legacy-buildcache-migration-complete "${BUILDCACHE_LAYOUT_MARKER}"; do
        source_path="${BUILDCACHE_ROOT}/${entry}"
        [ -e "${source_path}" ] || continue
        mv "${source_path}" "${archive_dir}/"
    done

    echo "    archive: ${archive_dir}"
    write_buildcache_layout_marker
    release_buildcache_migration_lock
}

validate_legacy_buildcache_sources() {
    local source_dir
    local marker

    for source_dir in "$@"; do
        marker="${source_dir}/${BUILDCACHE_LAYOUT_MARKER}"
        if buildcache_layout_is_current "${marker}"; then
            continue
        fi
        if [ "${CHAPAR_ALLOW_UNMARKED_BUILDCACHE_MIGRATION:-false}" = "true" ]; then
            echo "WARNING: migrating unmarked buildcache source after explicit override: ${source_dir}" >&2
            continue
        fi
        die "legacy buildcache source is unmarked for ${BUILDCACHE_LAYOUT_VERSION}: ${source_dir}; rebuild it or set CHAPAR_ALLOW_UNMARKED_BUILDCACHE_MIGRATION=true only after validating it was built with the current padded layout"
    done
}

# Copy legacy payloads without overwriting destination files. The old cache is
# left in place so operators can audit or retire it after validation.
copy_buildcache_contents() {
    local source_dir="$1"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --ignore-existing "${source_dir}/" "${BUILDCACHE_ROOT}/"
    else
        cp -Rp -n "${source_dir}/." "${BUILDCACHE_ROOT}/"
    fi
}

update_buildcache_index() {
    [ -n "${BUILD_SCOPE_DIR}" ] || return 0
    [ -d "${BUILD_SCOPE_DIR}" ] || return 0

    echo "==> Updating Chapar buildcache index"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    if ! spack -C "${BUILD_SCOPE_DIR}" buildcache update-index "file://${BUILDCACHE_ROOT}"; then
        echo "WARNING: failed to update Chapar buildcache index: ${BUILDCACHE_ROOT}" >&2
        return 1
    fi
}

# A cache with blobs but no index is effectively invisible to Spack reuse. Refresh
# before concretization so release builds can reuse partial progress from an
# interrupted previous run.
ensure_buildcache_index() {
    buildcache_has_payload || return 0
    buildcache_index_exists && return 0

    echo "==> Buildcache has payloads but no index; updating before concretization"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    update_buildcache_index || die "could not update buildcache index before concretization"
}

# Wrap concretization with an optional timeout. CI uses this to fail solver stalls
# inside the build step instead of consuming the full workflow timeout.
run_with_timeout() {
    local timeout_seconds="$1"
    shift

    if [ -z "${timeout_seconds}" ] || [ "${timeout_seconds}" = "0" ]; then
        "$@"
        return
    fi

    case "${timeout_seconds}" in
        *[!0-9]*) die "CHAPAR_CONCRETIZE_TIMEOUT must be an integer number of seconds: ${timeout_seconds}" ;;
    esac

    ensure_cmd timeout
    timeout "${timeout_seconds}" "$@"
}

migrate_legacy_buildcaches() {
    local source_dir
    local sources=()
    local sentinel
    local migrated="false"
    local failed="false"

    sentinel="$(legacy_buildcache_migration_sentinel)"
    if [ -e "${sentinel}" ]; then
        echo "==> Legacy buildcache migration already completed"
        echo "    sentinel: ${sentinel}"
        return 0
    fi

    while IFS= read -r source_dir; do
        sources+=("${source_dir}")
    done < <(legacy_buildcache_sources)

    if [ "${#sources[@]}" -eq 0 ]; then
        echo "==> No legacy buildcache sources found"
        write_legacy_buildcache_migration_sentinel "${sentinel}"
        return 0
    fi

    # Migration is intentionally opt-in and conservative. Normal `build` must not
    # import legacy caches because old binaries can poison later concretizations.
    validate_legacy_buildcache_sources "${sources[@]}"

    echo "==> Migrating legacy buildcache contents"
    echo "    destination: ${BUILDCACHE_ROOT}"
    echo "    policy: copy only, do not delete sources, do not overwrite destination files"

    acquire_buildcache_migration_lock || die "could not acquire buildcache migration lock"
    for source_dir in "${sources[@]}"; do
        [ -d "${source_dir}" ] || continue
        echo "    source: ${source_dir}"
        if copy_buildcache_contents "${source_dir}"; then
            migrated="true"
        else
            echo "WARNING: failed to copy legacy buildcache source: ${source_dir}" >&2
            failed="true"
        fi
    done
    release_buildcache_migration_lock

    if [ "${failed}" = "true" ]; then
        die "legacy buildcache migration failed; not writing completion sentinel"
    fi

    if [ "${migrated}" = "true" ]; then
        update_buildcache_index
    fi

    write_legacy_buildcache_migration_sentinel "${sentinel}" "${sources[@]}"
}

refresh_buildcache_index() {
    [ "${PUBLISH_BUILDCACHE}" = "true" ] || return 0
    update_buildcache_index
}

# Install unsigned/signed mirror trust keys opportunistically. The local Chapar
# cache is unsigned today, but online upstream mirrors may still need trusted keys
# for binary reuse.
trust_buildcache_keys() {
    echo "==> Installing buildcache trust keys"
    if ! run_with_timeout 300 spack -C "${BUILD_SCOPE_DIR}" buildcache keys --install --trust; then
        echo "WARNING: failed to install buildcache keys; signed online caches may be skipped" >&2
    fi
}

install_release_prerequisite() {
    local scope_dir="$1"
    local spec="$2"
    shift 2

    echo "==> Ensuring release prerequisite"
    echo "    spec: ${spec}"
    if spack -C "${scope_dir}" find "${spec}" >/dev/null 2>&1; then
        echo "    status: already installed"
        return 0
    fi

    spack -C "${scope_dir}" install "$@" "${spec}"
}

# Return the architecture-specific CUDA target directory. NVIDIA's toolkit puts
# headers and runtime libraries below targets/<arch>-linux; CUDA-aware libfabric
# needs both the runtime library and driver stubs during its package build.
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

# Work around the CUDA-aware libfabric build ordering. Spack can install
# libfabric's dependencies first, but the libfabric package build itself needs
# CUDA target headers/libraries and driver stubs visible in compiler search paths.
# We therefore:
#
# 1. Find concrete libfabric specs that include `+cuda`.
# 2. Install their dependencies only.
# 3. Locate the concrete CUDA major selected by the environment.
# 4. Build just the missing libfabric packages with CPATH/LIBRARY_PATH pointing
#    at the CUDA runtime and stub libraries.
#
# Keep this workaround scoped to Rocky release builds. Do not solve downstream
# CUDA/NVML link failures by disabling CUDA/GDR variants; those transports are a
# required hpcsim policy.
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
        rocky9|rocky10) ;;
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
    cuda_prefix="$(spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" location -i "cuda@${CUDA_MAJOR_VERSION}")"
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

    release_buildcache_migration_lock

    if [ "${status}" -ne 0 ] && [ -n "${BUILD_STAGING_DIR}" ] && [ -d "${BUILD_STAGING_DIR}" ]; then
        case "${BUILD_STAGING_DIR##*/}" in
            .*.staging.*)
                echo "==> Removing failed release staging: ${BUILD_STAGING_DIR}" >&2
                rm -rf "${BUILD_STAGING_DIR}"
                ;;
            *)
                echo "==> Refusing to remove unexpected staging path: ${BUILD_STAGING_DIR}" >&2
                ;;
        esac
    fi

    if [ -n "${BUILD_SCOPE_DIR}" ] && [ -d "${BUILD_SCOPE_DIR}" ]; then
        rm -rf "${BUILD_SCOPE_DIR}"
    fi

    exit "${status}"
}

# The migration command has a smaller cleanup surface than build, but it still
# owns a generated Spack scope and may hold the cache lock.
cleanup_migration() {
    local status="$?"

    release_buildcache_migration_lock

    if [ -n "${BUILD_SCOPE_DIR}" ] && [ -d "${BUILD_SCOPE_DIR}" ]; then
        rm -rf "${BUILD_SCOPE_DIR}"
    fi

    exit "${status}"
}

# Copy enough metadata into the immutable release directory to answer later
# questions about which environment file and store/cache roots produced it.
copy_manifest() {
    local release_dir="$1"
    local arch_triplet="$2"

    cp "${ENV_PATH}/spack.yaml" "${release_dir}/spack.yaml"
    if [ -f "${ENV_PATH}/spack.lock" ]; then
        cp "${ENV_PATH}/spack.lock" "${release_dir}/spack.lock"
    fi

    printf '%s\n' "${arch_triplet}" > "${release_dir}/.chapar-arch"

    {
        printf 'release_id: %s\n' "${RELEASE_ID}"
        printf 'os: %s\n' "${OS_NAME}"
        printf 'arch: %s\n' "${arch_triplet}"
        printf 'built_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'env_path: %s\n' "${ENV_PATH}"
        printf 'store: %s\n' "${STORE_ROOT}"
        printf 'install_tree_projection: %s\n' "${CHAPAR_INSTALL_TREE_PROJECTION}"
        printf 'buildcache: %s\n' "${BUILDCACHE_ROOT}"
        if [ -n "${CHAPAR_MODULE_ROOT}" ]; then
            printf 'promoted_module_root: %s\n' "${CHAPAR_MODULE_ROOT}"
        fi
    } > "${release_dir}/metadata.txt"
}

# Spack's module refresh command wants concrete hashes, while users see
# `{name}/{version}`. Record both so we can validate visible names before writing
# hashless modules.
write_root_module_specs() {
    local output_file="$1"

    spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" python -c \
        'exec("import spack.environment as ev\nimport sys\nenv = ev.active_environment()\nif env is None:\n    sys.exit(\"no active Spack environment\")\nfor spec in env.concrete_roots():\n    print(\"{} {}/{}\".format(spec.dag_hash(), spec.name, spec.version))")' \
        > "${output_file}"
}

# Hashless module names are a deliberate UX contract. If two explicit roots would
# produce the same visible module, fail the release instead of adding hash suffixes
# or refreshing dependency-only modules.
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

modulefile_has_marker() {
    local module_file="$1"
    local marker="$2"
    local line

    while IFS= read -r line; do
        [ "${line}" = "${marker}" ] && return 0
    done < "${module_file}"
    return 1
}

modulefile_prefix_for_exe() {
    local module_file="$1"
    local exe_name="$2"
    local directive=""
    local variable=""
    local value=""
    local _rest=""

    while read -r directive variable value _rest; do
        [ "${directive}" = "prepend-path" ] || continue
        [ "${variable}" = "PATH" ] || continue
        [ -n "${value}" ] || continue
        value="${value#\{}"
        value="${value%\}}"
        value="${value#\"}"
        value="${value%\"}"
        if [ -x "${value}/${exe_name}" ]; then
            dirname "${value}"
            return 0
        fi
    done < "${module_file}"

    return 1
}

find_prted_for_openmpi_prefix() {
    local openmpi_prefix="$1"
    local store_root
    local candidate

    store_root="$(dirname "${openmpi_prefix}")"
    for candidate in "${openmpi_prefix}/bin/prted" "${store_root}"/prrte-*/bin/prted; do
        [ -x "${candidate}" ] || continue
        printf '%s\n' "${candidate}"
        return 0
    done

    return 1
}

ensure_release_cuda_driver_stub_dir() {
    local release_dir="$1"
    local cuda_module
    local cuda_prefix
    local stub_source
    local stub_dir
    local libcuda_stub=""
    local nvml_stub=""

    for cuda_module in "${release_dir}/modulefiles"/*/cuda/*; do
        [ -f "${cuda_module}" ] || continue
        cuda_prefix="$(modulefile_prefix_for_exe "${cuda_module}" nvcc || true)"
        [ -n "${cuda_prefix}" ] || continue

        libcuda_stub=""
        nvml_stub=""
        for stub_source in "${cuda_prefix}"/targets/*-linux/lib/stubs "${cuda_prefix}"/lib64/stubs; do
            [ -d "${stub_source}" ] || continue
            if [ -z "${libcuda_stub}" ] && [ -r "${stub_source}/libcuda.so" ]; then
                libcuda_stub="${stub_source}/libcuda.so"
            fi
            if [ -z "${nvml_stub}" ] && [ -r "${stub_source}/libnvidia-ml.so" ]; then
                nvml_stub="${stub_source}/libnvidia-ml.so"
            fi
        done

        if [ -n "${libcuda_stub}" ] && [ -n "${nvml_stub}" ]; then
            stub_dir="${release_dir}/support/cuda-driver-stubs"
            mkdir -p "${stub_dir}"
            ln -sf "${libcuda_stub}" "${stub_dir}/libcuda.so"
            ln -sf "${libcuda_stub}" "${stub_dir}/libcuda.so.1"
            ln -sf "${nvml_stub}" "${stub_dir}/libnvidia-ml.so"
            ln -sf "${nvml_stub}" "${stub_dir}/libnvidia-ml.so.1"
            printf '%s\n' "${stub_dir}"
            return 0
        elif [ -n "${libcuda_stub}" ]; then
            echo "==> WARNING: CUDA module has libcuda stub but no libnvidia-ml stub" >&2
            echo "    cuda: ${cuda_prefix}" >&2
        fi
    done

    return 1
}

append_openmpi_module_policy() {
    local module_file="$1"
    local openmpi_prefix
    local prted
    local prte_bin
    local marker="# Chapar Open MPI runtime policy"

    modulefile_has_marker "${module_file}" "${marker}" && return 0

    openmpi_prefix="$(modulefile_prefix_for_exe "${module_file}" mpirun || true)"
    if [ -n "${openmpi_prefix}" ]; then
        prted="$(find_prted_for_openmpi_prefix "${openmpi_prefix}" || true)"
    fi

    {
        printf '\n%s\n' "${marker}"
        cat <<'EOF'
# Suppress CUDA plugin dlopen noise only on nodes without the NVIDIA driver.
if {![file exists "/dev/nvidiactl"] && ![file exists "/proc/driver/nvidia/version"]} {
    if {![info exists env(OMPI_MCA_mca_base_component_show_load_errors)]} {
        setenv OMPI_MCA_mca_base_component_show_load_errors 0
    }
}
EOF
        if [ -n "${prted}" ]; then
            prte_bin="$(dirname "${prted}")"
            cat <<EOF
# Open MPI 5 uses PRRTE daemons for multi-node mpirun launches.
prepend-path PATH {${prte_bin}}
if {![info exists env(PRTE_MCA_prte_launch_agent)]} {
    setenv PRTE_MCA_prte_launch_agent {${prted}}
}
if {![info exists env(PRTE_MCA_plm_slurm_args)]} {
    setenv PRTE_MCA_plm_slurm_args {--cpu-bind=none --export=ALL}
}
if {![info exists env(OMPI_MCA_plm_slurm_args)]} {
    setenv OMPI_MCA_plm_slurm_args {--cpu-bind=none --export=ALL}
}
EOF
        else
            echo "# WARNING: Chapar could not locate prted for this Open MPI module."
        fi
    } >> "${module_file}"
}

append_cuda_stub_module_policy() {
    local module_file="$1"
    local stub_dir="$2"
    local marker="# Chapar CUDA driver-stub runtime policy"

    [ -n "${stub_dir}" ] || return 0
    modulefile_has_marker "${module_file}" "${marker}" && return 0

    cat >> "${module_file}" <<EOF

${marker}
# CUDA-aware libfabric has NVIDIA driver-library dependencies. On non-GPU nodes,
# expose CUDA's driver stubs so CPU-only MPI/libfabric commands can start. GPU
# nodes keep using the real NVIDIA driver libraries.
if {![file exists "/dev/nvidiactl"] && ![file exists "/proc/driver/nvidia/version"]} {
    prepend-path LD_LIBRARY_PATH {${stub_dir}}
}
EOF
}

append_intelmpi_module_policy() {
    local module_file="$1"
    local marker="# Chapar Intel MPI runtime policy"

    modulefile_has_marker "${module_file}" "${marker}" && return 0

    cat >> "${module_file}" <<'EOF'

# Chapar Intel MPI runtime policy
# Default to the OFI provider path validated for hpcsim. Users can override
# these before loading the module when testing another provider or fabric.
if {![info exists env(I_MPI_FABRICS)]} {
    setenv I_MPI_FABRICS {shm:ofi}
}
if {![info exists env(I_MPI_OFI_PROVIDER)]} {
    setenv I_MPI_OFI_PROVIDER {verbs}
}
if {![info exists env(FI_PROVIDER)]} {
    setenv FI_PROVIDER {verbs;ofi_rxm}
}
EOF
}

apply_release_module_runtime_policy() {
    local release_dir="$1"
    local cuda_stub_dir=""
    local module_file
    local needs_cuda_stub="false"

    [ -d "${release_dir}/modulefiles" ] || return 0

    cuda_stub_dir="$(ensure_release_cuda_driver_stub_dir "${release_dir}" || true)"

    for module_file in "${release_dir}/modulefiles"/*/intel-oneapi-mpi/* "${release_dir}/modulefiles"/*/libfabric/*; do
        [ -f "${module_file}" ] || continue
        needs_cuda_stub="true"
        break
    done

    if [ "${needs_cuda_stub}" = "true" ] && [ -z "${cuda_stub_dir}" ]; then
        die "could not create CUDA driver-stub support directory for Intel MPI/libfabric modules in ${release_dir}"
    fi

    for module_file in "${release_dir}/modulefiles"/*/openmpi/*; do
        [ -f "${module_file}" ] || continue
        append_openmpi_module_policy "${module_file}"
    done

    for module_file in "${release_dir}/modulefiles"/*/intel-oneapi-mpi/*; do
        [ -f "${module_file}" ] || continue
        append_intelmpi_module_policy "${module_file}"
    done

    for module_file in "${release_dir}/modulefiles"/*/intel-oneapi-mpi/* "${release_dir}/modulefiles"/*/libfabric/*; do
        [ -f "${module_file}" ] || continue
        append_cuda_stub_module_policy "${module_file}" "${cuda_stub_dir}"
    done
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

# Resolve either an explicit release ID or the current symlink to a physical path.
# This keeps module-use output tied to a specific release tree even if `current`
# changes later.
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

validate_arch_triplet() {
    local arch_triplet="$1"

    case "${arch_triplet}" in
        ""|.|..|*/*|*[!A-Za-z0-9._-]*)
            die "invalid Spack architecture triplet for module symlink: ${arch_triplet}"
            ;;
    esac
}

release_arch_triplet() {
    local release_dir="$1"
    local arch_triplet=""
    local module_arch_triplet=""
    local arch_dir
    local candidate

    if [ -r "${release_dir}/.chapar-arch" ]; then
        IFS= read -r arch_triplet < "${release_dir}/.chapar-arch" || true
        validate_arch_triplet "${arch_triplet}"
    fi

    if [ -z "${arch_triplet}" ] && [ -r "${release_dir}/metadata.txt" ]; then
        while IFS= read -r candidate; do
            case "${candidate}" in
                arch:\ *)
                    arch_triplet="${candidate#arch: }"
                    validate_arch_triplet "${arch_triplet}"
                    break
                    ;;
            esac
        done < "${release_dir}/metadata.txt"
    fi

    if [ -n "${arch_triplet}" ] && [ -d "${release_dir}/modulefiles/${arch_triplet}" ]; then
        printf '%s\n' "${arch_triplet}"
        return 0
    fi

    for arch_dir in "${release_dir}/modulefiles"/*; do
        [ -d "${arch_dir}" ] || continue
        candidate="$(basename "${arch_dir}")"
        case "${candidate}" in
            *-*-*) ;;
            *) continue ;;
        esac
        validate_arch_triplet "${candidate}"
        if [ -n "${module_arch_triplet}" ] && [ "${module_arch_triplet}" != "${candidate}" ]; then
            die "release has multiple module architectures; cannot choose shared symlink: ${release_dir}"
        fi
        module_arch_triplet="${candidate}"
    done

    [ -n "${module_arch_triplet}" ] || die "could not determine release module architecture from ${release_dir}"
    if [ -n "${arch_triplet}" ] && [ "${arch_triplet}" != "${module_arch_triplet}" ]; then
        echo "==> Recorded release arch has no module tree; using generated module arch" >&2
        echo "    recorded: ${arch_triplet}" >&2
        echo "    module:   ${module_arch_triplet}" >&2
    fi
    arch_triplet="${module_arch_triplet}"
    printf '%s\n' "${arch_triplet}"
}

prepare_shared_module_link() {
    local release_dir="$1"
    local arch_triplet
    local module_dir
    local module_link
    local tmp_link

    [ -n "${CHAPAR_MODULE_ROOT}" ] || return 0

    arch_triplet="$(release_arch_triplet "${release_dir}")"
    module_dir="${release_dir}/modulefiles/${arch_triplet}"
    module_link="${CHAPAR_MODULE_ROOT}/${arch_triplet}"
    tmp_link="${CHAPAR_MODULE_ROOT}/.${arch_triplet}.$$"

    [ -d "${module_dir}" ] || die "missing release module directory: ${module_dir}"
    prepare_shared_directory "${CHAPAR_MODULE_ROOT}" "shared module root"
    if [ -e "${module_link}" ] && [ ! -L "${module_link}" ]; then
        die "shared module path exists and is not a symlink: ${module_link}"
    fi

    rm -f "${tmp_link}"
    ln -s "${module_dir}" "${tmp_link}"

    PROMOTE_MODULE_LINK="${module_link}"
    PROMOTE_MODULE_TMP_LINK="${tmp_link}"
    PROMOTE_MODULE_TARGET="${module_dir}"
}

discard_prepared_shared_module_link() {
    if [ -n "${PROMOTE_MODULE_TMP_LINK}" ]; then
        rm -f "${PROMOTE_MODULE_TMP_LINK}"
    fi
    PROMOTE_MODULE_LINK=""
    PROMOTE_MODULE_TMP_LINK=""
    PROMOTE_MODULE_TARGET=""
}

commit_prepared_shared_module_link() {
    [ -n "${PROMOTE_MODULE_TMP_LINK}" ] || return 0

    perl -e 'rename $ARGV[0], $ARGV[1] or die "$!\n"' "${PROMOTE_MODULE_TMP_LINK}" "${PROMOTE_MODULE_LINK}"
    echo "    module:  ${PROMOTE_MODULE_LINK} -> ${PROMOTE_MODULE_TARGET}"
    PROMOTE_MODULE_LINK=""
    PROMOTE_MODULE_TMP_LINK=""
    PROMOTE_MODULE_TARGET=""
}

# Build command: install into the configured shared install tree, generate
# release-local modules in staging, then atomically publish the immutable release
# directory.
cmd_build() {
    RELEASE_ID="${1:-}"
    local promote="${2:-}"
    local staging_dir
    local final_dir
    local scope_dir
    local arch_triplet
    local concretize_timeout

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

    concretize_timeout="${CHAPAR_CONCRETIZE_TIMEOUT}"
    case "${OS_NAME}" in
        rocky9|rocky10)
            case "${concretize_timeout}" in
                ""|0|*[!0-9]*) ;;
                *)
                    if [ "${concretize_timeout}" -lt 10800 ]; then
                        echo "==> Raising ${OS_NAME} concretization timeout to 10800 seconds"
                        echo "    requested: ${concretize_timeout}"
                        concretize_timeout="10800"
                    fi
                    ;;
            esac
            ;;
    esac

    final_dir="${RELEASES_ROOT}/${RELEASE_ID}"
    staging_dir="${RELEASES_ROOT}/.${RELEASE_ID}.staging.$$"
    BUILD_STAGING_DIR="${staging_dir}"
    [ ! -e "${final_dir}" ] || die "release already exists: ${final_dir}"
    [ ! -e "${staging_dir}" ] || die "staging path already exists: ${staging_dir}"

    prepare_release_roots
    mkdir -p "${staging_dir}/logs"
    trap cleanup_build EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Prepare the cache before creating the generated scope/index. This prevents
    # stale unmarked payloads from participating in concretization.
    prepare_buildcache_root
    scope_dir="$(make_scope "${staging_dir}")"
    BUILD_SCOPE_DIR="${scope_dir}"
    REFRESH_BUILDCACHE_ON_EXIT="${PUBLISH_BUILDCACHE}"
    ensure_buildcache_index

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
        rocky9|rocky10)
            # GCC 15 is the only hpcsim compiler stack; bootstrap it with the OS compiler.
            install_release_prerequisite "${scope_dir}" "gcc@15+profiled %gcc" "${install_args[@]}"
            ;;
    esac

    case "${OS_NAME}" in
        rocky9|rocky10)
            # LLVM+Clang provides C/CXX virtuals; preinstall it so concretization can reuse a concrete provider.
            install_release_prerequisite "${scope_dir}" "llvm@21+clang+lld~lldb~flang~polly~ipo build_system=cmake targets=x86,nvptx %gcc" "${install_args[@]}"
            ;;
    esac

    # Concretize after all reusable toolchain pieces are present so Spack can
    # prefer concrete providers and binary cache hits where hashes match.
    echo "==> Concretizing hpcsim environment"
    run_with_timeout "${concretize_timeout}" spack -e "${ENV_PATH}" -C "${scope_dir}" concretize -f
    install_cuda_libfabric_specs "${install_args[@]}"
    echo "==> Installing hpcsim environment"
    spack -e "${ENV_PATH}" -C "${scope_dir}" install --only-concrete "${install_args[@]}"
    echo "==> Refreshing hpcsim root modules"
    refresh_root_modules
    apply_release_module_runtime_policy "${staging_dir}"

    arch_triplet="$(release_arch_triplet "${staging_dir}")"
    copy_manifest "${staging_dir}" "${arch_triplet}"

    # The final rename is the publication point. Anything before this can fail
    # without creating a partially visible release directory.
    mv "${staging_dir}" "${final_dir}"
    BUILD_STAGING_DIR=""
    echo "==> Release build complete"
    echo "    release: ${final_dir}"
    echo "    module:  ${final_dir}/modulefiles/${arch_triplet}"

    if [ "${promote}" = "--promote" ]; then
        cmd_promote "${RELEASE_ID}"
    fi
}

# Explicit one-time migration command. It shares cache preparation/indexing logic
# with builds but never runs automatically from `cmd_build`.
cmd_migrate_buildcache() {
    local force="${1:-}"
    local scope_dir
    local sentinel

    case "${force}" in
        ""|--force) ;;
        *) die "unknown migrate-buildcache option: ${force}" ;;
    esac

    ensure_cmd spack
    set_paths
    trap cleanup_migration EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    prepare_buildcache_root
    scope_dir="$(make_scope "${OS_ROOT}/migration")"
    BUILD_SCOPE_DIR="${scope_dir}"

    sentinel="$(legacy_buildcache_migration_sentinel)"
    if [ "${force}" = "--force" ] && [ -e "${sentinel}" ]; then
        rm -f "${sentinel}"
    fi

    echo "==> Running one-time legacy buildcache migration"
    echo "    os:         ${OS_NAME}"
    echo "    buildcache: ${BUILDCACHE_ROOT}"
    echo "    sentinel:   ${sentinel}"
    migrate_legacy_buildcaches
}

# Promotion is intentionally a pointer update after ensuring generated modulefiles
# carry the current runtime policy. Stores remain immutable so running jobs keep
# using the package prefixes they loaded.
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
    apply_release_module_runtime_policy "${release_dir}"
    prepare_shared_module_link "${release_dir}"

    tmp_link="${OS_ROOT}/.current.$$"
    rm -f "${tmp_link}"
    if ! ln -s "releases/${release_id}" "${tmp_link}"; then
        discard_prepared_shared_module_link
        die "could not prepare current symlink: ${tmp_link}"
    fi
    # POSIX rename is atomic on the same filesystem, which avoids readers seeing
    # a missing or half-written `current` link during promotion/rollback.
    if ! perl -e 'rename $ARGV[0], $ARGV[1] or die "$!\n"' "${tmp_link}" "${CURRENT_LINK}"; then
        rm -f "${tmp_link}"
        discard_prepared_shared_module_link
        die "could not update current symlink: ${CURRENT_LINK}"
    fi

    echo "==> Promoted hpcsim release"
    echo "    os:      ${OS_NAME}"
    echo "    current: ${CURRENT_LINK} -> releases/${release_id}"
    commit_prepared_shared_module_link
}

# Publish only shared module-root symlinks. This is for sites that expose a
# stable module root such as ${CHAPAR_MODULE_ROOT}/<arch> without using the
# per-OS current symlink.
cmd_publish_modules() {
    local release_id="${1:-}"
    local release_dir

    [ -n "${release_id}" ] || die "release-id is required for publish-modules"
    validate_release_id "${release_id}"
    set_paths
    [ -n "${CHAPAR_MODULE_ROOT}" ] || die "CHAPAR_MODULE_ROOT is required for publish-modules"
    release_dir="${RELEASES_ROOT}/${release_id}"
    [ -d "${release_dir}" ] || die "missing release directory: ${release_dir}"
    ensure_cmd perl

    apply_release_module_runtime_policy "${release_dir}"
    prepare_shared_module_link "${release_dir}"
    echo "==> Published hpcsim modules"
    echo "    os:      ${OS_NAME}"
    commit_prepared_shared_module_link
}

# Print shell commands rather than mutating the caller's environment. Operators
# can inspect the resolved module path before evaluating it in their shell.
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

# Lightweight diagnostics for operators and CI logs.
cmd_status() {
    set_paths
    echo "install mode: ${CHAPAR_INSTALL_MODE}"
    echo "hpcsim root: ${HPCSIM_ROOT}"
    echo "buildcache root: ${CHAPAR_BUILDCACHE_ROOT}"
    echo "ccache root: ${CHAPAR_CCACHE_ROOT}"
    echo "os root:     ${OS_ROOT}"
    echo "store:       ${STORE_ROOT}"
    echo "projection:  ${CHAPAR_INSTALL_TREE_PROJECTION}"
    if [ -n "${CHAPAR_MODULE_ROOT}" ]; then
        echo "module root: ${CHAPAR_MODULE_ROOT}"
    else
        echo "module root: (release-local)"
    fi
    echo "releases:    ${RELEASES_ROOT}"
    echo "buildcache:  ${BUILDCACHE_ROOT}"
    echo "ccache:      ${CCACHE_ROOT}"
    if [ -L "${CURRENT_LINK}" ]; then
        echo "current:     ${CURRENT_LINK} -> $(readlink "${CURRENT_LINK}")"
    elif [ -e "${CURRENT_LINK}" ]; then
        echo "current:     ${CURRENT_LINK} (not a symlink)"
    else
        echo "current:     (none)"
    fi
    if [ -n "${CHAPAR_MODULE_ROOT}" ] && [ -d "${CHAPAR_MODULE_ROOT}" ]; then
        local module_link
        for module_link in "${CHAPAR_MODULE_ROOT}"/*; do
            [ -e "${module_link}" ] || [ -L "${module_link}" ] || continue
            case "$(basename "${module_link}")" in
                *-*-*) ;;
                *) continue ;;
            esac
            if [ -L "${module_link}" ]; then
                echo "module link: $(basename "${module_link}") -> $(readlink "${module_link}")"
            else
                echo "module link: $(basename "${module_link}") (not a symlink)"
            fi
        done
    fi
}

# Command dispatcher. Keep command implementations above this point so sourced or
# traced debugging sessions can inspect all helpers before main executes.
main() {
    local cmd="${1:-}"
    case "${cmd}" in
        build)
            shift
            cmd_build "$@"
            ;;
        migrate-buildcache)
            shift
            cmd_migrate_buildcache "$@"
            ;;
        promote)
            shift
            cmd_promote "$@"
            ;;
        publish-modules)
            shift
            cmd_publish_modules "$@"
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
