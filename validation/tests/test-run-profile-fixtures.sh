#!/usr/bin/env bash
set -euo pipefail

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures_dir="${validation_dir}/fixtures/profiles"
temporary_dir="$(mktemp -d)"
trap 'rm -rf "${temporary_dir}"' EXIT

success_output="$(CHAPAR_DRY_RUN=1 RESULTS_ROOT="${temporary_dir}/results" "${validation_dir}/run" --profile capability --site-profile "${fixtures_dir}/cpu-only-developer.yaml")"
evidence_path="$(python3 - "${success_output}" <<'PY'
import sys

for line in sys.argv[1].splitlines():
    if line.startswith("PROFILE_SELECTION_EVIDENCE="):
        print(line.split("=", 1)[1])
        break
else:
    raise SystemExit("profile selection evidence path was not reported")
PY
)"

python3 - "${evidence_path}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    evidence = json.load(stream)

assert evidence["tier"] == "capability"
assert evidence["selected_suites"] == ["cpu-platform"]
assert evidence["storage_targets"] == ["job-scratch", "managed-results"]
assert evidence["storage_paths_resolved"] is False
assert any(item["suite"] == "gpu-topology" and item["verdict"] == "SKIP" for item in evidence["skipped_suites"])
assert any(item["suite"] == "rdma-link-check" and item["verdict"] == "SKIP" for item in evidence["skipped_suites"])
assert any(item["suite"] == "vast" and item["verdict"] == "SKIP" for item in evidence["skipped_suites"])
assert any(item["capability"] == "gpu" and item["verdict"] == "SKIP" for item in evidence["capability_evidence"])
assert any(item["capability"] == "rdma" and item["verdict"] == "SKIP" for item in evidence["capability_evidence"])
PY

if CHAPAR_DRY_RUN=1 RESULTS_ROOT="${temporary_dir}/results" "${validation_dir}/run" --profile capability --site-profile "${fixtures_dir}/required-rdma-mismatch.yaml" >"${temporary_dir}/mismatch.out" 2>"${temporary_dir}/mismatch.err"; then
    printf '%s\n' 'required capability mismatch was unexpectedly accepted' >&2
    exit 1
fi

printf '%s\n' 'validation/run profile fixtures: CPU-only selection accepted; required capability mismatch rejected'
