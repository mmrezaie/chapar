from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

import pytest
import yaml

from tools.chapar_config.tests.helpers import make_fixture, run_cli


@pytest.mark.parametrize(
    ("software_set", "target", "expected_container"),
    [
        ("vlad", "linux-x86_64-v4", "nvidia-vlad"),
        ("vlad", "linux-aarch64-gb300", "nvidia-vlad"),
        ("hpcsim", "linux-x86_64-generic", "ubuntu-hpcsim"),
    ],
)
def test_supported_tuple_renders_deterministically(
    tmp_path: Path,
    software_set: str,
    target: str,
    expected_container: str,
) -> None:
    fixture = make_fixture(tmp_path)
    first = run_cli(fixture, software_set=software_set, target=target)
    assert first.returncode == 0, first.stderr
    artifacts = {
        path.name: path.read_bytes() for path in sorted(fixture.output.iterdir())
    }
    selection = json.loads(artifacts["selection.json"])
    manifest = yaml.safe_load(artifacts["spack.yaml"])
    policy = yaml.safe_load(artifacts["target-policy.yaml"])
    assert selection["policy"] == {
        "datacenter": "example-lab",
        "software_set": software_set,
        "target": target,
    }
    assert selection["containers"] == [expected_container]
    assert selection["selected_roots"]
    assert manifest["spack"]["specs"]
    assert policy["target"]["id"] == target
    digest = hashlib.sha256(artifacts["selection.json"]).hexdigest()
    assert first.stdout.strip() == digest

    second_root = tmp_path / "repeat"
    second = make_fixture(second_root)
    rerun = run_cli(second, software_set=software_set, target=target)
    assert rerun.returncode == 0, rerun.stderr
    repeated = {
        path.name: path.read_bytes() for path in sorted(second.output.iterdir())
    }
    assert artifacts == repeated


def test_arm_records_architecture_exclusions(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path)
    result = run_cli(fixture, target="linux-aarch64-gb300")
    assert result.returncode == 0, result.stderr
    selection = json.loads((fixture.output / "selection.json").read_text())
    exclusions = [
        item
        for item in selection["excluded_roots"]
        if "native_arch" in item["reason"]
    ]
    assert len(exclusions) == 2
    assert {item["reason"] for item in exclusions} == {
        "native_arch aarch64 excludes x86_64 root"
    }


def test_authority_change_changes_selection_digest(tmp_path: Path) -> None:
    first = make_fixture(tmp_path / "first")
    one = run_cli(first)
    assert one.returncode == 0, one.stderr
    second = make_fixture(tmp_path / "second")
    second.catalog.write_bytes(second.catalog.read_bytes() + b"\n")
    two = run_cli(second)
    assert two.returncode == 0, two.stderr
    assert one.stdout != two.stdout


def test_explicit_all_tuple_has_no_implicit_container(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path)
    result = run_cli(fixture, software_set="all", target="linux-x86_64-v4")
    assert result.returncode == 0, result.stderr
    selection = json.loads((fixture.output / "selection.json").read_text())
    assert selection["containers"] == []


@pytest.mark.parametrize(
    ("software_set", "target"),
    [
        ("vlad", "linux-x86_64-v4"),
        ("vlad", "linux-aarch64-gb300"),
        ("hpcsim", "linux-x86_64-generic"),
        ("all", "linux-x86_64-v4"),
    ],
)
def test_effective_manifest_derives_target_facts_from_registry(
    tmp_path: Path, software_set: str, target: str
) -> None:
    # Given a supported tuple; When the resolver renders it; Then CUDA, LLVM, and Spack target facts match its registry record.
    fixture = make_fixture(tmp_path)
    result = run_cli(fixture, software_set=software_set, target=target)
    assert result.returncode == 0, result.stderr
    target_fact = json.loads(fixture.targets.read_text(encoding="utf-8"))["targets"][target]
    manifest = yaml.safe_load((fixture.output / "spack.yaml").read_text(encoding="utf-8"))
    policy = yaml.safe_load((fixture.output / "target-policy.yaml").read_text(encoding="utf-8"))
    assert policy["target"] == {"id": target, **target_fact}
    requirements = manifest["spack"]["packages"]
    assert f"target={target_fact['spack_target']}" in requirements["all"]["require"]
    assert f"targets={','.join(target_fact['llvm_targets'])}" in requirements["llvm"]["require"]
    # CUDA architecture is a package requirement, so it binds transitive
    # instances too. Root specs must stay exactly as the catalog declares them.
    assert not re.search(r"cuda_arch=", "\n".join(manifest["spack"]["specs"]))
    expected_cuda = ",".join(target_fact["cuda_arch"])
    rendered = {
        name: json.dumps(entry.get("require", []))
        for name, entry in requirements.items()
        if isinstance(entry, dict)
    }
    for name in ("gdrcopy", "nccl", "nccl-tests", "nvbandwidth", "nvshmem", "nvtop"):
        assert f"cuda_arch={expected_cuda}" in rendered[name], name
    for name in ("babelstream", "caliper", "hwloc", "libfabric", "openmpi", "ucx"):
        assert {"spec": f"cuda_arch={expected_cuda}", "when": "+cuda"} in requirements[name]["require"], name
