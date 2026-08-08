#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from dataclasses import asdict, dataclass
from enum import StrEnum
from pathlib import Path, PurePosixPath
from typing import Final, assert_never

ROOT: Final = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.chapar_config.consumer_inventory import canonical_selected_roots
from tools.chapar_config.errors import ResolverError
from tools.chapar_config.paths import validated_identity
from validation.checks import RootCheck, RootInventoryError, canonical_root_checks

type JsonScalar = str | int | float | bool | None
type JsonValue = JsonScalar | list[JsonValue] | dict[str, JsonValue]

IDENTIFIER: Final = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


class SelectionError(Exception):
    pass


def unique_object(pairs: list[tuple[str, JsonValue]]) -> dict[str, JsonValue]:
    result: dict[str, JsonValue] = {}
    for key, value in pairs:
        if key in result:
            raise SelectionError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


class Command(StrEnum):
    PLAN = "plan"
    CHECKS = "checks"
    SHELL = "shell"


@dataclass(frozen=True, slots=True)
class ValidationPlan:
    action: str
    test: str
    policy: dict[str, str]
    release_id: str
    run_id: str
    module_path: str
    result_namespace: str
    partition: str
    constraint: str
    account: str
    qos: str
    root_count: int
    checks: tuple[RootCheck, ...]


def load_bytes(path: Path, label: str) -> bytes:
    if not path.is_absolute() or ".." in path.parts:
        raise SelectionError(f"{label} must be absolute without traversal")
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
                    raise SelectionError(f"{label} must be a regular file")
                payload = stream.read()
        finally:
            os.close(directory)
    except OSError as error:
        raise SelectionError(f"cannot read {label}: {error}") from error
    return payload


def load_document(path: Path, label: str) -> tuple[dict[str, JsonValue], bytes]:
    payload = load_bytes(path, label)
    try:
        document = json.loads(payload, object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SelectionError(f"cannot read {label}: {error}") from error
    if not isinstance(document, dict):
        raise SelectionError(f"{label} must be a JSON object")
    return document, payload


def mapping(document: dict[str, JsonValue], key: str) -> dict[str, JsonValue]:
    value = document.get(key)
    if not isinstance(value, dict):
        raise SelectionError(f"missing {key} object")
    return value


def text(document: dict[str, JsonValue], key: str) -> str:
    value = document.get(key)
    if not isinstance(value, str) or not value:
        raise SelectionError(f"missing {key}")
    return value


def expected_paths(contract: dict[str, JsonValue], policy: dict[str, str], release_id: str, run_id: str) -> tuple[str, str]:
    paths = mapping(contract, "paths")
    durable = mapping(paths, "durable_writable")
    temporary = mapping(paths, "temporary")
    namespace = PurePosixPath(policy["datacenter"], policy["software_set"], policy["target"])
    module_path = PurePosixPath(text(durable, "modulefiles")) / namespace / release_id
    result_path = PurePosixPath(text(temporary, "validation_work")) / namespace / run_id
    return str(module_path), str(result_path)


def canonical_contract(supplied: Path, policy: dict[str, str], authorities: dict[str, JsonValue]) -> tuple[dict[str, JsonValue], bytes, bytes, bytes]:
    root = Path(os.environ["CHAPAR_VALIDATION_AUTHORITY_ROOT"]) if os.environ.get("CHAPAR_DRY_RUN") == "1" and os.environ.get("CHAPAR_VALIDATION_AUTHORITY_ROOT") else Path(__file__).resolve().parents[1]
    canonical = root / "datacenters" / policy["datacenter"] / "targets" / policy["target"] / "contract.json"
    if supplied != canonical:
        raise SelectionError("target contract is not the canonical policy authority")
    paths = {
        "software_catalog": root / "envs/software/spack.yaml",
        "target_registry": root / "containers/images/targets.json",
        "container_registry": root / "containers/images/containers.json",
        "datacenter_contract": root / "datacenters" / policy["datacenter"] / "datacenter.json",
        "target_contract": canonical,
    }
    contract = load_document(canonical, "target contract")
    payloads = {
        name: contract[1] if name == "target_contract" else load_bytes(path, name)
        for name, path in paths.items()
    }
    for name, payload in payloads.items():
        if hashlib.sha256(payload).hexdigest() != text(authorities, name):
            raise SelectionError(f"canonical {name} authority digest mismatch")
    return contract[0], contract[1], payloads["software_catalog"], payloads["target_registry"]


def build_plan(
    selection_path: Path,
    selection_digest: str,
    contract_path: Path,
    test: str,
    seal_dir: Path | None = None,
) -> ValidationPlan:
    selection, selection_bytes = load_document(selection_path, "selection")
    if hashlib.sha256(selection_bytes).hexdigest() != selection_digest:
        raise SelectionError("selection digest does not match supplied bytes")
    policy_raw = mapping(selection, "policy")
    policy = {key: text(policy_raw, key) for key in ("datacenter", "software_set", "target")}
    if any(IDENTIFIER.fullmatch(value) is None for value in policy.values()):
        raise SelectionError("selection policy identity is invalid")
    authorities = mapping(selection, "authorities")
    contract, contract_bytes, catalog_bytes, target_registry_bytes = canonical_contract(
        contract_path, policy, authorities
    )
    if text(contract, "datacenter_id") != policy["datacenter"]:
        raise SelectionError("contract datacenter does not match selection")
    if text(contract, "target") != policy["target"]:
        raise SelectionError("contract target does not match selection")
    allowed = contract.get("allowed_software_sets")
    if not isinstance(allowed, list) or policy["software_set"] not in allowed:
        raise SelectionError("contract rejects selected software set")
    paths = mapping(selection, "paths")
    module_path = text(paths, "modulefiles")
    result_namespace = text(paths, "validation_work")
    invocation = mapping(selection, "invocation")
    release_id = text(invocation, "release_id")
    run_id = text(invocation, "run_id")
    try:
        validated_identity(release_id, "release ID")
        validated_identity(run_id, "run ID")
    except ResolverError as error:
        raise SelectionError(str(error)) from error
    if (module_path, result_namespace) != expected_paths(contract, policy, release_id, run_id):
        raise SelectionError("selection validation paths differ from target contract")
    placement = mapping(contract, "slurm")
    try:
        expected_roots = canonical_selected_roots(
            ROOT / "envs/software/spack.yaml",
            catalog_bytes,
            ROOT / "containers/images/targets.json",
            target_registry_bytes,
            policy["software_set"],
            policy["target"],
        )
        checks = canonical_root_checks(selection, expected_roots)
    except (ResolverError, RootInventoryError) as error:
        raise SelectionError(f"invalid canonical root inventory: {error}") from error
    if seal_dir is not None:
        if not seal_dir.is_dir() or seal_dir.is_symlink():
            raise SelectionError("seal directory must be a real directory")
        for name, payload in (("selection.json", selection_bytes), ("contract.json", contract_bytes)):
            destination = seal_dir / name
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload)
    return ValidationPlan(
        action="dry-run",
        test=test,
        policy=policy,
        release_id=release_id,
        run_id=run_id,
        module_path=module_path,
        result_namespace=result_namespace,
        partition=text(placement, "partition"),
        constraint=text(placement, "constraint"),
        account=text(placement, "account"),
        qos=text(placement, "qos"),
        root_count=len(checks),
        checks=checks,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", type=Command, choices=tuple(Command))
    parser.add_argument("--selection", type=Path, required=True)
    parser.add_argument("--selection-digest", required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--test", required=True)
    parser.add_argument("--seal-dir", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        plan = build_plan(
            args.selection, args.selection_digest, args.contract, args.test, args.seal_dir
        )
    except SelectionError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    match args.command:
        case Command.PLAN:
            print(json.dumps(asdict(plan), sort_keys=True))
        case Command.CHECKS:
            for check in plan.checks:
                print(f"{check.module}\t{check.command}\t{check.description}")
        case Command.SHELL:
            values = (
                *plan.policy.values(), plan.module_path, plan.result_namespace,
                plan.partition, plan.constraint, plan.account, plan.qos,
            )
            print("\t".join(values))
        case unreachable:
            assert_never(unreachable)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
