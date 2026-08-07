#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from dataclasses import dataclass, fields
from pathlib import Path, PurePosixPath
from typing import Final

IDENTIFIER: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
SLURM_VALUE: Final = re.compile(r"^[A-Za-z0-9._+-]+$")
PATH_VALUE: Final = re.compile(r"^/[A-Za-z0-9._+/@=-]+(?:/[A-Za-z0-9._+/@=-]+)*$")
REQUIRED_PATHS: Final = (
    "release_final", "release_staging", "modulefiles", "install_tree",
    "writable_buildcache", "ccache", "spack_build_stage",
)
ALL_PATHS: Final = (
    "release_root", "release_final", "release_staging", "modulefiles", "install_tree",
    "writable_buildcache", "ccache", "container_outputs", "receipts", "evidence",
    "spack_build_stage", "image_staging", "validation_work", "resolver_work",
)

type JsonValue = str | int | float | bool | None | list["JsonValue"] | dict[str, "JsonValue"]
type JsonObject = dict[str, JsonValue]

PlanError = RuntimeError


@dataclass(frozen=True, slots=True)
class Arguments:
    selection: Path; selection_digest: str; contract: Path
    datacenter: str; software_set: str; target: str
    release_id: str; run_id: str


@dataclass(frozen=True, slots=True)
class Plan:
    tuple_id: str; selection: str; selection_digest: str; contract: str
    partition: str; constraint: str; account: str; qos: str; containers: str
    release_final: str; release_staging: str; modulefiles: str; install_tree: str
    writable_buildcache: str; ccache: str; spack_build_stage: str
    publish_buildcache: str; publish_modules: str; publish_containers: str
    promote_current: str


def parse_arguments() -> Arguments:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", required=True, type=Path)
    parser.add_argument("--selection-digest", required=True)
    parser.add_argument("--contract", required=True, type=Path)
    for option in ("datacenter", "software-set", "target", "release-id", "run-id"):
        parser.add_argument(f"--{option}", required=True)
    values = parser.parse_args()
    return Arguments(
        values.selection, values.selection_digest, values.contract,
        values.datacenter, values.software_set, values.target,
        values.release_id, values.run_id,
    )


def read_json(path: Path, label: str) -> tuple[JsonObject, bytes]:
    if not path.is_absolute() or path.is_symlink():
        raise PlanError(f"{label} must be an absolute regular file")
    try:
        payload = read_bytes(path, label)
        document: JsonValue = json.loads(payload)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PlanError(f"invalid {label}: {error}") from error
    if not isinstance(document, dict):
        raise PlanError(f"{label} must contain a JSON object")
    return document, payload


def read_bytes(path: Path, label: str) -> bytes:
    if not path.is_absolute() or ".." in path.parts:
        raise PlanError(f"{label} must be absolute without traversal")
    if len(path.parts) > 1 and path.parts[1] in {"tmp", "var"}:
        alias = Path(path.anchor) / path.parts[1]
        expected = Path("/private") / path.parts[1]
        if alias.is_symlink() and alias.resolve() == expected:
            path = expected.joinpath(*path.parts[2:])
    file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    directory_flags = file_flags | getattr(os, "O_DIRECTORY", 0)
    directory = os.open(path.anchor, directory_flags)
    try:
        for component in path.parts[1:-1]:
            child = os.open(component, directory_flags, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(path.name, file_flags, dir_fd=directory)
        with os.fdopen(descriptor, "rb") as authority:
            if not stat.S_ISREG(os.fstat(authority.fileno()).st_mode):
                raise PlanError(f"{label} must be a regular file")
            return authority.read()
    except OSError as error:
        raise PlanError(f"invalid {label}: {error}") from error
    finally:
        os.close(directory)


def expected_paths(contract: JsonObject, arguments: Arguments) -> JsonObject:
    paths = mapping(contract, "paths", "target contract")
    durable = mapping(paths, "durable_writable", "target contract.paths")
    temporary = mapping(paths, "temporary", "target contract.paths")
    sharing = mapping(contract, "sharing", "target contract")
    namespace = PurePosixPath(arguments.datacenter, arguments.software_set, arguments.target)
    shared = [arguments.datacenter]
    if sharing.get("share_across_software_sets") is not True:
        shared.append(arguments.software_set)
    if sharing.get("share_across_targets") is not True:
        shared.append(arguments.target)
    shared_namespace = PurePosixPath(*shared)
    roots = {
        name: text(durable, name, "target contract.paths.durable_writable", PATH_VALUE)
        for name in ("releases", "modulefiles", "install_tree", "writable_buildcache", "ccache", "container_outputs", "receipts", "evidence")
    }
    work = {
        name: text(temporary, name, "target contract.paths.temporary", PATH_VALUE)
        for name in ("release_staging", "spack_build_stage", "image_staging", "validation_work", "resolver_work")
    }
    def child(root: str, *parts: str | PurePosixPath) -> str:
        return str(PurePosixPath(root).joinpath(*parts))
    return {
        "release_root": child(roots["releases"], namespace),
        "release_final": child(roots["releases"], namespace, arguments.release_id),
        "release_staging": child(work["release_staging"], namespace, f"{arguments.release_id}.{arguments.run_id}"),
        "modulefiles": child(roots["modulefiles"], namespace, arguments.release_id),
        "install_tree": child(roots["install_tree"], shared_namespace),
        "writable_buildcache": child(roots["writable_buildcache"], shared_namespace),
        "ccache": child(roots["ccache"], shared_namespace),
        "container_outputs": child(roots["container_outputs"], namespace, arguments.release_id),
        "receipts": child(roots["receipts"], namespace, arguments.release_id),
        "evidence": child(roots["evidence"], namespace, arguments.run_id),
        "spack_build_stage": child(work["spack_build_stage"], namespace, arguments.run_id),
        "image_staging": child(work["image_staging"], namespace, arguments.run_id),
        "validation_work": child(work["validation_work"], namespace, arguments.run_id),
        "resolver_work": child(work["resolver_work"], namespace, arguments.run_id),
    }


def mapping(document: JsonObject, key: str, label: str) -> JsonObject:
    value = document.get(key)
    if not isinstance(value, dict):
        raise PlanError(f"{label}.{key} must be an object")
    return value


def text(mapping_value: JsonObject, key: str, label: str, pattern: re.Pattern[str]) -> str:
    value = mapping_value.get(key)
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise PlanError(f"{label}.{key} is invalid")
    return value


def flag(mapping_value: JsonObject, key: str, label: str) -> str:
    value = mapping_value.get(key)
    if not isinstance(value, bool):
        raise PlanError(f"{label}.{key} must be boolean")
    return str(value).lower()


def resolve(arguments: Arguments) -> Plan:
    selection, selection_bytes = read_json(arguments.selection, "selection")
    actual_digest = hashlib.sha256(selection_bytes).hexdigest()
    if arguments.selection_digest != actual_digest:
        raise PlanError("selection digest does not match selection bytes")
    if re.fullmatch(r"[a-f0-9]{64}", arguments.selection_digest) is None:
        raise PlanError("selection digest must be lowercase SHA-256")
    for value, label in (
        (arguments.datacenter, "datacenter"),
        (arguments.software_set, "software set"),
        (arguments.target, "target"),
        (arguments.release_id, "release ID"),
        (arguments.run_id, "run ID"),
    ):
        if IDENTIFIER.fullmatch(value) is None:
            raise PlanError(f"invalid {label}")
    policy = mapping(selection, "policy", "selection")
    invocation = mapping(selection, "invocation", "selection")
    expected = {
        "datacenter": arguments.datacenter,
        "software_set": arguments.software_set,
        "target": arguments.target,
    }
    if any(policy.get(key) != value for key, value in expected.items()):
        raise PlanError("selection policy does not match requested canonical tuple")
    if invocation.get("release_id") != arguments.release_id or invocation.get("run_id") != arguments.run_id:
        raise PlanError("selection invocation does not match requested release/run identity")
    contract, contract_bytes = read_json(arguments.contract, "target contract")
    authorities = mapping(selection, "authorities", "selection")
    if authorities.get("target_contract") != hashlib.sha256(contract_bytes).hexdigest():
        raise PlanError("target contract digest does not match the selection authority")
    if contract.get("datacenter_id") != arguments.datacenter or contract.get("target") != arguments.target:
        raise PlanError("target contract does not match requested canonical tuple")
    paths = mapping(selection, "paths", "selection")
    resolved_paths = {key: text(paths, key, "selection.paths", PATH_VALUE) for key in ALL_PATHS}
    if resolved_paths != expected_paths(contract, arguments):
        raise PlanError("selection paths do not match target contract derivation")
    repository_root = Path(__file__).resolve().parents[1]
    datacenter_contract = arguments.contract.parents[2] / "datacenter.json"
    authority_files = {
        "software_catalog": repository_root / "envs/software/spack.yaml",
        "target_registry": repository_root / "containers/images/targets.json",
        "container_registry": repository_root / "containers/images/containers.json",
        "datacenter_contract": datacenter_contract,
    }
    authority_payloads = {name: read_bytes(path, name.replace("_", " ")) for name, path in authority_files.items()}
    expected_authorities = {name: hashlib.sha256(payload).hexdigest() for name, payload in authority_payloads.items()}
    expected_authorities["target_contract"] = hashlib.sha256(contract_bytes).hexdigest()
    if authorities != expected_authorities:
        raise PlanError("selection authority digests do not match current authorities")
    artifacts = mapping(selection, "artifacts", "selection")
    effective_manifest = arguments.selection.parent / "spack.yaml"
    target_policy = arguments.selection.parent / "target-policy.yaml"
    manifest_payload = read_bytes(effective_manifest, "effective manifest")
    policy_payload = read_bytes(target_policy, "target policy")
    manifest_digest = hashlib.sha256(manifest_payload).hexdigest()
    policy_digest = hashlib.sha256(policy_payload).hexdigest()
    if artifacts != {"effective_manifest_sha256": manifest_digest, "target_policy_sha256": policy_digest}:
        raise PlanError("selection-local artifact digests do not match exact bytes")
    raw_containers = selection.get("containers")
    if not isinstance(raw_containers, list) or any(not isinstance(item, str) or IDENTIFIER.fullmatch(item) is None for item in raw_containers):
        raise PlanError("selection.containers must be an ID array")
    containers = [item for item in raw_containers if isinstance(item, str)]
    if len(containers) != len(set(containers)):
        raise PlanError("selection.containers contains duplicates")
    slurm = mapping(contract, "slurm", "target contract")
    publication = mapping(contract, "publication", "target contract")
    return Plan(
        tuple_id=f"{arguments.datacenter}/{arguments.software_set}/{arguments.target}",
        selection=str(arguments.selection), selection_digest=actual_digest, contract=str(arguments.contract),
        partition=text(slurm, "partition", "target contract.slurm", SLURM_VALUE),
        constraint=text(slurm, "constraint", "target contract.slurm", SLURM_VALUE),
        account=text(slurm, "account", "target contract.slurm", SLURM_VALUE),
        qos=text(slurm, "qos", "target contract.slurm", SLURM_VALUE),
        containers=",".join(containers),
        **{key: resolved_paths[key] for key in REQUIRED_PATHS},
        publish_buildcache=flag(publication, "publish_buildcache", "target contract.publication"),
        publish_modules=flag(publication, "publish_modules", "target contract.publication"),
        publish_containers=flag(publication, "publish_containers", "target contract.publication"),
        promote_current=flag(publication, "promote_current", "target contract.publication"),
    )


def main() -> int:
    try:
        plan = resolve(parse_arguments())
    except PlanError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    for field in fields(plan):
        print(f"{field.name}\t{getattr(plan, field.name)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
