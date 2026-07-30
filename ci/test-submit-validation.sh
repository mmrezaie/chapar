#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_environment=fixture-slurm-cpu
fixture_runner=fixture-slurm-cpu
output="$(CI_VALIDATION_DRY_RUN_FIXTURE=true CI_VALIDATION_GITHUB_ENVIRONMENT="${fixture_environment}" CI_VALIDATION_RUNNER_LABEL="${fixture_runner}" bash "${repository_root}/ci/submit-validation.sh" --dry-run --profile fixture-cpu --environment hpcsim --release candidate --tier capability)"
expected='DRY_RUN profile=fixture-cpu environment=hpcsim release=candidate tier=capability github_environment=fixture-slurm-cpu runner_label=fixture-slurm-cpu partition=fixture-cpu qos=fixture-validation expected_nodes=1 expected_edges=0'
[ "${output}" = "${expected}" ]

if CI_VALIDATION_DRY_RUN_FIXTURE=true CI_VALIDATION_GITHUB_ENVIRONMENT=wrong-environment CI_VALIDATION_RUNNER_LABEL="${fixture_runner}" bash "${repository_root}/ci/submit-validation.sh" --dry-run --profile fixture-cpu --environment hpcsim --release candidate --tier capability >/dev/null 2>&1; then
    printf '%s\n' 'mismatched protected environment was accepted' >&2
    exit 1
fi

if CI_VALIDATION_DRY_RUN_FIXTURE=true CI_VALIDATION_GITHUB_ENVIRONMENT="${fixture_environment}" CI_VALIDATION_RUNNER_LABEL="${fixture_runner}" bash "${repository_root}/ci/submit-validation.sh" --dry-run --profile fixture-cpu --environment hpcsim --release candidate --tier injected-command >/dev/null 2>&1; then
    printf '%s\n' 'invalid tier was accepted' >&2
    exit 1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "${temporary_dir}"' EXIT
selection_output="$(CHAPAR_DRY_RUN=1 RESULTS_ROOT="${temporary_dir}/results" "${repository_root}/validation/run" --profile capability --site-profile "${repository_root}/validation/fixtures/profiles/cpu-only-developer.yaml")"
selection_path="${selection_output%%$'\n'*}"
selection_path="${selection_path#PROFILE_SELECTION_EVIDENCE=}"
python3 - "${selection_path}" "${repository_root}/.github/workflows/slurm-infrastructure-validation.yml" "${repository_root}/ci/fixtures/submit-validation/policy.json" <<'PY'
import json
import sys

import yaml

selection_path, workflow_path, policy_path = sys.argv[1:]
with open(selection_path, encoding="utf-8") as stream:
    evidence = json.load(stream)
skipped = {item["capability"] for item in evidence["capability_evidence"] if item["verdict"] == "SKIP"}
assert {"gpu", "multi-node", "parallel-storage", "rdma", "slurm"} <= skipped

with open(workflow_path, encoding="utf-8") as stream:
    workflow = yaml.safe_load(stream)
with open(policy_path, encoding="utf-8") as stream:
    policy = json.load(stream)
matrix = workflow["jobs"]["validate"]["strategy"]["matrix"]["include"]
workflow_profiles = {
    item["profile"]: (item["github_environment"], item["runner_label"])
    for item in matrix
}
fixture_profiles = {key: value for key, value in policy["profiles"].items() if key != "fixture-cpu"}
assert workflow_profiles == {
    key: (value["github_environment"], value["runner_label"])
    for key, value in fixture_profiles.items()
}
trigger = workflow.get(True) or workflow.get("on")
inputs = trigger["workflow_dispatch"]["inputs"]
assert set(inputs) == {"profile", "environment", "release", "tier"}
for forbidden in ("partition", "qos", "nodes", "path", "command", "artifact", "promotion"):
    assert forbidden not in inputs
PY

printf '%s\n' 'submit-validation fixtures: protected capability mappings, fixed selectors, and CPU-only unavailable capability manifests accepted'
