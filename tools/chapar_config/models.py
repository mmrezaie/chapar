from __future__ import annotations

from dataclasses import dataclass
from typing import ClassVar, NewType

from pydantic import BaseModel, ConfigDict, Field, JsonValue, RootModel

from tools.chapar_datacenter_artifacts import DatacenterArtifact, TargetArtifact
from tools.chapar_datacenter_models import ContainerFact, SoftwareSet, TargetFact

DatacenterId = NewType("DatacenterId", str)
TargetId = NewType("TargetId", str)
ReleaseId = NewType("ReleaseId", str)
RunId = NewType("RunId", str)


class StrictModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(extra="forbid", frozen=True)


class JsonMapping(RootModel[dict[str, JsonValue]]):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)


class TargetRegistryDocument(StrictModel):
    schema_uri: str = Field(alias="schema")
    schema_version: int
    targets: dict[str, TargetFact]


class ContainerRegistryDocument(StrictModel):
    schema_uri: str = Field(alias="schema")
    schema_version: int
    containers: dict[str, ContainerFact]


@dataclass(frozen=True, slots=True)
class CatalogRoot:
    identity: str
    spec: str
    classification: str
    architecture: str | None


@dataclass(frozen=True, slots=True)
class Catalog:
    document: JsonMapping
    roots: tuple[CatalogRoot, ...]


@dataclass(frozen=True, slots=True)
class PolicyIdentity:
    datacenter: DatacenterId
    software_set: SoftwareSet
    target: TargetId


@dataclass(frozen=True, slots=True)
class InvocationIdentity:
    release_id: ReleaseId
    run_id: RunId


@dataclass(frozen=True, slots=True)
class Inputs:
    catalog: Catalog
    target_registry: TargetRegistryDocument
    container_registry: ContainerRegistryDocument
    datacenter: DatacenterArtifact
    contract: TargetArtifact
    peer_contracts: tuple[TargetArtifact, ...]


@dataclass(frozen=True, slots=True)
class AuthorityDigests:
    software_catalog: str
    target_registry: str
    container_registry: str
    datacenter_contract: str
    target_contract: str


@dataclass(frozen=True, slots=True)
class Request:
    policy: PolicyIdentity
    invocation: InvocationIdentity
    output_dir: str


@dataclass(frozen=True, slots=True)
class Resolution:
    request: Request
    inputs: Inputs
    target_fact: TargetFact
    containers: tuple[tuple[str, ContainerFact], ...]
    selected_roots: tuple[CatalogRoot, ...]
    excluded_roots: tuple[tuple[CatalogRoot, str], ...]
    paths: tuple[tuple[str, str], ...]
    authority_digests: AuthorityDigests
