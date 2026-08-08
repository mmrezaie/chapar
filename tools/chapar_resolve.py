#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "basedpyright>=1,<2",
#   "pydantic>=2,<3",
#   "pytest>=8,<9",
#   "PyYAML>=6,<7",
#   "ruff>=0.12,<1",
# ]
# ///

# ─── How to run ───
# 1. Install uv (if not installed):
#      curl -LsSf https://astral.sh/uv/install.sh | sh
# 2. Run directly (no venv, no pip install needed):
#      uv run tools/chapar_resolve.py --help
# 3. Or make executable and run:
#      chmod +x tools/chapar_resolve.py && ./tools/chapar_resolve.py --help
# ─────────────────

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.chapar_config.errors import ResolverError
from tools.chapar_config.models import (
    DatacenterId,
    InvocationIdentity,
    PolicyIdentity,
    ReleaseId,
    Request,
    RunId,
    TargetId,
)
from tools.chapar_config.paths import validated_identity
from tools.chapar_config.render import render
from tools.chapar_config.resolve import load_inputs, resolve
from tools.chapar_datacenter_models import SoftwareSet


@dataclass(frozen=True, slots=True)
class Command:
    catalog: Path
    targets: Path
    containers: Path
    datacenter: Path
    contract: Path
    request: Request


def parse_arguments(arguments: list[str]) -> Command:
    expected = {
        "--catalog",
        "--targets",
        "--containers",
        "--datacenter",
        "--contract",
        "--datacenter-id",
        "--software-set",
        "--target",
        "--release-id",
        "--run-id",
        "--output-dir",
    }
    if len(arguments) != len(expected) * 2:
        raise ResolverError("missing or extra selector; every policy and invocation field is required")
    values: dict[str, str] = {}
    for position in range(0, len(arguments), 2):
        flag, value = arguments[position : position + 2]
        if flag not in expected or flag in values or not value:
            raise ResolverError(f"unknown, duplicate, or empty selector: {flag}")
        values[flag] = value
    if set(values) != expected:
        raise ResolverError("missing or extra selector")
    try:
        software_set = SoftwareSet(values["--software-set"])
    except ValueError as error:
        raise ResolverError(f"unknown software set: {values['--software-set']}") from error
    request = Request(
        policy=PolicyIdentity(
            DatacenterId(validated_identity(values["--datacenter-id"], "datacenter ID")),
            software_set,
            TargetId(validated_identity(values["--target"], "target ID")),
        ),
        invocation=InvocationIdentity(
            ReleaseId(validated_identity(values["--release-id"], "release ID")),
            RunId(validated_identity(values["--run-id"], "run ID")),
        ),
        output_dir=values["--output-dir"],
    )
    return Command(
        Path(values["--catalog"]),
        Path(values["--targets"]),
        Path(values["--containers"]),
        Path(values["--datacenter"]),
        Path(values["--contract"]),
        request,
    )


def main(arguments: list[str]) -> int:
    command = parse_arguments(arguments)
    inputs, digests = load_inputs(
        command.catalog,
        command.targets,
        command.containers,
        command.datacenter,
        command.contract,
    )
    digest = render(
        resolve(command.request, inputs, digests), Path(__file__).resolve().parents[1]
    )
    print(digest)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ResolverError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2) from error
