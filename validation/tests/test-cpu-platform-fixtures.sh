#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
results_root="$(mktemp -d)"

cleanup() { rm -rf -- "${results_root}"; }
trap cleanup EXIT

run_fixture() {
    local suite="$1" fixture="$2" expected_exit="$3" expected_verdict="$4" actual_exit=0 result
    RESULTS_ROOT="${results_root}" bash "${script_dir}/${suite}.sbatch" --fixture "${validation_dir}/fixtures/cpu/${fixture}" || actual_exit=$?
    [ "${actual_exit}" -eq "${expected_exit}" ] || { printf '%s/%s: expected exit %s, got %s\n' "${suite}" "${fixture}" "${expected_exit}" "${actual_exit}" >&2; return 1; }
    result="$(python3 - "${results_root}/${suite}" "${suite}" <<'PY'
import pathlib
import sys

name = sys.argv[2].replace("-", "_") + ".json"
matches = list(pathlib.Path(sys.argv[1]).glob("**/" + name))
print(matches[0] if matches else "")
PY
)"
    [ -n "${result}" ] || { printf '%s/%s: missing result artifact\n' "${suite}" "${fixture}" >&2; return 1; }
    [ "$(python3 -c "import json; print(json.load(open('${result}'))['verdict'])")" = "${expected_verdict}" ]
    rm -rf -- "${results_root}/${suite}"
}

for fixture in intel-x86 amd-x86 nvidia-grace generic-aarch64; do
    run_fixture cpu-platform "${fixture}" 0 PASS
    run_fixture slurm-placement "${fixture}" 0 PASS
done
run_fixture cpu-platform elf-mismatch 1 FAIL
run_fixture slurm-placement unallocated 77 SKIP
printf '%s\n' 'cpu platform fixtures: Intel, AMD, Grace, generic ARM, ELF mismatch, and unallocated Slurm cases verified'
