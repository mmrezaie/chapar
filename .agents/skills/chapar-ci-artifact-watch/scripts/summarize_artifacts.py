#!/usr/bin/env python3
"""Read-only summary of Chapar CI artifact roots."""

from __future__ import annotations

import argparse
import os
import re
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


DEFAULT_LOCAL_ROOTS = (
    "/resources",
    "/share/base",
    "/Volumes/resources",
    "~/resources",
)

DEFAULT_OS_NAMES = ("ubuntu24.04",)

ROOT_ENV_VARS = (
    "HPCSIM_ROOT",
    "CHAPAR_HPCSIM_ROOT",
    "CHAPAR_BUILDCACHE_ROOT",
)

ERROR_RE = re.compile(r"\b(ERROR|FAILED|Killed|Traceback|timeout|timed out)\b|\bError:")
KEY_RE = re.compile(
    r"^(==>|\s+(output|store|releases|module|buildcache|hpcsim root|buildcache root|staging):)"
)


@dataclass(frozen=True)
class RunSummary:
    root: Path
    os_name: str
    run_id: str
    run_root: Path
    status: str
    metadata: dict[str, str]
    key_lines: list[str]
    errors: list[str]
    tail: list[str]
    line_count: int
    log_mtime: str | None
    concrete_envs: list[str]


def expand_path(value: str) -> Path:
    return Path(value).expanduser()


def existing_dirs(paths: Iterable[str | Path]) -> list[Path]:
    seen: set[Path] = set()
    result: list[Path] = []
    for item in paths:
        path = expand_path(str(item))
        try:
            resolved = path.resolve(strict=False)
        except OSError:
            continue
        if resolved in seen or not resolved.is_dir():
            continue
        seen.add(resolved)
        result.append(resolved)
    return result


def env_roots() -> list[str]:
    roots: list[str] = []
    for item in os.environ.get("CHAPAR_CI_ARTIFACT_ROOTS", "").split(os.pathsep):
        if item:
            roots.append(item)
    for var in ROOT_ENV_VARS:
        value = os.environ.get(var)
        if value:
            roots.append(value)
    return roots


def suffixes(path: Path) -> list[Path]:
    parts = [part for part in path.parts if part not in (path.anchor, os.sep)]
    result: list[Path] = []
    for index in range(1, len(parts)):
        result.append(Path(*parts[index:]))
    return result


def has_os_layout(path: Path, os_names: Iterable[str]) -> bool:
    return any((path / os_name / "runs").is_dir() for os_name in os_names)


def candidate_env_roots(local_roots: list[Path], ci_roots: list[Path], os_names: Iterable[str]) -> list[Path]:
    candidates: list[Path] = []

    for root in ci_roots:
        if root.is_dir():
            candidates.append(root)

    for local_root in local_roots:
        candidates.extend(
            (
                local_root,
                local_root / "chapar" / "hpcsim",
                local_root / "share" / "hpcsim",
                local_root / "hpcsim",
            )
        )
        try:
            for child in local_root.iterdir():
                if child.is_dir():
                    candidates.extend((child / "hpcsim", child / "share" / "hpcsim"))
        except OSError:
            pass

    for ci_root in ci_roots:
        for tail in suffixes(ci_root):
            for local_root in local_roots:
                candidates.append(local_root / tail)

    existing = existing_dirs(candidates)
    filtered = [path for path in existing if has_os_layout(path, os_names)]
    return unique_paths(filtered)


def unique_paths(paths: Iterable[Path]) -> list[Path]:
    seen: set[Path] = set()
    result: list[Path] = []
    for path in paths:
        try:
            resolved = path.resolve(strict=False)
        except OSError:
            resolved = path
        if resolved in seen:
            continue
        seen.add(resolved)
        result.append(resolved)
    return result


def safe_child(root: Path, child: Path) -> Path | None:
    try:
        resolved_root = root.resolve(strict=False)
        resolved_child = child.resolve(strict=False)
        resolved_child.relative_to(resolved_root)
    except (OSError, ValueError):
        return None
    return resolved_child


def read_text_file(path: Path, max_chars: int = 4096) -> str | None:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as stream:
            return stream.read(max_chars).strip()
    except OSError:
        return None


def file_mtime(path: Path) -> str | None:
    try:
        timestamp = path.stat().st_mtime
    except OSError:
        return None
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec="seconds")


def scan_log(path: Path, max_tail: int) -> tuple[list[str], list[str], list[str], int]:
    key_lines: list[str] = []
    errors: list[str] = []
    tail: deque[str] = deque(maxlen=max_tail)
    line_count = 0

    try:
        with path.open("r", encoding="utf-8", errors="replace") as stream:
            for raw_line in stream:
                line_count += 1
                line = raw_line.rstrip("\n")
                if line.strip():
                    tail.append(line)
                if KEY_RE.search(line):
                    key_lines.append(line)
                if ERROR_RE.search(line):
                    errors.append(line)
    except OSError:
        pass

    return key_lines[-40:], errors[:20], list(tail), line_count


def classify(key_lines: list[str], errors: list[str], log_exists: bool, run_exists: bool) -> str:
    joined = "\n".join(key_lines)
    if not run_exists:
        return "no run directory"
    if not log_exists:
        return "run directory exists, no build.log"
    if errors:
        return "error evidence present"
    if "hpcsim CI build completed" in joined:
        return "completed"
    if "Release build complete" in joined:
        return "release complete"
    if "Regenerating tcl module files" in joined:
        return "module generation"
    if "Concretized" in joined:
        return "post-concretization install/cache phase"
    if "staging:" in joined:
        return "started release helper, likely concretizing"
    return "log exists, phase unclear"


def list_dir_names(path: Path, limit: int = 20) -> list[str]:
    try:
        names = sorted(child.name + ("/" if child.is_dir() else "") for child in path.iterdir())
    except OSError:
        return []
    return names[:limit]


def summarize_run(root: Path, os_name: str, run_id: str, max_tail: int) -> RunSummary | None:
    run_root = safe_child(root, root / os_name / "runs" / run_id)
    if run_root is None:
        return None

    log_path = safe_child(root, run_root / "logs" / "build.log")
    log_exists = bool(log_path and log_path.is_file())
    run_exists = run_root.is_dir()
    key_lines: list[str] = []
    errors: list[str] = []
    tail: list[str] = []
    line_count = 0

    if log_exists and log_path is not None:
        key_lines, errors, tail, line_count = scan_log(log_path, max_tail)

    metadata = {
        "commit": read_text_file(run_root / "commit.txt") or "",
        "release_id": read_text_file(run_root / "release-id.txt") or "",
        "spack_version": read_text_file(run_root / "spack-version.txt") or "",
        "spack_commit": read_text_file(run_root / "spack-commit.txt") or "",
    }

    concrete_envs = list_dir_names(run_root / "concrete-envs")
    status = classify(key_lines, errors, log_exists, run_exists)
    return RunSummary(
        root=root,
        os_name=os_name,
        run_id=run_id,
        run_root=run_root,
        status=status,
        metadata=metadata,
        key_lines=key_lines,
        errors=errors,
        tail=tail,
        line_count=line_count,
        log_mtime=file_mtime(log_path) if log_path else None,
        concrete_envs=concrete_envs,
    )


def recent_runs(root: Path, os_name: str, limit: int) -> list[str]:
    runs_dir = safe_child(root, root / os_name / "runs")
    if runs_dir is None or not runs_dir.is_dir():
        return []
    try:
        children = [child for child in runs_dir.iterdir() if child.is_dir()]
    except OSError:
        return []
    children.sort(key=lambda item: item.stat().st_mtime if item.exists() else 0, reverse=True)
    return [child.name for child in children[:limit]]


def print_summary(summary: RunSummary) -> None:
    print(f"root: {summary.root}")
    print(f"os: {summary.os_name}")
    print(f"run: {summary.run_id}")
    print(f"run root: {summary.run_root}")
    print(f"status: {summary.status}")
    if summary.log_mtime:
        print(f"build.log mtime: {summary.log_mtime}")
    if summary.line_count:
        print(f"build.log lines: {summary.line_count}")
    for key, value in summary.metadata.items():
        if value:
            print(f"{key}: {value}")
    if summary.concrete_envs:
        print("concrete-envs: " + ", ".join(summary.concrete_envs))
    if summary.key_lines:
        print("last key lines:")
        for line in summary.key_lines[-12:]:
            print(f"  {line}")
    if summary.errors:
        print("error evidence:")
        for line in summary.errors[:8]:
            print(f"  {line}")
    if summary.tail:
        print("tail:")
        for line in summary.tail:
            print(f"  {line}")
    print()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", help="CI run ID to inspect")
    parser.add_argument("--os", dest="os_names", action="append", choices=DEFAULT_OS_NAMES)
    parser.add_argument("--ci-root", action="append", default=[], help="CI-internal artifact root")
    parser.add_argument("--local-root", action="append", default=[], help="Locally mounted artifact root")
    parser.add_argument("--recent", type=int, default=8, help="Number of recent runs to list without --run-id")
    parser.add_argument("--tail", type=int, default=20, help="Non-empty log tail lines to show")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    os_names = tuple(args.os_names or DEFAULT_OS_NAMES)
    local_roots = existing_dirs([*DEFAULT_LOCAL_ROOTS, *env_roots(), *args.local_root])
    ci_roots = [expand_path(item) for item in [*env_roots(), *args.ci_root]]
    roots = candidate_env_roots(local_roots, ci_roots, os_names)

    if not roots:
        print("No readable CI artifact roots found.")
        print("Pass --local-root or set CHAPAR_CI_ARTIFACT_ROOTS for this site.")
        return 2

    if not args.run_id:
        for root in roots:
            print(f"root: {root}")
            for os_name in os_names:
                runs = recent_runs(root, os_name, args.recent)
                if runs:
                    print(f"  {os_name}: " + ", ".join(runs))
        return 0

    found = False
    for root in roots:
        for os_name in os_names:
            summary = summarize_run(root, os_name, args.run_id, args.tail)
            if summary and summary.run_root.exists():
                found = True
                print_summary(summary)

    if not found:
        print(f"Run {args.run_id} was not found under readable CI artifact roots.")
        for root in roots:
            print(f"checked: {root}")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
