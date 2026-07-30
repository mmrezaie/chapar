#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
suite="${script_dir}/node-admission.sbatch"
results_root="$(mktemp -d)"

cleanup() { rm -rf "${results_root}"; }
trap cleanup EXIT

run_fixture() {
    local fixture="$1"
    local expected_exit="$2"
    local expected_verdict="$3"
    local actual_exit=0
    local result

    RESULTS_ROOT="${results_root}" bash "${suite}" --fixture "${fixture}" || actual_exit=$?
    if [ "${actual_exit}" -ne "${expected_exit}" ]; then
        printf '%s: expected exit %s, got %s\n' "${fixture}" "${expected_exit}" "${actual_exit}" >&2
        return 1
    fi
    result="$(python3 - "${results_root}/node-admission" <<'PY'
import pathlib
import sys

matches = list(pathlib.Path(sys.argv[1]).glob("**/node_admission.json"))
print(matches[0] if matches else "")
PY
)"
    [ -n "${result}" ] || { printf '%s: missing result artifact\n' "${fixture}" >&2; return 1; }
    [ "$(python3 -c "import json; print(json.load(open('${result}'))['verdict'])")" = "${expected_verdict}" ]
    rm -rf "${results_root}/node-admission"
}

run_fixture healthy 0 PASS
run_fixture ecc-fault 1 FAIL
run_fixture inventory-mismatch 1 FAIL
run_fixture missing-optional-diagnostic 0 WARN
printf 'node-admission fixtures: healthy, fault, mismatch, and optional diagnostic cases verified\n'
