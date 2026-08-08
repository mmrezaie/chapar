#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chapar-doc-fence-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

extract_fence() {
    awk '
        /^```bash$/ { bash_fences++; if (bash_fences == 1) { capture=1; next } }
        capture && /^```$/ { capture=0; next }
        capture { print }
        END { if (bash_fences != 1) exit 41 }
    ' "$REPO_ROOT/README.md"
}

make_fixture() {
    local fixture_root="$1"
    mkdir -p \
        "$fixture_root/bin" \
        "$fixture_root/repo/cookiecutter/chapar-datacenter/examples" \
        "$fixture_root/repo/envs/software" \
        "$fixture_root/repo/containers/images" \
        "$fixture_root/repo/ci" \
        "$fixture_root/repo/validation"
    printf '%s\n' 'root: /tmp/chapar-example' \
        > "$fixture_root/repo/cookiecutter/chapar-datacenter/examples/example-context.yaml"
    : > "$fixture_root/repo/envs/software/spack.yaml"
    : > "$fixture_root/repo/containers/images/targets.json"
    : > "$fixture_root/repo/containers/images/containers.json"
    : > "$fixture_root/repo/ci/selection-plan.py"
    : > "$fixture_root/repo/ci/cve-checker.py"

    cp "$TEST_ROOT/fence.sh" "$fixture_root/repo/fence.sh"
    chmod +x "$fixture_root/repo/fence.sh"
    apply_fixture_scripts "$fixture_root"
}

apply_fixture_scripts() {
    local fixture_root="$1"
    sed \
        -e "s#@MARKERS@#$fixture_root/markers#g" \
        -e "s#@TEMP_ROOT@#$fixture_root/tmp#g" \
        "$REPO_ROOT/ci/tests/fixtures/documentation-contract-python3.stub" \
        > "$fixture_root/bin/python3"
    sed \
        -e "s#@MARKERS@#$fixture_root/markers#g" \
        "$REPO_ROOT/ci/tests/fixtures/documentation-contract-uv.stub" \
        > "$fixture_root/bin/uv"
    sed \
        -e "s#@MARKERS@#$fixture_root/markers#g" \
        "$REPO_ROOT/ci/tests/fixtures/documentation-contract-bash.stub" \
        > "$fixture_root/bin/bash"
    sed \
        -e "s#@MARKERS@#$fixture_root/markers#g" \
        "$REPO_ROOT/ci/tests/fixtures/documentation-contract-validation.stub" \
        > "$fixture_root/repo/validation/run"
    chmod +x "$fixture_root/bin/python3" "$fixture_root/bin/uv" \
        "$fixture_root/bin/bash" "$fixture_root/repo/validation/run"
    mkdir -p "$fixture_root/tmp" "$fixture_root/markers"
}

assert_cleaned() {
    local fixture_root="$1"
    if find "$fixture_root/tmp" -maxdepth 1 -name 'chapar-offline.*' -print -quit | grep -q .; then
        echo "canonical fence leaked its disposable work root" >&2
        return 1
    fi
}

assert_flag() {
    local marker="$1"
    local flag="$2"
    grep -Fxq -- "$flag" "$marker"
}

extract_fence > "$TEST_ROOT/fence.sh"

failure_root="$TEST_ROOT/failure"
make_fixture "$failure_root"
set +e
(
    cd "$failure_root/repo"
    /usr/bin/env -i PATH="$failure_root/bin:/usr/bin:/bin" DOC_TEST_MODE=fail /bin/bash ./fence.sh
)
failure_status=$?
set -e
test "$failure_status" -eq 37
test -f "$failure_root/markers/render"
for marker in release ci validation cve; do
    test ! -e "$failure_root/markers/$marker"
done
assert_cleaned "$failure_root"

happy_root="$TEST_ROOT/happy"
make_fixture "$happy_root"
(
    cd "$happy_root/repo"
    /usr/bin/env -i PATH="$happy_root/bin:/usr/bin:/bin" DOC_TEST_MODE=happy /bin/bash ./fence.sh
)
for marker in render validate resolve release ci validation cve; do
    test -f "$happy_root/markers/$marker"
done
for flag in --catalog --targets --containers --datacenter --contract \
    --datacenter-id --software-set --target --release-id --run-id --output-dir; do
    assert_flag "$happy_root/markers/resolve" "$flag"
done
for consumer in release ci validation; do
    assert_flag "$happy_root/markers/$consumer" --selection
    assert_flag "$happy_root/markers/$consumer" --selection-digest
done
assert_flag "$happy_root/markers/ci" --contract
assert_flag "$happy_root/markers/cve" --selection
assert_flag "$happy_root/markers/cve" --selection-digest-file
assert_cleaned "$happy_root"

echo "documentation fence failure and cleanup contracts valid"
