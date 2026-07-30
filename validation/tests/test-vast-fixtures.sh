#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
results_root="$(mktemp -d)"

cleanup() { rm -rf -- "${results_root}"; }
trap cleanup EXIT

run_fixture() {
    local fixture="$1" expected_verdict expected_exit actual_exit=0 result
    expected_verdict="$(python3 - "${validation_dir}/fixtures/storage/${fixture}/manifest.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["verdicts"]["vast"])
PY
)"
    case "${expected_verdict}" in
        PASS|WARN) expected_exit=0 ;;
        SKIP) expected_exit=77 ;;
        FAIL) expected_exit=1 ;;
        *) printf 'invalid fixture verdict: %s\n' "${expected_verdict}" >&2; return 2 ;;
    esac
    RESULTS_ROOT="${results_root}" bash "${script_dir}/vast.sbatch" --fixture "${validation_dir}/fixtures/storage/${fixture}" || actual_exit=$?
    [ "${actual_exit}" -eq "${expected_exit}" ] || { printf '%s: expected exit %s, got %s\n' "${fixture}" "${expected_exit}" "${actual_exit}" >&2; return 1; }
    result="$(python3 - "${results_root}/vast" <<'PY'
import pathlib
import sys
matches = list(pathlib.Path(sys.argv[1]).glob("**/vast_mount.json"))
print(matches[0] if matches else "")
PY
)"
    [ -n "${result}" ] || { printf '%s: missing result artifact\n' "${fixture}" >&2; return 1; }
    [ "$(python3 -c "import json; print(json.load(open('${result}'))['verdict'])")" = "${expected_verdict}" ]
    rm -rf -- "${results_root:?}/vast"
}

for fixture in vast nfs non-vast mismatch namespace-failure checksum-corruption; do
    run_fixture "${fixture}"
done
printf '%s\n' 'VAST fixtures: VAST, NFS, generic, identity mismatch, namespace, and checksum cases verified'
