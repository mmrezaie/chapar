#!/usr/bin/env bash

# Suite manifests are evidence, not scheduler authority.  A post-job collector
# must consume sacct state, ExitCode, and TRES to create any tier manifest.

validation_result_init() {
    local suite="$1"
    local results_root="$2"
    local node="$3"
    local manual_identity

    validation_verdict_init || return
    case "${suite}" in
        cpu-platform|slurm-placement|node-admission|node-smoke|gpu-topology|nvlink-p2p|ib-link-check|rdma-link-check|rocev2-pairwise|nccl-transport-check|ib-pairwise|mpi-collective|transport|io|storage-burnin|vast) ;;
        *) printf 'suite is not migrated to the result-manifest contract: %s\n' "${suite}" >&2; return 2 ;;
    esac
    VALIDATION_RESULT_MODE="${VALIDATION_RESULT_MODE:-manual}"
    case "${VALIDATION_RESULT_MODE}" in
        runner)
            if [ -z "${VALIDATION_RUN_ID:-}" ] || [ -z "${VALIDATION_RUN_ISSUED_AT:-}" ]; then
                printf 'runner mode requires externally assigned VALIDATION_RUN_ID and VALIDATION_RUN_ISSUED_AT\n' >&2
                return 2
            fi
            VALIDATION_CI_AUTHORITATIVE=true
            ;;
        manual)
            manual_identity="$(python3 - <<'PY'
from datetime import datetime, timezone
from uuid import uuid4
print(f"manual-{uuid4()} {datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')}")
PY
)"
            VALIDATION_RUN_ID="${manual_identity%% *}"
            VALIDATION_RUN_ISSUED_AT="${manual_identity#* }"
            VALIDATION_CI_AUTHORITATIVE=false
            ;;
        *)
            printf 'invalid VALIDATION_RESULT_MODE: %s\n' "${VALIDATION_RESULT_MODE}" >&2
            return 2
            ;;
    esac
    case "${VALIDATION_RUN_ID}" in
        [A-Za-z0-9][A-Za-z0-9._-][A-Za-z0-9._-]*) ;;
        *) printf 'invalid VALIDATION_RUN_ID: %s\n' "${VALIDATION_RUN_ID}" >&2; return 2 ;;
    esac

    if ! python3 - "${VALIDATION_RUN_ISSUED_AT}" "${VALIDATION_MAX_RUN_AGE_SECONDS:-86400}" <<'PY'
from datetime import datetime, timezone
import sys
import time

issued = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
if issued.tzinfo is None:
    raise SystemExit("VALIDATION_RUN_ISSUED_AT must include a timezone")
age_limit = int(sys.argv[2])
age = time.time() - issued.timestamp()
if age > age_limit:
    raise SystemExit("VALIDATION_RUN_ID is stale")
if age < -300:
    raise SystemExit("VALIDATION_RUN_ISSUED_AT is too far in the future")
PY
    then
        return 2
    fi

    VALIDATION_SUITE="${suite}"
    VALIDATION_RESULTS_ROOT="${results_root}"
    VALIDATION_RUN_DIR="${results_root}/${suite}/${VALIDATION_RUN_ID}"
    VALIDATION_NODE_DIR="${VALIDATION_RUN_DIR}/${node}"
    if [ -e "${VALIDATION_RUN_DIR}" ]; then
        printf 'duplicate VALIDATION_RUN_ID for suite %s: %s\n' "${suite}" "${VALIDATION_RUN_ID}" >&2
        return 2
    fi
    mkdir -p "${VALIDATION_NODE_DIR}"
    validation_result_install_trap
}

validation_result_install_trap() {
    trap 'validation_result_finalize "$?"' EXIT
}

validation_result_write_atomic_json() {
    local destination="$1"
    shift
    python3 - "${destination}" "$@" <<'PY'
import json
import os
import sys
import tempfile

destination, payload = sys.argv[1:]
directory = os.path.dirname(destination)
data = json.loads(payload)
fd, temporary = tempfile.mkstemp(prefix=".tmp-", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(data, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, destination)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

validation_result_write_atomic_text() {
    local destination="$1"
    local content="$2"
    local temporary="${destination}.tmp.$$"
    umask 077
    printf '%b' "${content}" > "${temporary}"
    mv -f "${temporary}" "${destination}"
}

validation_result_validate_manifest() {
    local manifest="$1"
    local schema="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/result-manifest.schema.json"
    [ -f "${manifest}" ] || { printf 'missing suite manifest: %s\n' "${manifest}" >&2; return 2; }
    python3 - "${schema}" "${manifest}" <<'PY'
import json
import sys

import jsonschema

with open(sys.argv[1], encoding="utf-8") as stream:
    schema = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    manifest = json.load(stream)
jsonschema.Draft202012Validator(schema, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER).validate(manifest)
PY
}

validation_result_validate_runner_manifest() {
    local manifest="$1"
    validation_result_validate_manifest "${manifest}" || return
    python3 - "${manifest}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    provenance = json.load(stream)["provenance"]
if provenance != {"mode": "runner", "ci_authoritative": True}:
    raise SystemExit("manifest is not runner-authoritative")
PY
}

validation_result_finalize() {
    local command_status="$1"
    local verdict="${VALIDATION_VERDICT:-PASS}"
    local reason="${VALIDATION_VERDICT_REASON:-}"
    local generated_at summary manifest prom

    trap - EXIT
    if [ "${command_status}" -eq 77 ] && [ "${verdict}" = PASS ]; then
        verdict=SKIP
        reason="suite exited 77"
    elif [ "${command_status}" -ne 0 ] && [ "${verdict}" != FAIL ] && [ "${verdict}" != SKIP ]; then
        verdict=FAIL
        reason="suite command exited ${command_status}"
    fi
    generated_at="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
PY
)"
    summary="${VALIDATION_RUN_DIR}/summary.json"
    prom="${VALIDATION_RUN_DIR}/suite.prom"
    manifest="${VALIDATION_RUN_DIR}/suite-manifest.json"

    validation_result_write_atomic_json "${summary}" "$(python3 - "${VALIDATION_SUITE}" "${VALIDATION_RUN_ID}" "${VALIDATION_RESULT_MODE}" "${VALIDATION_CI_AUTHORITATIVE}" "${verdict}" "${reason}" "${VALIDATION_UNAVAILABLE_POLICY}" "${VALIDATION_THRESHOLD_POLICY}" "${command_status}" <<'PY'
import json
import sys
print(json.dumps({
    "suite": sys.argv[1], "run_id": sys.argv[2],
    "provenance": {"mode": sys.argv[3], "ci_authoritative": sys.argv[4] == "true"},
    "verdict": sys.argv[5], "reason": sys.argv[6],
    "policies": {"unavailable": sys.argv[7], "threshold": sys.argv[8]},
    "command_exit_code": int(sys.argv[9]),
}))
PY
)"
    validation_result_write_atomic_text "${prom}" "# HELP chapar_validation_suite_verdict Suite verdict (PASS=0 WARN=1 FAIL=2 SKIP=3)\n# TYPE chapar_validation_suite_verdict gauge\nchapar_validation_suite_verdict{suite=\"${VALIDATION_SUITE}\",run_id=\"${VALIDATION_RUN_ID}\",verdict=\"${verdict}\"} $(case "${verdict}" in PASS) echo 0;; WARN) echo 1;; FAIL) echo 2;; SKIP) echo 3;; esac)\n"
    validation_result_write_atomic_json "${manifest}" "$(python3 - "${VALIDATION_SUITE}" "${VALIDATION_RUN_ID}" "${VALIDATION_RUN_ISSUED_AT}" "${generated_at}" "${VALIDATION_RESULT_MODE}" "${VALIDATION_CI_AUTHORITATIVE}" "${verdict}" "${reason}" "${VALIDATION_UNAVAILABLE_POLICY}" "${VALIDATION_THRESHOLD_POLICY}" <<'PY'
import json
import sys
payload = {
    "schema_version": "1.0", "kind": "suite", "suite": sys.argv[1],
    "run_id": sys.argv[2], "run_issued_at": sys.argv[3], "generated_at": sys.argv[4],
    "provenance": {"mode": sys.argv[5], "ci_authoritative": sys.argv[6] == "true"},
    "verdict": sys.argv[7], "policies": {"unavailable": sys.argv[9], "threshold": sys.argv[10]},
    "artifacts": {"summary": "summary.json", "prometheus": "suite.prom"},
}
if sys.argv[8]:
    payload["reason"] = sys.argv[8]
print(json.dumps(payload))
PY
)"
    validation_result_validate_manifest "${manifest}" || exit 2
    case "${verdict}" in
        PASS|WARN) exit 0 ;;
        SKIP) exit 77 ;;
        FAIL) exit 1 ;;
    esac
}
