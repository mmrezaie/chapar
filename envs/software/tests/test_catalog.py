#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["PyYAML>=6,<7"]
# ///

# ─── How to run ───
# uv run envs/software/tests/test_catalog.py
# ──────────────────

from __future__ import annotations

import json
import re
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
RUNNER = ROOT / "envs/software/tests/catalog.py"
MANIFEST = ROOT / "envs/software/spack.yaml"
README = ROOT / "envs/software/README.md"
HISTORICAL_INVENTORY = ROOT / "envs/software/tests/fixtures/historical-root-inventory.json"
TARGET_FACT = re.compile(r"(?:cuda_arch=|(?:^|\s)target=|(?:^|\s)targets=)")
CUDA_ARCH_VALUE = re.compile(r"\s*cuda_arch=[0-9a,]+")


def run_catalog(manifest: Path, *arguments: str) -> CommandResult:
    completed = subprocess.run(
        [sys.executable, "-I", "-E", str(RUNNER), str(manifest), *arguments],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def replace_once(content: str, needle: str, replacement: str) -> str:
    require(needle in content, f"missing fixture anchor: {needle!r}")
    return content.replace(needle, replacement, 1)


def test_compositions_and_generated_readme() -> None:
    # Given the canonical catalog; When each historical set is rendered; Then its exact root count is stable.
    expected_counts = {"vlad": 42, "hpcsim": 75, "all": 81}
    for software_set, expected_count in expected_counts.items():
        result = run_catalog(MANIFEST, "--set", software_set)
        require(result.exit_code == 0, f"{software_set} catalog failed: {result.stderr}")
        require(f'"root_count": {expected_count}' in result.stdout, f"{software_set} root count drifted")
    result = run_catalog(MANIFEST, "--check-readme", str(README))
    require(result.exit_code == 0, f"generated README drifted: {result.stderr}")
    require(result.stdout == "catalog README is current\n", "catalog reported misleading README success")
    documentation = README.read_text(encoding="utf-8")
    require("90 exact historical root specs" in documentation, "historical union documentation drifted")
    require("48 exact HPCSim-not-Vlad" in documentation, "historical delta documentation drifted")
    require("10 historical variant-difference packages" in documentation, "historical variant documentation drifted")
    require("logical union has 81 roots" in documentation, "target-neutral union explanation drifted")
    arm = run_catalog(MANIFEST, "--set", "hpcsim", "--arch", "aarch64")
    require(arm.exit_code == 0, f"aarch64 catalog failed: {arm.stderr}")
    require('"root_count": 73' in arm.stdout, "aarch64 did not exclude x86-only roots")
    require('"exclusions": [' in arm.stdout and '"root-f660baf70174"' in arm.stdout, "aarch64 exclusions lost Intel roots")
    all_arm = run_catalog(MANIFEST, "--set", "all", "--arch", "aarch64")
    require(all_arm.exit_code == 0, f"aarch64 all catalog failed: {all_arm.stderr}")
    require('"root_count": 79' in all_arm.stdout, "aarch64 all composition drifted")


def test_catalog_preserves_frozen_historical_root_strings() -> None:
    # Given the frozen Task-1 inventory; When target facts are removed; Then the normalized historical union is unchanged.
    historical = json.loads(HISTORICAL_INVENTORY.read_text(encoding="utf-8"))
    expected = {
        " ".join(CUDA_ARCH_VALUE.sub("", root["spec"]).split())
        for root in historical["roots"]
    }
    result = run_catalog(MANIFEST, "--set", "all")
    require(result.exit_code == 0, f"all catalog failed: {result.stderr}")
    actual = {root["specification"] for root in json.loads(result.stdout)["roots"]}
    require(actual == expected, "catalog root strings drifted from normalized frozen history")


def test_catalog_contains_no_target_facts() -> None:
    # Given the canonical catalog; When its source is inspected; Then registry-owned target facts are absent.
    require(
        TARGET_FACT.search(MANIFEST.read_text(encoding="utf-8")) is None,
        "canonical catalog contains target-owned CUDA, Spack, or LLVM facts",
    )


def test_rejections_preserve_output() -> None:
    # Given malformed catalog variants; When the real parser runs; Then it rejects before replacing output.
    original = MANIFEST.read_text(encoding="utf-8")
    cases = {
        "duplicate-spec": replace_once(original, "- autoconf", "- autoconf\n    - autoconf"),
        "duplicate-id": replace_once(original, "root_shared_root-3eb7278e7eef", "root_shared_root-251d177e3e7d"),
        "missing-origin": replace_once(original, "root_shared_root-3eb7278e7eef", "root_unknown_root-3eb7278e7eef"),
        "unsupported-architecture": replace_once(original, "architecture_limited_x86_64", "architecture_limited_power9"),
        "malformed-yaml": "spack: [\n",
    }
    expected_errors = {
        "duplicate-spec": "duplicate root spec",
        "duplicate-id": "duplicate root id",
        "missing-origin": "missing origin classification",
        "unsupported-architecture": "unsupported architecture tag",
        "malformed-yaml": "malformed YAML",
    }
    with tempfile.TemporaryDirectory(prefix="chapar-catalog-test-") as temporary:
        directory = Path(temporary)
        for name, content in cases.items():
            manifest = directory / f"{name}.yaml"
            output = directory / f"{name}.json"
            manifest.write_text(content, encoding="utf-8")
            output.write_text("must-not-change\n", encoding="utf-8")
            result = run_catalog(manifest, "--set", "all", "--output", str(output))
            require(result.exit_code != 0, f"{name} unexpectedly succeeded")
            require(expected_errors[name] in result.stderr, f"{name} error changed: {result.stderr!r}")
            require(output.read_text(encoding="utf-8") == "must-not-change\n", f"{name} mutated output")


def test_stale_readme_is_rejected() -> None:
    # Given stale generated documentation; When it is checked; Then the parser rejects it without rewriting it.
    with tempfile.TemporaryDirectory(prefix="chapar-catalog-test-") as temporary:
        readme = Path(temporary) / "README.md"
        stale = README.read_text(encoding="utf-8").replace("HPCSim-not-Vlad", "HPCSim-not-Vlad (stale)", 1)
        readme.write_text(stale, encoding="utf-8")
        result = run_catalog(MANIFEST, "--check-readme", str(readme))
        require(result.exit_code != 0, "stale README unexpectedly succeeded")
        require("generated README is stale" in result.stderr, f"stale README error changed: {result.stderr!r}")
        require(readme.read_text(encoding="utf-8") == stale, "stale README was mutated")


def main() -> int:
    test_compositions_and_generated_readme()
    test_catalog_preserves_frozen_historical_root_strings()
    test_catalog_contains_no_target_facts()
    test_rejections_preserve_output()
    test_stale_readme_is_rejected()
    print("catalog test passed: compositions, generated docs, 6 failure scenarios")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
