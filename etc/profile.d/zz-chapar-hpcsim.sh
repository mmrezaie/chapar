#!/usr/bin/env bash

if [ -z "${CHAPAR_SELECTION_PATH:-}" ] || [ -z "${CHAPAR_SELECTION_SHA256:-}" ] || [ -z "${CHAPAR_TARGET_CONTRACT_PATH:-}" ]; then
    echo "ERROR: explicit Chapar selection, digest, and target contract are required" >&2
    return 1 2>/dev/null || exit 1
fi

_chapar_profile_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_chapar_selection_helper="${_chapar_profile_dir}/../chapar-selection.sh"
"${_chapar_selection_helper}" module-use \
    "${CHAPAR_SELECTION_PATH}" "${CHAPAR_SELECTION_SHA256}" "${CHAPAR_TARGET_CONTRACT_PATH}" || \
    { return 1 2>/dev/null || exit 1; }
unset _chapar_profile_dir _chapar_selection_helper
