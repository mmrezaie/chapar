#!/usr/bin/env bash
# DESCRIPTION: Integrity validation - verify all modules load and basic tools run (env-agnostic)
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:10:00
#SBATCH --job-name=integrity-test

set -euo pipefail

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -n "${ENV_NAME:-}" ] || [ -n "${MODULE_PATH:-}" ]; then
    echo "ERROR: ENV_NAME and MODULE_PATH are obsolete selection overrides" >&2
    exit 2
fi
selection="${CHAPAR_SELECTION:?CHAPAR_SELECTION is required}"
selection_digest="${CHAPAR_SELECTION_DIGEST:?CHAPAR_SELECTION_DIGEST is required}"
contract="${CHAPAR_TARGET_CONTRACT:?CHAPAR_TARGET_CONTRACT is required}"
identity="$(python3 "$validation_dir/selection.py" shell --selection "$selection" --selection-digest "$selection_digest" --contract "$contract" --test integrity-test)"
IFS=$'\t' read -r datacenter software_set target module_path result_namespace _partition _constraint _account _qos <<< "$identity"
run_id="${SLURM_JOB_ID:-$(date -u +%Y%m%dT%H%M%S)}"
node="${SLURM_NODELIST:-$(hostname -s)}"
RESULTS_DIR="${RESULTS_ROOT:-$result_namespace}/integrity-test/${run_id}/${node}"
mkdir -p "${RESULTS_DIR}"

SUMMARY="${RESULTS_DIR}/summary.json"
failures=0
total=0
results="["

if [ ! -d "$module_path" ]; then
    echo "FAIL: Module path not found: $module_path" >&2
    exit 1
fi

module use "$module_path"
echo "=== $datacenter/$software_set/$target integrity validation ===" >&2
echo "Module path: $module_path" >&2

check() {
    local module_name="$1"
    local check_cmd="$2"
    local check_desc="$3"
    total=$((total + 1))

    echo -n "  $module_name ... " >&2
    if module load "$module_name" 2>/dev/null; then
        if eval "$check_cmd" >/dev/null 2>&1; then
            echo "PASS" >&2
            results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"pass\"},"
        else
            echo "FAIL (check: $check_cmd)" >&2
            results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"fail\"},"
            failures=$((failures + 1))
        fi
    else
        echo "FAIL (load failed)" >&2
        results="${results}{\"module\":\"$module_name\",\"check\":\"$check_desc\",\"result\":\"load-fail\"},"
        failures=$((failures + 1))
    fi
}

while IFS=$'\t' read -r module_name check_cmd check_desc; do
    check "$module_name" "$check_cmd" "$check_desc"
done < <(python3 "$validation_dir/selection.py" checks --selection "$selection" --selection-digest "$selection_digest" --contract "$contract" --test integrity-test)

results="${results%,}]"
echo "{\"env\":\"$software_set\",\"total\":$total,\"passed\":$((total - failures)),\"failed\":$failures,\"results\":$results}" > "$SUMMARY"
cat "$SUMMARY"

echo "" >&2
echo "=== $datacenter/$software_set/$target integrity: $((total - failures))/$total passed, $failures failed ===" >&2
exit $failures
