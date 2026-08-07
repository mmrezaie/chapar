#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      uv run envs/software/tests/test_inventory.py
# 3. Or make executable and run:
#      chmod +x envs/software/tests/test_inventory.py && ./envs/software/tests/test_inventory.py
# ──────────────────

from __future__ import annotations

import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class CommandResult:
    exit_code: int
    stdout: str
    stderr: str


ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / "envs/software/tests/inventory.py"
FIXTURES = ROOT / "envs/software/tests/fixtures"


def run_inventory(*arguments: str) -> CommandResult:
    completed = subprocess.run(
        [sys.executable, "-I", "-E", str(RUNNER), *arguments],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_failure_preserves_output(fixture_name: str, expected_error: str) -> None:
    with tempfile.TemporaryDirectory(prefix="chapar-inventory-test-") as temporary:
        output = Path(temporary) / "report.json"
        sentinel = "must-not-be-replaced\n"
        output.write_text(sentinel, encoding="utf-8")
        result = run_inventory(str(FIXTURES / fixture_name), "--output", str(output))
        require(result.exit_code != 0, f"{fixture_name} unexpectedly succeeded")
        require(expected_error in result.stderr, f"{fixture_name} did not report {expected_error!r}: {result.stderr!r}")
        require(output.read_text(encoding="utf-8") == sentinel, f"{fixture_name} mutated output before rejection")


def test_happy_report_replaces_stale_artifact() -> None:
    with tempfile.TemporaryDirectory(prefix="chapar-inventory-test-") as temporary:
        output = Path(temporary) / "report.json"
        output.write_text("stale generated artifact\n", encoding="utf-8")
        result = run_inventory(str(FIXTURES / "historical-root-inventory.json"), "--output", str(output))
        require(result.exit_code == 0, f"baseline inventory failed: {result.stderr}")
        rendered = output.read_text(encoding="utf-8")
        require("stale generated artifact" not in rendered, "valid report did not replace stale artifact")
        require('"vlad": 42' in rendered and '"hpcsim": 75' in rendered, "historical source counts drifted")
        require('"ucx"' in rendered, "same-package variant diagnostics disappeared")


def test_protected_policy() -> None:
    result = run_inventory("--validate-protected-policy", str(FIXTURES / "protected-state.json"))
    require(result.exit_code == 0, f"protected policy failed: {result.stderr}")
    require(result.stdout == "protected-state policy valid\n", "protected policy emitted misleading success output")


def main() -> int:
    # Given invalid duplicate IDs; When the real CLI runs; Then it rejects without mutation.
    test_failure_preserves_output("duplicate-id.json", "duplicate root id")
    # Given an absent provenance field; When the real CLI runs; Then it rejects without mutation.
    test_failure_preserves_output("missing-origin.json", "missing origin")
    # Given variant strings falsely marked shared; When the real CLI runs; Then it rejects without mutation.
    test_failure_preserves_output("same-package-different-variant-invalid-shared.json", "shared provenance")
    test_failure_preserves_output("duplicate-spec.json", "duplicate root spec")
    test_failure_preserves_output("malformed.json", "malformed JSON")
    test_happy_report_replaces_stale_artifact()
    test_protected_policy()
    print("inventory test passed: 5 failure scenarios, baseline report, protected policy")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
