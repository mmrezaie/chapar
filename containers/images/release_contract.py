#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
#   Imported by containers/images/build-image.sh.

from __future__ import annotations

import hashlib
import json
import os
import stat
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Never

from registry import (
    Container,
    JsonValue,
    Sources,
    Target,
    parse_containers,
    parse_sources,
    parse_targets,
)
from selection_contract import SelectionError, validate_selection

METADATA_SCHEMA: Final = "https://nscaledev.github.io/chapar/schemas/release-metadata/v1"


@dataclass(frozen=True, slots=True)
class ContractError(Exception):
    message: str

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True, slots=True)
class ReleasePlan:
    identity: dict[str, str]
    roots: dict[str, str]
    paths: dict[str, str]
    target: Target
    container: Container
    sources: Sources
    selection_sha256: str
    lock_sha256: str


@dataclass(frozen=True, slots=True)
class ReleaseRequest:
    release_dir: Path
    base_id: str
    target_id: str
    catalog_path: Path
    targets_path: Path
    containers_path: Path
    sources_path: Path
    datacenter_contract_path: Path
    target_contract_path: Path


@dataclass(frozen=True, slots=True)
class Snapshot:
    payload: bytes
    sha256: str
    document: dict[str, JsonValue] | None


def fail(message: str) -> Never:
    raise ContractError(message)


def snapshot(path: Path, label: str, *, parse_json: bool = False) -> Snapshot:
    if not path.is_absolute() or ".." in path.parts:
        fail(f"{label} must be absolute without traversal")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    directory_flags = flags | getattr(os, "O_DIRECTORY", 0)
    try:
        directory = os.open(path.anchor, directory_flags)
        try:
            for component in path.parts[1:-1]:
                child = os.open(component, directory_flags, dir_fd=directory)
                os.close(directory)
                directory = child
            descriptor = os.open(path.name, flags, dir_fd=directory)
            with os.fdopen(descriptor, "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    fail(f"{label} is not a regular file")
                payload = stream.read()
        finally:
            os.close(directory)
    except OSError as error:
        fail(f"cannot read {label}: {error}")
    return Snapshot(payload, hashlib.sha256(payload).hexdigest(), parse_document(payload, label) if parse_json else None)


def unique(pairs: list[tuple[str, JsonValue]]) -> dict[str, JsonValue]:
    result: dict[str, JsonValue] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key in release contract: {key}")
        result[key] = value
    return result


def parse_document(payload: bytes, label: str) -> dict[str, JsonValue]:
    try:
        value: JsonValue = json.loads(payload, object_pairs_hook=unique)
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def mapping(value: JsonValue, label: str) -> dict[str, JsonValue]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def text(value: JsonValue, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a nonempty string")
    return value


def string_mapping(value: JsonValue, label: str) -> dict[str, str]:
    raw = mapping(value, label)
    return {key: text(item, f"{label}.{key}") for key, item in raw.items()}


def require_fields(value: Mapping[str, JsonValue], fields: frozenset[str], label: str) -> None:
    if frozenset(value) != fields:
        fail(f"{label} fields mismatch: expected {','.join(sorted(fields))}")


def verify_release(request: ReleaseRequest) -> ReleasePlan:
    release_dir = request.release_dir
    metadata_path = release_dir / "metadata.json"
    selection_path = release_dir / "selection.json"
    manifest_path = release_dir / "spack.yaml"
    lock_path = release_dir / "spack.lock"
    policy_path = release_dir / "target-policy.yaml"
    snapshots = {
        "metadata": snapshot(metadata_path, "release metadata", parse_json=True),
        "software_catalog": snapshot(request.catalog_path, "software catalog"),
        "target_registry": snapshot(request.targets_path, "target registry"),
        "container_registry": snapshot(request.containers_path, "container registry"),
        "sources": snapshot(request.sources_path, "source lock"),
        "datacenter_contract": snapshot(request.datacenter_contract_path, "datacenter contract"),
        "target_contract": snapshot(request.target_contract_path, "target contract"),
        "selection": snapshot(selection_path, "release selection"),
        "effective_manifest": snapshot(manifest_path, "release effective manifest"),
        "target_policy": snapshot(policy_path, "release target policy"),
        "release_local_lock": snapshot(lock_path, "release-local spack.lock"),
    }
    metadata = snapshots["metadata"].document
    if metadata is None:
        fail("release metadata is not parsed")
    require_fields(metadata, frozenset({"schema", "schema_version", "identity", "roots", "digests", "policy"}), "release metadata")
    if metadata["schema"] != METADATA_SCHEMA or metadata["schema_version"] != 1:
        fail("release metadata schema is unsupported")
    identity = string_mapping(metadata["identity"], "release identity")
    require_fields(identity, frozenset({"datacenter", "software_set", "target", "release_id", "run_id"}), "release identity")
    roots = string_mapping(metadata["roots"], "release roots")
    require_fields(roots, frozenset({"release_root", "release_final", "release_staging", "modulefiles", "install_tree", "writable_buildcache", "ccache", "spack_build_stage"}), "release roots")
    if Path(roots["release_final"]) != release_dir:
        fail("release metadata final path does not match --release-dir")
    expected_digests = string_mapping(metadata["digests"], "release digests")
    require_fields(expected_digests, frozenset({"software_catalog_sha256", "target_registry_sha256", "container_registry_sha256", "datacenter_contract_sha256", "target_contract_sha256", "selection_sha256", "effective_manifest_sha256", "target_policy_sha256", "release_local_lock_sha256"}), "release digests")
    policy = mapping(metadata["policy"], "release policy")

    actual = {
        f"{name}_sha256": snapshots[name].sha256
        for name in ("software_catalog", "target_registry", "container_registry", "datacenter_contract", "target_contract", "selection", "effective_manifest", "target_policy", "release_local_lock")
    }
    for name, actual_digest in actual.items():
        if expected_digests.get(name) != actual_digest:
            fail(f"release digest mismatch: {name}")
    targets = parse_targets(snapshots["target_registry"].payload)
    sources = parse_sources(snapshots["sources"].payload)
    containers = parse_containers(snapshots["container_registry"].payload, targets, sources)
    target = targets.get(request.target_id)
    container = containers.get(request.base_id)
    if target is None or container is None:
        fail("unknown target or container")
    if identity["target"] != request.target_id:
        fail("release target does not match image request")
    if identity["software_set"] not in container.accepted_software_sets:
        fail("release software set is not accepted by selected container")
    if request.target_id not in container.allowed_targets:
        fail("selected container does not allow release target")

    datacenter_contract = parse_document(snapshots["datacenter_contract"].payload, "datacenter contract")
    target_contract = parse_document(snapshots["target_contract"].payload, "target contract")
    datacenter_targets = datacenter_contract.get("targets")
    if datacenter_contract.get("datacenter_id") != identity["datacenter"]:
        fail("datacenter contract identity differs from release")
    if not isinstance(datacenter_targets, list) or request.target_id not in datacenter_targets:
        fail("datacenter contract does not allow release target")
    if target_contract.get("datacenter_id") != identity["datacenter"] or target_contract.get("target") != request.target_id:
        fail("target contract identity differs from release")
    allowed_sets = target_contract.get("allowed_software_sets")
    if not isinstance(allowed_sets, list) or identity["software_set"] not in allowed_sets:
        fail("target contract does not allow release software set")
    contract_containers = target_contract.get("container_selections")
    selected_pairs = [item for item in contract_containers if isinstance(item, dict) and item.get("software_set") == identity["software_set"]] if isinstance(contract_containers, list) else []
    if len(selected_pairs) != 1 or selected_pairs[0].get("container") != request.base_id:
        fail("target contract does not select requested container")
    # Publication policy belongs to the target contract, not to this tool. A
    # hardcoded expectation would make every contract with publish_buildcache
    # false produce releases that can never be imaged.
    contract_publication = target_contract.get("publication")
    if not isinstance(contract_publication, dict) or not isinstance(contract_publication.get("publish_buildcache"), bool):
        fail("target contract publication policy is invalid")
    publish_buildcache = contract_publication["publish_buildcache"]
    if policy != {"publish_buildcache": publish_buildcache, "buildcache_signed": False, "buildcache_autopush": publish_buildcache}:
        fail("release publication policy does not match the target contract")

    selection_document = parse_document(snapshots["selection"].payload, "release selection")
    try:
        selection = validate_selection(selection_document)
    except SelectionError as error:
        fail(str(error))
    for name in ("datacenter", "software_set", "target"):
        if selection.policy.get(name) != identity[name]:
            fail(f"selection identity mismatch: {name}")
    for name in ("release_id", "run_id"):
        if selection.invocation.get(name) != identity[name]:
            fail(f"selection identity mismatch: {name}")
    if request.base_id not in selection.containers:
        fail("selected container is absent from release selection")
    for name in ("software_catalog", "target_registry", "container_registry", "datacenter_contract", "target_contract"):
        if selection.authorities.get(name) != expected_digests[f"{name}_sha256"]:
            fail(f"selection authority mismatch: {name}")
    if selection.artifacts.get("effective_manifest_sha256") != actual["effective_manifest_sha256"]:
        fail("selection effective manifest digest mismatch")
    if selection.artifacts.get("target_policy_sha256") != actual["target_policy_sha256"]:
        fail("selection target policy digest mismatch")
    if selection.target_facts != {
        "oci_platform": target.oci_platform,
        "native_arch": target.native_arch,
        "spack_target": target.spack_target,
        "llvm_targets": list(target.llvm_targets),
        "cuda_arch": list(target.cuda_arch),
    }:
        fail("selection target facts differ from the global target registry")
    return ReleasePlan(identity, roots, selection.paths, target, container, sources, actual["selection_sha256"], actual["release_local_lock_sha256"])
