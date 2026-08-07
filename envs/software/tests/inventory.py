#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      uv run envs/software/tests/inventory.py envs/software/tests/fixtures/historical-root-inventory.json
# 3. Or make executable and run:
#      chmod +x envs/software/tests/inventory.py && ./envs/software/tests/inventory.py envs/software/tests/fixtures/historical-root-inventory.json
# ──────────────────

from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Never, TypedDict

ORIGIN_SOURCES: Final = {
    "shared": ("hpcsim", "vlad"),
    "vlad-only": ("vlad",),
    "hpcsim-only": ("hpcsim",),
}
PACKAGE_NAME: Final = re.compile(r"^([a-z0-9][a-z0-9-]*)")
ROOT_FORMAT: Final = "chapar-historical-root-inventory-v1"
POLICY_FORMAT: Final = "chapar-protected-state-v1"

type JsonScalar = str | int | float | bool | None
type JsonValue = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
type JsonObject = dict[str, JsonValue]


class InventoryCounts(TypedDict):
    vlad: int
    hpcsim: int
    shared: int
    vlad_only: int
    hpcsim_only: int
    variant_difference_packages: int


class SpecDifferences(TypedDict):
    shared: list[str]
    vlad_only: list[str]
    hpcsim_only: list[str]


class PackageDifferences(TypedDict):
    vlad_only: list[str]
    hpcsim_only: list[str]


class VariantDifference(TypedDict):
    vlad: list[str]
    hpcsim: list[str]


class InventoryReport(TypedDict):
    counts: InventoryCounts
    exact_spec_differences: SpecDifferences
    package_name_differences: PackageDifferences
    variant_differences: dict[str, VariantDifference]


@dataclass(frozen=True, slots=True)
class InventoryError(Exception):
    message: str

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True, slots=True)
class Root:
    identifier: str
    spec: str
    origin: str
    sources: tuple[str, ...]
    package: str


def fail(message: str) -> Never:
    raise InventoryError(message)


def mapping(value: JsonValue, label: str) -> JsonObject:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def string(value: JsonValue, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty string")
    return value


def strings(value: JsonValue, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        fail(f"{label} must be a non-empty string list")
    return tuple(item for item in value if isinstance(item, str))


def normalized_spec(value: JsonValue, label: str) -> tuple[str, str]:
    specification = string(value, label)
    normalized = " ".join(specification.split())
    if specification != normalized:
        fail(f"{label} is not normalized")
    name = PACKAGE_NAME.match(normalized)
    if name is None:
        fail(f"{label} has no package name")
    return normalized, name.group(1)


def load_json(path: Path) -> JsonObject:
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as error:
        raise InventoryError(f"cannot read {path}: {error}") from error
    try:
        document: JsonValue = json.loads(content)
        return mapping(document, str(path))
    except json.JSONDecodeError as error:
        raise InventoryError(f"malformed JSON: {path}: {error.msg}") from error


def load_roots(path: Path) -> tuple[Root, ...]:
    document = load_json(path)
    if document.get("format") != ROOT_FORMAT:
        fail("unsupported inventory format")
    raw_roots = document.get("roots")
    if not isinstance(raw_roots, list) or not raw_roots:
        fail("roots must be a non-empty list")
    roots: list[Root] = []
    identifiers: set[str] = set()
    specifications: set[str] = set()
    package_shared_specs: dict[str, set[str]] = defaultdict(set)
    for position, raw_root in enumerate(raw_roots):
        root = mapping(raw_root, f"roots[{position}]")
        identifier = string(root.get("id"), f"roots[{position}].id")
        if identifier in identifiers:
            fail(f"duplicate root id: {identifier}")
        identifiers.add(identifier)
        spec, package = normalized_spec(root.get("spec"), f"roots[{position}].spec")
        if spec in specifications:
            fail(f"duplicate root spec: {spec}")
        specifications.add(spec)
        origin = root.get("origin")
        if origin is None:
            fail(f"missing origin: roots[{position}]")
        origin_name = string(origin, f"roots[{position}].origin")
        expected_sources = ORIGIN_SOURCES.get(origin_name)
        if expected_sources is None:
            fail(f"unsupported origin: {origin_name}")
        sources = tuple(sorted(strings(root.get("historical_sources"), f"roots[{position}].historical_sources")))
        if sources != expected_sources:
            fail(f"origin/source mismatch for {identifier}")
        if origin_name == "shared":
            package_shared_specs[package].add(spec)
        roots.append(Root(identifier, spec, origin_name, sources, package))
    for package, specs in package_shared_specs.items():
        if len(specs) > 1:
            fail(f"shared provenance forbids variants of package: {package}")
    return tuple(roots)


def report(roots: tuple[Root, ...]) -> InventoryReport:
    by_origin: dict[str, list[Root]] = defaultdict(list)
    by_package: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    for root in roots:
        by_origin[root.origin].append(root)
        for source in root.sources:
            by_package[root.package][source].add(root.spec)
    package_only = PackageDifferences(vlad_only=[], hpcsim_only=[])
    variants: dict[str, VariantDifference] = {}
    for package, source_specs in sorted(by_package.items()):
        vlad_specs = source_specs.get("vlad", set())
        hpcsim_specs = source_specs.get("hpcsim", set())
        if not hpcsim_specs:
            package_only["vlad_only"].append(package)
        elif not vlad_specs:
            package_only["hpcsim_only"].append(package)
        elif vlad_specs != hpcsim_specs:
            variants[package] = {"vlad": sorted(vlad_specs), "hpcsim": sorted(hpcsim_specs)}
    def specs(origin: str) -> list[str]:
        return sorted(root.spec for root in by_origin[origin])
    return {
        "counts": {
            "vlad": sum("vlad" in root.sources for root in roots),
            "hpcsim": sum("hpcsim" in root.sources for root in roots),
            "shared": len(by_origin["shared"]),
            "vlad_only": len(by_origin["vlad-only"]),
            "hpcsim_only": len(by_origin["hpcsim-only"]),
            "variant_difference_packages": len(variants),
        },
        "exact_spec_differences": {"shared": specs("shared"), "vlad_only": specs("vlad-only"), "hpcsim_only": specs("hpcsim-only")},
        "package_name_differences": package_only,
        "variant_differences": variants,
    }


def validate_protected_policy(path: Path) -> None:
    document = load_json(path)
    if document.get("format") != POLICY_FORMAT:
        fail("unsupported protected-state format")
    roots = tuple(sorted(strings(document.get("legacy_deployment_roots"), "legacy_deployment_roots")))
    if roots != ("/resources/chapar/hpcsim", "/resources/chapar/vlad"):
        fail("protected legacy roots must be exact")
    files = document.get("tracked_files")
    if not isinstance(files, list) or len(files) != 2:
        fail("tracked_files must contain both protected files")
    expected_paths = {"envs/hpcsim/spack.lock", "containers/images/sources-lock.json"}
    actual_paths = {string(mapping(item, "tracked_files item").get("path"), "tracked_files path") for item in files}
    if actual_paths != expected_paths:
        fail("tracked_files paths must be exact")
    for item in files:
        value = mapping(item, "tracked_files item")
        string(value.get("head_blob"), "tracked_files head_blob")
        string(value.get("sha256"), "tracked_files sha256")


def parse_arguments(arguments: list[str]) -> tuple[Path | None, Path | None, Path | None]:
    if arguments[:1] == ["--validate-protected-policy"] and len(arguments) == 2:
        return None, None, Path(arguments[1])
    if not arguments:
        fail("usage: inventory.py INVENTORY.json [--output REPORT.json]")
    if len(arguments) == 1:
        return Path(arguments[0]), None, None
    if len(arguments) == 3 and arguments[1] == "--output":
        return Path(arguments[0]), Path(arguments[2]), None
    fail("usage: inventory.py INVENTORY.json [--output REPORT.json]")


def main(arguments: list[str]) -> int:
    inventory_path, output_path, policy_path = parse_arguments(arguments)
    if policy_path is not None:
        validate_protected_policy(policy_path)
        print("protected-state policy valid")
        return 0
    if inventory_path is None:
        fail("inventory path is required")
    rendered = json.dumps(report(load_roots(inventory_path)), indent=2, sort_keys=True) + "\n"
    if output_path is None:
        print(rendered, end="")
    else:
        output_path.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except InventoryError as error:
        print(f"inventory error: {error}", file=sys.stderr)
        raise SystemExit(2) from error
