#!/usr/bin/env bash
set -euo pipefail

# hpcsim release driver.
#
# This script is intentionally more than a thin `spack install` wrapper. A
# shared hpcsim deployment has a few invariants that are easy to violate when
# debugging CI failures or doing emergency cache repairs:
#
# - The Spack install tree is shared per OS, but module trees are release-local.
#   A new build may add packages to the shared store, but it must not rewrite the
#   module tree used by running jobs.
# - A release is assembled in `releases/.<id>.staging.<pid>` and moved into place
#   only after installation, module generation, and manifest writing succeed.
#   Promotion is a separate atomic symlink swap of `<os>/current`.
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
ENV_PATH="${ENV_PATH:-${SCRIPT_DIR}}"
HPCSIM_ROOT="${HPCSIM_ROOT:-/resources/share/hpcsim}"
CHAPAR_BUILDCACHE_ROOT="${CHAPAR_BUILDCACHE_ROOT:-/resources/chapar/cache}"
SPACK_INSTALL_ARGS="${SPACK_INSTALL_ARGS:-}"
PUBLISH_BUILDCACHE="${PUBLISH_BUILDCACHE:-false}"
CHAPAR_CONCRETIZE_TIMEOUT="${CHAPAR_CONCRETIZE_TIMEOUT:-}"
BUILD_SCOPE_DIR=""
BUILDCACHE_MIGRATION_LOCK_DIR=""
REFRESH_BUILDCACHE_ON_EXIT="false"
# Keep this as a major version to follow Chapar policy: dependency constraints
# may select the latest CUDA 13 patch release, but release helper code should not
# bake in a minor/patch CUDA toolkit version.
CUDA_MAJOR_VERSION="13"
INSTALL_TREE_PADDED_LENGTH="256"
BUILDCACHE_LAYOUT_VERSION="install-tree-padded-${INSTALL_TREE_PADDED_LENGTH}"
BUILDCACHE_LAYOUT_MARKER=".chapar-buildcache-layout"

# User-facing CLI help. Keep the usage text focused on operator commands; the
# policy details live in the header above and docs/buildcache.md.
usage() {
    cat <<'EOF'
Usage:
  release.sh build <release-id> [--promote]
  release.sh migrate-buildcache [--force]
  release.sh promote <release-id>
  release.sh module-use [release-id]
  release.sh status

Environment:
  ENV_PATH             Spack environment path. Default: envs/hpcsim
  HPCSIM_ROOT          Shared root. Default: /resources/share/hpcsim
  CHAPAR_BUILDCACHE_ROOT
                       Shared binary cache root. Default: /resources/chapar/cache
  OS_NAME              rocky8, rocky9, or macos. Auto-detected when unset.
  SPACK_INSTALL_ARGS   Extra arguments passed to spack install.
  CHAPAR_CONCRETIZE_TIMEOUT
                       Optional timeout in seconds for final environment
                       concretization. Empty means no timeout.
  CHAPAR_ALLOW_UNMARKED_BUILDCACHE_MIGRATION
                       Set true only after validating a legacy cache was built
                       with the current padded install-tree layout.

Release layout:
  /resources/share/hpcsim/<os>/store
  /resources/share/hpcsim/<os>/releases/<release-id>
  /resources/share/hpcsim/<os>/current -> releases/<release-id>
  /resources/chapar/cache/<os>

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

# Root validation deliberately allows only simple absolute paths under known
# shared roots by default. The unsafe overrides exist for local testing, not for
# production releases.
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

# The buildcache root is separate from HPCSIM_ROOT so binary artifacts can be
# shared across releases and ordinary user installs without living inside a
# mutable release tree.
validate_buildcache_root() {
    local home_root="${HOME}/resources/chapar/cache"

    case "${CHAPAR_BUILDCACHE_ROOT}" in
        /*) ;;
        *) die "CHAPAR_BUILDCACHE_ROOT must be an absolute path: ${CHAPAR_BUILDCACHE_ROOT}" ;;
    esac

    case "${CHAPAR_BUILDCACHE_ROOT}" in
        /|*'/../'*|*/..|*'/./'*|*/.|*[!A-Za-z0-9._/+-]*)
            die "CHAPAR_BUILDCACHE_ROOT is not an approved simple shared cache path: ${CHAPAR_BUILDCACHE_ROOT}"
            ;;
    esac

    case "${CHAPAR_BUILDCACHE_ROOT}" in
        /resources/chapar/cache|/resources/chapar/cache/*|"${home_root}"|"${home_root}"/*)
            ;;
        *)
            if [ "${CHAPAR_ALLOW_UNSAFE_BUILDCACHE_ROOT:-false}" != "true" ]; then
                die "CHAPAR_BUILDCACHE_ROOT must be under /resources/chapar/cache or ${home_root}; set CHAPAR_ALLOW_UNSAFE_BUILDCACHE_ROOT=true for local testing"
            fi
            ;;
    esac
}

# OS_NAME controls all per-OS paths and conditional hpcsim specs. CI can set it
# explicitly; interactive use usually relies on auto-detection.
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

# Derive all path globals from the validated roots and selected OS. Keeping the
# path calculation in one place avoids accidentally mixing Rocky 8/Rocky 9 stores
# or caches in migration and promotion commands.
set_paths() {
    OS_NAME="$(detect_os)"
    validate_hpcsim_root
    validate_buildcache_root
    OS_ROOT="${HPCSIM_ROOT}/${OS_NAME}"
    STORE_ROOT="${OS_ROOT}/store"
    RELEASES_ROOT="${OS_ROOT}/releases"
    CURRENT_LINK="${OS_ROOT}/current"
    BUILDCACHE_ROOT="${CHAPAR_BUILDCACHE_ROOT}/${OS_NAME}"
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

    acquire_buildcache_migration_lock || return 0
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
    if ! spack -C "${BUILD_SCOPE_DIR}" buildcache keys --install --trust; then
        echo "WARNING: failed to install buildcache keys; signed online caches may be skipped" >&2
    fi
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
        printf 'buildcache: %s\n' "${BUILDCACHE_ROOT}"
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

# Build command: install into the shared per-OS store, generate release-local
# modules in staging, then atomically publish the immutable release directory.
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
        rocky8|rocky9)
            case "${concretize_timeout}" in
                ""|0|*[!0-9]*) ;;
                *)
                    if [ "${concretize_timeout}" -lt 10800 ]; then
                        echo "==> Raising Rocky concretization timeout to 10800 seconds"
                        echo "    requested: ${concretize_timeout}"
                        concretize_timeout="10800"
                    fi
                    ;;
            esac
            ;;
    esac

    final_dir="${RELEASES_ROOT}/${RELEASE_ID}"
    staging_dir="${RELEASES_ROOT}/.${RELEASE_ID}.staging.$$"
    [ ! -e "${final_dir}" ] || die "release already exists: ${final_dir}"
    [ ! -e "${staging_dir}" ] || die "staging path already exists: ${staging_dir}"

    mkdir -p "${STORE_ROOT}" "${RELEASES_ROOT}" "${staging_dir}/logs"
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
        rocky8)
            # Rocky 8's system GCC is too old for Node 24 and CUDA 13 host builds.
            spack -C "${scope_dir}" install "${install_args[@]}" "gcc@15+profiled %gcc"
            ;;
        rocky9)
            # Node 24 needs a newer C++ toolchain than Rocky 9's system GCC 11.
            spack -C "${scope_dir}" install "${install_args[@]}" "gcc@15+profiled %gcc"
            ;;
    esac

    case "${OS_NAME}" in
        rocky8|rocky9)
            # LLVM+Clang provides C/CXX virtuals; preinstall it so concretization can reuse a concrete provider.
            spack -C "${scope_dir}" install "${install_args[@]}" "llvm@21+clang+lld~lldb~flang~polly~ipo build_system=cmake targets=x86,nvptx %gcc"
            ;;
    esac

    # Concretize after all reusable toolchain pieces are present so Spack can
    # prefer concrete providers and binary cache hits where hashes match.
    run_with_timeout "${concretize_timeout}" spack -e "${ENV_PATH}" -C "${scope_dir}" concretize -f
    install_cuda_libfabric_specs "${install_args[@]}"
    spack -e "${ENV_PATH}" -C "${scope_dir}" install --only-concrete "${install_args[@]}"
    refresh_root_modules

    arch_triplet="$(spack -e "${ENV_PATH}" -C "${scope_dir}" arch)"
    copy_manifest "${staging_dir}"

    # The final rename is the publication point. Anything before this can fail
    # without creating a partially visible release directory.
    mv "${staging_dir}" "${final_dir}"
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

# Promotion is intentionally only a symlink update. Stores and release module
# directories remain immutable so running jobs keep using the files they loaded.
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
    # POSIX rename is atomic on the same filesystem, which avoids readers seeing
    # a missing or half-written `current` link during promotion/rollback.
    perl -e 'rename $ARGV[0], $ARGV[1] or die "$!\n"' "${tmp_link}" "${CURRENT_LINK}"

    echo "==> Promoted hpcsim release"
    echo "    os:      ${OS_NAME}"
    echo "    current: ${CURRENT_LINK} -> releases/${release_id}"
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
    echo "hpcsim root: ${HPCSIM_ROOT}"
    echo "buildcache root: ${CHAPAR_BUILDCACHE_ROOT}"
    echo "os root:     ${OS_ROOT}"
    echo "store:       ${STORE_ROOT}"
    echo "releases:    ${RELEASES_ROOT}"
    echo "buildcache:  ${BUILDCACHE_ROOT}"
    if [ -L "${CURRENT_LINK}" ]; then
        echo "current:     ${CURRENT_LINK} -> $(readlink "${CURRENT_LINK}")"
    elif [ -e "${CURRENT_LINK}" ]; then
        echo "current:     ${CURRENT_LINK} (not a symlink)"
    else
        echo "current:     (none)"
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
