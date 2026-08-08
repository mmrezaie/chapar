#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
REGISTRY="${ROOT_DIR}/containers/images/registry.py"
TARGETS="${ROOT_DIR}/containers/images/targets.json"
CONTAINERS="${ROOT_DIR}/containers/images/containers.json"
SOURCES="${ROOT_DIR}/containers/images/sources-lock.json"
PYTHON_BIN="${CHAPAR_OFFLINE_PYTHON:-python3}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chapar-registry-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

cleanup_failed_case() {
    local name="$1"
    test ! -s "${TMP_DIR}/${name}.out"
}

resolve() {
    local container="$1"
    local software_set="$2"
    local target="$3"
    local targets_path="${4:-${TARGETS}}"
    local containers_path="${5:-${CONTAINERS}}"
    local sources_path="${6:-${SOURCES}}"

    "${PYTHON_BIN}" -I -E "${REGISTRY}" resolve \
        --targets "${targets_path}" \
        --containers "${containers_path}" \
        --sources "${sources_path}" \
        --container "${container}" \
        --software-set "${software_set}" \
        --target "${target}"
}

expect_failure() {
    local name="$1"
    shift
    set +e
    "$@" >"${TMP_DIR}/${name}.out" 2>"${TMP_DIR}/${name}.err"
    local status=$?
    set -e
    if [ "${status}" -eq 0 ]; then
        echo "expected ${name} to fail" >&2
        return 1
    fi
    cleanup_failed_case "${name}"
}

write_fixture() {
    local name="$1"
    local program="$2"
    "${PYTHON_BIN}" -I -E - "${TARGETS}" "${CONTAINERS}" "${SOURCES}" "${TMP_DIR}/${name}" <<PY
from pathlib import Path
import json
import sys

targets = Path(sys.argv[1])
containers = Path(sys.argv[2])
sources = Path(sys.argv[3])
destination = Path(sys.argv[4])
${program}
PY
}

if [ ! -f "${REGISTRY}" ]; then
    echo "registry helper is absent: ${REGISTRY}" >&2
    exit 1
fi
test -f "${TARGETS}"
test -f "${CONTAINERS}"

"${PYTHON_BIN}" -I -E - "${TARGETS}" "${ROOT_DIR}/containers/images/targets.schema.json" <<'PY'
from pathlib import Path
import json
import re
import sys

targets = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
schema = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
pattern = schema["properties"]["targets"]["propertyNames"]["pattern"]
expected = "^[a-z0-9][a-z0-9_-]{0,127}$"
if pattern != expected:
    raise SystemExit(f"target schema ID pattern drifted: {pattern}")
if not all(re.fullmatch(pattern, target_id) for target_id in targets["targets"]):
    raise SystemExit("target schema rejects a registered target ID")
PY

resolve nvidia-vlad vlad linux-x86_64-v4 >"${TMP_DIR}/nvidia-x86.json"
resolve nvidia-vlad vlad linux-aarch64-gb300 >"${TMP_DIR}/nvidia-arm.json"
resolve ubuntu-hpcsim hpcsim linux-x86_64-generic >"${TMP_DIR}/ubuntu-x86.json"
resolve nvidia-vlad vlad linux-x86_64-v4 >"${TMP_DIR}/repeat.json"
cmp "${TMP_DIR}/nvidia-x86.json" "${TMP_DIR}/repeat.json"

"${PYTHON_BIN}" -I -E - "${TMP_DIR}" <<'PY'
from pathlib import Path
import json
import sys

directory = Path(sys.argv[1])
expected = {
    "nvidia-x86.json": ("nvidia-vlad", "linux-x86_64-v4", "vlad"),
    "nvidia-arm.json": ("nvidia-vlad", "linux-aarch64-gb300", "vlad"),
    "ubuntu-x86.json": ("ubuntu-hpcsim", "linux-x86_64-generic", "hpcsim"),
}
for name, (container, target, software_set) in expected.items():
    report = json.loads((directory / name).read_text(encoding="utf-8"))
    assert report["container"]["id"] == container
    assert report["target"]["id"] == target
    assert report["software_set"] == software_set
    assert report["container"]["source_lock_category"]
PY

write_fixture unknown-target-field '
document = json.loads(targets.read_text(encoding="utf-8"))
document["unexpected"] = True
destination.write_text(json.dumps(document), encoding="utf-8")
'
expect_failure unknown-target-field resolve nvidia-vlad vlad linux-x86_64-v4 "${TMP_DIR}/unknown-target-field" "${CONTAINERS}" "${SOURCES}"

write_fixture unknown-container-field '
document = json.loads(containers.read_text(encoding="utf-8"))
document["containers"]["nvidia-vlad"]["unexpected"] = True
destination.write_text(json.dumps(document), encoding="utf-8")
'
expect_failure unknown-container-field resolve nvidia-vlad vlad linux-x86_64-v4 "${TARGETS}" "${TMP_DIR}/unknown-container-field" "${SOURCES}"

write_fixture duplicate-target-id '
document = targets.read_text(encoding="utf-8")
document = document.replace("\"targets\": {", "\"targets\": {\n    \"linux-x86_64-v4\": {},\n    \"linux-x86_64-v4\": {},", 1)
destination.write_text(document, encoding="utf-8")
'
expect_failure duplicate-target-id resolve nvidia-vlad vlad linux-x86_64-v4 "${TMP_DIR}/duplicate-target-id" "${CONTAINERS}" "${SOURCES}"

write_fixture duplicate-container-id '
document = containers.read_text(encoding="utf-8")
document = document.replace("\"containers\": {", "\"containers\": {\n    \"nvidia-vlad\": {},\n    \"nvidia-vlad\": {},", 1)
destination.write_text(document, encoding="utf-8")
'
expect_failure duplicate-container-id resolve nvidia-vlad vlad linux-x86_64-v4 "${TARGETS}" "${TMP_DIR}/duplicate-container-id" "${SOURCES}"

write_fixture unknown-target '
document = json.loads(containers.read_text(encoding="utf-8"))
document["containers"]["nvidia-vlad"]["allowed_targets"].append("linux-not-real")
destination.write_text(json.dumps(document), encoding="utf-8")
'
expect_failure unknown-target resolve nvidia-vlad vlad linux-x86_64-v4 "${TARGETS}" "${TMP_DIR}/unknown-target" "${SOURCES}"

write_fixture unknown-source-category '
document = json.loads(containers.read_text(encoding="utf-8"))
document["containers"]["nvidia-vlad"]["source_lock_category"] = "not-a-category"
destination.write_text(json.dumps(document), encoding="utf-8")
'
expect_failure unknown-source-category resolve nvidia-vlad vlad linux-x86_64-v4 "${TARGETS}" "${TMP_DIR}/unknown-source-category" "${SOURCES}"

write_fixture floating-base-identity '
document = json.loads(containers.read_text(encoding="utf-8"))
document["containers"]["ubuntu-hpcsim"]["base_image"] = "ubuntu:latest"
destination.write_text(json.dumps(document), encoding="utf-8")
'
expect_failure floating-base-identity resolve ubuntu-hpcsim hpcsim linux-x86_64-generic "${TARGETS}" "${TMP_DIR}/floating-base-identity" "${SOURCES}"

expect_failure unaccepted-software-set resolve nvidia-vlad hpcsim linux-x86_64-v4

expect_failure all-no-auto-selection "${PYTHON_BIN}" -I -E "${REGISTRY}" resolve \
    --targets "${TARGETS}" \
    --containers "${CONTAINERS}" \
    --sources "${SOURCES}" \
    --software-set all \
    --target linux-x86_64-generic

write_fixture inconsistent-oci-descriptor '
destination.mkdir()
source_document = json.loads(sources.read_text(encoding="utf-8"))
source_document["verified"]["nvidia_hpc_benchmarks_oci"] = {
    "image": "nvcr.io/nvidia/hpc-benchmarks",
    "tag": "26.02",
    "index_digest": "sha256:" + "1" * 64,
    "platforms": {
        "linux-x86_64-generic": {"oci_platform": "linux/amd64", "descriptor_digest": "sha256:" + "2" * 64, "config_digest": "sha256:" + "3" * 64},
        "linux-x86_64-v4": {"oci_platform": "linux/amd64", "descriptor_digest": "sha256:" + "4" * 64, "config_digest": "sha256:" + "3" * 64},
        "linux-aarch64-gb300": {"oci_platform": "linux/arm64", "descriptor_digest": "sha256:" + "5" * 64, "config_digest": "sha256:" + "6" * 64},
    },
    "resolved_on": "2026-08-07",
}
source_document["unresolved"] = [entry for entry in source_document["unresolved"] if entry["category"] != "nvidia_hpc_benchmarks_oci"]
source_document["status"] = "complete"
container_document = json.loads(containers.read_text(encoding="utf-8"))
container_document["containers"]["nvidia-vlad"]["allowed_targets"].insert(0, "linux-x86_64-generic")
(destination / "sources.json").write_text(json.dumps(source_document), encoding="utf-8")
(destination / "containers.json").write_text(json.dumps(container_document), encoding="utf-8")
'
expect_failure inconsistent-oci-descriptor resolve nvidia-vlad vlad linux-x86_64-generic "${TARGETS}" "${TMP_DIR}/inconsistent-oci-descriptor/containers.json" "${TMP_DIR}/inconsistent-oci-descriptor/sources.json"

test "$(shasum -a 256 "${SOURCES}" | awk '{print $1}')" = "$(git -C "${ROOT_DIR}" show HEAD:containers/images/sources-lock.json | shasum -a 256 | awk '{print $1}')"
printf 'registry tests passed\n'
