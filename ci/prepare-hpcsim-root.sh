#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAPAR_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

site_config="${CHAPAR_SITE_CONFIG:-${CHAPAR_ROOT}/envs/hpcsim/hpcsim-site.env}"
site_config_loaded="false"
if [ -r "${site_config}" ]; then
    # shellcheck disable=SC1090
    . "${site_config}"
    site_config_loaded="true"
fi

: "${OS_NAME:?OS_NAME is required}"
: "${CHAPAR_INSTALL_MODE:=home}"
: "${CHAPAR_HOME_ROOT:=${HOME}/.spack/chapar}"
: "${HPCSIM_HOME_ROOT:=${CHAPAR_HOME_ROOT}/envs/hpcsim}"
: "${HPCSIM_PUBLIC_ROOT:=}"
: "${CHAPAR_SHARED_CACHE_ROOT:=${CHAPAR_HOME_ROOT}/cache}"
: "${CHAPAR_BUILDCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/buildcache}"
: "${CHAPAR_CCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/ccache}"
: "${CHAPAR_INSTALL_TREE_ROOT:=}"
: "${CHAPAR_MODULE_ROOT:=}"
: "${CHAPAR_SHARED_GROUP:=}"
: "${CHAPAR_SHARED_DIR_MODE:=2775}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

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
            if [ "${site_config_loaded}" != "true" ]; then
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

case "${OS_NAME}" in
    rocky9|rocky10) ;;
    *) die "OS_NAME must be rocky9 or rocky10, got ${OS_NAME}" ;;
esac

if [ -z "${HPCSIM_ROOT:-}" ]; then
    case "${CHAPAR_INSTALL_MODE}" in
        home) HPCSIM_ROOT="${HPCSIM_HOME_ROOT}" ;;
        public)
            [ -n "${HPCSIM_PUBLIC_ROOT}" ] || die "HPCSIM_PUBLIC_ROOT is required when CHAPAR_INSTALL_MODE=public"
            HPCSIM_ROOT="${HPCSIM_PUBLIC_ROOT}"
            ;;
        *) die "CHAPAR_INSTALL_MODE must be home or public, got ${CHAPAR_INSTALL_MODE}" ;;
    esac
fi

validate_site_backed_path HPCSIM_ROOT "${HPCSIM_ROOT}"
validate_site_backed_path CHAPAR_BUILDCACHE_ROOT "${CHAPAR_BUILDCACHE_ROOT}"
validate_site_backed_path CHAPAR_CCACHE_ROOT "${CHAPAR_CCACHE_ROOT}"
validate_optional_site_backed_path CHAPAR_INSTALL_TREE_ROOT "${CHAPAR_INSTALL_TREE_ROOT}"
validate_optional_site_backed_path CHAPAR_MODULE_ROOT "${CHAPAR_MODULE_ROOT}"

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "cannot create shared directories; root privileges or passwordless sudo are required for $*"
    fi
}

ensure_dir() {
    local path="$1"
    local label="$2"
    local current_group

    if ! mkdir -p "${path}" 2>/dev/null; then
        run_as_root mkdir -p "${path}"
    fi

    if [ -n "${CHAPAR_SHARED_GROUP}" ]; then
        current_group="$(stat -c '%G' "${path}" 2>/dev/null || stat -f '%Sg' "${path}" 2>/dev/null || true)"
        if [ "${current_group}" != "${CHAPAR_SHARED_GROUP}" ]; then
            if ! chgrp "${CHAPAR_SHARED_GROUP}" "${path}" 2>/dev/null; then
                run_as_root chgrp "${CHAPAR_SHARED_GROUP}" "${path}"
            fi
        fi
    fi

    if ! chmod "${CHAPAR_SHARED_DIR_MODE}" "${path}" 2>/dev/null; then
        run_as_root chmod "${CHAPAR_SHARED_DIR_MODE}" "${path}" 2>/dev/null || echo "WARNING: could not set mode ${CHAPAR_SHARED_DIR_MODE} on ${label}: ${path}"
    fi

    [ -w "${path}" ] || die "${label} is not writable by $(id -un): ${path}"
}

os_root="${HPCSIM_ROOT}/${OS_NAME}"
store_dir="${CHAPAR_INSTALL_TREE_ROOT:-${os_root}/store}"
buildcache_dir="${CHAPAR_BUILDCACHE_ROOT}/${OS_NAME}"
ccache_dir="${CHAPAR_CCACHE_ROOT}/${OS_NAME}"

umask 0002
ensure_dir "${HPCSIM_ROOT}" "hpcsim root"
ensure_dir "${os_root}" "${OS_NAME} hpcsim root"
ensure_dir "${os_root}/releases" "${OS_NAME} releases root"
ensure_dir "${os_root}/runs" "${OS_NAME} runs root"
ensure_dir "${store_dir}" "Spack install tree"
if [ -n "${CHAPAR_MODULE_ROOT}" ]; then
    ensure_dir "${CHAPAR_MODULE_ROOT}" "shared module root"
fi
ensure_dir "${CHAPAR_BUILDCACHE_ROOT}" "shared buildcache root"
ensure_dir "${buildcache_dir}" "${OS_NAME} buildcache root"
ensure_dir "${CHAPAR_CCACHE_ROOT}" "shared ccache root"
ensure_dir "${ccache_dir}" "${OS_NAME} ccache root"

echo "Prepared hpcsim roots"
echo "  install mode: ${CHAPAR_INSTALL_MODE}"
echo "  hpcsim root: ${HPCSIM_ROOT}"
echo "  install tree: ${store_dir}"
if [ -n "${CHAPAR_MODULE_ROOT}" ]; then
    echo "  module root: ${CHAPAR_MODULE_ROOT}"
fi
echo "  buildcache:  ${buildcache_dir}"
echo "  ccache:      ${ccache_dir}"
