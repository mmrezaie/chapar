from __future__ import annotations

import copy
import os
import shutil
from hashlib import sha256
from importlib.metadata import version
from pathlib import Path
from typing import Final

import yaml
from pydantic import JsonValue

from tools.chapar_config.errors import ResolverError
from tools.chapar_config.io import canonical_json
from tools.chapar_config.models import JsonMapping, Resolution
from tools.chapar_config.paths import validate_output_path
from tools.chapar_config.resolve import tool_digest

CUDA_ARCH_PACKAGES: Final = frozenset(
    {
        "babelstream",
        "caliper",
        "hwloc",
        "nccl",
        "nccl-tests",
        "nvbandwidth",
        "nvshmem",
        "nvtop",
        "openmpi",
        "ucx",
    }
)
TOOL_VERSION: Final = "1.0.0"


def _target_policy(resolution: Resolution) -> dict[str, JsonValue]:
    target = resolution.target_fact
    return {
        "schema": "https://nscaledev.github.io/chapar/schemas/target-policy/v1",
        "schema_version": 1,
        "target": {
            "id": resolution.request.policy.target,
            "oci_platform": target.oci_platform,
            "native_arch": target.native_arch,
            "spack_target": target.spack_target,
            "llvm_targets": list(target.llvm_targets),
            "cuda_arch": list(target.cuda_arch),
        },
    }


def _with_target_cuda_arch(specification: str, cuda_arch: str) -> str:
    terms: list[str] = []
    for term in specification.split():
        terms.append(term)
        package = term.removeprefix("^").split("@", 1)[0].split("+", 1)[0].split("~", 1)[0]
        if package in CUDA_ARCH_PACKAGES:
            terms.append(f"cuda_arch={cuda_arch}")
    return " ".join(terms)


def _effective_manifest(resolution: Resolution) -> dict[str, JsonValue]:
    root = copy.deepcopy(resolution.inputs.catalog.document.root)
    spack = root["spack"]
    if not isinstance(spack, dict):
        raise ResolverError("typed catalog lost its spack mapping")
    cuda_arch = ",".join(resolution.target_fact.cuda_arch)
    spack["specs"] = [
        _with_target_cuda_arch(root.spec, cuda_arch)
        for root in resolution.selected_roots
    ]
    packages = spack.get("packages")
    if not isinstance(packages, dict):
        raise ResolverError("typed catalog packages must be a mapping")
    all_policy = packages.get("all")
    if not isinstance(all_policy, dict):
        raise ResolverError("typed catalog all-package policy must be a mapping")
    requirements = all_policy.setdefault("require", [])
    if not isinstance(requirements, list):
        raise ResolverError("typed catalog target requirements must be an array")
    requirements.append(f"target={resolution.target_fact.spack_target}")
    llvm = packages.get("llvm")
    if not isinstance(llvm, dict):
        raise ResolverError("typed catalog LLVM policy must be a mapping")
    llvm_require = llvm.get("require")
    if not isinstance(llvm_require, list):
        raise ResolverError("typed catalog LLVM requirements must be an array")
    llvm_require.append(f"targets={','.join(resolution.target_fact.llvm_targets)}")
    return JsonMapping.model_validate(root).root


def _selection(
    resolution: Resolution,
    policy_digest: str,
    manifest_digest: str,
    repository_root: Path,
) -> dict[str, JsonValue]:
    request = resolution.request
    return {
        "schema": "https://nscaledev.github.io/chapar/schemas/software-selection/v1",
        "schema_version": 1,
        "policy": {
            "datacenter": request.policy.datacenter,
            "software_set": request.policy.software_set.value,
            "target": request.policy.target,
        },
        "invocation": {
            "release_id": request.invocation.release_id,
            "run_id": request.invocation.run_id,
        },
        "target_facts": resolution.target_fact.model_dump(mode="json"),
        "containers": [identity for identity, _ in resolution.containers],
        "selected_roots": [
            {
                "id": root.identity,
                "spec": root.spec,
                "classification": root.classification,
            }
            for root in resolution.selected_roots
        ],
        "excluded_roots": [
            {"id": root.identity, "spec": root.spec, "reason": reason}
            for root, reason in resolution.excluded_roots
        ],
        "paths": dict(resolution.paths),
        "authorities": {
            "software_catalog": resolution.authority_digests.software_catalog,
            "target_registry": resolution.authority_digests.target_registry,
            "container_registry": resolution.authority_digests.container_registry,
            "datacenter_contract": resolution.authority_digests.datacenter_contract,
            "target_contract": resolution.authority_digests.target_contract,
        },
        "artifacts": {
            "target_policy_sha256": policy_digest,
            "effective_manifest_sha256": manifest_digest,
        },
        "versions": {
            "selection_schema": 1,
            "target_registry_schema": resolution.inputs.target_registry.schema_version,
            "container_registry_schema": resolution.inputs.container_registry.schema_version,
            "resolver": TOOL_VERSION,
            "resolver_sha256": tool_digest(repository_root),
            "pydantic": version("pydantic"),
            "PyYAML": version("PyYAML"),
        },
        "deferred_proofs": ["release staging and final destination share a filesystem on the target platform"],
    }


def render(resolution: Resolution, repository_root: Path) -> str:
    output = Path(resolution.request.output_dir)
    validate_output_path(output)
    policy_bytes = canonical_json(_target_policy(resolution))
    manifest_bytes = yaml.safe_dump(
        _effective_manifest(resolution), sort_keys=False
    ).encode()
    selection = _selection(
        resolution,
        sha256(policy_bytes).hexdigest(),
        sha256(manifest_bytes).hexdigest(),
        repository_root,
    )
    selection_bytes = canonical_json(selection)
    staging = output.parent / f".{output.name}.tmp.{resolution.request.invocation.run_id}"
    validate_output_path(staging)
    try:
        staging.mkdir(parents=True)
        _ = (staging / "selection.json").write_bytes(selection_bytes)
        _ = (staging / "target-policy.yaml").write_bytes(policy_bytes)
        _ = (staging / "spack.yaml").write_bytes(manifest_bytes)
        os.replace(staging, output)
    except OSError as error:
        shutil.rmtree(staging, ignore_errors=True)
        raise ResolverError(f"cannot publish resolver output: {error}") from error
    return sha256(selection_bytes).hexdigest()
