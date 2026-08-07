#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run the contract or its mutation self-test:
#      uv run ci/tests/nscale-vlad-runbook-test.py
#      uv run ci/tests/nscale-vlad-runbook-test.py --self-test
# 3. Or make executable and run it directly.
# ───────────────────

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Final, override

ROOT: Final = Path(__file__).resolve().parents[2]
RUNBOOK: Final = ROOT / "docs/nscale-vlad-manual-build.md"
RECEIPT_TOOL: Final = ROOT / "ci/verify-vlad-source-approval.py"
RECEIPT_TOOL_PACKAGE: Final = ROOT / "ci/vlad_source_approval"
INSTALLER: Final = ROOT / "ci/install-validated-sqsh.py"
SCHEMAS: Final = {
    "chapar-vlad-source-approval/v1": frozenset(
        {"approved_at", "approved_by", "change_ticket", "chapar_commit", "chapar_remote", "schema", "source_lock_path", "source_lock_sha256"}
    ),
    "chapar-vlad-release-binding/v1": frozenset(
        {"chapar_commit", "container_registry_sha256", "datacenter", "datacenter_contract_sha256", "effective_manifest_sha256", "metadata_path", "metadata_sha256", "release_dir", "release_id", "run_id", "schema", "selection_sha256", "software_catalog_sha256", "software_set", "source_lock_sha256", "spack_lock_path", "spack_lock_sha256", "status", "target", "target_contract_sha256", "target_policy_sha256", "target_registry_sha256"}
    ),
    "chapar-vlad-builder-handoff/v1": frozenset(
        {"build_root", "chapar_commit", "image_id", "image_path", "image_sha256", "image_size", "release_binding", "release_binding_sha256", "schema", "source_lock_sha256", "target", "validation_root"}
    ),
    "chapar-vlad-runtime-receipt/v1": frozenset(
        {"builder_handoff_sha256", "image_path", "image_sha256", "release_binding_sha256", "runtime_preflight_sha256", "runtime_receipt_path", "schema", "smoke_output_sha256", "status", "target", "validator_image_root", "validator_root"}
    ),
}
REQUIRED_RUNBOOK_ANCHORS: Final = (
    "`README.md`",
    "`envs/software/spack.yaml`",
    "`datacenters/<id>`",
    "`selection.json`",
    "`selection.sha256`",
    "release-local `spack.lock`",
    "builder, validator, and publisher",
    "candidate or final writes",
    "`nvidia-vlad`",
    "`ubuntu-hpcsim`",
    "`vlad-image`",
    "target-platform behavior not validated",
)
PROTECTED_TOOL_ANCHORS: Final = (
    "READ_FLAGS: Final = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW",
    "DIR_FLAGS: Final = READ_FLAGS | os.O_DIRECTORY",
    'result = libc.syscall(439, fd, ctypes.c_char_p(b""), mode, 0x1000 | 0x200)',
    '"GIT_CONFIG_NOSYSTEM": "1"',
    '"GIT_CONFIG_GLOBAL": "/dev/null"',
    '"--no-replace-objects"',
    'f"safe.directory={root}"',
    '"core.fsmonitor=false"',
    '"core.hooksPath=/dev/null"',
    '"core.untrackedCache=false"',
    "require(info.st_uid == uid and stat.S_IMODE(info.st_mode) == mode",
    'require_directory_identity(leaf, args.expected_directory_identity, "sealed directory")',
    'require(content.sha256 == expected_sha, "sealed file digest mismatch")',
)


@dataclass(frozen=True, slots=True)
class ContractError(Exception):
    detail: str

    @override
    def __str__(self) -> str:
        return self.detail


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise ContractError(detail)


def validate_runbook(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    require(re.search(r"(?ms)^```bash\n.*?^```$", text) is None, "manual runbook must defer to the one canonical runnable sequence")
    for anchor in REQUIRED_RUNBOOK_ANCHORS:
        require(anchor in text, f"missing normative anchor: {anchor}")
    require("sources-lock.json` is global and remains `blocked`" in text, "blocked source-lock warning is absent")
    require("None of the deferred platform commands has been run" in text, "deferred platform execution boundary is absent")
    require(re.search(r"(?m)^\s*(?:export\s+)?(?:CHAPAR_TARGET_PROFILE|ENV_NAME)=", text) is None, "legacy environment/profile command is active")
    require("retirement is approved" not in text.lower(), "legacy retirement approval is forbidden")
    for schema, keys in SCHEMAS.items():
        declaration = f"`{schema}`: `{','.join(sorted(keys))}`"
        require(declaration in text, f"exact receipt declaration missing: {schema}")
    tool = RECEIPT_TOOL.read_text(encoding="utf-8") + "".join(
        path.read_text(encoding="utf-8") for path in sorted(RECEIPT_TOOL_PACKAGE.glob("*.py"))
    )
    for anchor in PROTECTED_TOOL_ANCHORS:
        require(anchor in tool, f"receipt tool protected gate drift: {anchor}")


def expect_failure(text: str, label: str, expected: str) -> None:
    with tempfile.TemporaryDirectory(prefix="nscale-runbook-negative-") as temporary:
        fixture = Path(temporary) / "runbook.md"
        _ = fixture.write_text(text, encoding="utf-8")
        completed = subprocess.run(
            (sys.executable, str(Path(__file__).resolve()), str(fixture)),
            check=False,
            capture_output=True,
            text=True,
        )
    output = completed.stderr + completed.stdout
    require(completed.returncode == 1, f"{label} child status was {completed.returncode}, expected 1")
    require(expected in output, f"{label} failed for the wrong reason: {output}")


def run_self_test() -> None:
    text = RUNBOOK.read_text(encoding="utf-8")
    validate_runbook(RUNBOOK)
    mutations = {
        "runnable-platform-block": (text + "\n```bash\necho forbidden-platform-command\n```\n", "one canonical runnable sequence"),
        "missing-canonical-flow-link": (text.replace("`README.md`", "canonical guide", 1), "missing normative anchor"),
        "legacy-profile-authority": (text + "\nCHAPAR_TARGET_PROFILE=vlad\n", "legacy environment/profile command"),
        "missing-source-block": (text.replace("sources-lock.json` is global and remains `blocked`", "sources-lock.json is pending", 1), "blocked source-lock warning"),
        "missing-deferred-boundary": (text.replace("None of the deferred platform commands has been run", "Platform status is unknown", 1), "deferred platform execution boundary"),
        "legacy-retirement-approval": (text + "\nLegacy retirement is approved.\n", "legacy retirement approval"),
        "missing-release-schema": (text.replace("`chapar-vlad-release-binding/v1`", "`missing-release-schema`", 1), "exact receipt declaration missing"),
    }
    for label, (mutation, expected) in mutations.items():
        expect_failure(mutation, label, expected)
    for executable in (RECEIPT_TOOL, INSTALLER):
        completed = subprocess.run(
            (sys.executable, str(executable), "--self-test"),
            check=False,
            capture_output=True,
            text=True,
        )
        require(completed.returncode == 0, f"{executable.name} self-test failed: {completed.stderr}{completed.stdout}")
    print("nscale Vlad runbook self-test passed: " + ",".join(mutations))


def main(arguments: list[str]) -> int:
    try:
        if not arguments:
            validate_runbook(RUNBOOK)
            print("nscale Vlad runbook contract passed")
        elif arguments == ["--self-test"]:
            run_self_test()
        elif len(arguments) == 1:
            validate_runbook(Path(arguments[0]))
            print("nscale Vlad runbook contract passed")
        else:
            raise ContractError("usage: nscale-vlad-runbook-test.py [--self-test|RUNBOOK]")
    except (ContractError, OSError) as error:
        print(f"nscale Vlad runbook contract failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
