#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/submit-validation.sh --profile KEY --environment KEY --release KEY --tier NAME [--dry-run]

The four selectors are logical keys. A runner-owned policy maps them to the
site profile, immutable release, and fixed Slurm partition/QOS. This command
does not accept scheduler flags, commands, filesystem paths, or promotion.
USAGE
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

simple_id() {
    case "$1" in
        ""|.|..|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

sha256_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d ' ' -f 1
    else
        shasum -a 256 | cut -d ' ' -f 1
    fi
}

stat_owner() {
    stat -c '%U' "$1" 2>/dev/null || stat -f '%Su' "$1"
}

require_site_regular_file() {
    local path="$1"
    local label="$2"
    [ -f "${path}" ] && [ ! -L "${path}" ] || die "${label} must be a non-symlink regular file"
    case "$(stat_owner "${path}")" in
        root|"${SERVICE_ACCOUNT}") ;;
        *) die "${label} must be owned by ${SERVICE_ACCOUNT} or root" ;;
    esac
}

require_site_directory() {
    local path="$1"
    local label="$2"
    [ -d "${path}" ] && [ ! -L "${path}" ] || die "${label} must be a non-symlink directory"
    case "$(stat_owner "${path}")" in
        root|"${SERVICE_ACCOUNT}") ;;
        *) die "${label} must be owned by ${SERVICE_ACCOUNT} or root" ;;
    esac
}

policy_values() {
    python3 - "${POLICY_FILE}" "${PROFILE_KEY}" "${ENVIRONMENT_KEY}" "${RELEASE_KEY}" "${TIER}" "${GITHUB_ENVIRONMENT}" "${RUNNER_LABEL}" <<'PY'
import json
import re
import sys
from pathlib import Path

policy_path, profile_key, environment_key, release_key, tier, github_environment, runner_label = sys.argv[1:]
identifier = re.compile(r"^[A-Za-z0-9._-]+$")
tiers = {"capability", "node", "fabric", "storage", "accelerator", "full"}
capabilities = {"cpu", "gpu", "multi-node", "parallel-storage", "rdma", "slurm"}
required = {
    "schema_version", "service_account", "source_stage_root", "results_root",
    "profiles", "environments", "release_aliases",
}
with Path(policy_path).open(encoding="utf-8") as stream:
    policy = json.load(stream)
if not isinstance(policy, dict) or set(policy) != required:
    raise SystemExit("runner policy has unknown or missing fields")
if policy["schema_version"] != "1.0" or tier not in tiers:
    raise SystemExit("runner policy version or requested tier is invalid")
for value in (profile_key, environment_key, release_key, github_environment, runner_label, policy["service_account"]):
    if not isinstance(value, str) or not identifier.fullmatch(value):
        raise SystemExit("runner policy contains an invalid logical identifier")
profile = policy["profiles"].get(profile_key)
environment = policy["environments"].get(environment_key)
release = policy["release_aliases"].get(release_key)
if not isinstance(profile, dict) or set(profile) != {"site_profile", "github_environment", "runner_label", "required_capabilities", "allowed_tiers", "coverage", "submission"}:
    raise SystemExit("requested profile is not allowlisted")
if not isinstance(environment, dict) or set(environment) != {"release_root"}:
    raise SystemExit("requested environment is not allowlisted")
if not isinstance(release, dict) or set(release) != {"environment", "release_id"}:
    raise SystemExit("requested release is not allowlisted")
if release["environment"] != environment_key or not identifier.fullmatch(release["release_id"]):
    raise SystemExit("release alias does not belong to the requested environment")
if profile["github_environment"] != github_environment or profile["runner_label"] != runner_label:
    raise SystemExit("protected GitHub environment or runner label does not match the allowlisted profile")
if (not isinstance(profile["required_capabilities"], list) or not profile["required_capabilities"]
        or not set(profile["required_capabilities"]).issubset(capabilities)
        or len(profile["required_capabilities"]) != len(set(profile["required_capabilities"]))):
    raise SystemExit("profile capability mapping is invalid")
if (not isinstance(profile["allowed_tiers"], list) or not profile["allowed_tiers"]
        or not set(profile["allowed_tiers"]).issubset(tiers)
        or tier not in profile["allowed_tiers"]):
    raise SystemExit("requested tier is not allowlisted for the protected profile")
coverage = profile["coverage"]
if (not isinstance(coverage, dict) or set(coverage) != {"nodes", "edges"}
        or not isinstance(coverage["nodes"], int) or coverage["nodes"] < 1
        or not isinstance(coverage["edges"], int) or coverage["edges"] < 0):
    raise SystemExit("profile coverage policy is invalid")
submission = profile["submission"]
if not isinstance(submission, dict) or set(submission) != {"partition", "qos", "time_limit"}:
    raise SystemExit("runner submission policy is invalid")
for path in (profile["site_profile"], environment["release_root"], policy["source_stage_root"], policy["results_root"]):
    if not isinstance(path, str) or not path.startswith("/") or ".." in path.split("/"):
        raise SystemExit("runner policy contains an invalid site path")
for value in (submission["partition"], submission["qos"]):
    if not isinstance(value, str) or not identifier.fullmatch(value):
        raise SystemExit("runner submission policy contains an invalid Slurm value")
if not isinstance(submission["time_limit"], str) or not re.fullmatch(r"[0-9]{2}:[0-5][0-9]:[0-5][0-9]", submission["time_limit"]):
    raise SystemExit("runner submission policy contains an invalid time limit")
for key, value in (
    ("service_account", policy["service_account"]),
    ("profile_path", profile["site_profile"]),
    ("release_root", environment["release_root"]),
    ("release_id", release["release_id"]),
    ("source_stage_root", policy["source_stage_root"]),
    ("results_root", policy["results_root"]),
    ("github_environment", profile["github_environment"]),
    ("runner_label", profile["runner_label"]),
    ("required_capabilities", ",".join(profile["required_capabilities"])),
    ("allowed_tiers", ",".join(profile["allowed_tiers"])),
    ("expected_nodes", coverage["nodes"]),
    ("expected_edges", coverage["edges"]),
    ("partition", submission["partition"]),
    ("qos", submission["qos"]),
    ("time_limit", submission["time_limit"]),
):
    print(f"{key}\t{value}")
PY
}

profile_values() {
    python3 - "${PROFILE_PATH}" "${TIER}" "${REQUIRED_CAPABILITIES}" "${ALLOWED_TIERS}" "${EXPECTED_NODES}" "${EXPECTED_EDGES}" "${REPOSITORY_ROOT}/validation/config/cluster-profile.schema.json" "${REPOSITORY_ROOT}/validation/lib/result-manifest.schema.json" <<'PY'
import json
import sys

import jsonschema
import yaml

profile_path, tier, required_capabilities, allowed_tiers, expected_nodes, expected_edges, profile_schema_path, manifest_schema_path = sys.argv[1:]
with open(profile_schema_path, encoding="utf-8") as stream:
    profile_schema = json.load(stream)
with open(manifest_schema_path, encoding="utf-8") as stream:
    manifest_schema = json.load(stream)
with open(profile_path, encoding="utf-8") as stream:
    profile = yaml.safe_load(stream)
jsonschema.Draft202012Validator(profile_schema).validate(profile)
if tier not in profile["tiers"]:
    raise SystemExit("requested tier is not declared by the allowlisted profile")
if tier not in set(allowed_tiers.split(",")):
    raise SystemExit("requested tier is not allowlisted for the protected profile")
tier_data = profile["tiers"][tier]
available = set(profile["available_capabilities"])
missing = set(tier_data["required_capabilities"]) - available
if missing:
    raise SystemExit("tier requires unavailable capabilities")
missing = set(required_capabilities.split(",")) - available
if missing:
    raise SystemExit("protected profile capability mapping does not match the site profile")
if tier_data["resources"]["nodes"] != int(expected_nodes):
    raise SystemExit("site profile node request does not match protected coverage policy")
if tier_data["resources"]["max_edges"] < int(expected_edges):
    raise SystemExit("site profile edge bound is below protected coverage policy")
migrated = set(manifest_schema["properties"]["suite"]["enum"])
suites = tier_data["selected_suites"]
unsupported = sorted(set(suites) - migrated)
if unsupported:
    raise SystemExit("tier selects suites without runner result manifests: " + ", ".join(unsupported))
for key, value in (
    ("profile_id", profile["site"]["profile_id"]),
    ("operating_system", profile["platform"]["operating_system"]),
    ("architecture", profile["platform"]["architecture"]),
    ("nodes", tier_data["resources"]["nodes"]),
        ("gpus_per_node", tier_data["resources"]["gpus_per_node"]),
        ("max_edges", tier_data["resources"]["max_edges"]),
    ("suites", ",".join(suites)),
):
    print(f"{key}\t{value}")
PY
}

read_values() {
    local line key value
    while IFS=$'\t' read -r key value; do
        case "${key}" in
            service_account) SERVICE_ACCOUNT="${value}" ;;
            profile_path) PROFILE_PATH="${value}" ;;
            release_root) RELEASE_ROOT="${value}" ;;
            release_id) RESOLVED_RELEASE_ID="${value}" ;;
            source_stage_root) SOURCE_STAGE_ROOT="${value}" ;;
            results_root) RESULTS_ROOT="${value}" ;;
            github_environment) POLICY_GITHUB_ENVIRONMENT="${value}" ;;
            runner_label) POLICY_RUNNER_LABEL="${value}" ;;
            required_capabilities) REQUIRED_CAPABILITIES="${value}" ;;
            allowed_tiers) ALLOWED_TIERS="${value}" ;;
            expected_nodes) EXPECTED_NODES="${value}" ;;
            expected_edges) EXPECTED_EDGES="${value}" ;;
            partition) PARTITION="${value}" ;;
            qos) QOS="${value}" ;;
            time_limit) TIME_LIMIT="${value}" ;;
            profile_id) PROFILE_ID="${value}" ;;
            operating_system) OPERATING_SYSTEM="${value}" ;;
            architecture) ARCHITECTURE="${value}" ;;
            nodes) PROFILE_NODES="${value}" ;;
            gpus_per_node) EXPECTED_GPUS_PER_NODE="${value}" ;;
            max_edges) PROFILE_MAX_EDGES="${value}" ;;
            suites) SUITES="${value}" ;;
            *) die "policy parser emitted an unknown field" ;;
        esac
    done
}

write_dry_run() {
    printf 'DRY_RUN profile=%s environment=%s release=%s tier=%s github_environment=%s runner_label=%s partition=%s qos=%s expected_nodes=%s expected_edges=%s\n' \
        "${PROFILE_KEY}" "${ENVIRONMENT_KEY}" "${RELEASE_KEY}" "${TIER}" "${POLICY_GITHUB_ENVIRONMENT}" "${POLICY_RUNNER_LABEL}" "${PARTITION}" "${QOS}" "${EXPECTED_NODES}" "${EXPECTED_EDGES}"
}

write_job_script() {
    cat > "${JOB_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if ! type module >/dev/null 2>&1 && [ -r /etc/profile.d/modules.sh ]; then
    source /etc/profile.d/modules.sh
fi
type module >/dev/null 2>&1 || { printf '%s\n' 'module command is unavailable' >&2; exit 2; }
export -f module
export MODULEPATH='${RELEASE_DIR}/modulefiles/${RELEASE_ARCH}:'"\${MODULEPATH:-}"
export CHAPAR_RELEASE_DIR='${RELEASE_DIR}'
export RESULTS_ROOT='${RUN_ROOT}/results'
export VALIDATION_RESULT_MODE=runner
export VALIDATION_RUN_ID='${RUN_ID}'
export VALIDATION_RUN_ISSUED_AT='${RUN_ISSUED_AT}'
python3 - '${STAGED_PROFILE}' '${RUN_ROOT}/capability-inventory.json' <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    profile = yaml.safe_load(stream)
inventory = {
    "schema_version": "1.0",
    "profile_id": profile["site"]["profile_id"],
    "platform": profile["platform"],
    "hardware": profile["hardware"],
    "topology": profile["topology"],
    "available_capabilities": profile["available_capabilities"],
}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(inventory, stream, indent=2, sort_keys=True)
    stream.write("\\n")
PY
{
    module --version 2>&1 || true
    module -t list 2>&1 || true
    find '${RELEASE_DIR}/modulefiles' -type f -printf '%P\\n' 2>/dev/null || true
} > '${RUN_ROOT}/module-versions.txt'
exec '${SOURCE_DIR}/validation/run' --profile '${TIER}' --site-profile '${STAGED_PROFILE}'
EOF
    chmod 700 "${JOB_SCRIPT}"
}

collect_scheduler_record() {
    local record attempts=0
    sacct --allocations --noheader --parsable2 --jobs "${JOB_TOKEN}" --format=JobIDRaw,State,ExitCode,AllocTRES,NodeList > "${RUN_ROOT}/slurm-sacct.txt" 2>&1 || die "sacct could not read the submitted job"
    while [ "${attempts}" -lt 12 ]; do
        record="$(awk -F'|' -v id="${JOB_NUMERIC_ID}" '$1 == id { print; exit }' "${RUN_ROOT}/slurm-sacct.txt")"
        [ -n "${record}" ] && break
        sleep 5
        attempts=$((attempts + 1))
        sacct --allocations --noheader --parsable2 --jobs "${JOB_TOKEN}" --format=JobIDRaw,State,ExitCode,AllocTRES,NodeList > "${RUN_ROOT}/slurm-sacct.txt" 2>&1 || die "sacct could not read the submitted job"
    done
    [ -n "${record}" ] || die "sacct did not return the submitted job ID"
    IFS='|' read -r ACCOUNTING_JOB_ID SCHEDULER_STATE SCHEDULER_EXIT_CODE ALLOC_TRES ALLOCATED_NODELIST _ <<< "${record}"
    [ "${ACCOUNTING_JOB_ID}" = "${JOB_NUMERIC_ID}" ] || die "sacct returned an unexpected job ID"
    [ "${SCHEDULER_STATE}" = COMPLETED ] || die "Slurm job state is not COMPLETED"
    [ "${SCHEDULER_EXIT_CODE}" = 0:0 ] || die "Slurm job exit code is not 0:0"
    python3 - "${ALLOC_TRES}" "${EXPECTED_NODES}" "${EXPECTED_GPUS_PER_NODE}" <<'PY'
import sys

tres, expected_nodes, gpus_per_node = sys.argv[1:]
values = {}
for item in tres.split(','):
    key, separator, value = item.partition('=')
    if separator and value.isdigit():
        values[key] = int(value)
if values.get('node', 0) < int(expected_nodes):
    raise SystemExit('allocated node TRES is below the profile request')
if int(gpus_per_node):
    gpu_count = sum(value for key, value in values.items() if key == 'gres/gpu' or key.startswith('gres/gpu:'))
    if gpu_count < int(expected_nodes) * int(gpus_per_node):
        raise SystemExit('allocated GPU TRES is below the profile request')
PY
    [ -n "${ALLOCATED_NODELIST}" ] && [ "${ALLOCATED_NODELIST}" != Unknown ] || die "sacct did not record allocated nodes"
    scontrol show job -o "${JOB_NUMERIC_ID}" > "${RUN_ROOT}/slurm-scontrol-job.txt" 2>&1 || die "scontrol could not read the submitted job"
    scontrol show nodes "${ALLOCATED_NODELIST}" > "${RUN_ROOT}/slurm-scontrol-nodes.txt" 2>&1 || die "scontrol could not read allocated nodes"
    scontrol show hostnames "${ALLOCATED_NODELIST}" > "${RUN_ROOT}/allocated-nodes.txt" 2>&1 || die "scontrol could not enumerate allocated nodes"
}

collect_manifests() {
    local suite manifest
    IFS=',' read -r -a SUITE_NAMES <<< "${SUITES}"
    : > "${RUN_ROOT}/suite-manifests.txt"
    for suite in "${SUITE_NAMES[@]}"; do
        manifest="${RUN_ROOT}/results/${suite}/${RUN_ID}/suite-manifest.json"
        [ -f "${manifest}" ] && [ ! -L "${manifest}" ] || die "missing suite manifest for ${suite}"
        source "${SOURCE_DIR}/validation/lib/result-manifest.sh"
        validation_result_validate_runner_manifest "${manifest}" || die "invalid runner manifest for ${suite}"
        printf '%s\t%s\n' "${suite}" "${manifest}" >> "${RUN_ROOT}/suite-manifests.txt"
    done
}

write_coverage_report() {
    python3 - "${RUN_ROOT}" "${EXPECTED_NODES}" "${EXPECTED_EDGES}" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected_nodes, expected_edges = map(int, sys.argv[2:])
nodes = sorted({line.strip() for line in (root / "allocated-nodes.txt").read_text(encoding="utf-8").splitlines() if line.strip()})
edge_evidence = []
for path in (root / "results").rglob("*.json"):
    if path.name in {"summary.json", "suite-manifest.json"}:
        continue
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    if not isinstance(payload, dict):
        continue
    for key in ("benchmark_edge_count", "edge_count", "benchmark_count"):
        value = payload.get(key)
        if isinstance(value, int) and value >= 0:
            edge_evidence.append({"path": str(path.relative_to(root)), "field": key, "count": value})
    edges = payload.get("benchmark_edges")
    if isinstance(edges, list):
        edge_evidence.append({"path": str(path.relative_to(root)), "field": "benchmark_edges", "count": len(edges)})
observed_edges = max((entry["count"] for entry in edge_evidence), default=0)
coverage = {
    "schema_version": "1.0",
    "expected": {"nodes": expected_nodes, "edges": expected_edges},
    "observed": {"nodes": len(nodes), "edges": observed_edges},
    "node_names": nodes,
    "edge_evidence": edge_evidence,
}
coverage["complete"] = len(nodes) >= expected_nodes and observed_edges >= expected_edges
with (root / "coverage-report.json").open("w", encoding="utf-8") as stream:
    json.dump(coverage, stream, indent=2, sort_keys=True)
    stream.write("\n")
if not coverage["complete"]:
    raise SystemExit("selected profile did not produce expected node or edge coverage")
PY
}

write_aggregates() {
    python3 - "${RUN_ROOT}" "${RUN_ID}" "${PROFILE_ID}" "${TIER}" "${SOURCE_SHA}" "${BUILD_CHAPAR_SHA}" "${BUILD_SPACK_SHA}" "${RELEASE_METADATA_DIGEST}" "${PROFILE_DIGEST}" "${POLICY_DIGEST}" "${SCHEDULER_STATE}" "${SCHEDULER_EXIT_CODE}" "${ALLOC_TRES}" <<'PY'
import json
import os
import sys
from pathlib import Path

(run_root, run_id, profile_id, tier, source_sha, build_chapar_sha, build_spack_sha,
 release_digest, profile_digest, policy_digest, scheduler_state, scheduler_exit_code,
    alloc_tres) = sys.argv[1:]
root = Path(run_root)
suite_entries = []
for line in (root / "suite-manifests.txt").read_text(encoding="utf-8").splitlines():
    suite, manifest_path = line.split("\t", 1)
    with open(manifest_path, encoding="utf-8") as stream:
        manifest = json.load(stream)
    suite_entries.append({"suite": suite, "verdict": manifest["verdict"]})
counts = {name: sum(entry["verdict"] == name for entry in suite_entries) for name in ("PASS", "WARN", "FAIL", "SKIP")}
with (root / "coverage-report.json").open(encoding="utf-8") as stream:
    coverage = json.load(stream)
tier_manifest = {
    "schema_version": "1.0", "kind": "tier", "ci_authoritative": True,
    "run_id": run_id, "profile_id": profile_id, "tier": tier,
    "provenance": {"validation_source_sha": source_sha, "release_build_chapar_sha": build_chapar_sha,
                   "release_build_spack_sha": build_spack_sha, "release_metadata_digest": release_digest,
                   "profile_digest": profile_digest, "runner_policy_digest": policy_digest},
    "scheduler": {"state": scheduler_state, "exit_code": scheduler_exit_code, "alloc_tres": alloc_tres},
    "capability_inventory": "capability-inventory.json", "module_versions": "module-versions.txt",
    "coverage_report": coverage, "suites": suite_entries,
}
with (root / "tier-manifest.json").open("w", encoding="utf-8") as stream:
    json.dump(tier_manifest, stream, indent=2, sort_keys=True)
    stream.write("\n")
github = root / "github"
github.mkdir(mode=0o700)
summary = {"schema_version": "1.0", "kind": "validation-aggregate", "run_id": run_id,
           "profile_id": profile_id, "tier": tier, "scheduler_state": scheduler_state,
           "scheduler_exit_code": scheduler_exit_code, "alloc_tres": alloc_tres,
     "coverage_complete": coverage["complete"], "coverage": {"expected": coverage["expected"], "observed": coverage["observed"]},
     "verdict_counts": counts, "suites": suite_entries}
with (github / "validation-summary.json").open("w", encoding="utf-8") as stream:
    json.dump(summary, stream, indent=2, sort_keys=True)
    stream.write("\n")
with (github / "validation.prom").open("w", encoding="utf-8") as stream:
    for verdict, count in counts.items():
        stream.write(f'chapar_validation_suites{{tier="{tier}",verdict="{verdict}"}} {count}\n')
PY
    [ -z "$(find "${RUN_ROOT}/github" -type l -print -quit)" ] || die "sanitised artifact directory contains a symlink"
    [ "$(du -sk "${RUN_ROOT}/github" | cut -f 1)" -le 1024 ] || die "sanitised artifact aggregate exceeds 1 MiB"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf 'artifact_dir=%s\n' "${RUN_ROOT}/github" >> "${GITHUB_OUTPUT}"
    fi
}

cleanup() {
    local status="$?"
    trap - EXIT INT TERM
    if [ -n "${JOB_TOKEN:-}" ] && [ "${JOB_FINISHED:-false}" != true ]; then
        scancel -- "${JOB_TOKEN}" >/dev/null 2>&1 || true
    fi
    exit "${status}"
}

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_KEY=""
ENVIRONMENT_KEY=""
RELEASE_KEY=""
TIER=""
DRY_RUN=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) PROFILE_KEY="${2:-}"; shift 2 ;;
        --environment) ENVIRONMENT_KEY="${2:-}"; shift 2 ;;
        --release) RELEASE_KEY="${2:-}"; shift 2 ;;
        --tier) TIER="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

for value in "${PROFILE_KEY}" "${ENVIRONMENT_KEY}" "${RELEASE_KEY}" "${TIER}"; do
    simple_id "${value}" || die "selectors must be simple allowlist keys"
done
case "${TIER}" in capability|node|fabric|storage|accelerator|full) ;; *) die "unsupported tier" ;; esac
GITHUB_ENVIRONMENT="${CI_VALIDATION_GITHUB_ENVIRONMENT:-}"
RUNNER_LABEL="${CI_VALIDATION_RUNNER_LABEL:-}"
simple_id "${GITHUB_ENVIRONMENT}" || die "CI_VALIDATION_GITHUB_ENVIRONMENT must be a protected environment key"
simple_id "${RUNNER_LABEL}" || die "CI_VALIDATION_RUNNER_LABEL must be a dedicated runner label"

if [ "${CI_VALIDATION_DRY_RUN_FIXTURE:-false}" = true ]; then
    [ "${DRY_RUN}" = true ] || die "dry-run fixture mode requires --dry-run"
    POLICY_FILE="${REPOSITORY_ROOT}/ci/fixtures/submit-validation/policy.json"
else
    POLICY_FILE="${CI_VALIDATION_POLICY_FILE:-}"
    [ -n "${POLICY_FILE}" ] || die "CI_VALIDATION_POLICY_FILE must name the runner-owned policy"
fi

SERVICE_ACCOUNT=""
POLICY_OUTPUT="$(policy_values)" || die "runner policy validation failed"
read_values <<< "${POLICY_OUTPUT}"
if [ "${CI_VALIDATION_DRY_RUN_FIXTURE:-false}" != true ]; then
    require_site_regular_file "${POLICY_FILE}" "runner policy"
    [ "$(id -un)" = "${SERVICE_ACCOUNT}" ] || die "must run as the dedicated validation service account"
fi
POLICY_DIGEST="$(sha256_file "${POLICY_FILE}")"

if [ "${DRY_RUN}" = true ]; then
    write_dry_run
    exit 0
fi

require_site_regular_file "${PROFILE_PATH}" "site profile"
require_site_directory "${RELEASE_ROOT}" "release root"
require_site_directory "${SOURCE_STAGE_ROOT}" "source stage root"
require_site_directory "${RESULTS_ROOT}" "results root"
PROFILE_OUTPUT="$(profile_values)" || die "site profile validation failed"
read_values <<< "${PROFILE_OUTPUT}"
PROFILE_DIGEST="$(sha256_file "${PROFILE_PATH}")"
RELEASE_ARCH="linux-${OPERATING_SYSTEM}-${ARCHITECTURE}"
RELEASE_DIR="${RELEASE_ROOT}/${OPERATING_SYSTEM}/${RELEASE_ARCH}/releases/${RESOLVED_RELEASE_ID}"
[ -d "${RELEASE_DIR}" ] && [ ! -L "${RELEASE_DIR}" ] || die "allowlisted release is absent or symlinked"
RELEASE_DIR="$(cd -P "${RELEASE_DIR}" && pwd)"
[ -r "${RELEASE_DIR}/metadata.txt" ] && [ -r "${RELEASE_DIR}/spack.yaml" ] && [ -r "${RELEASE_DIR}/.chapar-arch" ] || die "release lacks immutable provenance files"
[ "$(cat "${RELEASE_DIR}/.chapar-arch")" = "${RELEASE_ARCH}" ] || die "release architecture does not match profile"
BUILD_SHAS="$(python3 - "${RELEASE_DIR}/metadata.txt" <<'PY'
import re
import sys

values = {}
with open(sys.argv[1], encoding="utf-8") as stream:
    for line in stream:
        key, separator, value = line.rstrip("\n").partition(": ")
        if separator:
            values[key] = value
for key in ("chapar_source_sha", "spack_source_sha"):
    value = values.get(key, "")
    if not re.fullmatch(r"[0-9a-f]{40,64}", value):
        raise SystemExit(f"release metadata is missing immutable {key}")
print(values["chapar_source_sha"], values["spack_source_sha"])
PY
)" || die "release metadata provenance validation failed"
read -r BUILD_CHAPAR_SHA BUILD_SPACK_SHA <<< "${BUILD_SHAS}"
RELEASE_METADATA_DIGEST="$( { sha256_file "${RELEASE_DIR}/metadata.txt"; sha256_file "${RELEASE_DIR}/spack.yaml"; sha256_file "${RELEASE_DIR}/.chapar-arch"; } | sha256_text)"
SOURCE_SHA="$(git -C "${REPOSITORY_ROOT}" rev-parse --verify HEAD^{commit})"
git -C "${REPOSITORY_ROOT}" diff --quiet
git -C "${REPOSITORY_ROOT}" diff --cached --quiet
RUN_ID="ci-${SOURCE_SHA:0:12}-$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ISSUED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_ROOT="${RESULTS_ROOT}/${RUN_ID}"
SOURCE_DIR="${SOURCE_STAGE_ROOT}/${RUN_ID}"
umask 077
mkdir "${RUN_ROOT}" "${SOURCE_DIR}" || die "run directory already exists"
trap cleanup EXIT INT TERM
git -C "${REPOSITORY_ROOT}" archive --format=tar "${SOURCE_SHA}" ci validation | tar -x -C "${SOURCE_DIR}"
cp "${PROFILE_PATH}" "${SOURCE_DIR}/validation/config/site-profile.yaml"
STAGED_PROFILE="${SOURCE_DIR}/validation/config/site-profile.yaml"
JOB_SCRIPT="${RUN_ROOT}/run-tier.sh"
write_job_script

SBATCH_ARGS=(--parsable --export=NONE --chdir "${SOURCE_DIR}" --partition "${PARTITION}" --qos "${QOS}" --time "${TIME_LIMIT}" --nodes "${EXPECTED_NODES}" --output "${RUN_ROOT}/slurm-%j.out" --error "${RUN_ROOT}/slurm-%j.err")
if [ "${EXPECTED_GPUS_PER_NODE}" -gt 0 ]; then
    SBATCH_ARGS+=(--gpus-per-node "${EXPECTED_GPUS_PER_NODE}")
fi
JOB_TOKEN="$(sbatch "${SBATCH_ARGS[@]}" "${JOB_SCRIPT}")"
case "${JOB_TOKEN}" in
    [0-9]*|[0-9]*';'*) ;;
    *) die "sbatch --parsable returned an invalid job identifier" ;;
esac
JOB_NUMERIC_ID="${JOB_TOKEN%%;*}"
case "${JOB_NUMERIC_ID}" in *[!0-9]*|"") die "sbatch --parsable returned an invalid numeric job identifier" ;; esac

polls=0
while squeue --noheader --jobs "${JOB_TOKEN}" >/dev/null 2>&1 && [ -n "$(squeue --noheader --jobs "${JOB_TOKEN}")" ]; do
    [ "${polls}" -lt 240 ] || die "Slurm job exceeded the bounded polling window"
    sleep 15
    polls=$((polls + 1))
done
collect_scheduler_record
JOB_FINISHED=true
collect_manifests
write_coverage_report
write_aggregates
printf 'VALIDATION_RUN_ID=%s\n' "${RUN_ID}"
