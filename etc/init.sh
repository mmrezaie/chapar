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
    _chapar_module_root="${HOME}/privatemodules"
    if [ -d "${_chapar_module_root}" ]; then
        for _chapar_module_archdir in "${_chapar_module_root}"/*; do
            [ -d "${_chapar_module_archdir}" ] || continue
            case "$(basename "${_chapar_module_archdir}")" in
                *-*-*) module use "${_chapar_module_archdir}" >/dev/null 2>&1 || true ;;
            esac
        done
    fi
fi

unset _chapar_etc_dir _chapar_root _chapar_spack_setup _chapar_spack_root
unset _chapar_module_root _chapar_module_archdir
