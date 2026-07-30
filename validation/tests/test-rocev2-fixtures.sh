#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
results_root="$(mktemp -d)"

cleanup() { rm -rf "${results_root}"; }
trap cleanup EXIT

run_fixture() {
    local fixture="$1" expected_exit="$2" expected_verdict="$3" actual_exit=0 result
    RESULTS_ROOT="${results_root}" bash "${script_dir}/rocev2-pairwise.sbatch" --fixture "${validation_dir}/fixtures/roce/${fixture}" || actual_exit=$?
    [ "${actual_exit}" -eq "${expected_exit}" ] || { printf '%s: expected exit %s, got %s\n' "${fixture}" "${expected_exit}" "${actual_exit}" >&2; return 1; }
    result="$(python3 - "${results_root}/rocev2-pairwise" <<'PY'
import pathlib
import sys

matches = list(pathlib.Path(sys.argv[1]).glob("**/rocev2_pairwise.json"))
print(matches[0] if matches else "")
PY
)"
    [ -n "${result}" ] || { printf '%s: missing result artifact\n' "${fixture}" >&2; return 1; }
    [ "$(python3 -c "import json; print(json.load(open('${result}'))['verdict'])")" = "${expected_verdict}" ]
    rm -rf "${results_root:?}/rocev2-pairwise"
}

run_fixture ethernet-valid 0 PASS
run_fixture infiniband-link-layer 1 FAIL
run_fixture bad-gid 1 FAIL
run_fixture bad-mtu 1 FAIL
run_fixture bad-vlan 1 FAIL
run_fixture counter-regression 1 FAIL
printf '%s\n' 'RoCE fixtures: Ethernet path and GID, MTU, VLAN, and counter rejections verified'
