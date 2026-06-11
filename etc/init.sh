#!/usr/bin/env bash
# Initialize Spack for this Chapar checkout without modifying Spack source files.
# Usage:
#   source /path/to/chapar/etc/init.sh

# This script must be sourced so it can export variables into the current shell.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "ERROR: source this file, do not execute it: source /path/to/chapar/etc/init.sh" >&2
    exit 1
fi

_chapar_etc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_chapar_root="$(cd "${_chapar_etc_dir}/.." && pwd)"
_chapar_spack_root="${CHAPAR_SPACK_ROOT:-${HOME}/.local/opt/spack}"
_chapar_spack_setup="${_chapar_spack_root}/share/spack/setup-env.sh"
export CHAPAR_ROOT="${_chapar_root}"

_chapar_site_config="${CHAPAR_SITE_CONFIG:-${_chapar_root}/envs/hpcsim/hpcsim-site.env}"
if [ -r "${_chapar_site_config}" ]; then
    # shellcheck disable=SC1090
    . "${_chapar_site_config}"
fi

: "${CHAPAR_INSTALL_MODE:=home}"
: "${CHAPAR_HOME_ROOT:=${HOME}/.spack/chapar}"
: "${HPCSIM_HOME_ROOT:=${CHAPAR_HOME_ROOT}/envs/hpcsim}"
: "${HPCSIM_PUBLIC_ROOT:=}"
: "${CHAPAR_SHARED_CACHE_ROOT:=${CHAPAR_HOME_ROOT}/cache}"
: "${CHAPAR_BUILDCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/buildcache}"
: "${CHAPAR_CCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/ccache}"
: "${CHAPAR_INSTALL_TREE_ROOT:=}"
: "${CHAPAR_INSTALL_TREE_PROJECTION:=}"
: "${CHAPAR_MODULE_ROOT:=}"
: "${CHAPAR_CCACHE_COMPILERCHECK:=content}"
if [ -z "${CHAPAR_INSTALL_TREE_PROJECTION}" ]; then
    if [ -n "${CHAPAR_INSTALL_TREE_ROOT}" ]; then
        CHAPAR_INSTALL_TREE_PROJECTION='{architecture}/{compiler.name}-{compiler.version}/{name}-{version}-{hash}'
    else
        CHAPAR_INSTALL_TREE_PROJECTION='{name}-{version}-{hash}'
    fi
fi

case "${CHAPAR_INSTALL_MODE}" in
    public)
        : "${HPCSIM_ROOT:=${HPCSIM_PUBLIC_ROOT}}"
        ;;
    home)
        : "${HPCSIM_ROOT:=${HPCSIM_HOME_ROOT}}"
        ;;
    *)
        echo "ERROR: CHAPAR_INSTALL_MODE must be home or public, got ${CHAPAR_INSTALL_MODE}" >&2
        return 1
        ;;
esac
: "${CHAPAR_HPCSIM_ROOT:=${HPCSIM_ROOT}}"
export CHAPAR_INSTALL_MODE CHAPAR_HOME_ROOT HPCSIM_HOME_ROOT HPCSIM_PUBLIC_ROOT
export CHAPAR_SHARED_CACHE_ROOT CHAPAR_BUILDCACHE_ROOT CHAPAR_CCACHE_ROOT
export CHAPAR_INSTALL_TREE_ROOT CHAPAR_INSTALL_TREE_PROJECTION CHAPAR_MODULE_ROOT
export CHAPAR_CCACHE_COMPILERCHECK HPCSIM_ROOT CHAPAR_HPCSIM_ROOT

_chapar_detect_hpcsim_os() {
    case "$(uname -s)" in
        Darwin)
            return 1
            ;;
        Linux)
            if [ -r /etc/os-release ]; then
                local ID=""
                local VERSION_ID=""
                # shellcheck disable=SC1091
                . /etc/os-release
                case "${ID}:${VERSION_ID%%.*}" in
                    rocky:9|rhel:9|almalinux:9|centos:9) printf '%s\n' rocky9 ;;
                    rocky:10|rhel:10|almalinux:10|centos:10) printf '%s\n' rocky10 ;;
                esac
            fi
            ;;
    esac
}

_chapar_hpcsim_os="$(_chapar_detect_hpcsim_os 2>/dev/null || true)"
if [ -n "${_chapar_hpcsim_os}" ] && [ -n "${CHAPAR_CCACHE_ROOT}" ]; then
    : "${CCACHE_DIR:=${CHAPAR_CCACHE_ROOT}/${_chapar_hpcsim_os}}"
    : "${CCACHE_TEMPDIR:=${TMPDIR:-/tmp}/${USER}/chapar-ccache-tmp/${_chapar_hpcsim_os}}"
    : "${CCACHE_UMASK:=002}"
    : "${CCACHE_COMPILERCHECK:=${CHAPAR_CCACHE_COMPILERCHECK}}"
    if [ -n "${CHAPAR_CCACHE_MAXSIZE:-}" ]; then
        : "${CCACHE_MAXSIZE:=${CHAPAR_CCACHE_MAXSIZE}}"
        export CCACHE_MAXSIZE
    fi
    export CCACHE_DIR CCACHE_TEMPDIR CCACHE_UMASK CCACHE_COMPILERCHECK
    mkdir -p "${CCACHE_DIR}" "${CCACHE_TEMPDIR}" 2>/dev/null || true
fi

if [ ! -r "${_chapar_spack_setup}" ]; then
    echo "ERROR: could not find Spack at ${_chapar_spack_root}" >&2
    echo "Install it with: bash ${_chapar_root}/etc/install-spack.sh" >&2
    return 1
fi

# Load Spack shell functions/command from the per-user upstream checkout.
export SPACK_ROOT="${_chapar_spack_root}"
. "${_chapar_spack_setup}"

# Bind this shell to chapar config scopes.
export SPACK_USER_CONFIG_PATH="${_chapar_root}/etc/user"
export SPACK_SYSTEM_CONFIG_PATH="${_chapar_root}/etc/system"

# Fast, machine-local user cache root. Auto-create for fresh machines/sessions.
: "${SPACK_USER_CACHE_PATH:=/tmp/${USER}/spack-cache}"
export SPACK_USER_CACHE_PATH
mkdir -p "${SPACK_USER_CACHE_PATH}" 2>/dev/null || true

# Keep user pip configuration from leaking into Spack Python package builds.
export PIP_CONFIG_FILE=/dev/null

# If environment modules is available, add Chapar-managed module roots.
# This keeps `module avail` aligned with `spack module tcl refresh` output.
if type module >/dev/null 2>&1; then
    _chapar_module_root="${HPCSIM_HOME_ROOT}/modulefiles"
    if [ -d "${_chapar_module_root}" ]; then
        for _chapar_module_archdir in "${_chapar_module_root}"/*; do
            [ -d "${_chapar_module_archdir}" ] || continue
            case "$(basename "${_chapar_module_archdir}")" in
                *-*-*) module use "${_chapar_module_archdir}" >/dev/null 2>&1 || true ;;
            esac
        done
    fi

    _chapar_hpcsim_root="${CHAPAR_HPCSIM_ROOT}"
    _chapar_shared_module_added="false"
    if [ -n "${_chapar_hpcsim_os}" ] && [ -n "${CHAPAR_MODULE_ROOT}" ] && [ -d "${CHAPAR_MODULE_ROOT}" ]; then
        for _chapar_hpcsim_module_dir in "${CHAPAR_MODULE_ROOT}"/*; do
            [ -d "${_chapar_hpcsim_module_dir}" ] || continue
            case "$(basename "${_chapar_hpcsim_module_dir}")" in
                *-"${_chapar_hpcsim_os}"-*)
                    module use "${_chapar_hpcsim_module_dir}" >/dev/null 2>&1 || true
                    _chapar_shared_module_added="true"
                    ;;
            esac
        done
    fi

    _chapar_hpcsim_current="${_chapar_hpcsim_root}/${_chapar_hpcsim_os}/current"
    if [ "${_chapar_shared_module_added}" != "true" ] && [ -n "${_chapar_hpcsim_os}" ] && { [ -L "${_chapar_hpcsim_current}" ] || [ -d "${_chapar_hpcsim_current}" ]; }; then
        _chapar_hpcsim_release="$(cd -P "${_chapar_hpcsim_current}" 2>/dev/null && pwd || true)"
        _chapar_hpcsim_module_root="${_chapar_hpcsim_release}/modulefiles"
        if [ -n "${_chapar_hpcsim_release}" ] && [ -d "${_chapar_hpcsim_module_root}" ]; then
            for _chapar_hpcsim_module_dir in "${_chapar_hpcsim_module_root}"/*; do
                [ -d "${_chapar_hpcsim_module_dir}" ] || continue
                case "$(basename "${_chapar_hpcsim_module_dir}")" in
                    *-*-*) module use "${_chapar_hpcsim_module_dir}" >/dev/null 2>&1 || true ;;
                esac
            done
        fi
    fi
fi

unset _chapar_etc_dir _chapar_root _chapar_spack_setup _chapar_spack_root _chapar_site_config
unset _chapar_module_root _chapar_module_archdir
unset _chapar_hpcsim_os _chapar_hpcsim_root _chapar_hpcsim_current _chapar_hpcsim_release
unset _chapar_hpcsim_module_root _chapar_hpcsim_module_dir
unset _chapar_shared_module_added
unset -f _chapar_detect_hpcsim_os 2>/dev/null || true
