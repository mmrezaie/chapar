#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chapar-submit-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

FIXTURE_ROOT="${TMP_ROOT}/chapar"
SELECTION="${TMP_ROOT}/selection.json"
MARKER="${TMP_ROOT}/sbatch-called"
mkdir -p "${FIXTURE_ROOT}/ci" "${FIXTURE_ROOT}/datacenters/example-lab/targets/linux-x86_64-v4" \
    "${FIXTURE_ROOT}/envs/software" "${FIXTURE_ROOT}/containers/images" "${TMP_ROOT}/bin"
test -x "${ROOT}/ci/submit-env-build.sh"
test -x "${ROOT}/ci/sbatch-env-build.sh"
test -x "${ROOT}/ci/selection-plan.py"
cp "${ROOT}/ci/submit-env-build.sh" "${ROOT}/ci/sbatch-env-build.sh" "${ROOT}/ci/selection-plan.py" "${FIXTURE_ROOT}/ci/"
cp "${ROOT}/envs/software/spack.yaml" "${FIXTURE_ROOT}/envs/software/spack.yaml"
cp "${ROOT}/containers/images/targets.json" "${ROOT}/containers/images/containers.json" "${FIXTURE_ROOT}/containers/images/"
cp "${ROOT}/Makefile" "${FIXTURE_ROOT}/"
test -x "${FIXTURE_ROOT}/ci/submit-env-build.sh"
test -x "${FIXTURE_ROOT}/ci/sbatch-env-build.sh"
test -x "${FIXTURE_ROOT}/ci/selection-plan.py"
printf '%s\n' '#!/usr/bin/env bash' "printf 'called\\n' > '${MARKER}'" > "${TMP_ROOT}/bin/sbatch"
chmod +x "${TMP_ROOT}/bin/sbatch"

python3 - "${FIXTURE_ROOT}" "${SELECTION}" <<'PY'
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
selection = Path(sys.argv[2])
contract = root / "datacenters/example-lab/targets/linux-x86_64-v4/contract.json"
contract_data = {
    "datacenter_id": "example-lab",
    "target": "linux-x86_64-v4",
    "slurm": {"partition": "fixture-build", "constraint": "fixture-v4", "account": "fixture-account", "qos": "fixture-qos"},
    "publication": {"publish_buildcache": False, "publish_modules": False, "publish_containers": False, "promote_current": False},
    "paths": {
        "durable_writable": {
            "releases": "/tmp/chapar-fixture/releases", "modulefiles": "/tmp/chapar-fixture/modules",
            "install_tree": "/tmp/chapar-fixture/install", "writable_buildcache": "/tmp/chapar-fixture/buildcache",
            "ccache": "/tmp/chapar-fixture/ccache", "container_outputs": "/tmp/chapar-fixture/containers",
            "receipts": "/tmp/chapar-fixture/receipts", "evidence": "/tmp/chapar-fixture/evidence",
        },
        "temporary": {
            "release_staging": "/tmp/chapar-fixture/releases/.staging", "spack_build_stage": "/tmp/chapar-fixture/work/spack",
            "image_staging": "/tmp/chapar-fixture/work/images", "validation_work": "/tmp/chapar-fixture/work/validation",
            "resolver_work": "/tmp/chapar-fixture/work/resolver",
        },
    },
    "sharing": {"share_across_software_sets": False, "share_across_targets": False},
}
contract.write_text(json.dumps(contract_data, sort_keys=True) + "\n", encoding="utf-8")
contract_digest = hashlib.sha256(contract.read_bytes()).hexdigest()
datacenter = root / "datacenters/example-lab/datacenter.json"
datacenter.write_text(json.dumps({"datacenter_id": "example-lab", "targets": ["linux-x86_64-v4"]}, sort_keys=True) + "\n")
manifest = selection.parent / "spack.yaml"
policy_file = selection.parent / "target-policy.yaml"
manifest.write_text("spack:\n  specs: []\n")
policy_file.write_text("target: linux-x86_64-v4\n")
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
selection_data = {
    "schema": "https://nscaledev.github.io/chapar/schemas/software-selection/v1", "schema_version": 1,
    "policy": {"datacenter": "example-lab", "software_set": "vlad", "target": "linux-x86_64-v4"},
    "invocation": {"release_id": "release-fixture", "run_id": "run-fixture"},
    "paths": {
        "release_root": "/tmp/chapar-fixture/releases/example-lab/vlad/linux-x86_64-v4",
        "release_final": "/tmp/chapar-fixture/releases/example-lab/vlad/linux-x86_64-v4/release-fixture",
        "release_staging": "/tmp/chapar-fixture/releases/.staging/example-lab/vlad/linux-x86_64-v4/release-fixture.run-fixture",
        "modulefiles": "/tmp/chapar-fixture/modules/example-lab/vlad/linux-x86_64-v4/release-fixture",
        "install_tree": "/tmp/chapar-fixture/install/example-lab/vlad/linux-x86_64-v4",
        "writable_buildcache": "/tmp/chapar-fixture/buildcache/example-lab/vlad/linux-x86_64-v4",
        "ccache": "/tmp/chapar-fixture/ccache/example-lab/vlad/linux-x86_64-v4",
        "container_outputs": "/tmp/chapar-fixture/containers/example-lab/vlad/linux-x86_64-v4/release-fixture",
        "receipts": "/tmp/chapar-fixture/receipts/example-lab/vlad/linux-x86_64-v4/release-fixture",
        "evidence": "/tmp/chapar-fixture/evidence/example-lab/vlad/linux-x86_64-v4/run-fixture",
        "spack_build_stage": "/tmp/chapar-fixture/work/spack/example-lab/vlad/linux-x86_64-v4/run-fixture",
        "image_staging": "/tmp/chapar-fixture/work/images/example-lab/vlad/linux-x86_64-v4/run-fixture",
        "validation_work": "/tmp/chapar-fixture/work/validation/example-lab/vlad/linux-x86_64-v4/run-fixture",
        "resolver_work": "/tmp/chapar-fixture/work/resolver/example-lab/vlad/linux-x86_64-v4/run-fixture",
    },
    "containers": ["nvidia-vlad"],
    "authorities": {
        "software_catalog": sha(root / "envs/software/spack.yaml"),
        "target_registry": sha(root / "containers/images/targets.json"),
        "container_registry": sha(root / "containers/images/containers.json"),
        "datacenter_contract": sha(datacenter), "target_contract": contract_digest,
    },
    "artifacts": {"effective_manifest_sha256": sha(manifest), "target_policy_sha256": sha(policy_file)},
}
selection.write_text(json.dumps(selection_data, sort_keys=True) + "\n", encoding="utf-8")
PY

DIGEST="$(shasum -a 256 "${SELECTION}" | awk '{print $1}')"
BASE=(
    --datacenter example-lab
    --software-set vlad
    --target linux-x86_64-v4
    --release-id release-fixture
    --run-id run-fixture
    --selection "${SELECTION}"
    --selection-digest "${DIGEST}"
)

run_submit() {
    PATH="${TMP_ROOT}/bin:${PATH}" \
    CHAPAR_ROOT="${FIXTURE_ROOT}" \
    ENV_PATH=/poisoned ENV_NAME=poisoned CHAPAR_ENV_ROOT=/poisoned PUBLISH_CURRENT=true \
    bash "${FIXTURE_ROOT}/ci/submit-env-build.sh" "$@"
}

require_failure() {
    local name="$1"
    shift
    if run_submit "$@" >"${TMP_ROOT}/${name}.out" 2>"${TMP_ROOT}/${name}.err"; then
        printf 'expected failure: %s\n' "${name}" >&2
        exit 1
    fi
    grep -qi 'migration\|required\|digest\|contract\|duplicate\|selection' "${TMP_ROOT}/${name}.err"
    test ! -e "${MARKER}"
}

require_failure old-env --env-name hpcsim
require_failure old-path "${BASE[@]}" --env-path /poisoned
require_failure old-partition "${BASE[@]}" --partition poisoned
require_failure missing-datacenter --software-set vlad --target linux-x86_64-v4 --release-id release-fixture --run-id run-fixture --selection "${SELECTION}" --selection-digest "${DIGEST}"
require_failure missing-software-set --datacenter example-lab --target linux-x86_64-v4 --release-id release-fixture --run-id run-fixture --selection "${SELECTION}" --selection-digest "${DIGEST}"
require_failure missing-target --datacenter example-lab --software-set vlad --release-id release-fixture --run-id run-fixture --selection "${SELECTION}" --selection-digest "${DIGEST}"
require_failure missing-release --datacenter example-lab --software-set vlad --target linux-x86_64-v4 --run-id run-fixture --selection "${SELECTION}" --selection-digest "${DIGEST}"
require_failure missing-run --datacenter example-lab --software-set vlad --target linux-x86_64-v4 --release-id release-fixture --selection "${SELECTION}" --selection-digest "${DIGEST}"
require_failure missing-selection --datacenter example-lab --software-set vlad --target linux-x86_64-v4 --release-id release-fixture --run-id run-fixture --selection-digest "${DIGEST}"
require_failure missing-digest --datacenter example-lab --software-set vlad --target linux-x86_64-v4 --release-id release-fixture --run-id run-fixture --selection "${SELECTION}"
require_failure duplicate-datacenter "${BASE[@]}" --datacenter other-lab
require_failure duplicate-software-set "${BASE[@]}" --software-set hpcsim
require_failure duplicate-target "${BASE[@]}" --target linux-x86_64-generic
require_failure duplicate-release "${BASE[@]}" --release-id other-release
require_failure duplicate-run "${BASE[@]}" --run-id another-run
require_failure duplicate-selection "${BASE[@]}" --selection "${SELECTION}"
require_failure duplicate-digest "${BASE[@]}" --selection-digest "${DIGEST}"
require_failure red-wrong-digest "${BASE[@]}" --selection-digest "${DIGEST%?}0"
require_failure unknown-target "${BASE[@]}" --target linux-unknown

run_submit "${BASE[@]}" --dry-run >"${TMP_ROOT}/valid.out"
grep -F 'canonical tuple: example-lab/vlad/linux-x86_64-v4' "${TMP_ROOT}/valid.out"
grep -F 'partition: fixture-build' "${TMP_ROOT}/valid.out"
grep -F 'constraint: fixture-v4' "${TMP_ROOT}/valid.out"
grep -F 'containers: nvidia-vlad' "${TMP_ROOT}/valid.out"
grep -F 'canonical selection:' "${TMP_ROOT}/valid.out"
grep -F '/selection.json' "${TMP_ROOT}/valid.out"
grep -F "selection digest: ${DIGEST}" "${TMP_ROOT}/valid.out"
grep -F '/tmp/chapar-fixture/releases/example-lab/vlad/linux-x86_64-v4/release-fixture' "${TMP_ROOT}/valid.out"
test ! -e "${MARKER}"
test ! -e "${FIXTURE_ROOT}/slogs"

PATH="${TMP_ROOT}/bin:${PATH}" make -C "${FIXTURE_ROOT}" submit \
    DATACENTER=example-lab SOFTWARE_SET=vlad TARGET=linux-x86_64-v4 \
    RELEASE_ID=release-fixture RUN_ID=run-fixture SELECTION="${SELECTION}" \
    SELECTION_DIGEST="${DIGEST}" DRY_RUN=true >"${TMP_ROOT}/make-valid.out"
grep -F 'canonical tuple: example-lab/vlad/linux-x86_64-v4' "${TMP_ROOT}/make-valid.out"
grep -F 'canonical selection:' "${TMP_ROOT}/make-valid.out"
grep -F '/selection.json' "${TMP_ROOT}/make-valid.out"
grep -F "selection digest: ${DIGEST}" "${TMP_ROOT}/make-valid.out"
test ! -e "${MARKER}"

printf '%s\n' '{"tampered":true}' > "${FIXTURE_ROOT}/datacenters/example-lab/targets/linux-x86_64-v4/contract.json"
require_failure stale-contract "${BASE[@]}" --dry-run

LOCK_HASH_BEFORE="$(shasum -a 256 "${ROOT}/envs/hpcsim/spack.lock" | awk '{print $1}')"
if make -C "${ROOT}" clean-locks ENV=hpcsim >"${TMP_ROOT}/clean-locks.out" 2>"${TMP_ROOT}/clean-locks.err"; then
    printf 'clean-locks unexpectedly succeeded\n' >&2
    exit 1
fi
LOCK_HASH_AFTER="$(shasum -a 256 "${ROOT}/envs/hpcsim/spack.lock" | awk '{print $1}')"
test "${LOCK_HASH_BEFORE}" = "${LOCK_HASH_AFTER}"
test ! -e "${MARKER}"

printf 'PASS: submit-env-build contract-bound dry-run and adversarial cases\n'
