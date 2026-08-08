#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 -I -E containers/images/registry.py resolve --help
"""Strict, side-effect-free resolver for Chapar target/container registries."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Never

TARGET_SCHEMA: Final = "https://nscaledev.github.io/chapar/schemas/vlad-image-targets/v1"
CONTAINER_SCHEMA: Final = "https://nscaledev.github.io/chapar/schemas/vlad-image-containers/v1"
IDENTITY: Final = re.compile(r"^[a-z0-9][a-z0-9-]{0,127}$")
TARGET_ID: Final = re.compile(r"^[a-z0-9][a-z0-9_-]{0,127}$")
CATEGORY: Final = re.compile(r"^[a-z][a-z0-9_]{0,127}$")
BASE_IMAGE: Final = re.compile(r"^[a-z0-9][a-z0-9./-]{0,255}$")
CUDA_ARCH: Final = re.compile(r"^[0-9]+a?$")
OCI_DIGEST: Final = re.compile(r"^sha256:[0-9a-f]{64}$")
FLOATING: Final = frozenset({"latest", "main", "master", "head", "stable"})
JsonValue = None | bool | int | str | list["JsonValue"] | dict[str, "JsonValue"]


@dataclass(frozen=True, slots=True)
class RegistryError(Exception):
    """An untrusted registry input violates its schema or compatibility rules."""

    message: str

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True, slots=True)
class Target:
    """Architecture facts owned exclusively by targets.json."""

    identity: str
    oci_platform: str
    native_arch: str
    spack_target: str
    llvm_targets: tuple[str, ...]
    cuda_arch: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class Container:
    """Injection compatibility owned exclusively by containers.json."""

    identity: str
    base_image: str
    source_lock_category: str
    accepted_software_sets: tuple[str, ...]
    allowed_targets: tuple[str, ...]
    module_destination: str
    injection_requirements: dict[str, JsonValue]
    runtime_requirements: dict[str, JsonValue]


@dataclass(frozen=True, slots=True)
class Sources:
    """The lock categories and any resolved OCI descriptor chains."""

    status: str
    categories: frozenset[str]
    verified: dict[str, JsonValue]


def reject(message: str) -> Never:
    raise RegistryError(message)


def unique_object(pairs: list[tuple[str, JsonValue]]) -> dict[str, JsonValue]:
    result: dict[str, JsonValue] = {}
    for key, value in pairs:
        if key in result:
            reject(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def document(source: Path | bytes, label: str) -> dict[str, JsonValue]:
    try:
        payload = source.read_bytes() if isinstance(source, Path) else source
        value: JsonValue = json.loads(payload, object_pairs_hook=unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        reject(f"cannot read {label}: {error}")
    if not isinstance(value, dict):
        reject(f"{label} must be a JSON object")
    return value


def exact(value: JsonValue, fields: frozenset[str], label: str) -> dict[str, JsonValue]:
    if not isinstance(value, dict) or frozenset(value) != fields:
        reject(f"{label} must contain exactly: {','.join(sorted(fields))}")
    return value


def string(value: JsonValue, label: str) -> str:
    if not isinstance(value, str) or not value:
        reject(f"{label} must be a nonempty string")
    return value


def strings(value: JsonValue, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) and item for item in value):
        reject(f"{label} must be a nonempty string array")
    result = tuple(item for item in value if isinstance(item, str))
    if len(result) != len(set(result)):
        reject(f"{label} must not contain duplicates")
    return result


def identity(value: str, label: str) -> str:
    if IDENTITY.fullmatch(value) is None:
        reject(f"{label} is malformed")
    return value


def target_identity(value: str, label: str) -> str:
    if TARGET_ID.fullmatch(value) is None:
        reject(f"{label} is malformed")
    return value


def category(value: str, label: str) -> str:
    if CATEGORY.fullmatch(value) is None:
        reject(f"{label} is malformed")
    return value


def parse_targets(source: Path | bytes) -> dict[str, Target]:
    root = exact(document(source, "target registry"), frozenset({"schema", "schema_version", "targets"}), "target registry")
    if root["schema"] != TARGET_SCHEMA or root["schema_version"] != 1:
        reject("target registry schema identity is unsupported")
    raw_targets = root["targets"]
    if not isinstance(raw_targets, dict) or not raw_targets:
        reject("target registry targets must be a nonempty object")
    parsed: dict[str, Target] = {}
    for raw_identity, raw_target in raw_targets.items():
        target_id = target_identity(raw_identity, "target ID")
        entry = exact(raw_target, frozenset({"oci_platform", "native_arch", "spack_target", "llvm_targets", "cuda_arch"}), f"target {target_id}")
        oci_platform = string(entry["oci_platform"], f"target {target_id} oci_platform")
        native_arch = string(entry["native_arch"], f"target {target_id} native_arch")
        spack_target = string(entry["spack_target"], f"target {target_id} spack_target")
        llvm_targets = strings(entry["llvm_targets"], f"target {target_id} llvm_targets")
        cuda_arch = strings(entry["cuda_arch"], f"target {target_id} cuda_arch")
        if oci_platform not in {"linux/amd64", "linux/arm64"} or native_arch not in {"x86_64", "aarch64"}:
            reject(f"target {target_id} has unsupported architecture facts")
        if (native_arch, oci_platform) not in {("x86_64", "linux/amd64"), ("aarch64", "linux/arm64")}:
            reject(f"target {target_id} native and OCI architecture disagree")
        if not all(CUDA_ARCH.fullmatch(item) for item in cuda_arch):
            reject(f"target {target_id} CUDA architectures are malformed")
        parsed[target_id] = Target(target_id, oci_platform, native_arch, spack_target, llvm_targets, cuda_arch)
    return parsed


def parse_sources(source: Path | bytes) -> Sources:
    root = document(source, "source lock")
    status = string(root.get("status"), "source lock status")
    verified_raw = root.get("verified")
    unresolved_raw = root.get("unresolved")
    if not isinstance(verified_raw, dict) or not isinstance(unresolved_raw, list):
        reject("source lock must expose verified and unresolved categories")
    categories = set(verified_raw)
    for raw_entry in unresolved_raw:
        if not isinstance(raw_entry, dict):
            reject("source lock unresolved entry must be an object")
        categories.add(category(string(raw_entry.get("category"), "source lock unresolved category"), "source lock unresolved category"))
    verified: dict[str, JsonValue] = {}
    for raw_category, raw_entry in verified_raw.items():
        verified[category(raw_category, "source lock verified category")] = raw_entry
    return Sources(status, frozenset(categories), verified)


def parse_containers(source: Path | bytes, targets: dict[str, Target], sources: Sources) -> dict[str, Container]:
    root = exact(document(source, "container registry"), frozenset({"schema", "schema_version", "containers"}), "container registry")
    if root["schema"] != CONTAINER_SCHEMA or root["schema_version"] != 1:
        reject("container registry schema identity is unsupported")
    raw_containers = root["containers"]
    if not isinstance(raw_containers, dict) or not raw_containers:
        reject("container registry containers must be a nonempty object")
    parsed: dict[str, Container] = {}
    fields = frozenset({"base_image", "source_lock_category", "accepted_software_sets", "allowed_targets", "module_destination", "injection_requirements", "runtime_requirements"})
    for raw_identity, raw_container in raw_containers.items():
        container_id = identity(raw_identity, "container ID")
        entry = exact(raw_container, fields, f"container {container_id}")
        base_image = string(entry["base_image"], f"container {container_id} base_image")
        category_id = category(string(entry["source_lock_category"], f"container {container_id} source_lock_category"), f"container {container_id} source_lock_category")
        software_sets = strings(entry["accepted_software_sets"], f"container {container_id} accepted_software_sets")
        allowed_targets = strings(entry["allowed_targets"], f"container {container_id} allowed_targets")
        module_destination = string(entry["module_destination"], f"container {container_id} module_destination")
        injection = exact(entry["injection_requirements"], frozenset({"closure_deptypes", "preserve_base_environment", "prefix_policy"}), f"container {container_id} injection_requirements")
        runtime = exact(entry["runtime_requirements"], frozenset({"activation", "require_module_command", "required_roles"}), f"container {container_id} runtime_requirements")
        if BASE_IMAGE.fullmatch(base_image) is None or ":" in base_image or "@" in base_image:
            reject(f"container {container_id} base_image must be an untagged registry identity")
        if category_id not in sources.categories:
            reject(f"container {container_id} source lock category is unknown: {category_id}")
        if any(item not in {"vlad", "hpcsim", "all"} for item in software_sets):
            reject(f"container {container_id} has an unknown software set")
        if any(item not in targets for item in allowed_targets):
            reject(f"container {container_id} references an unknown target")
        if not module_destination.startswith("/") or ".." in Path(module_destination).parts:
            reject(f"container {container_id} module destination is not an absolute normalized path")
        if injection["closure_deptypes"] != ["link", "run"] or injection["preserve_base_environment"] is not True or injection["prefix_policy"] != "build-time-absolute":
            reject(f"container {container_id} injection requirements are unsupported")
        if runtime["activation"] != "module-use-opt-in" or runtime["require_module_command"] is not True or runtime["required_roles"] != ["builders", "validators", "publishers"]:
            reject(f"container {container_id} runtime requirements are unsupported")
        parsed[container_id] = Container(container_id, base_image, category_id, software_sets, allowed_targets, module_destination, injection, runtime)
    return parsed


def validate_oci_chains(sources: Sources, targets: dict[str, Target]) -> None:
    for category, entry in sources.verified.items():
        if not isinstance(entry, dict):
            continue
        platforms = entry.get("platforms")
        if platforms is None:
            continue
        if not isinstance(platforms, dict):
            reject(f"source lock category {category} platforms must be an object")
        chains: dict[str, tuple[str, str]] = {}
        for target_id, raw_platform in platforms.items():
            target = targets.get(target_id)
            if target is None:
                reject(f"source lock category {category} references an unknown target: {target_id}")
            platform = exact(raw_platform, frozenset({"oci_platform", "descriptor_digest", "config_digest"}), f"source lock category {category} platform {target_id}")
            oci_platform = string(platform["oci_platform"], f"source lock category {category} OCI platform")
            descriptor = string(platform["descriptor_digest"], f"source lock category {category} descriptor digest")
            config = string(platform["config_digest"], f"source lock category {category} config digest")
            if oci_platform != target.oci_platform or OCI_DIGEST.fullmatch(descriptor) is None or OCI_DIGEST.fullmatch(config) is None:
                reject(f"source lock category {category} has an inconsistent OCI descriptor chain")
            existing = chains.get(oci_platform)
            if existing is None:
                chains[oci_platform] = (descriptor, config)
            elif existing != (descriptor, config):
                reject(f"source lock category {category} has inconsistent descriptors for OCI platform {oci_platform}")


def resolve(container_id: str, software_set: str, target_id: str, targets: dict[str, Target], containers: dict[str, Container], sources: Sources) -> dict[str, JsonValue]:
    container = containers.get(container_id)
    target = targets.get(target_id)
    if container is None:
        reject(f"unknown container: {container_id}")
    if target is None:
        reject(f"unknown target: {target_id}")
    if software_set not in container.accepted_software_sets:
        reject(f"container {container_id} does not accept software set: {software_set}")
    if target_id not in container.allowed_targets:
        reject(f"container {container_id} does not allow target: {target_id}")
    state = "verified" if container.source_lock_category in sources.verified else "unresolved"
    return {
        "container": {"id": container.identity, "base_image": container.base_image, "source_lock_category": container.source_lock_category, "module_destination": container.module_destination, "injection_requirements": container.injection_requirements, "runtime_requirements": container.runtime_requirements},
        "software_set": software_set,
        "source_lock": {"status": sources.status, "category_state": state},
        "target": {"id": target.identity, "oci_platform": target.oci_platform, "native_arch": target.native_arch, "spack_target": target.spack_target, "llvm_targets": list(target.llvm_targets), "cuda_arch": list(target.cuda_arch)},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    command = subcommands.add_parser("resolve", help="resolve one explicitly selected container/target tuple")
    command.add_argument("--targets", type=Path, required=True)
    command.add_argument("--containers", type=Path, required=True)
    command.add_argument("--sources", type=Path, required=True)
    command.add_argument("--container", required=True)
    command.add_argument("--software-set", required=True)
    command.add_argument("--target", required=True)
    arguments = parser.parse_args()
    try:
        targets = parse_targets(arguments.targets)
        sources = parse_sources(arguments.sources)
        containers = parse_containers(arguments.containers, targets, sources)
        validate_oci_chains(sources, targets)
        print(json.dumps(resolve(arguments.container, arguments.software_set, arguments.target, targets, containers, sources), indent=2, sort_keys=True))
    except RegistryError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
