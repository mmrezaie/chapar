# shellcheck shell=sh
# setup_results_dir: create a standardized results directory
#
# Usage:
#   setup_results_dir <suite> [nodelist]
#
# Creates: results/<suite>/<timestamp>/<nodelist>/
# Prints the path on success.

setup_results_dir() {
    set -euo pipefail
    local suite="$1"
    local nodelist="${2:-unknown}"
    local timestamp
    timestamp=$(date -u +%Y%m%dT%H%M%S)
    local dir="results/${suite}/${timestamp}/${nodelist}"
    mkdir -p "${dir}"
    printf '%s\n' "${dir}"
}
