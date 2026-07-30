#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
results_root="$(mktemp -d)"

cleanup() { rm -rf "${results_root}"; }
trap cleanup EXIT

run_fixture() {
    local suite="$1"
    local fixture="$2"
    local expected_exit="$3"
    local expected_verdict="$4"
    local actual_exit=0
    local result

    RESULTS_ROOT="${results_root}" bash "${script_dir}/${suite}.sbatch" --fixture "${validation_dir}/fixtures/gpu/${fixture}" || actual_exit=$?
    [ "${actual_exit}" -eq "${expected_exit}" ] || { printf '%s/%s: expected exit %s, got %s\n' "${suite}" "${fixture}" "${expected_exit}" "${actual_exit}" >&2; return 1; }
    result="$(python3 - "${results_root}/${suite}" <<'PY'
import pathlib
import sys

matches = list(pathlib.Path(sys.argv[1]).glob("**/*.json"))
print(next((str(path) for path in matches if path.name not in {"summary.json", "suite-manifest.json"}), ""))
PY
)"
    [ -n "${result}" ] || { printf '%s/%s: missing result artifact\n' "${suite}" "${fixture}" >&2; return 1; }
    [ "$(python3 -c "import json; print(json.load(open('${result}'))['verdict'])")" = "${expected_verdict}" ]
    rm -rf "${results_root:?}/${suite}"
}

for fixture in nvlink nvswitch-nvls ib socket; do
    run_fixture gpu-topology "${fixture}" 0 PASS
done
run_fixture gpu-topology command-unavailable 1 FAIL

run_fixture nvlink-p2p nvlink 0 PASS
run_fixture nvlink-p2p nvswitch-nvls 0 PASS
run_fixture nvlink-p2p ib 0 WARN
run_fixture nvlink-p2p socket 0 WARN
run_fixture nvlink-p2p command-unavailable 1 FAIL

for fixture in nvlink nvswitch-nvls ib socket; do
    run_fixture nccl-transport-check "${fixture}" 0 PASS
done
run_fixture nccl-transport-check command-unavailable 1 FAIL
printf '%s\n' 'GPU fixtures: NVLink, NVSwitch/NVLS, IB, Socket, and unavailable commands verified'
