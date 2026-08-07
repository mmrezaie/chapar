from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Literal, assert_never

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.chapar_config.tests.helpers import Fixture, make_fixture, run_cli
from validation import selection as validation_selection

RUN, CVE = ROOT / "validation/run", ROOT / "ci/cve-checker.py"


def resolve_fixture(tmp_path: Path, software_set: str, target: str) -> Fixture:
    fixture = make_fixture(tmp_path)
    canonical_files = {
        fixture.root / "envs/software/spack.yaml": fixture.catalog,
        fixture.root / "containers/images/targets.json": fixture.targets,
        fixture.root / "containers/images/containers.json": fixture.containers,
    }
    for destination, source in canonical_files.items():
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(source.read_bytes())
    result = run_cli(fixture, software_set=software_set, target=target)
    assert result.returncode == 0, result.stderr
    return fixture


def contract_for(fixture: Fixture, target: str) -> Path:
    return fixture.contracts / target / "contract.json"


def digest_file(fixture: Fixture) -> Path:
    destination = fixture.root / "selection.sha256"
    destination.write_text(hashlib.sha256((fixture.output / "selection.json").read_bytes()).hexdigest() + "\n", encoding="utf-8")
    return destination


def dry_run(fixture: Fixture, target: str, test: str = "integrity-test") -> subprocess.CompletedProcess[str]:
    selection = fixture.output / "selection.json"
    return subprocess.run(
        [str(RUN), "--selection", str(selection), "--selection-digest", hashlib.sha256(selection.read_bytes()).hexdigest(), "--contract", str(contract_for(fixture, target)), test],
        cwd=ROOT, env={**os.environ, "CHAPAR_DRY_RUN": "1", "CHAPAR_VALIDATION_AUTHORITY_ROOT": str(fixture.root)}, check=False, capture_output=True, text=True,
    )


@pytest.mark.parametrize(
    ("software_set", "target"),
    [
        ("vlad", "linux-x86_64-v4"),
        ("vlad", "linux-aarch64-gb300"),
        ("hpcsim", "linux-x86_64-generic"),
        ("all", "linux-x86_64-v4"),
    ],
)
def test_validation_dry_run_uses_verified_tuple(
    tmp_path: Path, software_set: str, target: str
) -> None:
    fixture = resolve_fixture(tmp_path, software_set, target)
    result = dry_run(fixture, target)
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan["policy"] == {
        "datacenter": "example-lab",
        "software_set": software_set,
        "target": target,
    }
    assert plan["module_path"] == json.loads(
        (fixture.output / "selection.json").read_text(encoding="utf-8")
    )["paths"]["modulefiles"]
    assert plan["partition"]
    assert plan["constraint"]
    assert f"/example-lab/{software_set}/{target}/" in plan["result_namespace"]
    assert plan["root_count"] > 0
    assert plan["action"] == "dry-run"


def test_cve_plan_uses_selected_canonical_inventory(tmp_path: Path) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-x86_64-v4")
    state = tmp_path / "state"
    result = subprocess.run(
        [
            sys.executable,
            str(CVE),
            "--selection",
            str(fixture.output / "selection.json"),
            "--selection-digest-file",
            str(digest_file(fixture)),
            "--spack-yaml",
            str(fixture.root / "envs/software/spack.yaml"),
            "--state-dir",
            str(state),
            "--plan",
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    selection = json.loads((fixture.output / "selection.json").read_text())
    assert plan["policy"] == selection["policy"]
    assert plan["packages"]
    assert plan["package_count"] == len(plan["packages"])
    assert not state.exists()


@pytest.mark.parametrize(
    "mutation",
    [
        "missing_inventory",
        "duplicate_root",
        "missing_check",
        "mixed_module_path",
        "wrong_target",
        "wrong_contract_digest",
    ],
)
def test_invalid_selection_fails_without_side_effects(
    tmp_path: Path,
    mutation: Literal[
        "missing_inventory",
        "duplicate_root",
        "missing_check",
        "mixed_module_path",
        "wrong_target",
        "wrong_contract_digest",
    ],
) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-x86_64-v4")
    selection_path = fixture.output / "selection.json"
    selection = json.loads(selection_path.read_text(encoding="utf-8"))
    match mutation:
        case "missing_inventory":
            selection["selected_roots"] = []
        case "duplicate_root":
            selection["selected_roots"].append(selection["selected_roots"][0])
        case "missing_check":
            selection["selected_roots"][0]["spec"] = "???"
        case "mixed_module_path":
            selection["paths"]["modulefiles"] = "/tmp/other-dc/other-set/other-target/modules"
        case "wrong_target":
            selection["policy"]["target"] = "linux-aarch64-gb300"
        case "wrong_contract_digest":
            selection["authorities"]["target_contract"] = "0" * 64
        case unreachable:
            assert_never(unreachable)
    selection_path.write_text(json.dumps(selection), encoding="utf-8")
    sentinel = tmp_path / "sentinel"
    sentinel.write_text("unchanged", encoding="utf-8")
    result = dry_run(fixture, "linux-x86_64-v4")
    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "unchanged"


def test_old_env_name_and_symlinked_selection_are_rejected(tmp_path: Path) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-x86_64-v4")
    link = tmp_path / "selection-link.json"
    link.symlink_to(fixture.output / "selection.json")
    env = {**os.environ, "CHAPAR_DRY_RUN": "1", "ENV_NAME": "poison"}
    result = subprocess.run(
        [str(RUN), "--selection", str(link), "--selection-digest", hashlib.sha256(link.read_bytes()).hexdigest(), "--contract", str(contract_for(fixture, "linux-x86_64-v4")), "module-smoke"],
        cwd=ROOT,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "ENV_NAME" in result.stderr or "symlink" in result.stderr


def test_module_plan_is_deterministic(tmp_path: Path) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-aarch64-gb300")
    first = dry_run(fixture, "linux-aarch64-gb300", "module-smoke")
    second = dry_run(fixture, "linux-aarch64-gb300", "module-smoke")
    assert first.returncode == second.returncode == 0
    assert first.stdout == second.stdout
    assert json.loads(first.stdout)["test"] == "module-smoke"


def test_validation_rejects_wrong_selection_digest(tmp_path: Path) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-x86_64-v4")
    result = subprocess.run(
        [
            str(RUN),
            "--selection",
            str(fixture.output / "selection.json"),
            "--selection-digest",
            "0" * 64,
            "--contract",
            str(contract_for(fixture, "linux-x86_64-v4")),
            "integrity-test",
        ],
        cwd=ROOT,
        env={**os.environ, "CHAPAR_DRY_RUN": "1"},
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "selection digest" in result.stderr


def test_validation_plan_uses_authenticated_selection_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-x86_64-v4")
    monkeypatch.setenv("CHAPAR_DRY_RUN", "1")
    monkeypatch.setenv("CHAPAR_VALIDATION_AUTHORITY_ROOT", str(fixture.root))
    selection_path = fixture.output / "selection.json"
    contract_path = contract_for(fixture, "linux-x86_64-v4")
    digest = hashlib.sha256(selection_path.read_bytes()).hexdigest()
    original = validation_selection.load_document
    expected_module = json.loads(selection_path.read_text())["paths"]["modulefiles"]
    replaced = False

    def replace_after_read(path: Path, label: str):
        nonlocal replaced
        document, payload = original(path, label)
        if label == "selection" and not replaced:
            forged = json.loads(payload)
            forged["paths"]["modulefiles"] = str(tmp_path / "foreign/modules")
            selection_path.write_text(json.dumps(forged), encoding="utf-8")
            replaced = True
        return document, payload

    monkeypatch.setattr(validation_selection, "load_document", replace_after_read)
    plan = validation_selection.build_plan(
        selection_path, digest, contract_path, "integrity-test"
    )
    assert plan.module_path == expected_module


def test_cve_plan_rejects_catalog_digest_drift(tmp_path: Path) -> None:
    fixture = resolve_fixture(tmp_path, "hpcsim", "linux-x86_64-generic")
    canonical_catalog = fixture.root / "envs/software/spack.yaml"
    canonical_catalog.write_bytes(canonical_catalog.read_bytes() + b"\n")
    result = subprocess.run(
        [sys.executable, str(CVE), "--selection", str(fixture.output / "selection.json"), "--selection-digest-file", str(digest_file(fixture)), "--spack-yaml", str(canonical_catalog), "--plan"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "digest" in result.stderr


def test_dry_run_never_invokes_target_commands(tmp_path: Path) -> None:
    fixture = resolve_fixture(tmp_path, "hpcsim", "linux-x86_64-generic")
    poison = tmp_path / "poison-bin"
    poison.mkdir()
    marker = tmp_path / "invoked"
    for name in ("sbatch", "module", "spack"):
        script = poison / name
        script.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 97\n", encoding="utf-8")
        script.chmod(0o755)
    env = {**os.environ, "CHAPAR_DRY_RUN": "1", "CHAPAR_VALIDATION_AUTHORITY_ROOT": str(fixture.root), "PATH": f"{poison}:{os.environ['PATH']}"}
    result = subprocess.run(
        [str(RUN), "--selection", str(fixture.output / "selection.json"), "--selection-digest", hashlib.sha256((fixture.output / "selection.json").read_bytes()).hexdigest(), "--contract", str(contract_for(fixture, "linux-x86_64-generic")), "all"],
        cwd=ROOT,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    assert not marker.exists()


def test_machine_readable_summary_fields_are_preserved() -> None:
    for script in (ROOT / "validation/tests/integrity-test.sbatch", ROOT / "validation/tests/module-smoke.sbatch"):
        source = script.read_text(encoding="utf-8")
        for field in ("total", "passed", "failed", "results", "module", "check", "result"):
            assert field in source
