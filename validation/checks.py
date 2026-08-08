from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Final

from tools.chapar_config.models import CatalogRoot

type JsonScalar = str | int | float | bool | None
type JsonValue = JsonScalar | list[JsonValue] | dict[str, JsonValue]

SPEC_NAME: Final = re.compile(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)")
CHECK_COMMANDS: Final = {
    "babelstream": ("module show babelstream", "babelstream module"), "caliper": ("cali-query --help", "caliper tool runs"), "cmake": ("cmake --version", "cmake runs"),
    "cuda": ("nvcc --version", "nvcc --version"), "cuda-memtest": ("command -v cuda_memtest", "cuda_memtest on PATH"), "fio": ("fio --version", "fio runs"),
    "gcc": ("gcc --version", "compiler runs"), "hpcg": ("command -v hpcg || command -v xhpcg", "hpcg binary"), "hpctoolkit": ("command -v hpcrun", "hpctoolkit on PATH"),
    "hwloc": ("lstopo --version || hwloc-info --version", "hwloc runs"), "ior": ("ior --version", "ior runs"), "libfabric": ("fi_info --version", "libfabric available"),
    "likwid": ("likwid-perfctr --version", "likwid on PATH"), "mdtest": ("command -v mdtest", "mdtest on PATH"), "meson": ("meson --version", "meson runs"),
    "nccl": ("module show nccl", "nccl module"), "ninja": ("ninja --version", "ninja runs"), "numactl": ("numactl --show", "numactl runs"),
    "openmpi": ("mpirun --version", "mpirun --version"), "osu-micro-benchmarks": ("command -v osu_latency", "osu_latency on PATH"),
    "papi": ("command -v papi_command_line", "papi on PATH"), "pmix": ("pmi_info --version || pmi_info --help", "pmix available"),
    "py-mpi4py": ("python3 -c 'import mpi4py'", "mpi4py importable"), "python": ("python3 --version", "python3 --version"),
    "qperf": ("qperf --help", "qperf runs"), "scalasca": ("command -v scalasca || command -v scout", "scalasca on PATH"),
    "stream": ("command -v stream_c.exe", "stream on PATH"), "tau": ("command -v tau_exec", "tau on PATH"), "ucx": ("ucx_info -v", "ucx_info runs"),
}


class RootInventoryError(Exception):
    pass


@dataclass(frozen=True, slots=True)
class RootCheck:
    module: str
    command: str
    description: str


def _text(document: dict[str, JsonValue], key: str) -> str:
    value = document.get(key)
    if not isinstance(value, str) or not value:
        raise RootInventoryError(f"missing {key}")
    return value


def canonical_root_checks(
    selection: dict[str, JsonValue], expected: tuple[CatalogRoot, ...]
) -> tuple[RootCheck, ...]:
    raw_roots = selection.get("selected_roots")
    if not isinstance(raw_roots, list):
        raise RootInventoryError("selected root inventory is required")
    actual: list[tuple[str, str, str]] = []
    checks: list[RootCheck] = []
    for raw_root in raw_roots:
        if not isinstance(raw_root, dict):
            raise RootInventoryError("selected root must be an object")
        identity = _text(raw_root, "id")
        spec = _text(raw_root, "spec")
        actual.append((identity, spec, _text(raw_root, "classification")))
        match = SPEC_NAME.match(spec)
        if match is None:
            raise RootInventoryError(f"selected root has no module name: {identity}")
        module_name = match.group(1)
        command, description = CHECK_COMMANDS.get(
            module_name, (f"module show {module_name}", f"{module_name} module")
        )
        checks.append(RootCheck(module_name, command, description))
    canonical = [(root.identity, root.spec, root.classification) for root in expected]
    if actual != canonical:
        raise RootInventoryError("selected root inventory differs from canonical catalog")
    return tuple(checks)
