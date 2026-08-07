#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from ci.direct_install_audit.audit import (
    audit_documents,
    audit_repository,
    parse_cli,
    parse_file_list,
)
from ci.direct_install_audit.model import AUDIT_PATH, AuditInputError
from ci.direct_install_audit.shell import direct_install_segment

SELF_TEST_FIXTURES: dict[str, str] = {
    "prerequisite": 'spack -C "${scope_dir}" install "$@" "${spec}"',
    "cuda-dependencies": 'spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" install --only-concrete "${install_args_ref[@]}" --only dependencies "${spec_hash}"',
    "cuda-package": 'spack -e "${ENV_PATH}" -C "${BUILD_SCOPE_DIR}" install --only-concrete --dirty "${install_args_ref[@]}" --only package "${spec_hash}"',
    "environment": 'spack -e "${ENV_PATH}" -C "${scope_dir}" install --only-concrete "${install_args[@]}"',
    "staged-environment": 'spack -e "${RELEASE_STAGING}" -C "${BUILD_SCOPE_DIR}" install --only-concrete',
    "policy-never": "NEVER run `spack install example` directly.",
    "policy-do-not": "Do NOT run `spack install example` directly.",
    "policy-forbidden": "A direct `spack install example` is forbidden.",
    "policy-must-not": "Operators must not run `spack install example` directly.",
    "rogue": "spack install rogue-package",
}

def synthetic_python(mapping_name: str, annotation: str, expression: str, *, nested: bool = False) -> str:
    assignment = f"{mapping_name}: {annotation} = {{'case': {expression}}}\n"
    return f"def holder():\n    {assignment}" if nested else assignment


def run_self_test() -> int:
    internal_path = PurePosixPath("envs/software/release.sh")
    accepted_cases: tuple[tuple[str, PurePosixPath, str], ...] = (
        ("internal-prerequisite", internal_path, f"install_release_prerequisite() {{\n  {SELF_TEST_FIXTURES['prerequisite']}\n}}\n"),
        ("internal-software-path", PurePosixPath("envs/software/release.sh"), f"install_release_prerequisite() {{\n  {SELF_TEST_FIXTURES['prerequisite']}\n}}\n"),
        ("internal-cuda-dependencies", internal_path, f"install_cuda_libfabric_specs() {{\nfor spec in one; do\n  {SELF_TEST_FIXTURES['cuda-dependencies']}\ndone\n}}\n"),
        ("internal-cuda-package", internal_path, f"install_cuda_libfabric_specs() {{\nfor spec in one; do\n  {SELF_TEST_FIXTURES['cuda-package']}\ndone\n}}\n"),
        ("internal-environment", internal_path, f"cmd_build() {{\n  {SELF_TEST_FIXTURES['environment']}\n}}\n"),
        ("internal-staged-environment", internal_path, f"cmd_build() {{\n  {SELF_TEST_FIXTURES['staged-environment']}\n}}\n"),
        ("policy-never", PurePosixPath("AGENTS.md"), SELF_TEST_FIXTURES["policy-never"]),
        ("policy-do-not", PurePosixPath("agents/skills/chapar-release-helper/SKILL.md"), SELF_TEST_FIXTURES["policy-do-not"]),
        ("policy-forbidden", PurePosixPath("agents/skills/chapar-spack-env-change/SKILL.md"), SELF_TEST_FIXTURES["policy-forbidden"]),
        ("policy-must-not", PurePosixPath("docs/ci-github-actions.md"), SELF_TEST_FIXTURES["policy-must-not"]),
        ("policy-multiline", PurePosixPath("docs/ci-github-actions.md"), "Operators must not\n  `spack install example` directly.\n"),
        ("fixture-ast", AUDIT_PATH, synthetic_python("SELF_TEST_FIXTURES", "dict[str, str]", repr(SELF_TEST_FIXTURES["rogue"]))),
        ("shell-comment", PurePosixPath("rogue.sh"), f"# {SELF_TEST_FIXTURES['rogue']}\n"),
        ("backtick-escaped", PurePosixPath("rogue.sh"), "echo \\`spack install inert\\`\n"),
        ("backtick-escaped-quoted", PurePosixPath("rogue.sh"), 'echo "\\`spack install inert\\`"\n'),
        ("backtick-single-quoted", PurePosixPath("rogue.sh"), "printf '%s' '`spack install inert`'\n"),
        ("backtick-heredoc", PurePosixPath("rogue.sh"), "cat <<'DATA'\n`spack install inert`\nDATA\n"),
    )
    rogue = SELF_TEST_FIXTURES["rogue"]
    rejected_cases: tuple[tuple[str, PurePosixPath, str], ...] = (
        ("internal-path", PurePosixPath("envs/other/release.sh"), accepted_cases[0][2]),
        ("internal-function", internal_path, accepted_cases[0][2].replace("install_release_prerequisite", "other_function")),
        ("internal-token", internal_path, accepted_cases[0][2].replace("${scope_dir}", "${other_scope}")),
        ("internal-argv-order", internal_path, accepted_cases[3][2].replace('--dirty "${install_args_ref[@]}"', '"${install_args_ref[@]}" --dirty')),
        ("internal-argv-extra", internal_path, accepted_cases[4][2].replace("--only-concrete", "--only-concrete --reuse")),
        ("policy-path", PurePosixPath("README.md"), SELF_TEST_FIXTURES["policy-never"]),
        ("policy-token", PurePosixPath("AGENTS.md"), "- " + SELF_TEST_FIXTURES["policy-never"].replace("NEVER", "Avoid")),
        ("fixture-file", PurePosixPath("ci/tests/other.py"), accepted_cases[11][2]),
        ("fixture-name", AUDIT_PATH, synthetic_python("OTHER_FIXTURES", "dict[str, str]", repr(rogue))),
        ("fixture-annotation", AUDIT_PATH, synthetic_python("SELF_TEST_FIXTURES", "Mapping[str, str]", repr(rogue))),
        ("fixture-nested", AUDIT_PATH, synthetic_python("SELF_TEST_FIXTURES", "dict[str, str]", repr(rogue), nested=True)),
        ("fixture-computed", AUDIT_PATH, synthetic_python("SELF_TEST_FIXTURES", "dict[str, str]", f"{'spack '!r} + {'install rogue-package'!r}")),
        ("fixture-comment", AUDIT_PATH, f"# {rogue}\nSELF_TEST_FIXTURES: dict[str, str] = {{}}\n"),
        ("shell-multiline", PurePosixPath("rogue.sh"), "spack " + chr(92) + "\n  install rogue-package\n"),
        ("shell-env-prefix", PurePosixPath("rogue.sh"), f"env MODE=x {rogue}\n"),
        ("shell-malformed-quote", PurePosixPath("rogue.sh"), rogue.replace("rogue-package", chr(34) + "rogue-package")),
        ("shell-substitution", PurePosixPath("rogue.sh"), f"$({rogue})\n"),
        ("shell-separator", PurePosixPath("rogue.sh"), f"true; {rogue}\n"),
        ("internal-env-prefix", internal_path, accepted_cases[0][2].replace("  spack", "  env MODE=x spack")),
        ("internal-substitution", internal_path, accepted_cases[0][2].replace("  spack", "  $(spack").replace("\n}\n", ")\n}\n")),
        ("internal-separator", internal_path, accepted_cases[0][2].replace("  spack", "  true; spack")),
        ("markdown-multiline", PurePosixPath("README.md"), "```bash\nspack " + chr(92) + "\n install rogue-package\n```\n"),
        ("python-malformed", PurePosixPath("rogue.py"), "command = " + chr(34) + rogue + "\n"),
        ("json-malformed", PurePosixPath("rogue.json"), "{" + chr(34) + "command" + chr(34) + ": " + chr(34) + rogue),
        ("string-newline-separator", PurePosixPath("rogue.py"), f"command = {'echo ok' + chr(10) + rogue!r}\n"),
        *((f"wrapper-{name}", PurePosixPath("rogue.sh"), f"{prefix} {rogue}\n") for name, prefix in (("sudo", "sudo"), ("sudo-option", "sudo -u root"), ("command", "command"), ("command-option", "command --"), ("nice", "nice"), ("nice-option", "nice -n 10"), ("timeout", "timeout 60"), ("timeout-option", "timeout --signal KILL 60"), ("nohup", "nohup"), ("nohup-option", "nohup --"), ("env-i", "env -i"), ("env-i-option", "env -i MODE=x"), ("env-ignore", "env --ignore-environment"), ("env-ignore-option", "env --ignore-environment MODE=x"))),
        *((f"control-{name}", internal_path, f"install_release_prerequisite() {{\n{body}\n}}\n") for name, body in (("if", f"if true; then\n {SELF_TEST_FIXTURES['prerequisite']}\nfi"), ("for", f"for item in one; do\n {SELF_TEST_FIXTURES['prerequisite']}\ndone"), ("while", f"while true; do\n {SELF_TEST_FIXTURES['prerequisite']}\ndone"), ("until", f"until false; do\n {SELF_TEST_FIXTURES['prerequisite']}\ndone"), ("case", f"case x in x)\n {SELF_TEST_FIXTURES['prerequisite']}\n;; esac"), ("select", f"select item in one; do\n {SELF_TEST_FIXTURES['prerequisite']}\ndone"), ("group", f"{{\n {SELF_TEST_FIXTURES['prerequisite']}\n}}"), ("subshell", f"(\n {SELF_TEST_FIXTURES['prerequisite']}\n)"), ("substitution-multiline", f"value=\"$(\n {SELF_TEST_FIXTURES['prerequisite']}\n)\""))),
        *((f"separator-{name}", PurePosixPath("rogue.sh"), f"{prefix} {rogue}\n") for name, prefix in (("and", "true &&"), ("or", "false ||"), ("pipe", "printf x |"))),
        ("internal-cuda-extra-control", internal_path, accepted_cases[2][2].replace("for spec in one; do", "for spec in one; do\nif true; then").replace("done\n}", "fi\ndone\n}")),
        ("policy-multiline-path", PurePosixPath("README.md"), "Operators must not\n `spack install example` directly.\n"),
        ("policy-multiline-token", PurePosixPath("AGENTS.md"), "- Operators should avoid\n `spack install example` directly.\n"),
        ("policy-mixed-positive", PurePosixPath("AGENTS.md"), "NEVER run `spack install blocked`; the positive example is `spack install allowed`.\n"),
        ("policy-fence", PurePosixPath("AGENTS.md"), f"```bash\n# NEVER\n{rogue}\n```\n"),
        ("payload-bash-clustered", PurePosixPath("rogue.sh"), f"bash -xc {rogue!r}\n"),
        ("payload-bash-prefixed-clustered", PurePosixPath("rogue.sh"), f"bash --noprofile -xc {rogue!r}\n"),
        ("payload-sh-clustered", PurePosixPath("rogue.sh"), f"sh -ec {rogue!r}\n"),
        ("payload-env-s", PurePosixPath("rogue.sh"), f"env -S {rogue!r}\n"),
        ("payload-env-s-clustered", PurePosixPath("rogue.sh"), f"env -S{rogue!r}\n"),
        ("payload-env-s-long", PurePosixPath("rogue.sh"), f"env --split-string={rogue!r}\n"),
        ("payload-env-s-long-separate", PurePosixPath("rogue.sh"), f"env --split-string {rogue!r}\n"),
        ("substitution-quoted", PurePosixPath("rogue.sh"), f'echo "$({rogue})"\n'),
        ("substitution-inline-approved", internal_path, accepted_cases[0][2].replace("  spack", '  value="$(printf x; spack').replace("\n}\n", ')"\n}\n')),
        ("substitution-prefixed-multiline", internal_path, accepted_cases[0][2].replace("  spack", '  value="$(printf x;\n  spack').replace("\n}\n", '\n)"\n}\n')),
        ("substitution-unquoted-multiline", internal_path, accepted_cases[0][2].replace("  spack", "  value=$(printf x;\n  spack").replace("\n}\n", "\n)\n}\n")),
        ("fence-info-string", PurePosixPath("AGENTS.md"), f"```bash title=blocked\n{rogue}\n```\n"),
        ("fence-tilde", PurePosixPath("AGENTS.md"), f"~~~bash\n{rogue}\n~~~\n"),
        ("fence-four-backticks", PurePosixPath("AGENTS.md"), f"````bash\n{rogue}\n````\n"),
        ("fence-unterminated", PurePosixPath("AGENTS.md"), f"```bash\n{rogue}\n"),
        ("policy-positive-sentence", PurePosixPath("AGENTS.md"), "NEVER run blocked. Run `spack install allowed` for setup.\n"),
        ("policy-positive-only", PurePosixPath("AGENTS.md"), "Run `spack install allowed` for setup.\n"),
        ("backtick-beginning", PurePosixPath("rogue.sh"), f"`{rogue}`\n"),
        ("backtick-middle", PurePosixPath("rogue.sh"), f"echo before `{rogue}` after\n"),
        ("backtick-double-quoted", PurePosixPath("rogue.sh"), f'echo "`{rogue}`"\n'),
        ("backtick-internal", internal_path, f"install_release_prerequisite() {{\n  value=`{SELF_TEST_FIXTURES['prerequisite']}`\n}}\n"),
        ("backtick-shell-payload", PurePosixPath("rogue.sh"), f"bash -c {f'echo `{rogue}`'!r}\n"),
        ("backtick-internal-multiline", internal_path, f"install_release_prerequisite() {{\n  value=`printf x\n  {SELF_TEST_FIXTURES['prerequisite']}\n  `\n}}\n"),
        ("backtick-unterminated", PurePosixPath("rogue.sh"), f"echo `{rogue}\n"),
    )
    failures: list[str] = []
    input_error_cases = frozenset({"shell-malformed-quote", "python-malformed", "json-malformed", "backtick-unterminated"})
    own_source = Path(__file__).read_text(encoding="utf-8")
    own_result = audit_documents({AUDIT_PATH: own_source})
    expected_fixture_candidates = sum(
        direct_install_segment(value) is not None for value in SELF_TEST_FIXTURES.values()
    )
    if own_result.violations or own_result.self_fixtures != expected_fixture_candidates:
        failures.append("annotated module-level fixture mapping was not bounded exactly")
    print(f"SELF-TEST accepted fixture-source-span count={own_result.self_fixtures}")
    for name, path, text in accepted_cases:
        result = audit_documents({path: text})
        if result.violations:
            failures.append(f"accepted case rejected: {name}")
        if name == "policy-multiline" and result.negative_policy != 1:
            failures.append("accepted multiline policy was not classified")
        print(f"SELF-TEST accepted {name}")
    for name, path, text in rejected_cases:
        try:
            result = audit_documents({path: text})
        except AuditInputError:
            result = None
        if name in input_error_cases:
            if result is not None:
                failures.append(f"malformed case did not fail input parsing: {name}")
        elif result is None:
            failures.append(f"valid rogue case failed input parsing: {name}")
        elif not result.violations:
            failures.append(f"rogue case accepted: {name}")
        print(f"SELF-TEST rejected {name}")
    valid_paths = (PurePosixPath("README.md"), PurePosixPath("envs/software/release.sh"))
    valid_payload = b"README.md\0envs/software/release.sh\0"
    if parse_file_list(valid_payload) != valid_paths:
        failures.append("valid NUL file list changed")
    print("SELF-TEST accepted file-list-nul")
    invalid_file_lists = {
        "file-list-termination": b"README.md\n",
        "file-list-duplicate": b"README.md\0README.md\0",
        "file-list-parent": b"../README.md\0",
    }
    for name, payload in invalid_file_lists.items():
        try:
            parse_file_list(payload)
        except AuditInputError:
            print(f"SELF-TEST rejected {name}")
        else:
            failures.append(f"rogue case accepted: {name}")
    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1
    print(f"SELF-TEST PASS: accepted={len(accepted_cases)} rejected={len(rejected_cases)}")
    return 0



def main() -> int:
    try:
        arguments = parse_cli(sys.argv[1:])
        if arguments.self_test:
            return run_self_test()
        return audit_repository(Path(arguments.root).resolve(), arguments.file_list)
    except (AuditInputError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
