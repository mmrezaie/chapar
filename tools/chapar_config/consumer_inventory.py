from __future__ import annotations

from pathlib import Path

from tools.chapar_config.errors import ResolverError
from tools.chapar_config.io import load_catalog, load_registry
from tools.chapar_config.models import CatalogRoot, TargetRegistryDocument
from tools.chapar_config.resolve import select_catalog_roots
from tools.chapar_datacenter_models import SoftwareSet


def canonical_selected_roots(
    catalog_path: Path,
    catalog_bytes: bytes,
    target_registry_path: Path,
    target_registry_bytes: bytes,
    software_set_name: str,
    target_id: str,
) -> tuple[CatalogRoot, ...]:
    catalog = load_catalog(catalog_path, catalog_bytes)
    targets = load_registry(
        target_registry_path, TargetRegistryDocument, target_registry_bytes
    )
    try:
        software_set = SoftwareSet(software_set_name)
    except ValueError as error:
        raise ResolverError(f"unsupported software set: {software_set_name}") from error
    target = targets.targets.get(target_id)
    if target is None:
        raise ResolverError(f"canonical target registry lacks target: {target_id}")
    selected, _ = select_catalog_roots(
        catalog.roots, software_set, target.native_arch
    )
    return selected
