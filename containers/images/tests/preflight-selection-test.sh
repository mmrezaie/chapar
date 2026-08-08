#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
PREFLIGHT="${ROOT}/containers/images/preflight.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chapar-preflight-selection.XXXXXX")"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT HUP INT TERM
chmod 0700 "${TMP}"
mkdir -p "${TMP}/authority" "${TMP}/paths/image-stage" "${TMP}/paths/receipts" "${TMP}/paths/containers" "${TMP}/out"
cp "${ROOT}/containers/images/targets.json" "${TMP}/authority/targets.json"
cp "${ROOT}/containers/images/containers.json" "${TMP}/authority/containers.json"
python3 - "${TMP}" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
durable = {name: str(root / "roots" / name) for name in (
    "install_tree", "releases", "modulefiles", "writable_buildcache", "ccache",
    "container_outputs", "receipts", "evidence",
)}
temporary = {name: str(root / "roots" / name) for name in (
    "release_staging", "spack_build_stage", "image_staging", "validation_work", "resolver_work",
)}
contract = {
    "schema": "https://nscaledev.github.io/chapar/schemas/target-contract/v1",
    "schema_version": 1,
    "datacenter_id": "fixture-dc",
    "status": "example",
    "target": "linux-x86_64-v4",
    "allowed_software_sets": ["vlad"],
    "container_selections": [{"software_set": "vlad", "container": "nvidia-vlad"}],
    "paths": {"durable_writable": durable, "temporary": temporary, "read_only_inputs": []},
    "slurm": {"partition": "fixture", "constraint": "x86_v4", "account": "fixture", "qos": "normal"},
    "roles": {"builder": "fixture-builder", "validator": "fixture-validator", "publisher": "fixture-publisher"},
    "sharing": {}, "publication": {}, "provenance": {},
}
contract_path = root / "authority/contract.json"
contract_path.write_text(json.dumps(contract, sort_keys=True))
contract_digest = hashlib.sha256(contract_path.read_bytes()).hexdigest()
target_facts = json.loads((root / "authority/targets.json").read_text())["targets"]["linux-x86_64-v4"]
target_digest = hashlib.sha256((root / "authority/targets.json").read_bytes()).hexdigest()
container_digest = hashlib.sha256((root / "authority/containers.json").read_bytes()).hexdigest()
path_names = ("release_root", "release_final", "release_staging", "modulefiles", "install_tree", "writable_buildcache", "ccache", "container_outputs", "receipts", "evidence", "spack_build_stage", "image_staging", "validation_work", "resolver_work")
paths = {name: str(root / "paths" / name) for name in path_names}
namespace = Path("fixture-dc/vlad/linux-x86_64-v4")
paths.update({
    "image_staging": str(Path(temporary["image_staging"]) / namespace / "fixture-run"),
    "receipts": str(Path(durable["receipts"]) / namespace / "fixture-release"),
    "container_outputs": str(Path(durable["container_outputs"]) / namespace / "fixture-release"),
})
selection = {
    "schema": "https://nscaledev.github.io/chapar/schemas/software-selection/v1",
    "schema_version": 1,
    "policy": {"datacenter": "fixture-dc", "software_set": "vlad", "target": "linux-x86_64-v4"},
    "invocation": {"release_id": "fixture-release", "run_id": "fixture-run"},
    "target_facts": target_facts,
    "containers": ["nvidia-vlad"],
    "selected_roots": [{"id": "fixture", "spec": "fixture@1", "classification": "runtime"}],
    "excluded_roots": [],
    "paths": paths,
    "authorities": {"software_catalog": "a" * 64, "target_registry": target_digest, "container_registry": container_digest, "datacenter_contract": "d" * 64, "target_contract": contract_digest},
    "artifacts": {"target_policy_sha256": "e" * 64, "effective_manifest_sha256": "f" * 64},
    "versions": {"selection_schema": 1, "target_registry_schema": 1, "container_registry_schema": 1, "resolver": "fixture-1", "resolver_sha256": "1" * 64, "pydantic": "2", "PyYAML": "6"},
    "deferred_proofs": ["fixture proof"],
}
selection_path = root / "authority/selection.json"
selection_path.write_text(json.dumps(selection, sort_keys=True))
(root / "authority/sources.json").write_text(json.dumps({"status": "complete", "unresolved": [], "verified": {"nvidia_hpc_benchmarks_oci": {}, "ubuntu_base_oci": {}}}, sort_keys=True))
(root / "digests").write_text(contract_digest + " " + hashlib.sha256(selection_path.read_bytes()).hexdigest() + "\n")
PY
read -r CONTRACT_SHA SELECTION_SHA <"${TMP}/digests"
: >"${TMP}/marker"

invoke() {
  VLAD_PREFLIGHT_TEST_MODE=1 \
  VLAD_PREFLIGHT_TEST_ROOT="${TMP}" \
  VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER="${TMP}/marker" \
  VLAD_PREFLIGHT_TEST_CONTRACT_UID="$(id -u)" \
  VLAD_PREFLIGHT_TEST_SOURCES_LOCK="${TMP}/authority/sources.json" \
  VLAD_PREFLIGHT_TEST_TARGETS="${TMP}/authority/targets.json" \
  VLAD_PREFLIGHT_TEST_CONTAINERS="${TMP}/authority/containers.json" \
  VLAD_PREFLIGHT_TEST_UNAME_M=x86_64 \
  VLAD_PREFLIGHT_TEST_ROLE_IDENTITY="${1}" \
  "${PREFLIGHT}" --mode build --plan-only --base nvidia-vlad --target linux-x86_64-v4 \
    --image-id fixture-image --selection "${TMP}/authority/selection.json" \
    --selection-sha256 "${2}" --target-contract "${TMP}/authority/contract.json" \
    --target-contract-sha256 "${3}"
}

before="$(find "${TMP}/paths" -type f -print | sort)"
invoke fixture-builder "${SELECTION_SHA}" "${CONTRACT_SHA}" >"${TMP}/out/happy.json"
grep -Fq '"datacenter":"fixture-dc"' "${TMP}/out/happy.json"
grep -Fq '"role":"builder"' "${TMP}/out/happy.json"
[[ "${before}" == "$(find "${TMP}/paths" -type f -print | sort)" ]]
printf 'PASS: selected-contract preflight plan derived tuple, role, paths, and Slurm placement\n'

expect_failure() {
  local name="$1" expected="$2"; shift 2
  set +e
  "$@" >"${TMP}/out/${name}.out" 2>"${TMP}/out/${name}.err"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  grep -Fq "${expected}" "${TMP}/out/${name}.err"
  [[ "${before}" == "$(find "${TMP}/paths" -type f -print | sort)" ]]
  printf 'PASS: %s failed before custody writes\n' "${name}"
}

expect_failure wrong-role 'does not own selected contract role' invoke intruder "${SELECTION_SHA}" "${CONTRACT_SHA}"
expect_failure selection-tamper 'selection SHA-256 mismatch' invoke fixture-builder "$(printf '0%.0s' {1..64})" "${CONTRACT_SHA}"
expect_failure contract-tamper 'target contract SHA-256 mismatch' invoke fixture-builder "${SELECTION_SHA}" "$(printf '0%.0s' {1..64})"
cp "${TMP}/authority/selection.json" "${TMP}/authority/selection.good"
python3 - "${TMP}/authority/selection.json" <<'PY'
import json, sys
p = sys.argv[1]; value = json.load(open(p)); value["unknown_field"] = "rejected"; open(p, "w").write(json.dumps(value))
PY
UNKNOWN_TOP_SHA="$(shasum -a 256 "${TMP}/authority/selection.json" | awk '{print $1}')"
expect_failure selection-unknown-top 'selection fields mismatch' invoke fixture-builder "${UNKNOWN_TOP_SHA}" "${CONTRACT_SHA}"
mv "${TMP}/authority/selection.good" "${TMP}/authority/selection.json"
cp "${TMP}/authority/selection.json" "${TMP}/authority/selection.good"
python3 - "${TMP}/authority/selection.json" <<'PY'
import json, sys
p = sys.argv[1]; value = json.load(open(p)); value["paths"]["unknown_field"] = "/rejected"; open(p, "w").write(json.dumps(value))
PY
UNKNOWN_NESTED_SHA="$(shasum -a 256 "${TMP}/authority/selection.json" | awk '{print $1}')"
expect_failure selection-unknown-nested 'selection.paths fields mismatch' invoke fixture-builder "${UNKNOWN_NESTED_SHA}" "${CONTRACT_SHA}"
mv "${TMP}/authority/selection.good" "${TMP}/authority/selection.json"
cp "${TMP}/authority/selection.json" "${TMP}/authority/selection.good"
python3 - "${TMP}/authority/selection.json" <<'PY'
import json, sys
p = sys.argv[1]; value = json.load(open(p)); del value["versions"]; open(p, "w").write(json.dumps(value))
PY
MISSING_TOP_SHA="$(shasum -a 256 "${TMP}/authority/selection.json" | awk '{print $1}')"
expect_failure selection-missing-top 'selection fields mismatch' invoke fixture-builder "${MISSING_TOP_SHA}" "${CONTRACT_SHA}"
mv "${TMP}/authority/selection.good" "${TMP}/authority/selection.json"
cp "${TMP}/authority/selection.json" "${TMP}/authority/selection.good"
python3 - "${TMP}/authority/selection.json" <<'PY'
import json, sys
p = sys.argv[1]; value = json.load(open(p)); del value["policy"]["target"]; open(p, "w").write(json.dumps(value))
PY
MISSING_NESTED_SHA="$(shasum -a 256 "${TMP}/authority/selection.json" | awk '{print $1}')"
expect_failure selection-missing-nested 'selection.policy fields mismatch' invoke fixture-builder "${MISSING_NESTED_SHA}" "${CONTRACT_SHA}"
mv "${TMP}/authority/selection.good" "${TMP}/authority/selection.json"
cp "${TMP}/authority/selection.json" "${TMP}/authority/selection.good"
python3 - "${TMP}/authority/selection.json" <<'PY'
import json, sys
p = sys.argv[1]; value = json.load(open(p)); value["paths"]["image_staging"] = 7; open(p, "w").write(json.dumps(value))
PY
WRONG_TYPE_SHA="$(shasum -a 256 "${TMP}/authority/selection.json" | awk '{print $1}')"
expect_failure selection-wrong-nested-type 'selection.paths values must be nonempty strings' invoke fixture-builder "${WRONG_TYPE_SHA}" "${CONTRACT_SHA}"
mv "${TMP}/authority/selection.good" "${TMP}/authority/selection.json"
cp "${TMP}/authority/selection.json" "${TMP}/authority/selection.good"
python3 - "${TMP}/authority" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
targets = root / "targets.forged.json"
containers = root / "containers.forged.json"
targets.write_bytes((root / "targets.json").read_bytes() + b"\n")
containers.write_bytes((root / "containers.json").read_bytes() + b"\n")
selection = json.loads((root / "selection.json").read_text())
selection["authorities"]["target_registry"] = hashlib.sha256(targets.read_bytes()).hexdigest()
selection["authorities"]["container_registry"] = hashlib.sha256(containers.read_bytes()).hexdigest()
(root / "selection.json").write_text(json.dumps(selection, sort_keys=True))
PY
FORGED_SELECTION_SHA="$(shasum -a 256 "${TMP}/authority/selection.json" | awk '{print $1}')"
expect_failure forged-authority-graph 'target-registry authority digest mismatch' invoke fixture-builder "${FORGED_SELECTION_SHA}" "${CONTRACT_SHA}"
mv "${TMP}/authority/selection.good" "${TMP}/authority/selection.json"
python3 - "${TMP}/authority/sources.json" <<'PY'
import json, sys
p = sys.argv[1]; value = json.load(open(p)); value["status"] = "blocked"; value["unresolved"] = [{"category": "nvidia_hpc_benchmarks_oci"}]; open(p, "w").write(json.dumps(value))
PY
expect_failure blocked-source 'source lock is blocked or incomplete' invoke fixture-builder "${SELECTION_SHA}" "${CONTRACT_SHA}"
printf '%s\n' '{"status":"complete","unresolved":[],"verified":{"nvidia_hpc_benchmarks_oci":{},"ubuntu_base_oci":{}}}' >"${TMP}/authority/sources.json"
printf '%s\n' '{"replaced":true}' >"${TMP}/authority/selection.replacement"
printf '%s\n' '{"replaced":true}' >"${TMP}/authority/contract.replacement"
printf '%s\n' '{"status":"blocked","unresolved":[{"category":"nvidia_hpc_benchmarks_oci"}],"verified":{}}' >"${TMP}/authority/sources.replacement"
cp "${TMP}/authority/targets.json" "${TMP}/authority/targets.replacement"
cp "${TMP}/authority/containers.json" "${TMP}/authority/containers.replacement"
VLAD_PREFLIGHT_TEST_SWAP_SELECTION="${TMP}/authority/selection.replacement" \
VLAD_PREFLIGHT_TEST_SWAP_CONTRACT="${TMP}/authority/contract.replacement" \
VLAD_PREFLIGHT_TEST_SWAP_SOURCE_LOCK="${TMP}/authority/sources.replacement" \
VLAD_PREFLIGHT_TEST_SWAP_TARGETS="${TMP}/authority/targets.replacement" \
VLAD_PREFLIGHT_TEST_SWAP_CONTAINERS="${TMP}/authority/containers.replacement" \
  invoke fixture-builder "${SELECTION_SHA}" "${CONTRACT_SHA}" >"${TMP}/out/snapshot-swap.json"
grep -Fq '"datacenter":"fixture-dc"' "${TMP}/out/snapshot-swap.json"
[[ "${before}" == "$(find "${TMP}/paths" -type f -print | sort)" ]]
printf 'PASS: authenticated selection, contract, registries, and source-lock snapshots survived pathname replacement\n'
printf 'PASS: preflight selection fixture remained plan-only and side-effect free\n'
