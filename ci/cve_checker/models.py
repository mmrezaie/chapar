from __future__ import annotations

from dataclasses import dataclass, field
from typing import Final, TypeAlias

JsonScalar: TypeAlias = str | int | float | bool | None
JsonValue: TypeAlias = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]
SEVERITY_ORDER: Final = {
    "NONE": 0,
    "LOW": 1,
    "MEDIUM": 2,
    "HIGH": 3,
    "CRITICAL": 4,
}


@dataclass(frozen=True, slots=True)
class Package:
    name: str
    version: str | None = None
    spec: str | None = None
    aliases: tuple[str, ...] = field(default_factory=tuple)

    @property
    def label(self) -> str:
        return f"{self.name}@{self.version}" if self.version else self.name


@dataclass(frozen=True, slots=True)
class SelectionPolicy:
    datacenter: str
    software_set: str
    target: str

    def as_json(self) -> dict[str, str]:
        return {
            "datacenter": self.datacenter,
            "software_set": self.software_set,
            "target": self.target,
        }


@dataclass(frozen=True, slots=True)
class Finding:
    package: Package
    source: str
    cve_id: str
    severity: str
    score: float | None
    published: str | None
    modified: str | None
    summary: str
    url: str
    references: tuple[str, ...]
    evidence: str
    nemotron_summary: str | None = None
