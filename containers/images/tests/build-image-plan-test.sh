#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/chapar-image-plan.XXXXXX")"
TMP_BASE="$(cd "${TMP_BASE}" && pwd -P)"
trap 'chmod -R u+rwX "${TMP_BASE}" 2>/dev/null || true; rm -rf "${TMP_BASE}"' EXIT HUP INT TERM
PIPELINE_ROOT="${TMP_BASE}/repo/containers/images"
PLAN_SCRIPT="${PIPELINE_ROOT}/build-image.sh"
CATALOG="${TMP_BASE}/repo/envs/software/spack.yaml"
RELEASE_DIR="${TMP_BASE}/release"
STORE_ROOT="${TMP_BASE}/store"
CONTRACTS="${TMP_BASE}/contracts"
OUTPUTS="${TMP_BASE}/outputs"
TOOLS="${TMP_BASE}/tools"
TOOL_LOG="${TMP_BASE}/tools.log"
PYTHON_DIR="$(dirname "$(command -v python3)")"
mkdir -p "${PIPELINE_ROOT}/tests" "$(dirname "${CATALOG}")" "${CONTRACTS}" "${OUTPUTS}" "${TOOLS}"
cp "${ROOT_DIR}/containers/images/build-image.sh" "${ROOT_DIR}/containers/images/registry.py" \
  "${ROOT_DIR}/containers/images/release_contract.py" "${ROOT_DIR}/containers/images/selection_contract.py" "${ROOT_DIR}/containers/images/containers.json" \
  "${ROOT_DIR}/containers/images/targets.json" "${PIPELINE_ROOT}/"
cp "${ROOT_DIR}/envs/software/spack.yaml" "${CATALOG}"
chmod 0755 "${PLAN_SCRIPT}"
: >"${TOOL_LOG}"
for tool in enroot skopeo spack docker srun ssh curl wget git; do
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '${tool}' >>\"\${TOOL_LOG:?}\"" 'exit 97' >"${TOOLS}/${tool}"
  chmod 0755 "${TOOLS}/${tool}"
done

snapshot() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
from pathlib import Path
root = Path(sys.argv[1])
rows = []
if root.exists():
    for path in sorted(root.rglob("*")):
        rows.append((path.relative_to(root).as_posix(), "link:" + os.readlink(path) if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "dir"))
print(hashlib.sha256(repr(rows).encode()).hexdigest())
PY
}

write_fixture() {
  local base="$1" set_id="$2" target="$3" arch="$4"
  rm -rf "${RELEASE_DIR}" "${STORE_ROOT}" "${CONTRACTS}"
  mkdir -p "${RELEASE_DIR}/modulefiles/${arch}" "${STORE_ROOT}/root-1.0-aaaabbbb" \
    "${STORE_ROOT}/runtime-1.0-ccccdddd" "${STORE_ROOT}/build-1.0-eeeeffff" "${CONTRACTS}"
  printf 'module fixture\n' >"${RELEASE_DIR}/modulefiles/${arch}/root.lua"
  printf '{"datacenter_id":"example-lab","targets":["%s"]}\n' "${target}" >"${CONTRACTS}/datacenter.json"
  printf '{"datacenter_id":"example-lab","target":"%s","allowed_software_sets":["%s"],"container_selections":[{"software_set":"%s","container":"%s"}],"publication":{"publish_buildcache":true,"publish_modules":true,"publish_containers":true,"promote_current":true}}\n' "${target}" "${set_id}" "${set_id}" "${base}" >"${CONTRACTS}/target.json"
  python3 - "${PIPELINE_ROOT}" "${CATALOG}" "${RELEASE_DIR}" "${STORE_ROOT}" "${CONTRACTS}" "${base}" "${set_id}" "${target}" <<'PY'
import hashlib, json, sys
from pathlib import Path
pipeline, catalog, release, store, contracts, base, software_set, target = sys.argv[1:]
pipeline, catalog, release, store, contracts = map(Path, (pipeline, catalog, release, store, contracts))
targets = json.loads((pipeline / "targets.json").read_text())["targets"]
categories = {
    "nvidia_hpc_benchmarks_oci": ("nvcr.io/nvidia/hpc-benchmarks", "26.02", ["linux-x86_64-v4", "linux-aarch64-gb300"]),
    "ubuntu_base_oci": ("ubuntu", "24.04", ["linux-x86_64-generic"]),
}
verified = {}
for category, (image, tag, allowed) in categories.items():
    verified[category] = {"image": image, "tag": tag, "platforms": {item: {"descriptor_digest": "sha256:" + ("1" if item == "linux-x86_64-v4" else "2" if item == "linux-aarch64-gb300" else "3") * 64} for item in allowed}}
(pipeline / "sources-lock.json").write_text(json.dumps({"status": "complete", "unresolved": [], "verified": verified}, sort_keys=True))
lock = {"roots": [{"hash": "aaaabbbb"}], "concrete_specs": {"aaaabbbb": {"dependencies": [{"hash": "ccccdddd", "type": ["link", "run"]}, {"hash": "eeeeffff", "type": ["build"]}]}, "ccccdddd": {"dependencies": []}, "eeeeffff": {"dependencies": []}}}
(release / "spack.lock").write_text(json.dumps(lock, sort_keys=True))
(release / "spack.yaml").write_text("spack:\n  specs: []\n")
(release / "target-policy.yaml").write_text("target: " + target + "\n")
sha = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
authority = {"software_catalog": sha(catalog), "target_registry": sha(pipeline / "targets.json"), "container_registry": sha(pipeline / "containers.json"), "datacenter_contract": sha(contracts / "datacenter.json"), "target_contract": sha(contracts / "target.json")}
path_names = ("release_root", "release_final", "release_staging", "modulefiles", "install_tree", "writable_buildcache", "ccache", "container_outputs", "receipts", "evidence", "spack_build_stage", "image_staging", "validation_work", "resolver_work")
selection_paths = {name: str(release.parent / name) for name in path_names}
# Mirror what release.sh actually emits: release_final is the release directory,
# install_tree is the store, and "modulefiles" is the *durable published* root --
# never the release-local modulefiles tree. Pointing it at release/modulefiles
# would describe a release shape release.sh cannot produce.
selection_paths["release_root"] = str(release.parent)
selection_paths["release_final"] = str(release)
selection_paths["install_tree"] = str(store)
selection = {"schema": "https://nscaledev.github.io/chapar/schemas/software-selection/v1", "schema_version": 1, "policy": {"datacenter": "example-lab", "software_set": software_set, "target": target}, "invocation": {"release_id": "release-1", "run_id": "run-1"}, "target_facts": targets[target], "containers": [base], "selected_roots": [{"id": "fixture-root", "spec": "fixture@1", "classification": "runtime"}], "excluded_roots": [], "paths": selection_paths, "authorities": authority, "artifacts": {"target_policy_sha256": sha(release / "target-policy.yaml"), "effective_manifest_sha256": sha(release / "spack.yaml")}, "versions": {"selection_schema": 1, "target_registry_schema": 1, "container_registry_schema": 1, "resolver": "fixture-1", "resolver_sha256": "f" * 64, "pydantic": "2", "PyYAML": "6"}, "deferred_proofs": ["fixture proof"]}
(release / "selection.json").write_text(json.dumps(selection, indent=2, sort_keys=True) + "\n")
digests = {name + "_sha256": value for name, value in authority.items()}
digests.update({"selection_sha256": sha(release / "selection.json"), "effective_manifest_sha256": sha(release / "spack.yaml"), "target_policy_sha256": sha(release / "target-policy.yaml"), "release_local_lock_sha256": sha(release / "spack.lock")})
metadata = {"schema": "https://nscaledev.github.io/chapar/schemas/release-metadata/v1", "schema_version": 1, "identity": {"datacenter": "example-lab", "software_set": software_set, "target": target, "release_id": "release-1", "run_id": "run-1"}, "roots": {name: selection_paths[name] for name in ("release_root", "release_final", "release_staging", "modulefiles", "install_tree", "writable_buildcache", "ccache", "spack_build_stage")}, "digests": digests, "policy": {"publish_buildcache": True, "buildcache_signed": False, "buildcache_autopush": True}}
(release / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
PY
}

invoke() {
  env -i HOME="${TMP_BASE}" LC_ALL=C PATH="${TOOLS}:${PYTHON_DIR}:/usr/bin:/bin" TOOL_LOG="${TOOL_LOG}" \
    "${PLAN_SCRIPT}" --base "$1" --target "$2" --release-dir "${RELEASE_DIR}" \
    --datacenter-contract "${CONTRACTS}/datacenter.json" --target-contract "${CONTRACTS}/target.json" \
    --image-id fixture-image --plan-only
}

expect_success() {
  local name="$1" base="$2" target="$3" before
  before="$(snapshot "${TMP_BASE}/candidates")|$(snapshot "${TMP_BASE}/final")"
  : >"${TOOL_LOG}"
  invoke "${base}" "${target}" >"${OUTPUTS}/${name}.out" 2>"${OUTPUTS}/${name}.err" || { cat "${OUTPUTS}/${name}.err" >&2; exit 1; }
  [[ ! -s "${TOOL_LOG}" && "${before}" == "$(snapshot "${TMP_BASE}/candidates")|$(snapshot "${TMP_BASE}/final")" ]]
  grep -Fq 'selection:' "${OUTPUTS}/${name}.out"
  grep -Fq 'release lock:' "${OUTPUTS}/${name}.out"
  printf 'PASS: %s\n' "${name}"
}

expect_failure() {
  local name="$1" expected="$2" base="$3" target="$4" before status
  before="$(snapshot "${TMP_BASE}/candidates")|$(snapshot "${TMP_BASE}/final")"
  : >"${TOOL_LOG}"
  set +e
  invoke "${base}" "${target}" >"${OUTPUTS}/${name}.out" 2>"${OUTPUTS}/${name}.err"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]]
  grep -Fq "${expected}" "${OUTPUTS}/${name}.out" "${OUTPUTS}/${name}.err"
  [[ ! -s "${TOOL_LOG}" && "${before}" == "$(snapshot "${TMP_BASE}/candidates")|$(snapshot "${TMP_BASE}/final")" ]]
  printf 'PASS: %s failed without image/tool writes\n' "${name}"
}

tamper_json() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, key, value = sys.argv[1:]
doc = json.loads(open(path).read())
node = doc
parts = key.split(".")
for part in parts[:-1]: node = node[part]
node[parts[-1]] = value
open(path, "w").write(json.dumps(doc, indent=2, sort_keys=True) + "\n")
PY
}

rebind_selection_digest() {
  python3 - "${RELEASE_DIR}/metadata.json" "${RELEASE_DIR}/selection.json" <<'PY'
import hashlib, json, sys
metadata_path, selection_path = sys.argv[1:]
metadata = json.load(open(metadata_path))
metadata["digests"]["selection_sha256"] = hashlib.sha256(open(selection_path, "rb").read()).hexdigest()
open(metadata_path, "w").write(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
PY
}

write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
expect_success nvidia-x86 nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-aarch64-gb300 linux-ubuntu24.04-aarch64
expect_success nvidia-arm nvidia-vlad linux-aarch64-gb300
write_fixture ubuntu-hpcsim hpcsim linux-x86_64-generic linux-ubuntu24.04-x86_64
expect_success ubuntu-generic ubuntu-hpcsim linux-x86_64-generic

write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
tamper_json "${RELEASE_DIR}/metadata.json" identity.software_set hpcsim
expect_failure wrong-set 'software set is not accepted' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
tamper_json "${RELEASE_DIR}/metadata.json" identity.target linux-aarch64-gb300
expect_failure wrong-target 'release target does not match' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
tamper_json "${RELEASE_DIR}/metadata.json" identity.datacenter other-lab
expect_failure wrong-datacenter 'datacenter contract identity differs from release' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
printf 'tamper\n' >>"${RELEASE_DIR}/spack.lock"
expect_failure lock-digest 'release digest mismatch: release_local_lock_sha256' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
printf 'tamper\n' >>"${RELEASE_DIR}/selection.json"
expect_failure selection-digest 'release digest mismatch: selection_sha256' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
tamper_json "${RELEASE_DIR}/selection.json" unknown_field rejected
rebind_selection_digest
expect_failure selection-unknown-top 'selection fields mismatch' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
tamper_json "${RELEASE_DIR}/selection.json" policy.unknown_field rejected
rebind_selection_digest
expect_failure selection-unknown-nested 'selection.policy fields mismatch' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
printf 'tamper\n' >>"${CONTRACTS}/target.json"
expect_failure contract-digest 'release digest mismatch: target_contract_sha256' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
tamper_json "${PIPELINE_ROOT}/sources-lock.json" status blocked
expect_failure blocked-source 'source lock is not usable' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
rm -rf "${STORE_ROOT}/runtime-1.0-ccccdddd"
expect_failure missing-prefix 'runtime closure are not installed' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
mkdir "${STORE_ROOT}/runtime-copy-ccccdddd"
expect_failure duplicate-prefix 'multiple prefixes' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad vlad linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
ln -s "${TMP_BASE}" "${STORE_ROOT}/foreign-ccccdddd"
expect_failure foreign-prefix 'symlinked prefix' nvidia-vlad linux-x86_64-v4
write_fixture nvidia-vlad all linux-x86_64-v4 linux-ubuntu24.04-x86_64_v4
expect_failure union-masquerade 'software set is not accepted' nvidia-vlad linux-x86_64-v4

printf 'PASS: plan-only registry, selection, provenance, closure, and no-side-effect scenarios\n'
