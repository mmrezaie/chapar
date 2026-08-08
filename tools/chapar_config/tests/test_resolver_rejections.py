from __future__ import annotations

import json
from hashlib import sha256
from pathlib import Path

import pytest

from tools.chapar_config.tests.helpers import (
    cli_arguments,
    make_fixture,
    run_cli,
    run_raw,
)


@pytest.mark.parametrize(
    ("software_set", "target", "expected"),
    [
        ("unknown", "linux-x86_64-v4", "software set"),
        ("hpcsim", "linux-x86_64-v4", "forbidden tuple"),
        ("vlad", "linux-unknown", "unknown target"),
    ],
)
def test_invalid_selector_has_zero_output(
    tmp_path: Path, software_set: str, target: str, expected: str
) -> None:
    fixture = make_fixture(tmp_path)
    result = run_cli(fixture, software_set=software_set, target=target)
    assert result.returncode != 0
    assert expected in result.stderr.lower()
    assert not fixture.output.exists()


@pytest.mark.parametrize(
    ("path_class", "value", "expected"),
    [
        ("releases", "/resources/chapar", "protected"),
        ("releases", "/resources", "protected"),
        ("releases", "/resources/chapar/new", "protected"),
        ("releases", "/tmp/shared", "overlap"),
        ("modulefiles", "/tmp/shared", "overlap"),
    ],
)
def test_unsafe_writable_path_has_zero_output(
    tmp_path: Path, path_class: str, value: str, expected: str
) -> None:
    fixture = make_fixture(tmp_path)
    contract = fixture.contracts / "linux-x86_64-v4/contract.json"
    document = json.loads(contract.read_text())
    document["paths"]["durable_writable"][path_class] = value
    if value == "/tmp/shared":
        document["paths"]["durable_writable"]["receipts"] = value
    contract.write_text(json.dumps(document), encoding="utf-8")
    result = run_cli(fixture)
    assert result.returncode != 0
    assert "unique" in result.stderr.lower() or expected in result.stderr.lower()
    assert not fixture.output.exists()


def test_seed_publisher_and_nonadjacent_staging_fail(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path)
    contract = fixture.contracts / "linux-x86_64-v4/contract.json"
    document = json.loads(contract.read_text())
    document["sharing"]["seed_mirrors_read_only"] = False
    contract.write_text(json.dumps(document), encoding="utf-8")
    seed = run_cli(fixture)
    assert seed.returncode != 0
    assert "seed" in seed.stderr.lower()
    assert not fixture.output.exists()

    fixture = make_fixture(tmp_path / "adjacency")
    contract = fixture.contracts / "linux-x86_64-v4/contract.json"
    document = json.loads(contract.read_text())
    document["paths"]["temporary"]["release_staging"] = "/tmp/not-adjacent"
    contract.write_text(json.dumps(document), encoding="utf-8")
    adjacent = run_cli(fixture)
    assert adjacent.returncode != 0
    assert "adjacent" in adjacent.stderr.lower()
    assert not fixture.output.exists()


def test_digest_tamper_and_incompatible_container_fail(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path)
    contract = fixture.contracts / "linux-x86_64-v4/contract.json"
    document = json.loads(contract.read_text())
    document["provenance"]["authority_sha256"]["target_registry"] = "0" * 64
    contract.write_text(json.dumps(document), encoding="utf-8")
    tamper = run_cli(fixture)
    assert tamper.returncode != 0
    assert "digest" in tamper.stderr.lower()
    assert not fixture.output.exists()

    fixture = make_fixture(tmp_path / "container")
    contract = fixture.contracts / "linux-x86_64-v4/contract.json"
    document = json.loads(contract.read_text())
    document["container_selections"][0]["container"] = "ubuntu-hpcsim"
    contract.write_text(json.dumps(document), encoding="utf-8")
    incompatible = run_cli(fixture)
    assert incompatible.returncode != 0
    assert "container" in incompatible.stderr.lower()
    assert not fixture.output.exists()


def test_symlinked_authority_and_existing_destination_fail(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path)
    link = fixture.root / "linked-targets.json"
    link.symlink_to(fixture.targets)
    linked = fixture.__class__(
        root=fixture.root,
        catalog=fixture.catalog,
        targets=link,
        containers=fixture.containers,
        datacenter=fixture.datacenter,
        contracts=fixture.contracts,
        output=fixture.output,
    )
    result = run_cli(linked)
    assert result.returncode != 0
    assert "symlink" in result.stderr.lower()
    assert not fixture.output.exists()

    fixture.output.mkdir()
    sentinel = fixture.output / "incomplete"
    sentinel.write_text("keep\n", encoding="utf-8")
    existing = run_cli(fixture)
    assert existing.returncode != 0
    assert "destination" in existing.stderr.lower()
    assert sentinel.read_text(encoding="utf-8") == "keep\n"


def test_missing_extra_and_relative_arguments_have_zero_output(tmp_path: Path) -> None:
    missing = run_raw(("--software-set", "vlad"))
    assert missing.returncode != 0
    assert "missing or extra selector" in missing.stderr.lower()
    extra = run_raw(tuple(["--unknown", "value"] * 11))
    assert extra.returncode != 0
    fixture = make_fixture(tmp_path)
    relative = fixture.__class__(
        root=fixture.root,
        catalog=Path("relative/spack.yaml"),
        targets=fixture.targets,
        containers=fixture.containers,
        datacenter=fixture.datacenter,
        contracts=fixture.contracts,
        output=fixture.output,
    )
    result = run_cli(relative)
    assert result.returncode != 0
    assert "absolute" in result.stderr.lower()
    assert not fixture.output.exists()
    traversal = fixture.__class__(
        root=fixture.root,
        catalog=Path("/tmp/chapar-authorities/../escape/spack.yaml"),
        targets=fixture.targets,
        containers=fixture.containers,
        datacenter=fixture.datacenter,
        contracts=fixture.contracts,
        output=fixture.output,
    )
    escaped = run_cli(traversal)
    assert escaped.returncode != 0
    assert "traversal" in escaped.stderr.lower()
    assert not fixture.output.exists()


def test_cross_target_collision_and_ambiguous_module_fail(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path)
    peer = fixture.contracts / "linux-aarch64-gb300/contract.json"
    peer_document = json.loads(peer.read_text())
    peer_document["paths"]["durable_writable"]["ccache"] = (
        "/tmp/chapar-example/example-lab/linux-x86_64-v4/ccache"
    )
    peer.write_text(json.dumps(peer_document), encoding="utf-8")
    collision = run_cli(fixture)
    assert collision.returncode != 0
    assert "cross-target" in collision.stderr.lower()
    assert not fixture.output.exists()

    fixture = make_fixture(tmp_path / "module")
    registry = json.loads(fixture.containers.read_text())
    registry["containers"]["nvidia-vlad"]["module_destination"] = "relative/modules"
    fixture.containers.write_text(json.dumps(registry), encoding="utf-8")
    contract = fixture.contracts / "linux-x86_64-v4/contract.json"
    contract_document = json.loads(contract.read_text())
    contract_document["provenance"]["authority_sha256"]["container_registry"] = (
        sha256(fixture.containers.read_bytes()).hexdigest()
    )
    contract.write_text(json.dumps(contract_document), encoding="utf-8")
    ambiguous = run_cli(fixture)
    assert ambiguous.returncode != 0
    assert "module" in ambiguous.stderr.lower()
    assert not fixture.output.exists()


def test_duplicate_catalog_root_id_fails_without_output(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path)
    content = fixture.catalog.read_text(encoding="utf-8")
    marker = "  - root_shared_root-3eb7278e7eef:\n    - autoconf\n"
    fixture.catalog.write_text(content.replace(marker, marker + marker, 1), encoding="utf-8")
    result = run_cli(fixture)
    assert result.returncode != 0
    assert "duplicate root id" in result.stderr.lower()
    assert not fixture.output.exists()


def test_mismatched_datacenter_id_fails_without_output(tmp_path: Path) -> None:
    fixture = make_fixture(tmp_path)
    result = run_cli(fixture, datacenter_id="foreign-datacenter")
    assert result.returncode != 0
    assert "datacenter selector" in result.stderr.lower()
    assert not fixture.output.exists()


@pytest.mark.parametrize(
    "identity",
    ("..", "../escaped", "/absolute", "bad\nidentity"),
)
def test_malformed_datacenter_identity_fails_before_output(
    tmp_path: Path, identity: str
) -> None:
    fixture = make_fixture(tmp_path)
    result = run_cli(fixture, datacenter_id=identity)
    assert result.returncode != 0
    assert "invalid datacenter" in result.stderr.lower()
    assert not fixture.output.exists()


@pytest.mark.parametrize(
    "identity_flag",
    ["--datacenter-id", "--software-set", "--target", "--release-id", "--run-id"],
)
def test_missing_identity_field_fails_without_output(
    tmp_path: Path, identity_flag: str
) -> None:
    fixture = make_fixture(tmp_path)
    arguments = cli_arguments(fixture)
    position = arguments.index(identity_flag)
    result = run_raw(arguments[:position] + arguments[position + 2 :])
    assert result.returncode != 0
    assert "missing or extra selector" in result.stderr.lower()
    assert not fixture.output.exists()


@pytest.mark.parametrize(
    "identity_flag",
    ["--datacenter-id", "--software-set", "--target", "--release-id", "--run-id"],
)
def test_duplicate_identity_field_fails_without_output(
    tmp_path: Path, identity_flag: str
) -> None:
    fixture = make_fixture(tmp_path)
    arguments = cli_arguments(fixture)
    position = arguments.index(identity_flag)
    duplicated = arguments + arguments[position : position + 2]
    result = run_raw(duplicated)
    assert result.returncode != 0
    assert "missing or extra selector" in result.stderr.lower()
    assert not fixture.output.exists()
