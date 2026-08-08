#!/usr/bin/env bash
# Chapar selection-bound module path.
#
# This runs for every login shell on the host. With no selection exported there
# is simply nothing to activate, so stay silent: failing here printed an error
# and returned non-zero on every login for every user, whether or not they were
# using Chapar at all.
#
# A partially exported selection is a genuine misconfiguration, so warn -- but
# never abort the caller's shell startup over it.
#
# The helper is asked for the verified module root and `module use` is run here.
# Invoking `chapar-selection.sh module-use` as a child process would verify the
# selection correctly and then discard the MODULEPATH change with the subshell.

if [ -n "${CHAPAR_SELECTION_PATH:-}${CHAPAR_SELECTION_SHA256:-}${CHAPAR_TARGET_CONTRACT_PATH:-}" ]; then
    if [ -z "${CHAPAR_SELECTION_PATH:-}" ] || [ -z "${CHAPAR_SELECTION_SHA256:-}" ] || [ -z "${CHAPAR_TARGET_CONTRACT_PATH:-}" ]; then
        echo "WARNING: Chapar selection, digest, and target contract must be exported together" >&2
    else
        _chapar_profile_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        _chapar_helper="${_chapar_profile_dir}/../chapar-selection.sh"
        _chapar_exports=""
        if [ ! -x "${_chapar_helper}" ]; then
            echo "WARNING: Chapar selection helper is missing: ${_chapar_helper}" >&2
        elif ! _chapar_exports="$("${_chapar_helper}" exports \
            "${CHAPAR_SELECTION_PATH}" "${CHAPAR_SELECTION_SHA256}" "${CHAPAR_TARGET_CONTRACT_PATH}")"; then
            echo "WARNING: Chapar selection did not verify; modules were not added" >&2
        else
            eval "${_chapar_exports}"
            if ! command -v module >/dev/null 2>&1; then
                echo "WARNING: module command is unavailable; Chapar modules were not added" >&2
            elif [ -d "${CHAPAR_MODULE_ROOT}" ]; then
                module use "${CHAPAR_MODULE_ROOT}"
            else
                echo "WARNING: Chapar module root is not published: ${CHAPAR_MODULE_ROOT}" >&2
            fi
        fi
        unset _chapar_profile_dir _chapar_helper _chapar_exports
    fi
fi
