from __future__ import annotations

import argparse
import ctypes
import errno
import os
import pwd
import stat
import subprocess
import sys
from collections.abc import Callable

from .core import (
    CHUNK,
    DIR_FLAGS,
    DIRECTORY_IDENTITY_KEYS,
    READ_FLAGS,
    SEALED_EVIDENCE_KEYS,
    ActionResult,
    ContractError,
    JsonMap,
    JsonValue,
    canonical_absolute,
    fail,
    opened_parent,
    parse_json,
    require,
    require_sha,
    simple_name,
    stable_bytes_fd,
)


def faccess(fd: int, mode: int) -> bool:
    require(sys.platform.startswith("linux"), "faccessat2 descriptor checks require Linux")
    libc = ctypes.CDLL(None, use_errno=True)
    ctypes.set_errno(0)
    result = libc.syscall(439, fd, ctypes.c_char_p(b""), mode, 0x1000 | 0x200)
    error = ctypes.get_errno()
    if result == 0:
        return True
    require(error in (errno.EACCES, errno.EROFS), f"faccessat2 failed: {error}")
    return False


def role_uid(role: str) -> int:
    require(role in ("validator", "publisher"), "owner role must be validator or publisher")
    try:
        return pwd.getpwnam(role).pw_uid
    except KeyError as error:
        fail(f"owner role does not exist: {error}")


def walk_directories(raw: str) -> list[int]:
    absolute = canonical_absolute(raw, "evidence directory")
    fds = [os.open("/", DIR_FLAGS)]
    try:
        for part in absolute.split("/")[1:]:
            fds.append(os.open(part, DIR_FLAGS, dir_fd=fds[-1]))
        return fds
    except OSError:
        for fd in reversed(fds):
            os.close(fd)
        raise


def close_fds(fds: list[int]) -> None:
    for fd in reversed(fds):
        os.close(fd)


def require_owner_mode(info: os.stat_result, uid: int, mode: int, label: str) -> None:
    require(info.st_uid == uid and stat.S_IMODE(info.st_mode) == mode, f"{label} owner/mode mismatch")


def require_directory_identity(info: os.stat_result, expected: str, label: str) -> None:
    require(f"{info.st_dev}:{info.st_ino}" == expected, f"{label} identity drift")


def verify_empty_evidence(raw: str, role: str) -> JsonMap:
    uid = role_uid(role)
    fds = walk_directories(raw)
    try:
        for fd in fds[:-1]:
            info = os.fstat(fd)
            require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o555 and not faccess(fd, os.W_OK), "evidence ancestor is not root-owned 0555 nonwritable")
        leaf = os.fstat(fds[-1])
        require(leaf.st_uid == uid and stat.S_IMODE(leaf.st_mode) == 0o755, "evidence leaf owner/mode mismatch")
        require(faccess(fds[-1], os.W_OK), "evidence leaf is not writable by owner role")
        require(os.listdir(fds[-1]) == [], "evidence leaf is not empty")
        return {"directory_identity": f"{leaf.st_dev}:{leaf.st_ino}"}
    finally:
        close_fds(fds)


def run_and_capture(args: argparse.Namespace) -> None:
    output = canonical_absolute(args.output, "capture output")
    require(args.command, "capture command is required")
    with opened_parent(output) as (parent_fd, name):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent_fd)
        try:
            completed = subprocess.run(args.command, check=False, stdout=fd, stderr=fd if args.capture_stderr else None)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(parent_fd)
    require(completed.returncode == 0, f"captured command failed with status {completed.returncode}")


def seal_evidence(args: argparse.Namespace) -> None:
    require(args.file_mode == "0444" and args.directory_mode == "0555", "seal modes must be 0444/0555")
    fds = walk_directories(args.seal_evidence_directory)
    try:
        leaf = os.fstat(fds[-1])
        require_directory_identity(leaf, args.expected_directory_identity, "evidence directory")
        require(leaf.st_uid == os.geteuid(), "evidence leaf is not role-owned")
        for name in os.listdir(fds[-1]):
            simple_name(name, "evidence file")
            fd = os.open(name, READ_FLAGS, dir_fd=fds[-1])
            try:
                info = os.fstat(fd)
                require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid(), "evidence entry owner/type mismatch")
                os.fchmod(fd, 0o444)
                os.fsync(fd)
            finally:
                os.close(fd)
        os.fchmod(fds[-1], 0o555)
        os.fsync(fds[-1])
        os.fsync(fds[-2])
    finally:
        close_fds(fds)


def verify_sealed(args: argparse.Namespace) -> JsonMap:
    uid = role_uid(args.owner_role)
    expected_sha = require_sha(args.expected_sha256, "expected evidence digest")
    name = simple_name(args.expected_file, "expected evidence file")
    fds = walk_directories(args.verify_sealed_evidence_directory)
    try:
        for fd in fds[:-1]:
            info = os.fstat(fd)
            require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o555 and not faccess(fd, os.W_OK), "sealed ancestor mismatch")
        leaf = os.fstat(fds[-1])
        require_directory_identity(leaf, args.expected_directory_identity, "sealed directory")
        require(leaf.st_uid == uid and stat.S_IMODE(leaf.st_mode) == 0o555 and not faccess(fds[-1], os.W_OK), "sealed leaf owner/mode mismatch")
        entries = os.listdir(fds[-1])
        require(name in entries, "expected sealed evidence file is absent")
        for entry in entries:
            simple_name(entry, "sealed evidence file")
            entry_fd = os.open(entry, READ_FLAGS, dir_fd=fds[-1])
            try:
                entry_info = os.fstat(entry_fd)
                require(stat.S_ISREG(entry_info.st_mode) and entry_info.st_uid == uid and stat.S_IMODE(entry_info.st_mode) == 0o444, "sealed evidence entry owner/mode/type mismatch")
            finally:
                os.close(entry_fd)
        file_fd = os.open(name, READ_FLAGS, dir_fd=fds[-1])
        try:
            content = stable_bytes_fd(file_fd, "sealed evidence")
        finally:
            os.close(file_fd)
        require(content.uid == uid and content.mode == 0o444, "sealed file owner/mode mismatch")
        require(content.sha256 == expected_sha, "sealed file digest mismatch")
        return {"directory_identity": args.expected_directory_identity, "file_sha256": expected_sha}
    finally:
        close_fds(fds)


def extract_canonical(args: argparse.Namespace) -> None:
    data = parse_json(sys.stdin.buffer.read())
    expected = DIRECTORY_IDENTITY_KEYS if args.schema == "directory-identity" else SEALED_EVIDENCE_KEYS
    require(set(data) == expected, "canonical helper key set mismatch")
    require(args.field in expected, "field is not in canonical schema")
    value = data[args.field]
    require(type(value) in (str, int, bool), "canonical field is not scalar")
    print(value)


def expect_child_failure(label: str, action: Callable[[], ActionResult], expected: str) -> str:
    read_fd, write_fd = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(read_fd)
        try:
            action()
        except (ContractError, OSError, subprocess.SubprocessError) as error:
            os.write(write_fd, str(error).encode())
            os.close(write_fd)
            os._exit(41)
        os.write(write_fd, b"unexpected success")
        os.close(write_fd)
        os._exit(0)
    os.close(write_fd)
    output = os.read(read_fd, CHUNK).decode()
    os.close(read_fd)
    _, status = os.waitpid(child, 0)
    require(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 41, f"{label} child status mismatch: {status}:{output}")
    require(expected in output, f"{label} failed for the wrong reason: {output}")
    return label


def mutated(data: JsonMap, key: str, value: JsonValue) -> JsonMap:
    return {**data, key: value}
