#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
results_root="$(mktemp -d)"

cleanup() { rm -rf "${results_root}"; }
trap cleanup EXIT

run_fixture() {
    local fixture="$1" expected_exit="$2" expected_verdict="$3" actual_exit=0 result
    RESULTS_ROOT="${results_root}" bash "${script_dir}/rdma-link-check.sbatch" --fixture "${validation_dir}/fixtures/rdma/${fixture}" || actual_exit=$?
    [ "${actual_exit}" -eq "${expected_exit}" ] || { printf '%s: expected exit %s, got %s\n' "${fixture}" "${expected_exit}" "${actual_exit}" >&2; return 1; }
    result="$(python3 - "${results_root}/rdma-link-check" <<'PY'
import pathlib
import sys

matches = list(pathlib.Path(sys.argv[1]).glob("**/rdma_link_check.json"))
print(matches[0] if matches else "")
PY
)"
    [ -n "${result}" ] || { printf '%s: missing result artifact\n' "${fixture}" >&2; return 1; }
    [ "$(python3 -c "import json; print(json.load(open('${result}'))['verdict'])")" = "${expected_verdict}" ]
    rm -rf "${results_root:?}/rdma-link-check"
}

run_fixture connectx8-match 0 PASS
run_fixture connectx8-mismatch 1 FAIL
run_fixture down-port 1 FAIL
run_fixture firmware-mismatch 1 FAIL
run_fixture counter-regression 1 FAIL
printf '%s\n' 'RDMA fixtures: multiple HCAs, ConnectX-8, down port, firmware, and counter cases verified'
