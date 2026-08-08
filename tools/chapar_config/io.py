from __future__ import annotations

import json
import os
import re
import stat
from pathlib import Path
from typing import Final

import yaml
from pydantic import JsonValue, ValidationError

from tools.chapar_config.errors import ResolverError
from tools.chapar_config.models import (
    Catalog,
    CatalogRoot,
    ContainerRegistryDocument,
    JsonMapping,
    TargetRegistryDocument,
)
from tools.chapar_datacenter_artifacts import DatacenterArtifact, TargetArtifact

ROOT_DEFINITION: Final = re.compile(
    r"^root_(shared|vlad_only|hpcsim_only|architecture_limited_([a-z0-9_]+))_root-[a-f0-9]{12}$"
)


def read_authority(path: Path, label: str) -> bytes:
    """Read one regular, non-symlink authority through a single descriptor."""
    validate_input_path(path, label)
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
            metadata = os.fstat(authority.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                raise ResolverError(f"{label} input is not a regular file: {path}")
            return authority.read()
    except OSError as error:
        raise ResolverError(f"cannot open {label} authority {path}: {error}") from error
    finally:
        os.close(directory)


def validate_input_path(path: Path, label: str) -> None:
    if not path.is_absolute() or ".." in path.parts:
        raise ResolverError(f"{label} input must be absolute without traversal")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ResolverError(f"{label} input has symlink ambiguity: {current}")
    if not path.is_file():
        raise ResolverError(f"{label} input is not a regular file: {path}")


def load_json(path: Path, model: type[DatacenterArtifact], payload: bytes | None = None) -> DatacenterArtifact:
    try:
        return model.model_validate_json(payload if payload is not None else read_authority(path, "datacenter contract"))
    except (OSError, UnicodeError, ValidationError) as error:
        raise ResolverError(f"invalid JSON authority {path}: {error}") from error


def load_target_contract(path: Path, payload: bytes | None = None) -> TargetArtifact:
    try:
        return TargetArtifact.model_validate_json(payload if payload is not None else read_authority(path, "target contract"))
    except (OSError, UnicodeError, ValidationError) as error:
        raise ResolverError(f"invalid target contract {path}: {error}") from error


def load_registry[T: TargetRegistryDocument | ContainerRegistryDocument](
    path: Path, model: type[T], payload: bytes | None = None
) -> T:
    try:
        return model.model_validate_json(payload if payload is not None else read_authority(path, "registry"))
    except (OSError, UnicodeError, ValidationError) as error:
        raise ResolverError(f"invalid registry {path}: {error}") from error


def _parse_definitions(raw: JsonValue) -> tuple[CatalogRoot, ...]:
    if not isinstance(raw, list):
        raise ResolverError("software catalog definitions must be an array")
    roots: list[CatalogRoot] = []
    identities: set[str] = set()
    specs: set[str] = set()
    for entry in raw:
        if not isinstance(entry, dict) or len(entry) != 1:
            raise ResolverError("each catalog definition must have exactly one ID")
        identity, values = next(iter(entry.items()))
        match = ROOT_DEFINITION.fullmatch(identity)
        if match is None:
            continue
        if identity in identities:
            raise ResolverError(f"duplicate root ID: {identity}")
        if not isinstance(values, list) or len(values) != 1:
            raise ResolverError(f"root {identity} must contain exactly one spec")
        spec = values[0]
        if not isinstance(spec, str) or not spec:
            raise ResolverError(f"root {identity} spec must be a string")
        if spec in specs:
            raise ResolverError(f"duplicate root spec: {spec}")
        classification = match.group(1)
        architecture = match.group(2)
        roots.append(CatalogRoot(identity, spec, classification, architecture))
        identities.add(identity)
        specs.add(spec)
    if not roots:
        raise ResolverError("software catalog has no classified roots")
    return tuple(roots)


def load_catalog(path: Path, payload: bytes | None = None) -> Catalog:
    try:
        document = JsonMapping.model_validate(
            yaml.safe_load(payload if payload is not None else read_authority(path, "software catalog"))
        )
    except (OSError, UnicodeError, yaml.YAMLError, ValidationError) as error:
        raise ResolverError(f"invalid software catalog {path}: {error}") from error
    spack = document.root.get("spack")
    if not isinstance(spack, dict) or set(document.root) != {"spack"}:
        raise ResolverError("software catalog must contain exactly one spack document")
    specs = spack.get("specs")
    if specs != []:
        raise ResolverError("canonical software catalog specs must remain resolver-owned")
    return Catalog(document, _parse_definitions(spack.get("definitions")))


def canonical_json(value: JsonValue) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
