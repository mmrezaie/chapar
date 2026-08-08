from __future__ import annotations

import json
from hashlib import sha256
from pathlib import Path
from typing import Final

from pydantic import JsonValue

from tools.chapar_datacenter_models import DatacenterContext, JsonDocument

ROOT: Final = Path(__file__).resolve().parents[1]
TEMPLATE: Final = ROOT / "cookiecutter/chapar-datacenter"
SCHEMAS: Final = ROOT / "datacenters/schemas"
TARGETS: Final = ROOT / "containers/images/targets.json"
CONTAINERS: Final = ROOT / "containers/images/containers.json"
TOOL_VERSION: Final = "1.0.0"


def sha256_bytes(content: bytes) -> str:
    return sha256(content).hexdigest()


def sha256_files(paths: tuple[Path, ...]) -> str:
    digest = sha256()
    for path in paths:
        digest.update(path.relative_to(ROOT).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def context_digest(context: DatacenterContext) -> str:
    document = JsonDocument.model_validate(context.model_dump(mode="json")).root
    canonical = json.dumps(document, separators=(",", ":"), sort_keys=True).encode()
    return sha256_bytes(canonical)


def build_provenance(
    context: DatacenterContext, dependencies: dict[str, str]
) -> dict[str, JsonValue]:
    template_files = (
        TEMPLATE / "cookiecutter.json",
        TEMPLATE / "hooks/post_gen_project.py",
        TEMPLATE / "{{cookiecutter.datacenter_id}}/.chapar-payload.json",
    )
    tool_files = (
        ROOT / "tools/chapar_datacenter_template.py",
        ROOT / "tools/chapar_datacenter_rendering.py",
        ROOT / "tools/chapar_datacenter_models.py",
        ROOT / "tools/chapar_datacenter_artifacts.py",
        Path(__file__),
    )
    authority_files = {
        "container_registry": CONTAINERS,
        "datacenter_schema": SCHEMAS / "datacenter.schema.json",
        "target_contract_schema": SCHEMAS / "target-contract.schema.json",
        "target_registry": TARGETS,
    }
    return JsonDocument.model_validate(
        {
            "template": {
                "name": "chapar-datacenter",
                "version": context.template_version,
                "sha256": sha256_files(template_files),
            },
            "context_sha256": context_digest(context),
            "tool": {
                "name": "chapar_datacenter_template",
                "version": TOOL_VERSION,
                "sha256": sha256_files(tool_files),
                "dependencies": dependencies,
            },
            "authority_sha256": {
                name: sha256_bytes(path.read_bytes())
                for name, path in sorted(authority_files.items())
            },
        }
    ).root
