from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Literal

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from validation.tests.test_selection_consumers import (
    ROOT,
    RUN,
    contract_for,
    dry_run,
    resolve_fixture,
)


def test_validation_rejects_forged_self_digested_contract_pair(tmp_path: Path) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-x86_64-v4")
    selection_path = fixture.output / "selection.json"
    forged_contract = json.loads(
        contract_for(fixture, "linux-x86_64-v4").read_text(encoding="utf-8")
    )
    forged_contract["paths"]["durable_writable"]["modulefiles"] = str(tmp_path / "forged/modules")
    forged_contract["paths"]["temporary"]["validation_work"] = str(tmp_path / "forged/results")
    forged_contract_path = tmp_path / "forged-contract.json"
    forged_contract_path.write_text(json.dumps(forged_contract), encoding="utf-8")
    selection = json.loads(selection_path.read_text(encoding="utf-8"))
    selection["authorities"]["target_contract"] = hashlib.sha256(forged_contract_path.read_bytes()).hexdigest()
    namespace = Path("example-lab/vlad/linux-x86_64-v4")
    selection["paths"]["modulefiles"] = str(tmp_path / "forged/modules" / namespace / "release-1")
    selection["paths"]["validation_work"] = str(tmp_path / "forged/results" / namespace / "run-1")
    selection_path.write_text(json.dumps(selection), encoding="utf-8")
    result = subprocess.run(
        [str(RUN), "--selection", str(selection_path), "--selection-digest", hashlib.sha256(selection_path.read_bytes()).hexdigest(), "--contract", str(forged_contract_path), "integrity-test"],
        cwd=ROOT, env={**os.environ, "CHAPAR_DRY_RUN": "1", "CHAPAR_VALIDATION_AUTHORITY_ROOT": str(fixture.root)}, check=False,
        capture_output=True, text=True,
    )
    assert result.returncode != 0
    assert "canonical" in result.stderr or "authority" in result.stderr
    assert not (tmp_path / "forged").exists()


def test_validation_rejects_forged_roots_with_canonical_authorities(
    tmp_path: Path,
) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-x86_64-v4")
    selection_path = fixture.output / "selection.json"
    selection = json.loads(selection_path.read_text(encoding="utf-8"))
    selection["selected_roots"] = [
        {
            "id": "root_shared_root-000000000000",
            "spec": "forged-package@99",
            "classification": "shared",
        }
    ]
    selection_path.write_text(json.dumps(selection), encoding="utf-8")
    sentinel = tmp_path / "sentinel"
    sentinel.write_text("unchanged", encoding="utf-8")

    result = dry_run(fixture, "linux-x86_64-v4")

    assert result.returncode != 0
    assert "selected root inventory" in result.stderr
    assert sentinel.read_text(encoding="utf-8") == "unchanged"


@pytest.mark.parametrize("field", ["release_id", "run_id"])
def test_validation_rejects_traversal_invocation_without_effects(
    tmp_path: Path, field: Literal["release_id", "run_id"]
) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-x86_64-v4")
    selection_path = fixture.output / "selection.json"
    selection = json.loads(selection_path.read_text(encoding="utf-8"))
    selection["invocation"][field] = "../escape"
    contract = json.loads(contract_for(fixture, "linux-x86_64-v4").read_text())
    namespace = Path("example-lab/vlad/linux-x86_64-v4")
    path_key = "modulefiles" if field == "release_id" else "validation_work"
    path_group = "durable_writable" if field == "release_id" else "temporary"
    selection["paths"][path_key] = str(
        Path(contract["paths"][path_group][path_key]) / namespace / "../escape"
    )
    selection_path.write_text(json.dumps(selection), encoding="utf-8")

    result = dry_run(fixture, "linux-x86_64-v4")

    assert result.returncode != 0
    assert field.replace("_", " ") in result.stderr.lower()
    assert not (tmp_path / "escape").exists()
