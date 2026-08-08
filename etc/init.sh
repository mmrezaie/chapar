#!/usr/bin/env bash

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "ERROR: source this file, do not execute it: source /path/to/chapar/etc/init.sh" >&2
    exit 1
fi

_chapar_etc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_chapar_root="$(cd "${_chapar_etc_dir}/.." && pwd)"
_chapar_selection_helper="${_chapar_etc_dir}/chapar-selection.sh"

if [ -z "${CHAPAR_SELECTION_PATH:-}" ] || [ -z "${CHAPAR_SELECTION_SHA256:-}" ] || [ -z "${CHAPAR_TARGET_CONTRACT_PATH:-}" ]; then
    echo "ERROR: CHAPAR_SELECTION_PATH, CHAPAR_SELECTION_SHA256, and CHAPAR_TARGET_CONTRACT_PATH are required" >&2
    return 1
fi

_chapar_exports="$("${_chapar_selection_helper}" exports \
    "${CHAPAR_SELECTION_PATH}" "${CHAPAR_SELECTION_SHA256}" "${CHAPAR_TARGET_CONTRACT_PATH}")" || return 1
eval "${_chapar_exports}"
export CHAPAR_ROOT="${_chapar_root}"

_chapar_spack_root="${CHAPAR_SPACK_ROOT:-${HOME}/.local/opt/spack}"
_chapar_spack_setup="${_chapar_spack_root}/share/spack/setup-env.sh"
if [ ! -r "${_chapar_spack_setup}" ]; then
    echo "ERROR: could not find Spack at ${_chapar_spack_root}" >&2
    echo "Install it with: bash ${_chapar_root}/etc/install-spack.sh" >&2
    return 1
fi

export SPACK_ROOT="${_chapar_spack_root}"
. "${_chapar_spack_setup}"
export SPACK_USER_CONFIG_PATH="${_chapar_root}/etc/user"
export SPACK_SYSTEM_CONFIG_PATH="${_chapar_root}/etc/system"
: "${SPACK_USER_CACHE_PATH:=${TMPDIR:-/tmp}/${USER}/spack-cache}"
export SPACK_USER_CACHE_PATH
export PIP_CONFIG_FILE=/dev/null

export CCACHE_DIR="${CHAPAR_CCACHE_DIR}"
: "${CCACHE_TEMPDIR:=${TMPDIR:-/tmp}/${USER}/chapar-ccache-tmp/${CHAPAR_TARGET}}"
: "${CCACHE_UMASK:=002}"
: "${CCACHE_COMPILERCHECK:=content}"
export CCACHE_TEMPDIR CCACHE_UMASK CCACHE_COMPILERCHECK

# The helper's `module-use` runs `module use` in its own process, so calling it
# here would verify the selection and then discard the MODULEPATH change with the
# subshell. CHAPAR_MODULE_ROOT comes from the same verified exports above.
if type module >/dev/null 2>&1; then
    if [ -d "${CHAPAR_MODULE_ROOT}" ]; then
        module use "${CHAPAR_MODULE_ROOT}"
    else
        echo "WARNING: no published modulefiles for this selection: ${CHAPAR_MODULE_ROOT}" >&2
    fi
fi

unset _chapar_etc_dir _chapar_root _chapar_selection_helper _chapar_exports
unset _chapar_spack_root _chapar_spack_setup
