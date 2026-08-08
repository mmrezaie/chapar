from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Never

from tools.chapar_config.consumer_inventory import canonical_selected_roots
from tools.chapar_config.errors import ResolverError

from .models import JsonObject, JsonValue, Package, SelectionPolicy


def die(message: str) -> Never:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def unique_object(pairs: list[tuple[str, JsonValue]]) -> JsonObject:
    result: JsonObject = {}
    for key, value in pairs:
        if key in result:
            die(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json_bytes(payload: bytes, label: str) -> JsonObject:
    data = json.loads(payload, object_pairs_hook=unique_object)
    if not isinstance(data, dict):
        die(f"expected JSON object in {label}")
    return data


def read_regular_once(path: Path, label: str) -> bytes:
    if not path.is_absolute() or ".." in path.parts:
        die(f"{label} must be absolute without traversal")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            die(f"{label} must be a regular file")
        return stream.read()


def load_json(path: Path) -> JsonObject:
    return load_json_bytes(read_regular_once(path.resolve(), str(path)), str(path))


def normalize_version(version: str | None) -> str | None:
    if not version:
        return None
    normalized = version.strip().strip('"\'')
    if not normalized:
        return None
    if ":" in normalized:
        lower, _, upper = normalized.partition(":")
        if lower and lower == upper:
            return lower
    return normalized


def parse_spack_spec(spec: str) -> Package | None:
    normalized = spec.strip().strip('"\'')
    if not normalized or normalized.startswith(("$", "#")):
        return None
    root = normalized.split()[0]
    if root.startswith(("^", "[")):
        return None
    name_match = re.match(r"([A-Za-z0-9][A-Za-z0-9_.-]*)", root)
    if not name_match:
        return None
    version_match = re.search(r"@([^+~%^\s=]+)", root)
    version = normalize_version(version_match.group(1)) if version_match else None
    return Package(name=name_match.group(1), version=version, spec=normalized)


def load_selected_inventory(
    selection_path: Path,
    selection_digest_path: Path,
    catalog_path: Path,
) -> tuple[list[Package], SelectionPolicy]:
    if selection_path.is_symlink():
        die(f"selection must not be a symlink: {selection_path}")
    if selection_digest_path.is_symlink():
        die(f"selection digest must not be a symlink: {selection_digest_path}")
    expected_digest = read_regular_once(selection_digest_path, "selection digest").decode().strip()
    selection_bytes = read_regular_once(selection_path, "selection")
    if hashlib.sha256(selection_bytes).hexdigest() != expected_digest:
        die("selection digest does not match supplied bytes")

    selection = load_json_bytes(selection_bytes, "selection")
    policy = selection.get("policy")
    authorities = selection.get("authorities")
    if not isinstance(policy, dict) or not isinstance(authorities, dict):
        die("selection policy and authorities are required")
    catalog_digest = str(authorities.get("software_catalog", ""))
    catalog_bytes = read_regular_once(catalog_path, "software catalog")
    if hashlib.sha256(catalog_bytes).hexdigest() != catalog_digest:
        die("canonical software catalog digest does not match selection")

    values = tuple(str(policy.get(key, "")).strip() for key in ("datacenter", "software_set", "target"))
    if not all(values):
        die("selection policy identity is incomplete")
    selected_policy = SelectionPolicy(*values)
    if catalog_path.parts[-3:] != ("envs", "software", "spack.yaml"):
        die("software catalog must use the canonical repository path")
    target_registry_path = catalog_path.parents[2] / "containers/images/targets.json"
    target_registry_bytes = read_regular_once(target_registry_path, "target registry")
    if hashlib.sha256(target_registry_bytes).hexdigest() != str(
        authorities.get("target_registry", "")
    ):
        die("canonical target registry digest does not match selection")
    try:
        canonical_roots = canonical_selected_roots(
            catalog_path,
            catalog_bytes,
            target_registry_path,
            target_registry_bytes,
            selected_policy.software_set,
            selected_policy.target,
        )
    except ResolverError as error:
        die(f"invalid canonical inventory authority: {error}")
    roots = selection.get("selected_roots")
    if not isinstance(roots, list):
        die("selected root inventory is required")
    actual = [
        (
            str(root.get("id", "")),
            str(root.get("spec", "")),
            str(root.get("classification", "")),
        )
        for root in roots
        if isinstance(root, dict)
    ]
    expected = [
        (root.identity, root.spec, root.classification) for root in canonical_roots
    ]
    if len(actual) != len(roots) or actual != expected:
        die("selected root inventory differs from canonical catalog")
    packages = []
    for root in canonical_roots:
        package = parse_spack_spec(root.spec)
        if package is None:
            die(f"canonical root has no package: {root.identity}")
        packages.append(package)
    return sorted(packages, key=lambda package: (package.name, package.version or "")), selected_policy


def with_config_aliases(packages: list[Package], config: JsonObject) -> list[Package]:
    package_config = config.get("packages", {})
    if not isinstance(package_config, dict):
        die("config packages must be an object")
    result: list[Package] = []
    for package in packages:
        raw_settings = package_config.get(package.name, {})
        settings = raw_settings if isinstance(raw_settings, dict) else {}
        if settings.get("skip") is True:
            reason = settings.get("reason", "no reason configured")
            print(f"Skipping {package.label}: {reason}", flush=True)
            continue
        raw_aliases = settings.get("aliases", [])
        aliases = tuple(str(alias) for alias in raw_aliases) if isinstance(raw_aliases, list) else ()
        if package.name not in aliases:
            aliases = (package.name, *aliases)
        result.append(Package(package.name, package.version, package.spec, aliases))
    return result
