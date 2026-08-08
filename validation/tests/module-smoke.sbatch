#!/usr/bin/env bash
# DESCRIPTION: Module smoke test - verifies all vlad modules load and basic tools run
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:10:00
#SBATCH --job-name=vlad-module-smoke

set -euo pipefail

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${ENV_NAME:-}" ] || [ -n "${MODULE_PATH:-}" ] || [ -n "${CHAPAR_MODULE_ROOT:-}" ]; then
    echo "ERROR: ambient environment and module path overrides are obsolete" >&2
    exit 2
fi
selection="${CHAPAR_SELECTION:?CHAPAR_SELECTION is required}"
selection_digest="${CHAPAR_SELECTION_DIGEST:?CHAPAR_SELECTION_DIGEST is required}"
contract="${CHAPAR_TARGET_CONTRACT:?CHAPAR_TARGET_CONTRACT is required}"
identity="$(python3 "$validation_dir/selection.py" shell --selection "$selection" --selection-digest "$selection_digest" --contract "$contract" --test module-smoke)"
IFS=$'\t' read -r _datacenter _software_set _target module_path result_namespace _partition _constraint _account _qos <<< "$identity"
run_id="${SLURM_JOB_ID:-$(date -u +%Y%m%dT%H%M%S)}"
node="${SLURM_NODELIST:-$(hostname -s)}"
RESULTS_DIR="${RESULTS_ROOT:-$result_namespace}/module-smoke/${run_id}/${node}"
mkdir -p "${RESULTS_DIR}"

SUMMARY="${RESULTS_DIR}/summary.json"
failures=0
total=0
results="["

module_load_and_check() {
    local module_name="$1"
    local check_cmd="$2"
    local check_desc="$3"
    total=$((total + 1))

    echo "--- Testing: $module_name ($check_desc) ---" >&2

    if module load "$module_name" 2>/dev/null; then
        if eval "$check_cmd" >/dev/null 2>&1; then
            echo "  PASS: $module_name" >&2
            results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"pass\"},"
        else
            echo "  FAIL: $module_name loaded but check failed: $check_cmd" >&2
            results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"fail\"},"
            failures=$((failures + 1))
        fi
    else
        echo "  FAIL: $module_name could not be loaded" >&2
        results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"load-fail\"},"
        failures=$((failures + 1))
    fi
}

if [ ! -d "$module_path" ]; then
    echo "FAIL: Module path not found: $module_path" >&2
    exit 1
fi
module use "$module_path"
echo "=== Module search path: $module_path ===" >&2
while IFS=$'\t' read -r module_name check_cmd check_desc; do
    module_load_and_check "$module_name" "$check_cmd" "$check_desc"
done < <(python3 "$validation_dir/selection.py" checks --selection "$selection" --selection-digest "$selection_digest" --contract "$contract" --test module-smoke)

# Close JSON
results="${results%,}]"
echo "{\"total\":$total,\"passed\":$((total - failures)),\"failed\":$failures,\"results\":$results}" > "$SUMMARY"
cat "$SUMMARY"

echo "" >&2
echo "=== Summary: $((total - failures))/$total passed, $failures failed ===" >&2
exit $failures
