from __future__ import annotations

import re
from enum import StrEnum
from pathlib import PurePosixPath
from typing import Annotated, ClassVar, Final, LiteralString, Never, Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    JsonValue,
    RootModel,
    field_validator,
    model_validator,
)
from pydantic_core import PydanticCustomError

IDENTIFIER: Final = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
TARGET_IDENTIFIER: Final = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
PLACEHOLDER: Final = re.compile(r"(?i)(replace[_-]|placeholder|change[_-]?me|todo)")


class StrictModel(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        extra="forbid", frozen=True, populate_by_name=True
    )


class JsonDocument(RootModel[dict[str, JsonValue]]):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)


class SoftwareSet(StrEnum):
    VLAD = "vlad"
    HPCSIM = "hpcsim"
    ALL = "all"


class SharedPathClass(StrEnum):
    INSTALL_TREE = "install_tree"
    WRITABLE_BUILDCACHE = "writable_buildcache"
    CCACHE = "ccache"


class ReadOnlyKind(StrEnum):
    SOFTWARE_CATALOG = "software_catalog"
    TARGET_REGISTRY = "target_registry"
    CONTAINER_REGISTRY = "container_registry"
    SOURCES_LOCK = "sources_lock"
    SEED_MIRROR = "seed_mirror"


AbsoluteRoot = Annotated[str, Field(min_length=2)]


def model_error(message: LiteralString) -> Never:
    raise PydanticCustomError("contract_invalid", message)


def validate_absolute_root(value: str) -> str:
    path = PurePosixPath(value)
    if not path.is_absolute():
        model_error("path root must be absolute")
    if ".." in path.parts:
        model_error("path traversal is forbidden")
    if PLACEHOLDER.search(value):
        model_error("placeholder path is forbidden")
    if value != path.as_posix() or value == "/":
        model_error("path root must be normalized and non-root")
    return value


class DurableWritablePaths(StrictModel):
    install_tree: AbsoluteRoot
    releases: AbsoluteRoot
    modulefiles: AbsoluteRoot
    writable_buildcache: AbsoluteRoot
    ccache: AbsoluteRoot
    container_outputs: AbsoluteRoot
    receipts: AbsoluteRoot
    evidence: AbsoluteRoot

    @field_validator("*")
    @classmethod
    def absolute_roots(cls, value: str) -> str:
        return validate_absolute_root(value)

    def roots(self) -> tuple[str, ...]:
        return (
            self.install_tree,
            self.releases,
            self.modulefiles,
            self.writable_buildcache,
            self.ccache,
            self.container_outputs,
            self.receipts,
            self.evidence,
        )


class TemporaryPaths(StrictModel):
    release_staging: AbsoluteRoot
    spack_build_stage: AbsoluteRoot
    image_staging: AbsoluteRoot
    validation_work: AbsoluteRoot
    resolver_work: AbsoluteRoot

    @field_validator("*")
    @classmethod
    def absolute_roots(cls, value: str) -> str:
        return validate_absolute_root(value)

    def roots(self) -> tuple[str, ...]:
        return (
            self.release_staging,
            self.spack_build_stage,
            self.image_staging,
            self.validation_work,
            self.resolver_work,
        )


class ReadOnlyInput(StrictModel):
    kind: ReadOnlyKind
    path: AbsoluteRoot

    @field_validator("path")
    @classmethod
    def absolute_root(cls, value: str) -> str:
        return validate_absolute_root(value)


class ContractPaths(StrictModel):
    durable_writable: DurableWritablePaths
    read_only_inputs: tuple[ReadOnlyInput, ...] = Field(min_length=4)
    temporary: TemporaryPaths

    @model_validator(mode="after")
    def roots_are_unambiguous(self) -> Self:
        writable = self.durable_writable.roots() + self.temporary.roots()
        if len(set(writable)) != len(writable):
            model_error("writable and temporary path roots must be unique")
        for position, left in enumerate(writable):
            left_path = PurePosixPath(left)
            for right in writable[position + 1 :]:
                right_path = PurePosixPath(right)
                if left_path in right_path.parents or right_path in left_path.parents:
                    if (
                        left == self.durable_writable.releases
                        and right == self.temporary.release_staging
                        and right_path.parent == left_path
                        and right_path.name == ".staging"
                    ):
                        continue
                    model_error("writable and temporary path roots must not overlap")
        kinds = tuple(item.kind for item in self.read_only_inputs)
        required = {
            ReadOnlyKind.SOFTWARE_CATALOG,
            ReadOnlyKind.TARGET_REGISTRY,
            ReadOnlyKind.CONTAINER_REGISTRY,
            ReadOnlyKind.SOURCES_LOCK,
        }
        if not required.issubset(kinds):
            model_error("ordered read-only inputs must include every authority")
        return self


class SlurmPlacement(StrictModel):
    partition: str = Field(min_length=1)
    constraint: str = Field(min_length=1)
    account: str = Field(min_length=1)
    qos: str = Field(min_length=1)


class Roles(StrictModel):
    builder: str = Field(min_length=1)
    validator: str = Field(min_length=1)
    publisher: str = Field(min_length=1)


class SharingPolicy(StrictModel):
    shared_path_classes: tuple[SharedPathClass, ...]
    share_across_targets: bool
    share_across_software_sets: bool
    seed_mirrors_read_only: bool

    @field_validator("shared_path_classes")
    @classmethod
    def unique_classes(
        cls, value: tuple[SharedPathClass, ...]
    ) -> tuple[SharedPathClass, ...]:
        if len(set(value)) != len(value):
            model_error("shared path classes must be unique")
        return value


class PublicationPolicy(StrictModel):
    publish_buildcache: bool
    publish_modules: bool
    publish_containers: bool
    promote_current: bool


class ContainerSelection(StrictModel):
    software_set: SoftwareSet
    container: str = Field(pattern=IDENTIFIER.pattern)


class TargetContext(StrictModel):
    target: str = Field(pattern=TARGET_IDENTIFIER.pattern)
    allowed_software_sets: tuple[SoftwareSet, ...] = Field(min_length=1)
    container_selections: tuple[ContainerSelection, ...]
    paths: ContractPaths
    slurm: SlurmPlacement
    roles: Roles
    sharing: SharingPolicy
    publication: PublicationPolicy

    @model_validator(mode="after")
    def policy_is_consistent(self) -> Self:
        if len(set(self.allowed_software_sets)) != len(self.allowed_software_sets):
            model_error("allowed software sets must be unique")
        selected_sets = tuple(
            selection.software_set for selection in self.container_selections
        )
        if len(set(selected_sets)) != len(selected_sets):
            model_error("container selection software sets must be unique")
        if not set(selected_sets).issubset(self.allowed_software_sets):
            model_error("container selection must use an allowed software set")
        if SoftwareSet.ALL in selected_sets:
            model_error("all has no selected container unless global policy accepts it")
        return self


class DatacenterContext(StrictModel):
    template_version: str = Field(pattern=r"^1\.[0-9]+\.[0-9]+$")
    datacenter_id: str = Field(pattern=IDENTIFIER.pattern)
    status: str
    description: str = Field(min_length=1)
    targets: tuple[TargetContext, ...] = Field(min_length=1)

    @model_validator(mode="after")
    def example_is_deterministic(self) -> Self:
        if self.status != "example":
            model_error("one-time generator currently permits status example only")
        target_ids = tuple(target.target for target in self.targets)
        if tuple(sorted(target_ids)) != target_ids or len(set(target_ids)) != len(
            target_ids
        ):
            model_error("targets must be unique and sorted")
        return self


class TargetFact(StrictModel):
    oci_platform: str
    native_arch: str
    spack_target: str
    llvm_targets: tuple[str, ...]
    cuda_arch: tuple[str, ...]


class TargetRegistry(StrictModel):
    schema_uri: str = Field(alias="schema")
    schema_version: int
    targets: dict[str, TargetFact]


class ContainerFact(StrictModel):
    base_image: str
    source_lock_category: str
    accepted_software_sets: tuple[SoftwareSet, ...]
    allowed_targets: tuple[str, ...]
    module_destination: str
    injection_requirements: dict[str, str | bool | list[str]]
    runtime_requirements: dict[str, str | bool | list[str]]


class ContainerRegistry(StrictModel):
    schema_uri: str = Field(alias="schema")
    schema_version: int
    containers: dict[str, ContainerFact]


class GeneratedPayload(StrictModel):
    datacenter: dict[str, JsonValue]
    contracts: dict[str, dict[str, JsonValue]]
