from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from ci.cve_checker import selection as cve_selection
from ci.cve_checker.github_issues import issue_marker
from ci.cve_checker.models import Finding, Package
from validation.tests.test_selection_consumers import resolve_fixture


def test_issue_marker_binds_package_and_cve_for_deduplication() -> None:
    # given
    finding = Finding(
        package=Package("openmpi", "5"),
        source="NVD",
        cve_id="CVE-2026-0001",
        severity="HIGH",
        score=8.1,
        published=None,
        modified=None,
        summary="fixture",
        url="https://example.invalid/CVE-2026-0001",
        references=(),
        evidence="fixture",
    )
    # when
    marker = issue_marker(finding)

    # then
    assert marker == "chapar-cve-checker:v1 package=openmpi cve=CVE-2026-0001"


def test_selected_inventory_uses_authenticated_selection_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fixture = resolve_fixture(tmp_path, "vlad", "linux-x86_64-v4")
    catalog = fixture.root / "envs/software/spack.yaml"
    selection_path = fixture.output / "selection.json"
    selection = json.loads(selection_path.read_text(encoding="utf-8"))
    digest_path = tmp_path / "selection.sha256"
    digest_path.write_text(
        hashlib.sha256(selection_path.read_bytes()).hexdigest(), encoding="utf-8"
    )
    original = cve_selection.read_regular_once

    def replace_after_capture(path: Path, label: str) -> bytes:
        payload = original(path, label)
        if label == "selection":
            forged = {**selection, "selected_roots": [{"id": "forged", "spec": "forged-package@99"}]}
            selection_path.write_text(json.dumps(forged), encoding="utf-8")
        return payload

    monkeypatch.setattr(cve_selection, "read_regular_once", replace_after_capture)
    packages, _ = cve_selection.load_selected_inventory(
        selection_path, digest_path, catalog
    )
    assert "forged-package" not in {package.name for package in packages}


def test_selected_inventory_rejects_forged_roots_with_canonical_authorities(
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
    digest_path = tmp_path / "selection.sha256"
    digest_path.write_text(
        hashlib.sha256(selection_path.read_bytes()).hexdigest(), encoding="utf-8"
    )
    canonical_catalog = fixture.root / "envs/software/spack.yaml"
    state = tmp_path / "state"

    with pytest.raises(SystemExit):
        cve_selection.load_selected_inventory(
            selection_path, digest_path, canonical_catalog
        )

    assert not state.exists()
