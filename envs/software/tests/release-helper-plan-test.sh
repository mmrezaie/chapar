#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FIXTURES="${SCRIPT_DIR}/fixtures"
TMP_ROOT="$(mktemp -d /private/tmp/chapar-task6-test.XXXXXX)"
FIXTURE_ROOT="${TMP_ROOT}/repo"
HELPER="${FIXTURE_ROOT}/envs/software/release.sh"
SELECTION="${TMP_ROOT}/selection/selection.json"
CONTRACT="${FIXTURE_ROOT}/datacenters/fixture-dc/targets/linux-x86_64-v4/contract.json"
trap 'rm -rf -- "${TMP_ROOT}" /private/tmp/chapar-task6' EXIT
mkdir -p "$(dirname "${HELPER}")" "$(dirname "${CONTRACT}")" \
    "${FIXTURE_ROOT}/containers/images" "${FIXTURE_ROOT}/etc" "$(dirname "${SELECTION}")"
cp "${SOURCE_ROOT}/envs/software/release.sh" "${HELPER}"
# release.sh shares install-tree padding with etc/chapar-selection.sh so the two
# cannot emit different install_tree shapes for the same store.
cp "${SOURCE_ROOT}/etc/chapar-install-tree.sh" "${FIXTURE_ROOT}/etc/"
cp "${SOURCE_ROOT}/envs/software/spack.yaml" "${FIXTURE_ROOT}/envs/software/spack.yaml"
cp "${SOURCE_ROOT}/containers/images/targets.json" \
    "${SOURCE_ROOT}/containers/images/containers.json" "${FIXTURE_ROOT}/containers/images/"
cp "${FIXTURES}/release-plan-selection.json" "${SELECTION}"
cp "${FIXTURES}/spack.yaml" "$(dirname "${SELECTION}")/spack.yaml"
cp "${FIXTURES}/target-policy.yaml" "$(dirname "${SELECTION}")/target-policy.yaml"
python3 - "${FIXTURE_ROOT}" "${SELECTION}" "${CONTRACT}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root, selection_path, contract_path = map(Path, sys.argv[1:])
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
contract = {
    "datacenter_id": "fixture-dc", "target": "linux-x86_64-v4",
    "paths": {
        "durable_writable": {
            "releases": "/private/tmp/chapar-task6/releases", "modulefiles": "/private/tmp/chapar-task6/modules",
            "install_tree": "/private/tmp/chapar-task6/install", "writable_buildcache": "/private/tmp/chapar-task6/buildcache",
            "ccache": "/private/tmp/chapar-task6/ccache", "container_outputs": "/private/tmp/chapar-task6/containers",
            "receipts": "/private/tmp/chapar-task6/receipts", "evidence": "/private/tmp/chapar-task6/evidence",
        },
        "temporary": {
            "release_staging": "/private/tmp/chapar-task6/releases/.staging",
            "spack_build_stage": "/private/tmp/chapar-task6/work/spack-stage",
            "image_staging": "/private/tmp/chapar-task6/work/image-stage",
            "validation_work": "/private/tmp/chapar-task6/work/validation",
            "resolver_work": "/private/tmp/chapar-task6/work/resolver",
        },
    },
    "sharing": {"share_across_software_sets": False, "share_across_targets": False},
    "publication": {"publish_buildcache": True, "publish_modules": True, "publish_containers": False, "promote_current": True},
}
contract_path.write_text(json.dumps(contract, sort_keys=True) + "\n")
datacenter = contract_path.parents[2] / "datacenter.json"
datacenter.write_text(json.dumps({"datacenter_id": "fixture-dc", "targets": ["linux-x86_64-v4"]}, sort_keys=True) + "\n")
selection = json.loads(selection_path.read_bytes())
selection["authorities"] = {
    "software_catalog": sha(root / "envs/software/spack.yaml"),
    "target_registry": sha(root / "containers/images/targets.json"),
    "container_registry": sha(root / "containers/images/containers.json"),
    "datacenter_contract": sha(datacenter), "target_contract": sha(contract_path),
}
selection["artifacts"] = {
    "effective_manifest_sha256": sha(selection_path.parent / "spack.yaml"),
    "target_policy_sha256": sha(selection_path.parent / "target-policy.yaml"),
}
selection_path.write_text(json.dumps(selection, indent=2, sort_keys=True) + "\n")
PY
EXPECTED="$(shasum -a 256 "${SELECTION}" | awk '{print $1}')"

output="$(bash "${HELPER}" plan --selection "${SELECTION}" --selection-digest "${EXPECTED}")"
grep -q '^operation: build$' <<<"${output}"
grep -q '^identity: fixture-dc/vlad/linux-x86_64-v4/release-6/run-6$' <<<"${output}"
grep -q '^release_staging: /private/tmp/chapar-task6/releases/.staging/fixture-dc/vlad/linux-x86_64-v4/release-6.run-6$' <<<"${output}"
grep -q '^release_final: /private/tmp/chapar-task6/releases/fixture-dc/vlad/linux-x86_64-v4/release-6$' <<<"${output}"
grep -q '^modulefiles: /private/tmp/chapar-task6/modules/fixture-dc/vlad/linux-x86_64-v4/release-6$' <<<"${output}"
grep -q '^writable_buildcache: /private/tmp/chapar-task6/buildcache/fixture-dc/vlad/linux-x86_64-v4$' <<<"${output}"
grep -q '^spack_environment: /private/tmp/chapar-task6/releases/.staging/fixture-dc/vlad/linux-x86_64-v4/release-6.run-6$' <<<"${output}"
grep -q '^checkout_lock: forbidden$' <<<"${output}"
# ccache is bootstrapped with the OS external compiler before the staged roots,
# so it can accelerate the gcc build rather than depend on the OS shipping it.
grep -q '^bootstrap_specs: ccache$' <<<"${output}"
grep -q '^staged_roots: gcc$' <<<"${output}"
grep -q '^ccache_dir: /private/tmp/chapar-task6/ccache/fixture-dc/vlad/linux-x86_64-v4$' <<<"${output}"
grep -q '^publish_buildcache: true$' <<<"${output}"
grep -q '^buildcache_signed: false$' <<<"${output}"
grep -q '^buildcache_autopush: true$' <<<"${output}"

repeat="$(bash "${HELPER}" plan --selection "${SELECTION}" --selection-digest "${EXPECTED}")"
[ "${output}" = "${repeat}" ]

cp "${CONTRACT}" "${CONTRACT}.true"
cp "${SELECTION}" "${SELECTION}.true"
python3 - "${CONTRACT}" "${SELECTION}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
contract_path, selection_path = map(Path, sys.argv[1:])
contract = json.loads(contract_path.read_bytes())
contract["publication"] = {"publish_buildcache": False, "publish_modules": False, "publish_containers": False, "promote_current": False}
contract_path.write_text(json.dumps(contract, sort_keys=True) + "\n")
selection = json.loads(selection_path.read_bytes())
selection["authorities"]["target_contract"] = hashlib.sha256(contract_path.read_bytes()).hexdigest()
selection_path.write_text(json.dumps(selection, indent=2, sort_keys=True) + "\n")
PY
false_digest="$(shasum -a 256 "${SELECTION}" | awk '{print $1}')"
false_plan="$(bash "${HELPER}" plan --selection "${SELECTION}" --selection-digest "${false_digest}")"
grep -q '^publish_buildcache: false$' <<<"${false_plan}"
grep -q '^publish_modules: false$' <<<"${false_plan}"
grep -q '^promote_current: false$' <<<"${false_plan}"
mv "${CONTRACT}.true" "${CONTRACT}"
mv "${SELECTION}.true" "${SELECTION}"

expect_failure() {
    local label="$1"
    shift
    local stderr_file
    stderr_file="$(mktemp)"
    if "$@" >"${stderr_file}.stdout" 2>"${stderr_file}"; then
        echo "expected failure: ${label}" >&2
        return 1
    fi
    [ ! -s "${stderr_file}.stdout" ]
    grep -q '^ERROR:' "${stderr_file}"
    rm -f -- "${stderr_file}" "${stderr_file}.stdout"
}

expect_failure missing-digest bash "${HELPER}" plan --selection "${SELECTION}"
expect_failure wrong-digest bash "${HELPER}" plan --selection "${SELECTION}" --expected-selection-sha256 "${EXPECTED%?}0"
expect_failure poison-path env CHAPAR_INSTALL_TREE_ROOT=/tmp/poison bash "${HELPER}" plan --selection "${SELECTION}" --expected-selection-sha256 "${EXPECTED}"
expect_failure checkout-lock bash "${HELPER}" plan --selection "${SELECTION}" --expected-selection-sha256 "${EXPECTED}" --lock envs/hpcsim/spack.lock

make_case() {
    local name="$1"
    local mutation="$2"
    local destination="${TMP_ROOT}/${name}"
    mkdir -p "${destination}"
    cp "${FIXTURES}/spack.yaml" "${destination}/spack.yaml"
    cp "${FIXTURES}/target-policy.yaml" "${destination}/target-policy.yaml"
    python3 - "${SELECTION}" "${destination}/selection.json" "${mutation}" "${destination}/roots" <<'PY'
import json
import sys
from pathlib import Path
source, destination, mutation, root = sys.argv[1:]
document = json.loads(Path(source).read_bytes())
if mutation == "staging-mismatch":
    document["paths"]["release_staging"] = f"{root}/foreign/release-6.run-6"
elif mutation == "protected":
    document["paths"]["release_final"] = "/resources/chapar/vlad/release-6"
elif mutation == "seed-autopush":
    document["paths"]["seed_mirror"] = f"{root}/seed"
Path(destination).write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
    printf '%s\n' "${destination}/selection.json"
}

case_digest() {
    shasum -a 256 "$1" | awk '{print $1}'
}

case_selection="$(make_case staging staging-mismatch)"
expect_failure staging-mismatch bash "${HELPER}" plan --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"
case_selection="$(make_case protected protected)"
expect_failure protected-path bash "${HELPER}" plan --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"
case_selection="$(make_case seed seed-autopush)"
expect_failure seed-autopush bash "${HELPER}" plan --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"

case_selection="$(make_case duplicate duplicate)"
duplicate_final="/private/tmp/chapar-task6/releases/fixture-dc/vlad/linux-x86_64-v4/release-6"
mkdir -p "${duplicate_final}"
expect_failure duplicate-release bash "${HELPER}" plan --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"
rm -rf -- "${duplicate_final}"

case_selection="$(make_case stale-staging stale-staging)"
stale_staging="/private/tmp/chapar-task6/releases/.staging/fixture-dc/vlad/linux-x86_64-v4/release-6.run-6"
mkdir -p "${stale_staging}"
expect_failure stale-staging bash "${HELPER}" plan --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"
rm -rf -- "${stale_staging}"

case_selection="$(make_case promote promote-missing-lock)"
expect_failure promote-without-lock bash "${HELPER}" plan --operation promote --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"

case_selection="$(make_case stale stale-metadata)"
stale_final="/private/tmp/chapar-task6/releases/fixture-dc/vlad/linux-x86_64-v4/release-6"
mkdir -p "${stale_final}"
printf '{}\n' >"${stale_final}/spack.lock"
printf '{partial\n' >"${stale_final}/metadata.json"
expect_failure stale-metadata bash "${HELPER}" plan --operation promote --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"
rm -rf -- "${stale_final}"

case_selection="$(make_case valid valid-release)"
python3 - "${case_selection}" "${FIXTURES}/spack.yaml" "${FIXTURES}/target-policy.yaml" <<'PY'
import hashlib
import json
import shutil
import sys
from pathlib import Path
selection_path, manifest_path, policy_path = map(Path, sys.argv[1:])
selection = json.loads(selection_path.read_bytes())
final = Path(selection["paths"]["release_final"])
final.mkdir(parents=True)
shutil.copyfile(selection_path, final / "selection.json")
shutil.copyfile(manifest_path, final / "spack.yaml")
shutil.copyfile(policy_path, final / "target-policy.yaml")
(final / "spack.lock").write_text('{"roots": []}\n')
file_digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
identity = {**selection["policy"], **selection["invocation"]}
root_names = ("release_root", "release_final", "release_staging", "modulefiles", "install_tree", "writable_buildcache", "ccache", "spack_build_stage")
digests = {f"{name}_sha256": value for name, value in selection["authorities"].items()}
digests.update({
    "selection_sha256": file_digest(final / "selection.json"),
    "effective_manifest_sha256": file_digest(final / "spack.yaml"),
    "target_policy_sha256": file_digest(final / "target-policy.yaml"),
    "release_local_lock_sha256": file_digest(final / "spack.lock"),
})
metadata = {
    "schema": "https://nscaledev.github.io/chapar/schemas/release-metadata/v1",
    "schema_version": 1,
    "identity": identity,
    "roots": {name: selection["paths"][name] for name in root_names},
    "digests": digests,
    "policy": {"publish_buildcache": True, "buildcache_signed": False, "buildcache_autopush": True},
}
(final / "metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
PY
valid_output="$(bash "${HELPER}" plan --operation promote --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")")"
grep -q '^operation: promote$' <<<"${valid_output}"
valid_metadata="/private/tmp/chapar-task6/releases/fixture-dc/vlad/linux-x86_64-v4/release-6/metadata.json"
cp "${valid_metadata}" "${valid_metadata}.saved"
python3 - "${valid_metadata}" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
document = json.loads(path.read_bytes())
document["schema"] = "https://example.invalid/release-metadata/v2"
document["schema_version"] = 2
document["unexpected"] = True
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
expect_failure invalid-metadata-contract bash "${HELPER}" plan --operation promote --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"
mv "${valid_metadata}.saved" "${valid_metadata}"
cp "${valid_metadata}" "${valid_metadata}.clean"
for metadata_case in missing-top unknown-nested missing-nested type-mismatch invalid-digest; do
    cp "${valid_metadata}.clean" "${valid_metadata}"
    python3 - "${valid_metadata}" "${metadata_case}" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
mode = sys.argv[2]
document = json.loads(path.read_bytes())
if mode == "missing-top":
    document.pop("policy")
elif mode == "unknown-nested":
    document["identity"]["unexpected"] = "value"
elif mode == "missing-nested":
    document["roots"].pop("ccache")
elif mode == "type-mismatch":
    document["policy"]["publish_buildcache"] = "true"
elif mode == "invalid-digest":
    document["digests"]["selection_sha256"] = "not-a-digest"
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY
    expect_failure "metadata-${metadata_case}" bash "${HELPER}" plan --operation promote --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"
done
mv "${valid_metadata}.clean" "${valid_metadata}"
printf 'tampered\n' >>"/private/tmp/chapar-task6/releases/fixture-dc/vlad/linux-x86_64-v4/release-6/spack.yaml"
expect_failure release-byte-tamper bash "${HELPER}" plan --operation promote --selection "${case_selection}" --selection-digest "$(case_digest "${case_selection}")"
rm -rf -- /private/tmp/chapar-task6

ln -s "${SELECTION}" "${TMP_ROOT}/selection-link.json"
expect_failure selection-symlink bash "${HELPER}" plan --selection "${TMP_ROOT}/selection-link.json" --selection-digest "${EXPECTED}"

mkdir -p "${TMP_ROOT}/bin"
printf '#!/usr/bin/env bash\nprintf called >%q\n' "${TMP_ROOT}/spack-called" >"${TMP_ROOT}/bin/spack"
chmod +x "${TMP_ROOT}/bin/spack"
PATH="${TMP_ROOT}/bin:${PATH}" bash "${HELPER}" plan --selection "${SELECTION}" --selection-digest "${EXPECTED}" >/dev/null
[ ! -e "${TMP_ROOT}/spack-called" ]
[ ! -e /private/tmp/chapar-task6 ]
grep -q 'trap cleanup_build EXIT' "${HELPER}"
grep -q "trap 'exit 130' INT" "${HELPER}"
grep -Fq 'spack -e ' "${HELPER}"
grep -Fq 'RELEASE_STAGING' "${HELPER}"
if grep -Eq 'envs/[^ ]+/spack\.lock' "${HELPER}"; then
    echo "checkout lock reference found" >&2
    exit 1
fi

echo "release helper plan test passed"
