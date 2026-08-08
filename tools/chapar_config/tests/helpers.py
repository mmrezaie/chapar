from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml

from tools.chapar_datacenter_models import DatacenterContext
from tools.chapar_datacenter_rendering import build_payload

ROOT = Path(__file__).resolve().parents[3]
CLI = ROOT / "tools/chapar_resolve.py"
EXAMPLE = ROOT / "cookiecutter/chapar-datacenter/examples/example-context.yaml"


@dataclass(frozen=True, slots=True)
class Fixture:
    root: Path
    catalog: Path
    targets: Path
    containers: Path
    datacenter: Path
    contracts: Path
    output: Path


@dataclass(frozen=True, slots=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


def make_fixture(root: Path) -> Fixture:
    context = DatacenterContext.model_validate(
        yaml.safe_load(EXAMPLE.read_text(encoding="utf-8"))
    )
    payload = build_payload(context)
    authorities = root / "authorities"
    contracts = root / "datacenters/example-lab/targets"
    authorities.mkdir(parents=True)
    contracts.mkdir(parents=True)
    catalog = authorities / "spack.yaml"
    targets = authorities / "targets.json"
    containers = authorities / "containers.json"
    datacenter = root / "datacenters/example-lab/datacenter.json"
    _ = catalog.write_bytes((ROOT / "envs/software/spack.yaml").read_bytes())
    _ = targets.write_bytes((ROOT / "containers/images/targets.json").read_bytes())
    _ = containers.write_bytes((ROOT / "containers/images/containers.json").read_bytes())
    datacenter.parent.mkdir(parents=True, exist_ok=True)
    _ = datacenter.write_text(
        json.dumps(payload.datacenter, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    for target, document in payload.contracts.items():
        destination = contracts / target / "contract.json"
        destination.parent.mkdir(parents=True)
        _ = destination.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    return Fixture(
        root=root,
        catalog=catalog,
        targets=targets,
        containers=containers,
        datacenter=datacenter,
        contracts=contracts,
        output=root / "output",
    )


def run_cli(
    fixture: Fixture,
    *,
    datacenter_id: str = "example-lab",
    software_set: str = "vlad",
    target: str = "linux-x86_64-v4",
    extra: tuple[str, ...] = (),
) -> CommandResult:
    contract_target = target if (fixture.contracts / target).is_dir() else "linux-x86_64-v4"
    contract = fixture.contracts / contract_target / "contract.json"
    command = [
        sys.executable,
        str(CLI),
        "--catalog",
        str(fixture.catalog),
        "--targets",
        str(fixture.targets),
        "--containers",
        str(fixture.containers),
        "--datacenter",
        str(fixture.datacenter),
        "--datacenter-id",
        datacenter_id,
        "--contract",
        str(contract),
        "--software-set",
        software_set,
        "--target",
        target,
        "--release-id",
        "release-1",
        "--run-id",
        "run-1",
        "--output-dir",
        str(fixture.output),
        *extra,
    ]
    completed = subprocess.run(
        command,
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


def cli_arguments(fixture: Fixture) -> tuple[str, ...]:
    contract = fixture.contracts / "linux-x86_64-v4/contract.json"
    return (
        "--catalog", str(fixture.catalog),
        "--targets", str(fixture.targets),
        "--containers", str(fixture.containers),
        "--datacenter", str(fixture.datacenter),
        "--datacenter-id", "example-lab",
        "--contract", str(contract),
        "--software-set", "vlad",
        "--target", "linux-x86_64-v4",
        "--release-id", "release-1",
        "--run-id", "run-1",
        "--output-dir", str(fixture.output),
    )


def run_raw(arguments: tuple[str, ...]) -> CommandResult:
    completed = subprocess.run(
        [sys.executable, str(CLI), *arguments],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)
