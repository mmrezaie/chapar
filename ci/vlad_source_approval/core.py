from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Never, NewType, TypeVar

JsonScalar = str | int | bool | None
JsonValue = JsonScalar | list["JsonValue"] | dict[str, "JsonValue"]
JsonMap = dict[str, JsonValue]
Sha256 = NewType("Sha256", str)
Commit = NewType("Commit", str)
ActionResult = TypeVar("ActionResult")

HEX40: Final = re.compile(r"[0-9a-f]{40}")
HEX64: Final = re.compile(r"[0-9a-f]{64}")
IDENTIFIER: Final = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
TARGETS_DOCUMENT: Final = json.loads((Path(__file__).resolve().parents[2] / "containers/images/targets.json").read_text(encoding="utf-8"))
TARGETS: Final = frozenset(TARGETS_DOCUMENT["targets"])
REMOTE: Final = "https://github.com/nscaledev/chapar.git"
SOURCE_SCHEMA: Final = "chapar-vlad-source-approval/v1"
RELEASE_SCHEMA: Final = "chapar-vlad-release-binding/v1"
BUILDER_SCHEMA: Final = "chapar-vlad-builder-handoff/v1"
RUNTIME_SCHEMA: Final = "chapar-vlad-runtime-receipt/v1"
SCHEMA_KEYS: Final = {
    SOURCE_SCHEMA: frozenset({"schema", "approved_by", "approved_at", "change_ticket", "chapar_remote", "chapar_commit", "source_lock_path", "source_lock_sha256"}),
    RELEASE_SCHEMA: frozenset({"schema", "release_dir", "release_id", "run_id", "datacenter", "software_set", "chapar_commit", "source_lock_sha256", "target", "metadata_path", "metadata_sha256", "selection_sha256", "datacenter_contract_sha256", "target_contract_sha256", "software_catalog_sha256", "target_registry_sha256", "container_registry_sha256", "effective_manifest_sha256", "target_policy_sha256", "spack_lock_path", "spack_lock_sha256", "status"}),
    BUILDER_SCHEMA: frozenset({"schema", "build_root", "chapar_commit", "source_lock_sha256", "release_binding", "release_binding_sha256", "target", "image_id", "image_path", "image_sha256", "image_size", "validation_root"}),
    RUNTIME_SCHEMA: frozenset({"schema", "builder_handoff_sha256", "release_binding_sha256", "target", "image_path", "image_sha256", "validator_root", "validator_image_root", "runtime_receipt_path", "runtime_preflight_sha256", "smoke_output_sha256", "status"}),
}
DIRECTORY_IDENTITY_KEYS: Final = frozenset({"directory_identity"})
SEALED_EVIDENCE_KEYS: Final = frozenset({"directory_identity", "file_sha256"})
READ_FLAGS: Final = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
DIR_FLAGS: Final = READ_FLAGS | os.O_DIRECTORY
CHUNK: Final = 1024 * 1024


class ContractError(Exception):
    __slots__ = ("detail",)

    def __init__(self, detail: str) -> None:
        super().__init__(detail)
        self.detail = detail

    def __str__(self) -> str:
        return self.detail


@dataclass(frozen=True, slots=True)
class FileBytes:
    content: bytes
    sha256: Sha256
    size: int
    uid: int
    mode: int


@dataclass(frozen=True, slots=True)
class ReleaseInputs:
    output: str
    release_dir: str
    metadata: str
    spack_lock: str
    chapar_commit: str
    source_lock_sha256: str
    target: str
    release_id: str
    status: str


def fail(detail: str) -> Never:
    raise ContractError(detail)


def require(condition: bool, detail: str) -> None:
    if not condition:
        fail(detail)


def unique_pairs(pairs: list[tuple[str, JsonValue]]) -> JsonMap:
    result: JsonMap = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json(content: bytes) -> JsonMap:
    try:
        value: JsonValue = json.loads(content, object_pairs_hook=unique_pairs)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        fail(f"invalid JSON: {error}")
    if type(value) is not dict:
        fail("JSON root must be an object")
    return value


def canonical_absolute(raw: str, label: str) -> str:
    require(raw.startswith("/") and os.path.normpath(raw) == raw, f"{label} must be canonical absolute path")
    parts = raw.split("/")[1:]
    if not parts or not all(part not in ("", ".", "..") for part in parts):
        fail(f"{label} has invalid path components")
    return raw


def simple_name(raw: str, label: str) -> str:
    require(raw not in ("", ".", "..") and "/" not in raw, f"{label} must be one path component")
    return raw


@contextmanager
def opened_path(raw: str, final_directory: bool = False) -> Iterator[int]:
    absolute = canonical_absolute(raw, "path")
    parts = absolute.split("/")[1:]
    fd = os.open("/", DIR_FLAGS)
    try:
        for index, part in enumerate(parts):
            flags = DIR_FLAGS if index < len(parts) - 1 or final_directory else READ_FLAGS
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        yield fd
    finally:
        os.close(fd)


@contextmanager
def opened_parent(raw: str) -> Iterator[tuple[int, str]]:
    absolute = canonical_absolute(raw, "path")
    parent, name = os.path.split(absolute)
    simple_name(name, "file name")
    with opened_path(parent, final_directory=True) as parent_fd:
        yield parent_fd, name


def stable_bytes_fd(fd: int, label: str) -> FileBytes:
    before = os.fstat(fd)
    require(stat.S_ISREG(before.st_mode), f"{label} is not a regular file")
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    chunks: list[bytes] = []
    while chunk := os.read(fd, CHUNK):
        digest.update(chunk)
        chunks.append(chunk)
    after = os.fstat(fd)
    identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    require(identity(before) == identity(after), f"{label} changed while open")
    return FileBytes(b"".join(chunks), Sha256(digest.hexdigest()), before.st_size, before.st_uid, stat.S_IMODE(before.st_mode))


def read_file(raw: str, label: str, required_mode: int | None = None) -> FileBytes:
    with opened_path(raw) as fd:
        result = stable_bytes_fd(fd, label)
    if required_mode is not None:
        require(result.mode == required_mode, f"{label} mode must be {required_mode:04o}")
    return result


def expect_string(data: JsonMap, key: str) -> str:
    value = data.get(key)
    if type(value) is not str:
        fail(f"{key} must be a string")
    return value


def expect_integer(data: JsonMap, key: str) -> int:
    value = data.get(key)
    if type(value) is not int or value <= 0:
        fail(f"{key} must be a positive integer")
    return value


def require_sha(raw: str, label: str) -> Sha256:
    require(HEX64.fullmatch(raw) is not None, f"{label} must be lowercase SHA-256")
    return Sha256(raw)


def require_commit(raw: str) -> Commit:
    require(HEX40.fullmatch(raw) is not None, "chapar_commit must be lowercase 40-hex")
    return Commit(raw)


def require_identifier(raw: str, label: str) -> str:
    require(IDENTIFIER.fullmatch(raw) is not None, f"{label} is invalid")
    return raw


def require_target(raw: str) -> str:
    require(raw in TARGETS, "target is not a Vlad image target")
    return raw


def require_schema(data: JsonMap, identity: str) -> None:
    require(set(data) == SCHEMA_KEYS[identity], f"{identity} key set mismatch")
    require(expect_string(data, "schema") == identity, f"wrong schema identity: {identity}")


def receipt(raw: str, expected_sha256: str | None = None) -> tuple[JsonMap, FileBytes]:
    file_bytes = read_file(raw, "receipt", 0o444)
    if expected_sha256 is not None:
        require(file_bytes.sha256 == require_sha(expected_sha256, "expected receipt digest"), "receipt SHA-256 mismatch")
    return parse_json(file_bytes.content), file_bytes


def write_exclusive_json(raw: str, data: JsonMap) -> Sha256:
    payload = json.dumps(data, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    with opened_parent(raw) as (parent_fd, name):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o444, dir_fd=parent_fd)
        try:
            os.fchmod(fd, 0o444)
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(parent_fd)
    reread = read_file(raw, "written receipt", 0o444)
    require(reread.content == payload, "written receipt bytes drifted")
    return reread.sha256
