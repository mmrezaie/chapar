#!/usr/bin/env bash

# The launcher records selection intent only. A scheduler-authoritative tier
# manifest remains the responsibility of the post-job collector.

validation_profile_select() {
    local profile_path="$1"
    local tier_name="$2"
    local selection_output kind value

    selection_output="$(python3 - "${profile_path}" "${tier_name}" "${VALIDATION_DIR}/config/cluster-profile.schema.json" "${VALIDATION_DIR}/tests" "${RESULTS_ROOT:-${VALIDATION_DIR}/results}" <<'PY'
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from uuid import uuid4

import jsonschema
import yaml

profile_path, tier_name, schema_path, tests_path, results_root = map(Path, sys.argv[1:])
tier_name = str(tier_name)

with schema_path.open(encoding="utf-8") as stream:
    schema = json.load(stream)
with profile_path.open(encoding="utf-8") as stream:
    profile = yaml.safe_load(stream)

validator = jsonschema.Draft202012Validator(schema)
failures = list(validator.iter_errors(profile))
available = set(profile.get("available_capabilities", [])) if isinstance(profile, dict) else set()
tiers = profile.get("tiers", {}) if isinstance(profile, dict) and isinstance(profile.get("tiers", {}), dict) else {}
for candidate_name, candidate_tier in tiers.items():
    if isinstance(candidate_tier, dict):
        required = set(candidate_tier.get("required_capabilities", []))
        unsupported = sorted(required - available)
        if unsupported:
            failures.append(ValueError(f"{candidate_name} requires unavailable capabilities: {', '.join(unsupported)}"))

if failures:
    failure = sorted(failures, key=str)[0]
    message = getattr(failure, "message", str(failure))
    raise SystemExit(f"site profile rejected: {message}")

if tier_name not in {"capability", "node", "fabric", "storage", "accelerator", "full"}:
    raise SystemExit(f"unsupported profile tier: {tier_name}")
if tier_name not in tiers:
    raise SystemExit(f"site profile does not define tier: {tier_name}")

tier = tiers[tier_name]
selected_suites = tier["selected_suites"]
suite_manifests = sorted(path.stem for path in Path(tests_path).glob("*.sbatch"))
unknown_suites = sorted(set(selected_suites) - set(suite_manifests))
if unknown_suites:
    raise SystemExit(f"site profile selects missing suite manifests: {', '.join(unknown_suites)}")

known_capabilities = ("cpu", "gpu", "multi-node", "parallel-storage", "rdma", "slurm")
required_capabilities = set(tier["required_capabilities"])
profile_id = profile["site"]["profile_id"]
selection_id = f"manual-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid4().hex}"
evidence_path = Path(results_root) / "profile-selection" / profile_id / selection_id / "selection.json"
evidence_path.parent.mkdir(parents=True, exist_ok=False)

evidence = {
    "schema_version": "1.0",
    "kind": "profile-selection",
    "ci_authoritative": False,
    "profile_id": profile_id,
    "tier": tier_name,
    "selected_suites": selected_suites,
    "skipped_suites": [
        {"suite": suite, "verdict": "SKIP", "reason": "not selected by requested profile tier"}
        for suite in suite_manifests
        if suite not in selected_suites
    ],
    "capability_evidence": [
        {
            "capability": capability,
            "verdict": "PASS" if capability in required_capabilities else "SKIP",
            "reason": "required by requested profile tier" if capability in required_capabilities else "not required by requested profile tier",
        }
        if capability in available
        else {"capability": capability, "verdict": "SKIP", "reason": "not advertised by site profile"}
        for capability in known_capabilities
    ],
    "storage_targets": ["job-scratch", "managed-results"],
    "storage_paths_resolved": False,
    "policies": {
        "unavailable": tier["unavailable_policy"],
        "threshold": tier["threshold_policy"],
    },
}

with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=evidence_path.parent, delete=False) as stream:
    json.dump(evidence, stream, indent=2, sort_keys=True)
    stream.write("\n")
    temporary_path = Path(stream.name)
os.replace(temporary_path, evidence_path)

for suite in selected_suites:
    print(f"suite\t{suite}")
print(f"unavailable_policy\t{tier['unavailable_policy']}")
print(f"threshold_policy\t{tier['threshold_policy']}")
print(f"evidence\t{evidence_path}")
PY
)" || return

    VALIDATION_PROFILE_SELECTED_SUITES=()
    VALIDATION_PROFILE_UNAVAILABLE_POLICY=""
    VALIDATION_PROFILE_THRESHOLD_POLICY=""
    VALIDATION_PROFILE_EVIDENCE=""
    while IFS=$'\t' read -r kind value; do
        case "${kind}" in
            suite) VALIDATION_PROFILE_SELECTED_SUITES+=("${value}") ;;
            unavailable_policy) VALIDATION_PROFILE_UNAVAILABLE_POLICY="${value}" ;;
            threshold_policy) VALIDATION_PROFILE_THRESHOLD_POLICY="${value}" ;;
            evidence) VALIDATION_PROFILE_EVIDENCE="${value}" ;;
            *) printf 'invalid profile selection output: %s\n' "${kind}" >&2; return 2 ;;
        esac
    done <<< "${selection_output}"

    [ "${#VALIDATION_PROFILE_SELECTED_SUITES[@]}" -gt 0 ] || {
        printf 'site profile selected no suite manifests\n' >&2
        return 2
    }
}
