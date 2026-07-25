# shellcheck shell=sh
# resolve_test_dir: locate the test directory from a list of candidates
#
# Usage:
#   resolve_test_dir <base_path> <candidate1> [candidate2 ...]
#
# Returns the first existing directory matching one of the candidates.
# If none match, prints an error to stderr and returns 1.

resolve_test_dir() {
    set -euo pipefail
    local submit_dir="${1:-$PWD}"
    shift
    for candidate in "$@"; do
        local full="${submit_dir}/${candidate}"
        [ -d "${full}" ] && printf '%s\n' "${full}" && return 0
    done
    echo "could not locate test directory; set <ENV>_TEST_DIR" >&2
    return 1
}
