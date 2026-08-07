#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Final, Never

from registry import JsonValue

SCHEMA: Final = "https://nscaledev.github.io/chapar/schemas/software-selection/v1"
SHA256: Final = re.compile(r"^[0-9a-f]{64}$")
TOP_FIELDS: Final = frozenset({
    "schema", "schema_version", "policy", "invocation", "target_facts",
    "containers", "selected_roots", "excluded_roots", "paths",
    "authorities", "artifacts", "versions", "deferred_proofs",
})
PATH_FIELDS: Final = frozenset({
    "release_root", "release_final", "release_staging", "modulefiles",
    "install_tree", "writable_buildcache", "ccache", "container_outputs",
    "receipts", "evidence", "spack_build_stage", "image_staging",
    "validation_work", "resolver_work",
})
AUTHORITY_FIELDS: Final = frozenset({
    "software_catalog", "target_registry", "container_registry",
    "datacenter_contract", "target_contract",
})


@dataclass(frozen=True, slots=True)
class SelectionError(Exception):
    message: str

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True, slots=True)
class Selection:
    policy: dict[str, str]
    invocation: dict[str, str]
    target_facts: dict[str, JsonValue]
    containers: tuple[str, ...]
    paths: dict[str, str]
    authorities: dict[str, str]
    artifacts: dict[str, str]


def fail(message: str) -> Never:
    raise SelectionError(message)


def exact(value: JsonValue, fields: frozenset[str], label: str) -> dict[str, JsonValue]:
    if not isinstance(value, dict) or frozenset(value) != fields:
        fail(f"{label} fields mismatch: expected {','.join(sorted(fields))}")
    return value


def strings(value: JsonValue, fields: frozenset[str], label: str) -> dict[str, str]:
    raw = exact(value, fields, label)
    if any(not isinstance(item, str) or not item for item in raw.values()):
        fail(f"{label} values must be nonempty strings")
    return {key: item for key, item in raw.items() if isinstance(item, str)}


def string_list(value: JsonValue, label: str, *, unique: bool = False) -> tuple[str, ...]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        fail(f"{label} must be an array of nonempty strings")
    result = tuple(item for item in value if isinstance(item, str))
    if unique and len(result) != len(set(result)):
        fail(f"{label} must not contain duplicates")
    return result


def root_list(value: JsonValue, fields: frozenset[str], label: str) -> None:
    if not isinstance(value, list):
        fail(f"{label} must be an array")
    for index, item in enumerate(value):
        strings(item, fields, f"{label}[{index}]")


def validate_selection(value: dict[str, JsonValue]) -> Selection:
    exact(value, TOP_FIELDS, "selection")
    if value.get("schema") != SCHEMA or value.get("schema_version") != 1:
        fail("selection schema identity is unsupported")
    policy = strings(value.get("policy"), frozenset({"datacenter", "software_set", "target"}), "selection.policy")
    if policy["software_set"] not in {"vlad", "hpcsim", "all"}:
        fail("selection.policy.software_set is unsupported")
    invocation = strings(value.get("invocation"), frozenset({"release_id", "run_id"}), "selection.invocation")
    target_facts = exact(value.get("target_facts"), frozenset({"oci_platform", "native_arch", "spack_target", "llvm_targets", "cuda_arch"}), "selection.target_facts")
    for name in ("oci_platform", "native_arch", "spack_target"):
        if not isinstance(target_facts[name], str) or not target_facts[name]:
            fail(f"selection.target_facts.{name} must be a nonempty string")
    string_list(target_facts["llvm_targets"], "selection.target_facts.llvm_targets", unique=True)
    string_list(target_facts["cuda_arch"], "selection.target_facts.cuda_arch", unique=True)
    containers = string_list(value.get("containers"), "selection.containers", unique=True)
    root_list(value.get("selected_roots"), frozenset({"id", "spec", "classification"}), "selection.selected_roots")
    root_list(value.get("excluded_roots"), frozenset({"id", "spec", "reason"}), "selection.excluded_roots")
    paths = strings(value.get("paths"), PATH_FIELDS, "selection.paths")
    authorities = strings(value.get("authorities"), AUTHORITY_FIELDS, "selection.authorities")
    artifacts = strings(value.get("artifacts"), frozenset({"target_policy_sha256", "effective_manifest_sha256"}), "selection.artifacts")
    for label, digest in (*authorities.items(), *artifacts.items()):
        if SHA256.fullmatch(digest) is None:
            fail(f"selection digest is invalid: {label}")
    versions = exact(value.get("versions"), frozenset({"selection_schema", "target_registry_schema", "container_registry_schema", "resolver", "resolver_sha256", "pydantic", "PyYAML"}), "selection.versions")
    for name in ("selection_schema", "target_registry_schema", "container_registry_schema"):
        version = versions[name]
        if not isinstance(version, int) or isinstance(version, bool) or version < 1:
            fail(f"selection.versions.{name} must be a positive integer")
    for name in ("resolver", "pydantic", "PyYAML"):
        if not isinstance(versions[name], str) or not versions[name]:
            fail(f"selection.versions.{name} must be a nonempty string")
    if not isinstance(versions["resolver_sha256"], str) or SHA256.fullmatch(versions["resolver_sha256"]) is None:
        fail("selection.versions.resolver_sha256 is invalid")
    string_list(value.get("deferred_proofs"), "selection.deferred_proofs", unique=True)
    return Selection(policy, invocation, target_facts, containers, paths, authorities, artifacts)
