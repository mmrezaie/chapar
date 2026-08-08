from __future__ import annotations

from typing import ClassVar

from pydantic import ConfigDict, Field

from tools.chapar_datacenter_models import StrictModel, TargetContext


class TemplateProvenance(StrictModel):
    name: str
    version: str
    sha256: str


class ToolProvenance(StrictModel):
    name: str
    version: str
    sha256: str
    dependencies: dict[str, str]


class AuthorityProvenance(StrictModel):
    container_registry: str
    datacenter_schema: str
    target_contract_schema: str
    target_registry: str


class Provenance(StrictModel):
    template: TemplateProvenance
    context_sha256: str
    tool: ToolProvenance
    authority_sha256: AuthorityProvenance


class DatacenterArtifact(StrictModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid", frozen=True, populate_by_name=True
    )

    schema_uri: str = Field(alias="schema")
    schema_version: int
    datacenter_id: str
    status: str
    description: str
    targets: tuple[str, ...]
    provenance: Provenance


class TargetArtifact(TargetContext):
    schema_uri: str = Field(alias="schema")
    schema_version: int
    datacenter_id: str
    status: str
    provenance: Provenance
