#!/usr/bin/env bash
# run_test.sh — validation harness entry point
#
# Usage:
#   run_test.sh --suite <name> --env <config> [--scheduler slurm|local] [--dry-run]
#
# This is a MOCK implementation. Actual execution will be wired in T7.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") --suite <name> --env <config> [options]

Required:
  --suite <name>      Test suite name (e.g., mpi-rdma, vlad)
  --env <config>      Path to environment config YAML

Options:
  --scheduler <type>  Scheduler to use: slurm (default) or local
  --dry-run           Print what would be done without executing
  --help              Show this help

Examples:
  $(basename "$0") --suite mpi-rdma --env validation/config/cluster.yaml --dry-run
  $(basename "$0") --suite vlad --env validation/config/cluster.yaml --scheduler local --dry-run
EOF
}

# ---- Parse arguments ----
suite=""
env_config=""
scheduler="slurm"
dry_run=false

while [ $# -gt 0 ]; do
    case "$1" in
        --suite) suite="$2"; shift 2 ;;
        --env) env_config="$2"; shift 2 ;;
        --scheduler) scheduler="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        --help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ---- Validate required arguments ----
if [ -z "${suite}" ]; then
    echo "ERROR: --suite is required" >&2
    usage >&2
    exit 1
fi
if [ -z "${env_config}" ]; then
    echo "ERROR: --env is required" >&2
    usage >&2
    exit 1
fi

# ---- Resolve paths ----
HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${HARNESS_DIR}/../.." && pwd)"

TEST_YAML="${PROJECT_DIR}/validation/${suite}/tests/${suite}.yaml"

# Source helpers
# shellcheck source=resolve_test_dir.sh
source "${HARNESS_DIR}/resolve_test_dir.sh"

# ---- Dry-run: diagnostic output ----
if [ "${dry_run}" = true ]; then
    echo "=== DRY RUN ==="
    echo "Suite:            ${suite}"
    echo "Env config:       ${env_config}"
    echo "Scheduler:        ${scheduler}"
    echo "Harness dir:      ${HARNESS_DIR}"
    echo "Project dir:      ${PROJECT_DIR}"
    echo "Test YAML:        ${TEST_YAML}"

    if [ -f "${TEST_YAML}" ]; then
        echo "Test YAML status: found"
    else
        echo "Test YAML status: NOT FOUND (will continue with defaults)"
    fi

    if [ -f "${env_config}" ]; then
        echo "Env config status: found"
        echo ""
        echo "--- Module loads from env config ---"
        if command -v python3 &>/dev/null; then
            python3 -c "
import yaml, sys
try:
    with open('${env_config}') as f:
        cfg = yaml.safe_load(f)
    if cfg is None:
        cfg = {}
    module_map = cfg.get('module_map', {}) or {}
    if not module_map:
        print('  (no module_map defined)')
    for sym, mod in module_map.items():
        print(f'  module load {mod}')
    tool_map = cfg.get('tool_map', {}) or {}
    if tool_map:
        print('')
        print('--- Tool path resolutions ---')
        for sym, path in tool_map.items():
            exists = 'YES' if __import__('os').path.exists(str(path)) else 'NO'
            print(f'  {sym}: {path}  [exists={exists}]')
    scheduler_cfg = cfg.get('scheduler', {}) or {}
    if scheduler_cfg:
        print('')
        print('--- Scheduler defaults ---')
        for k, v in scheduler_cfg.items():
            print(f'  {k}: {v}')
    expected = cfg.get('expected', {}) or {}
    if expected:
        print('')
        print('--- Expected performance ---')
        for k, v in expected.items():
            print(f'  {k}: {v}')
except Exception as e:
    print(f'  ERROR reading config: {e}', file=sys.stderr)
"
        else
            echo "  (python3 not available, cannot inspect config)"
        fi
    else
        echo "Env config status: NOT FOUND"
    fi

    echo ""
    echo "--- Test commands (would execute) ---"
    echo "  resolve_test_dir \"${PROJECT_DIR}\" \"validation/${suite}\""
    echo "  (test execution body — not yet implemented)"
    echo ""
    echo "=== END DRY RUN ==="
    exit 0
fi

# ---- Execution paths ----
case "${scheduler}" in
    local)
        echo "local execution not yet implemented, use --dry-run to preview" >&2
        exit 1
        ;;
    slurm)
        echo "slurm execution not yet fully implemented, use --dry-run to preview" >&2
        exit 1
        ;;
    *)
        echo "ERROR: unknown scheduler: ${scheduler}" >&2
        exit 1
        ;;
esac
