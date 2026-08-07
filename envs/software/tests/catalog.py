#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["PyYAML>=6,<7"]
# ///

# ─── How to run ───
# uv run envs/software/tests/catalog.py envs/software/spack.yaml --set all
# ──────────────────

from __future__ import annotations

import hashlib
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Final, Never, TypeAlias

import yaml

LEAF_PREFIXES: Final = {
    "root_shared_": ("shared", ("vlad", "hpcsim"), ()),
    "root_vlad_only_": ("vlad-only", ("vlad",), ()),
    "root_hpcsim_only_": ("hpcsim-only", ("hpcsim",), ()),
    "root_architecture_limited_x86_64_": ("architecture-limited", ("hpcsim",), ("x86_64",)),
}
SETS: Final = ("vlad", "hpcsim", "all")
ARCHITECTURES: Final = ("x86_64", "aarch64")
README_BEGIN: Final = "<!-- BEGIN GENERATED CATALOG INVENTORY -->"
README_END: Final = "<!-- END GENERATED CATALOG INVENTORY -->"
YamlScalar: TypeAlias = str | int | float | bool | None
YamlValue: TypeAlias = YamlScalar | list["YamlValue"] | dict[str, "YamlValue"]


@dataclass(frozen=True, slots=True)
class CatalogError(Exception):
    message: str

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True, slots=True)
class Root:
    identifier: str
    specification: str
    origin: str
    sets: tuple[str, ...]
    architectures: tuple[str, ...]


class CatalogLoader(yaml.SafeLoader):
    pass


def construct_mapping(loader: CatalogLoader, node: yaml.MappingNode, deep: bool = False) -> dict[str, YamlValue]:
    """Reject duplicate keys before PyYAML silently overwrites them."""
    result: dict[str, YamlValue] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str):
            raise CatalogError("YAML mapping key must be a string")
        if key in result:
            if key.startswith("root_"):
                raise CatalogError(f"duplicate root id: {key.rsplit('_', 1)[-1]}")
            raise CatalogError(f"duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


CatalogLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)


def fail(message: str) -> Never:
    raise CatalogError(message)


def mapping(value: YamlValue, label: str) -> dict[str, YamlValue]:
    if not isinstance(value, dict):
        fail(f"{label} must be a mapping")
    return value


def strings(value: YamlValue, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        fail(f"{label} must be a non-empty string list")
    return tuple(item for item in value if isinstance(item, str))


def load_document(path: Path) -> dict[str, YamlValue]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        raise CatalogError(f"cannot read {path}: {error}") from error
    try:
        loaded = yaml.load(raw, Loader=CatalogLoader)
    except (yaml.YAMLError, CatalogError) as error:
        raise CatalogError(f"malformed YAML: {error}") from error
    return mapping(loaded, "catalog document")


def leaf_metadata(name: str) -> tuple[str, tuple[str, ...], tuple[str, ...], str] | None:
    for prefix, metadata in LEAF_PREFIXES.items():
        if name.startswith(prefix):
            origin, sets, architectures = metadata
            return origin, sets, architectures, name.removeprefix(prefix)
    return None


def load_roots(path: Path) -> tuple[Root, ...]:
    document = load_document(path)
    spack = mapping(document.get("spack"), "spack")
    definitions = spack.get("definitions")
    if not isinstance(definitions, list):
        fail("spack.definitions must be a list")
    if spack.get("specs") != []:
        fail("spack.specs must be an empty resolver-owned list")
    roots: list[Root] = []
    specifications: set[str] = set()
    identifiers: set[str] = set()
    for index, raw_definition in enumerate(definitions):
        definition = mapping(raw_definition, f"definitions[{index}]")
        if len(definition) != 1:
            fail(f"definitions[{index}] must have one key")
        name, value = next(iter(definition.items()))
        metadata = leaf_metadata(name)
        if metadata is None:
            if name.startswith("root_architecture_limited_"):
                fail(f"unsupported architecture tag: {name}")
            if name.startswith("root_"):
                fail(f"missing origin classification: {name}")
            continue
        origin, sets, architectures, identifier = metadata
        if origin == "architecture-limited" and not architectures:
            fail(f"unsupported architecture tag: {name}")
        if identifier in identifiers:
            fail(f"duplicate root id: {identifier}")
        identifiers.add(identifier)
        specifications_for_root = strings(value, name)
        if len(specifications_for_root) != 1:
            if len(set(specifications_for_root)) != len(specifications_for_root):
                fail(f"duplicate root spec: {specifications_for_root[0]}")
            fail(f"{name} must contain exactly one root spec")
        specification = specifications_for_root[0]
        if specification in specifications:
            fail(f"duplicate root spec: {specification}")
        specifications.add(specification)
        roots.append(Root(identifier, specification, origin, sets, architectures))
    if not roots:
        fail("catalog has no root definitions")
    for root in roots:
        expected_identifier = f"root-{hashlib.sha256(root.specification.encode()).hexdigest()[:12]}"
        if root.identifier != expected_identifier:
            fail(f"root id does not match specification: {root.identifier}")
    return tuple(sorted(roots, key=lambda root: root.specification))


def selected(roots: tuple[Root, ...], software_set: str, architecture: str) -> tuple[tuple[Root, ...], tuple[Root, ...]]:
    if software_set not in SETS:
        fail(f"unsupported software set: {software_set}")
    if architecture not in ARCHITECTURES:
        fail(f"unsupported architecture tag: {architecture}")
    selected_roots: list[Root] = []
    exclusions: list[Root] = []
    for root in roots:
        included = software_set == "all" or software_set in root.sets
        compatible = not root.architectures or architecture in root.architectures
        if included and compatible:
            selected_roots.append(root)
        elif included and root.architectures:
            exclusions.append(root)
    return tuple(selected_roots), tuple(exclusions)


def source_report(roots: tuple[Root, ...]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {"shared": [], "vlad-only": [], "hpcsim-only": [], "architecture-limited": []}
    for root in roots:
        grouped[root.origin].append(root.specification)
    return grouped


def variant_differences(roots: tuple[Root, ...]) -> dict[str, dict[str, list[str]]]:
    by_package: dict[str, dict[str, list[str]]] = {}
    for root in roots:
        package = root.specification.split("@", 1)[0].split("+", 1)[0].split("~", 1)[0].split(" ", 1)[0]
        entry = by_package.setdefault(package, {"vlad": [], "hpcsim": []})
        for software_set in root.sets:
            entry[software_set].append(root.specification)
    return {package: values for package, values in sorted(by_package.items()) if values["vlad"] and values["hpcsim"] and values["vlad"] != values["hpcsim"]}


def render_readme(roots: tuple[Root, ...]) -> str:
    groups = source_report(roots)
    hpcsim_not_vlad = groups["hpcsim-only"] + groups["architecture-limited"]
    lines = [
        "# Chapar software catalog",
        "",
        "`spack.yaml` is the sole active root-spec and package-policy source. Its `specs:` list is intentionally empty: a later resolver owns effective selection and generated manifests.",
        "",
        "Target-native, Spack, LLVM, and CUDA architecture values belong to the target registry. The only architecture metadata here is the `x86_64` selection tag for historical Intel roots.",
        "",
        README_BEGIN,
        "## Generated exact inventory",
        "",
        "This section is rendered from `spack.yaml` by `tests/catalog.py`; do not edit it manually.",
        "",
        "The [frozen historical inventory](tests/fixtures/historical-root-inventory.json) preserves 90 exact historical root specs: 42 Vlad, 75 HPCSim, 48 exact HPCSim-not-Vlad entries, and 10 historical variant-difference packages. The target-neutral catalog retains the 42/75 compositions (73 HPCSim roots on ARM), while its logical union has 81 roots because nine CUDA-architecture-only legacy duplicates collapse into shared roots.",
        "",
        f"- Shared: {len(groups['shared'])}",
        f"- Vlad-only: {len(groups['vlad-only'])}",
        f"- HPCSim-only: {len(groups['hpcsim-only'])}",
        f"- Architecture-limited: {len(groups['architecture-limited'])} (x86_64 only)",
        "",
        "### HPCSim-not-Vlad",
        "",
    ]
    lines.extend(f"- `{specification}`" for specification in hpcsim_not_vlad)
    lines.extend(["", "### Historical variant differences", ""])
    for package, values in variant_differences(roots).items():
        lines.append(f"- `{package}`: Vlad `{values['vlad'][0]}`; HPCSim `{values['hpcsim'][0]}`")
    lines.extend([README_END, ""])
    return "\n".join(lines)


def parse_arguments(arguments: list[str]) -> tuple[Path, str, str, Path | None, Path | None, bool]:
    if not arguments:
        fail("usage: catalog.py MANIFEST --set {vlad,hpcsim,all} [--arch ARCH] [--output PATH] [--check-readme PATH] [--render-readme]")
    manifest = Path(arguments[0])
    software_set = "all"
    architecture = "x86_64"
    output: Path | None = None
    readme: Path | None = None
    render = False
    index = 1
    while index < len(arguments):
        option = arguments[index]
        if option == "--render-readme":
            render = True
            index += 1
        elif option in {"--set", "--arch", "--output", "--check-readme"} and index + 1 < len(arguments):
            value = arguments[index + 1]
            if option == "--set":
                software_set = value
            elif option == "--arch":
                architecture = value
            elif option == "--output":
                output = Path(value)
            else:
                readme = Path(value)
            index += 2
        else:
            fail(f"invalid argument: {option}")
    return manifest, software_set, architecture, output, readme, render


def main(arguments: list[str]) -> int:
    manifest, software_set, architecture, output, readme, render = parse_arguments(arguments)
    roots = load_roots(manifest)
    if render:
        print(render_readme(roots), end="")
        return 0
    if readme is not None:
        if readme.read_text(encoding="utf-8") != render_readme(roots):
            fail("generated README is stale")
        print("catalog README is current")
        return 0
    selected_roots, exclusions = selected(roots, software_set, architecture)
    rendered = json.dumps({"architecture": architecture, "exclusions": [asdict(root) for root in exclusions], "root_count": len(selected_roots), "roots": [asdict(root) for root in selected_roots], "software_set": software_set}, indent=2, sort_keys=True) + "\n"
    if output is None:
        print(rendered, end="")
    else:
        output.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except CatalogError as error:
        print(f"catalog error: {error}", file=sys.stderr)
        raise SystemExit(2) from error
