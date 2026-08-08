#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "basedpyright>=1,<2",
#   "cookiecutter>=2,<3",
#   "jsonschema>=4,<5",
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
#      uv run tools/chapar_datacenter_template.py render CONTEXT.yaml --output-root OUTPUT
# 3. Or make executable and run:
#      chmod +x tools/chapar_datacenter_template.py && ./tools/chapar_datacenter_template.py render CONTEXT.yaml --output-root OUTPUT
# ─────────────────

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path
from typing import assert_never

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.chapar_datacenter_rendering import TemplateError, render, validate_tree


@dataclass(frozen=True, slots=True)
class RenderCommand:
    context: Path
    output: Path


@dataclass(frozen=True, slots=True)
class ValidateCommand:
    directory: Path


type Command = RenderCommand | ValidateCommand


def parse_arguments(arguments: list[str]) -> Command:
    if (
        len(arguments) == 4
        and arguments[0] == "render"
        and arguments[2] == "--output-root"
    ):
        return RenderCommand(Path(arguments[1]), Path(arguments[3]))
    if len(arguments) == 2 and arguments[0] == "validate-tree":
        return ValidateCommand(Path(arguments[1]))
    raise TemplateError(
        "usage: chapar_datacenter_template.py render CONTEXT --output-root OUTPUT | validate-tree DIRECTORY"
    )


def main(arguments: list[str]) -> int:
    match parse_arguments(arguments):
        case RenderCommand(context=context, output=output):
            render(context, output)
        case ValidateCommand(directory=directory):
            validate_tree(directory)
            print(f"generated tree valid: {directory}")
        case unreachable:
            assert_never(unreachable)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except TemplateError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2) from error
