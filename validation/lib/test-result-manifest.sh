#!/usr/bin/env bash
set -euo pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures="${lib_dir}/fixtures/result-manifest"
source "${lib_dir}/verdict.sh"
source "${lib_dir}/result-manifest.sh"

expect_valid() {
    validation_result_validate_manifest "$1"
}

expect_runner_valid() {
    validation_result_validate_runner_manifest "$1"
}

expect_invalid() {
    if validation_result_validate_manifest "$1"; then
        printf 'unexpectedly accepted: %s\n' "$1" >&2
        return 1
    fi
}

expect_invalid "${fixtures}/legacy-node-smoke-summary.json"
expect_runner_valid "${fixtures}/pass.json"
expect_valid "${fixtures}/warn.json"
expect_valid "${fixtures}/threshold-fail.json"
expect_valid "${fixtures}/optional-skip.json"
expect_valid "${fixtures}/mandatory-unavailable.json"
expect_invalid "${fixtures}/unknown-schema.json"
expect_invalid "${fixtures}/missing-manifest.json"
expect_valid "${fixtures}/manual.json"
expect_invalid_runner() {
    if validation_result_validate_runner_manifest "$1"; then
        printf 'unexpectedly accepted as runner evidence: %s\n' "$1" >&2
        return 1
    fi
}
expect_invalid_runner "${fixtures}/manual.json"

temporary="$(mktemp -d)"
cleanup() { rm -rf "${temporary}"; }
trap cleanup EXIT

VALIDATION_RESULT_MODE=runner
VALIDATION_RUN_ID="fixture-stale-001"
VALIDATION_RUN_ISSUED_AT="$(python3 - "${fixtures}/stale-run-id.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["run_issued_at"])
PY
)"
if validation_result_init transport "${temporary}" node01; then
    printf 'stale run ID was unexpectedly accepted\n' >&2
    exit 1
fi

unset VALIDATION_RUN_ID VALIDATION_RUN_ISSUED_AT
if validation_result_init node-smoke "${temporary}" node01; then
    printf 'missing run ID was unexpectedly accepted\n' >&2
    exit 1
fi

(
    VALIDATION_RESULT_MODE=runner
    VALIDATION_RUN_ID="fixture-duplicate-001"
    VALIDATION_RUN_ISSUED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    validation_result_init node-admission "${temporary}" node01
    trap - EXIT
    if validation_result_init node-smoke "${temporary}" node01; then
        printf 'duplicate run ID was unexpectedly accepted\n' >&2
        exit 1
    fi
)

(
    VALIDATION_RESULT_MODE=manual
    unset VALIDATION_RUN_ID VALIDATION_RUN_ISSUED_AT
    validation_result_init node-smoke "${temporary}" node01
    case "${VALIDATION_RUN_ID}" in manual-*) ;; *) exit 1 ;; esac
    [ "${VALIDATION_CI_AUTHORITATIVE}" = false ]
    trap - EXIT
)

printf 'result manifest contract: runner evidence is strict; manual initialization is non-authoritative\n'
