from __future__ import annotations

from pathlib import Path

import pytest

from tools.chapar_config.errors import ResolverError
from tools.chapar_config.models import (
    DatacenterId,
    InvocationIdentity,
    PolicyIdentity,
    ReleaseId,
    Request,
    RunId,
    TargetId,
)
from tools.chapar_config.render import render
from tools.chapar_config.resolve import load_inputs, resolve
from tools.chapar_config.tests.helpers import ROOT, make_fixture
from tools.chapar_datacenter_models import SoftwareSet


def test_partial_write_cleans_temporary_output(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fixture = make_fixture(tmp_path)
    contract = fixture.contracts / "linux-x86_64-v4/contract.json"
    inputs, digests = load_inputs(
        fixture.catalog,
        fixture.targets,
        fixture.containers,
        fixture.datacenter,
        contract,
    )
    request = Request(
        PolicyIdentity(
            DatacenterId("example-lab"),
            SoftwareSet.VLAD,
            TargetId("linux-x86_64-v4"),
        ),
        InvocationIdentity(ReleaseId("release-1"), RunId("run-1")),
        str(fixture.output),
    )

    def fail_write(_path: Path, _content: bytes) -> int:
        raise OSError("injected partial write")

    monkeypatch.setattr(Path, "write_bytes", fail_write)
    with pytest.raises(ResolverError, match="cannot publish"):
        render(resolve(request, inputs, digests), ROOT)
    assert not fixture.output.exists()
    assert not (fixture.output.parent / ".output.tmp.run-1").exists()
