from __future__ import annotations

import re
import shutil
import subprocess
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Final, override

import yaml
from jsonschema import Draft202012Validator
from pydantic import JsonValue, ValidationError

from tools.chapar_datacenter_artifacts import (
    DatacenterArtifact,
    Provenance,
    TargetArtifact,
)
from tools.chapar_datacenter_models import (
    ContainerRegistry,
    DatacenterContext,
    GeneratedPayload,
    JsonDocument,
    TargetRegistry,
)
from tools.chapar_datacenter_provenance import (
    CONTAINERS,
    SCHEMAS,
    TARGETS,
    TEMPLATE,
    build_provenance,
)

SECRET_KEY: Final = re.compile(
    r"(?im)^\s*[a-z0-9_-]*(secret|password|token|credential)[a-z0-9_-]*\s*:"
)
PLACEHOLDER: Final = re.compile(r"(?i)(replace[_-]|placeholder|change[_-]?me)")
EXPECTED_FILES: Final = {"datacenter.json"}


class TemplateError(Exception):
    def __init__(self, message: str) -> None:
        self.message: str = message
        super().__init__(message)

    @override
    def __str__(self) -> str:
        return self.message


def load_json(path: Path) -> JsonDocument:
    try:
        return JsonDocument.model_validate_json(path.read_text(encoding="utf-8"))
    except (OSError, ValidationError) as error:
        raise TemplateError(f"cannot read JSON {path}: {error}") from error


def package_versions() -> dict[str, str]:
    dependencies: dict[str, str] = {}
    for package in ("cookiecutter", "jsonschema", "pydantic", "PyYAML"):
        try:
            dependencies[package] = version(package)
        except PackageNotFoundError as error:
            raise TemplateError(
                f"required isolated dependency is unavailable: {package}"
            ) from error
    return dependencies


def validate_context_source(path: Path) -> DatacenterContext:
    try:
        source = path.read_bytes()
        text = source.decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise TemplateError(f"cannot read context {path}: {error}") from error
    if SECRET_KEY.search(text):
        raise TemplateError("secret or credential fields are forbidden")
    if PLACEHOLDER.search(text):
        raise TemplateError("placeholder values are forbidden")
    try:
        yaml_document = JsonDocument.model_validate(yaml.safe_load(text))
        context = DatacenterContext.model_validate(yaml_document.root)
    except (yaml.YAMLError, ValidationError) as error:
        raise TemplateError(f"invalid context: {error}") from error
    return context


def validate_references(context: DatacenterContext) -> None:
    try:
        targets = TargetRegistry.model_validate(load_json(TARGETS).root)
        containers = ContainerRegistry.model_validate(load_json(CONTAINERS).root)
    except ValidationError as error:
        raise TemplateError(f"invalid global registry: {error}") from error
    for target in context.targets:
        if target.target not in targets.targets:
            raise TemplateError(f"unknown target: {target.target}")
        for selection in target.container_selections:
            container = containers.containers.get(selection.container)
            if container is None:
                raise TemplateError(f"unknown container: {selection.container}")
            if selection.software_set not in container.accepted_software_sets:
                raise TemplateError(
                    f"container {selection.container} rejects software set {selection.software_set}"
                )
            if target.target not in container.allowed_targets:
                raise TemplateError(
                    f"container {selection.container} rejects target {target.target}"
                )


def provenance(context: DatacenterContext) -> dict[str, JsonValue]:
    return build_provenance(context, package_versions())


def build_payload(context: DatacenterContext) -> GeneratedPayload:
    validate_references(context)
    shared_provenance = provenance(context)
    datacenter: dict[str, JsonValue] = {
        "schema": "https://nscaledev.github.io/chapar/schemas/datacenter/v1",
        "schema_version": 1,
        "datacenter_id": context.datacenter_id,
        "status": context.status,
        "description": context.description,
        "targets": [target.target for target in context.targets],
        "provenance": shared_provenance,
    }
    contracts: dict[str, dict[str, JsonValue]] = {}
    for target in context.targets:
        target_document = JsonDocument.model_validate(
            target.model_dump(mode="json")
        ).root
        contracts[target.target] = {
            "schema": "https://nscaledev.github.io/chapar/schemas/target-contract/v1",
            "schema_version": 1,
            "datacenter_id": context.datacenter_id,
            "status": context.status,
            **target_document,
            "provenance": shared_provenance,
        }
    return GeneratedPayload(datacenter=datacenter, contracts=contracts)


def reject_ambiguous_output(output_root: Path, datacenter_id: str) -> Path:
    datacenters_root = output_root / "datacenters"
    destination = datacenters_root / datacenter_id
    for candidate in (output_root, datacenters_root, destination):
        if candidate.is_symlink():
            raise TemplateError(f"output path has symlink ambiguity: {candidate}")
    if destination.exists() or destination.is_symlink():
        raise TemplateError(f"data-center directory already exists: {destination}")
    return destination


def validate_document(document: JsonDocument, schema_name: str) -> None:
    schema = load_json(SCHEMAS / schema_name)
    if not Draft202012Validator(schema.root).is_valid(document.root):
        raise TemplateError(f"schema validation failed: {schema_name}")


def validate_tree(directory: Path) -> None:
    datacenter = load_json(directory / "datacenter.json")
    try:
        datacenter_artifact = DatacenterArtifact.model_validate(datacenter.root)
    except ValidationError as error:
        raise TemplateError(
            f"generated datacenter artifact is invalid: {error}"
        ) from error
    if datacenter_artifact.status != "example":
        raise TemplateError("generated status must remain example")
    validate_document(datacenter, "datacenter.schema.json")
    targets = datacenter_artifact.targets
    expected = EXPECTED_FILES | {
        f"targets/{target}/contract.json" for target in targets
    }
    actual = {
        path.relative_to(directory).as_posix()
        for path in directory.rglob("*")
        if path.is_file()
    }
    unexpected = sorted(actual - expected)
    missing = sorted(expected - actual)
    if unexpected:
        raise TemplateError(f"unexpected generated artifact: {unexpected[0]}")
    if missing:
        raise TemplateError(f"missing generated artifact: {missing[0]}")
    target_artifacts: list[TargetArtifact] = []
    for target in targets:
        contract = load_json(directory / "targets" / target / "contract.json")
        try:
            target_artifact = TargetArtifact.model_validate(contract.root)
        except ValidationError as error:
            raise TemplateError(
                f"generated target artifact is invalid: {error}"
            ) from error
        if target_artifact.status != "example":
            raise TemplateError("generated target status must remain example")
        validate_document(contract, "target-contract.schema.json")
        if (
            target_artifact.datacenter_id != datacenter_artifact.datacenter_id
            or target_artifact.target != target
        ):
            raise TemplateError(f"generated identity mismatch for target {target}")
        target_artifacts.append(target_artifact)
    context = DatacenterContext(
        template_version=datacenter_artifact.provenance.template.version,
        datacenter_id=datacenter_artifact.datacenter_id,
        status=datacenter_artifact.status,
        description=datacenter_artifact.description,
        targets=tuple(target_artifacts),
    )
    expected = Provenance.model_validate(provenance(context))
    artifacts = (datacenter_artifact, *target_artifacts)
    if any(artifact.provenance != expected for artifact in artifacts):
        raise TemplateError("generated provenance digest verification failed")


def render(context_path: Path, output_root: Path) -> None:
    context = validate_context_source(context_path)
    payload = build_payload(context)
    destination = reject_ambiguous_output(output_root, context.datacenter_id)
    executable = shutil.which("cookiecutter")
    if executable is None:
        raise TemplateError(
            "real Cookiecutter CLI is unavailable in the isolated environment"
        )
    (output_root / "datacenters").mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        [
            executable,
            str(TEMPLATE),
            "--no-input",
            "--output-dir",
            str(output_root / "datacenters"),
            f"datacenter_id={context.datacenter_id}",
            f"payload_json={payload.model_dump_json()}",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if completed.returncode != 0:
        raise TemplateError(
            f"Cookiecutter CLI failed ({completed.returncode}): {completed.stderr.strip()}"
        )
    validate_tree(destination)
    cli_version = subprocess.run(
        [executable, "--version"],
        check=True,
        capture_output=True,
        text=True,
        timeout=10,
    ).stdout.strip()
    print(f"Cookiecutter CLI {cli_version} rendered and validated {destination}")
