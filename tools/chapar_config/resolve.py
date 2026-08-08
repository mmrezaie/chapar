from __future__ import annotations

from hashlib import sha256
from pathlib import Path, PurePosixPath

from tools.chapar_config.errors import ResolverError
from tools.chapar_config.io import (
    load_catalog,
    load_json,
    load_registry,
    load_target_contract,
    read_authority,
)
from tools.chapar_config.models import (
    AuthorityDigests,
    CatalogRoot,
    ContainerRegistryDocument,
    Inputs,
    Request,
    Resolution,
    TargetRegistryDocument,
)
from tools.chapar_config.paths import (
    resolved_paths,
    validate_contract_paths,
    validated_identity,
)
from tools.chapar_datacenter_artifacts import DatacenterArtifact, TargetArtifact
from tools.chapar_datacenter_models import ContainerFact, SoftwareSet


def select_catalog_roots(
    roots: tuple[CatalogRoot, ...], software_set: SoftwareSet, native_arch: str
) -> tuple[tuple[CatalogRoot, ...], tuple[tuple[CatalogRoot, str], ...]]:
    selected: list[CatalogRoot] = []
    excluded: list[tuple[CatalogRoot, str]] = []
    for root in roots:
        include = root.classification == "shared"
        if root.classification == "vlad_only":
            include = software_set in {SoftwareSet.VLAD, SoftwareSet.ALL}
        if root.classification == "hpcsim_only":
            include = software_set in {SoftwareSet.HPCSIM, SoftwareSet.ALL}
        if root.classification.startswith("architecture_limited_"):
            set_matches = software_set in {
                SoftwareSet.HPCSIM,
                SoftwareSet.ALL,
            }
            if root.architecture != native_arch:
                excluded.append(
                    (root, f"native_arch {native_arch} excludes {root.architecture} root")
                )
                continue
            include = set_matches
        if include:
            selected.append(root)
        else:
            excluded.append(
                (root, f"not a member of software set {software_set.value}")
            )
    return tuple(selected), tuple(excluded)


def _selected_containers(
    inputs: Inputs, request: Request
) -> tuple[tuple[str, ContainerFact], ...]:
    selections = tuple(
        item
        for item in inputs.contract.container_selections
        if item.software_set == request.policy.software_set
    )
    if request.policy.software_set != SoftwareSet.ALL and len(selections) != 1:
        raise ResolverError("selected software set requires exactly one container")
    selected: list[tuple[str, ContainerFact]] = []
    destinations: set[str] = set()
    for selection in selections:
        fact = inputs.container_registry.containers.get(selection.container)
        if fact is None:
            raise ResolverError(f"unknown container: {selection.container}")
        if request.policy.software_set not in fact.accepted_software_sets:
            raise ResolverError(f"container {selection.container} rejects software set")
        if request.policy.target not in fact.allowed_targets:
            raise ResolverError(f"container {selection.container} rejects target")
        module_destination = PurePosixPath(fact.module_destination)
        if (
            not module_destination.is_absolute()
            or ".." in module_destination.parts
            or module_destination.as_posix() != fact.module_destination
        ):
            raise ResolverError("ambiguous container module path")
        if fact.module_destination in destinations:
            raise ResolverError("ambiguous container module destination")
        destinations.add(fact.module_destination)
        selected.append((selection.container, fact))
    return tuple(selected)


def validate_compatibility(inputs: Inputs, request: Request) -> None:
    policy = request.policy
    validated_identity(str(policy.datacenter), "datacenter ID")
    validated_identity(str(policy.target), "target ID")
    validated_identity(inputs.datacenter.datacenter_id, "datacenter authority ID")
    validated_identity(inputs.contract.datacenter_id, "target contract datacenter ID")
    validated_identity(inputs.contract.target, "target contract target ID")
    if inputs.datacenter.datacenter_id != policy.datacenter:
        raise ResolverError("datacenter selector does not match authority")
    if policy.target not in inputs.datacenter.targets:
        raise ResolverError(f"unknown target: {policy.target}")
    if inputs.contract.datacenter_id != policy.datacenter:
        raise ResolverError("target contract has a foreign datacenter")
    if inputs.contract.target != policy.target:
        raise ResolverError("target selector does not match contract")
    if policy.software_set not in inputs.contract.allowed_software_sets:
        raise ResolverError("forbidden tuple: software set is not allowed for target")
    if policy.target not in inputs.target_registry.targets:
        raise ResolverError(f"unknown target: {policy.target}")
    expected = inputs.contract.provenance.authority_sha256
    actual_targets = inputs.target_registry
    actual_containers = inputs.container_registry
    if expected.target_registry == "" or not actual_targets.targets:
        raise ResolverError("target registry digest authority is invalid")
    if expected.container_registry == "" or not actual_containers.containers:
        raise ResolverError("container registry digest authority is invalid")


def resolve(
    request: Request,
    inputs: Inputs,
    digests: AuthorityDigests,
) -> Resolution:
    validate_compatibility(inputs, request)
    expected = inputs.contract.provenance.authority_sha256
    if expected.target_registry != digests.target_registry:
        raise ResolverError("target registry digest tamper detected")
    if expected.container_registry != digests.container_registry:
        raise ResolverError("container registry digest tamper detected")
    validate_contract_paths(inputs.contract, inputs.peer_contracts)
    target_fact = inputs.target_registry.targets[request.policy.target]
    selected, excluded = select_catalog_roots(
        inputs.catalog.roots, request.policy.software_set, target_fact.native_arch
    )
    containers = _selected_containers(inputs, request)
    paths = resolved_paths(inputs.contract, request.policy, request.invocation)
    return Resolution(
        request=request,
        inputs=inputs,
        target_fact=target_fact,
        containers=containers,
        selected_roots=selected,
        excluded_roots=excluded,
        paths=paths,
        authority_digests=digests,
    )


def load_inputs(
    catalog_path: Path,
    targets_path: Path,
    containers_path: Path,
    datacenter_path: Path,
    contract_path: Path,
) -> tuple[Inputs, AuthorityDigests]:
    authorities = (
        (catalog_path, "software catalog"),
        (targets_path, "target registry"),
        (containers_path, "container registry"),
        (datacenter_path, "datacenter contract"),
        (contract_path, "target contract"),
    )
    payloads = tuple(read_authority(path, label) for path, label in authorities)
    catalog = load_catalog(catalog_path, payloads[0])
    targets = load_registry(targets_path, TargetRegistryDocument, payloads[1])
    containers = load_registry(containers_path, ContainerRegistryDocument, payloads[2])
    datacenter = load_json(datacenter_path, DatacenterArtifact, payloads[3])
    contract = load_target_contract(contract_path, payloads[4])
    contracts_root = contract_path.parents[1]
    peers: list[TargetArtifact] = []
    for target in datacenter.targets:
        peer_path = contracts_root / target / "contract.json"
        peer_payload = read_authority(peer_path, f"peer contract {target}")
        peers.append(load_target_contract(peer_path, peer_payload))
    inputs = Inputs(catalog, targets, containers, datacenter, contract, tuple(peers))
    digests = AuthorityDigests(*(sha256(payload).hexdigest() for payload in payloads))
    return inputs, digests


def tool_digest(root: Path) -> str:
    """Digest every module a resolution actually depends on.

    The contract models and artifacts live in tools/chapar_datacenter_*.py.
    Covering only tools/chapar_config left selection.versions.resolver_sha256
    claiming to pin resolver code that it did not hash.
    """
    sources = (
        *(root / "tools/chapar_config").glob("*.py"),
        *root.glob("tools/chapar_datacenter_*.py"),
    )
    digest = sha256()
    for path in sorted(sources):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()
