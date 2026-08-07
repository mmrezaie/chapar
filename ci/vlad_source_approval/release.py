from __future__ import annotations

import datetime as dt
import re
import subprocess

from .core import (
    RELEASE_SCHEMA,
    REMOTE,
    SOURCE_SCHEMA,
    JsonMap,
    ReleaseInputs,
    canonical_absolute,
    expect_string,
    fail,
    parse_json,
    read_file,
    require,
    require_commit,
    require_identifier,
    require_schema,
    require_sha,
    require_target,
)


def validate_source(data: JsonMap, chapar_root: str, approved_by: str, ticket: str) -> None:
    require_schema(data, SOURCE_SCHEMA)
    root = canonical_absolute(chapar_root, "chapar root")
    require(expect_string(data, "approved_by") == approved_by and approved_by != "", "approved_by mismatch")
    require(expect_string(data, "change_ticket") == ticket and ticket != "", "change_ticket mismatch")
    approved_at = expect_string(data, "approved_at")
    require(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", approved_at) is not None, "approved_at must be RFC3339 UTC")
    try:
        dt.datetime.strptime(approved_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except ValueError as error:
        fail(f"approved_at is invalid: {error}")
    require(expect_string(data, "chapar_remote") == REMOTE, "chapar_remote mismatch")
    commit = require_commit(expect_string(data, "chapar_commit"))
    lock_path = expect_string(data, "source_lock_path")
    require(lock_path == f"{root}/containers/images/sources-lock.json", "source_lock_path mismatch")
    lock = read_file(lock_path, "source lock")
    require(lock.sha256 == require_sha(expect_string(data, "source_lock_sha256"), "source lock digest"), "source lock content mismatch")
    git_env = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LANG": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0"}
    git_prefix = ["/usr/bin/git", "--no-pager", "--no-replace-objects", "-C", root, "-c", f"safe.directory={root}", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false"]
    head = subprocess.run([*git_prefix, "rev-parse", "HEAD"], check=True, capture_output=True, text=True, env=git_env).stdout.strip()
    remote = subprocess.run([*git_prefix, "remote", "get-url", "origin"], check=True, capture_output=True, text=True, env=git_env).stdout.strip()
    require(head == commit, "approved commit does not match checkout HEAD")
    require(remote == REMOTE, "checkout origin does not match approved remote")


def release_data(inputs: ReleaseInputs) -> JsonMap:
    release_dir = canonical_absolute(inputs.release_dir, "release dir")
    metadata = canonical_absolute(inputs.metadata, "metadata path")
    spack_lock = canonical_absolute(inputs.spack_lock, "Spack lock path")
    require(metadata == f"{release_dir}/metadata.json", "metadata path is outside release")
    require(spack_lock == f"{release_dir}/spack.lock", "Spack lock must be release-local")
    require(inputs.status == "integrity-passed", "release status must be integrity-passed")
    metadata_bytes = read_file(metadata, "release metadata")
    lock_bytes = read_file(spack_lock, "Spack lock")
    metadata_json = parse_json(metadata_bytes.content)
    identity = metadata_json.get("identity")
    digests = metadata_json.get("digests")
    if not isinstance(identity, dict) or not isinstance(digests, dict):
        fail("release metadata identity or digests missing")
    identity_map: JsonMap = identity
    digest_map: JsonMap = digests
    require(expect_string(identity_map, "release_id") == inputs.release_id, "release metadata ID mismatch")
    require(expect_string(identity_map, "target") == inputs.target, "release metadata target mismatch")
    require(expect_string(digest_map, "release_local_lock_sha256") == lock_bytes.sha256, "release-local lock digest mismatch")
    for name, filename in (("selection_sha256", "selection.json"), ("effective_manifest_sha256", "spack.yaml"), ("target_policy_sha256", "target-policy.yaml")):
        require(expect_string(digest_map, name) == read_file(f"{release_dir}/{filename}", filename).sha256, f"release-local byte digest mismatch: {name}")
    return {
        "schema": RELEASE_SCHEMA, "release_dir": release_dir,
        "release_id": require_identifier(inputs.release_id, "release_id"),
        "run_id": require_identifier(expect_string(identity_map, "run_id"), "run_id"),
        "datacenter": require_identifier(expect_string(identity_map, "datacenter"), "datacenter"),
        "software_set": require_identifier(expect_string(identity_map, "software_set"), "software_set"),
        "chapar_commit": require_commit(inputs.chapar_commit),
        "source_lock_sha256": require_sha(inputs.source_lock_sha256, "source lock digest"),
        "target": require_target(inputs.target), "metadata_path": metadata,
        "metadata_sha256": metadata_bytes.sha256,
        "selection_sha256": require_sha(expect_string(digest_map, "selection_sha256"), "selection digest"),
        "datacenter_contract_sha256": require_sha(expect_string(digest_map, "datacenter_contract_sha256"), "datacenter contract digest"),
        "target_contract_sha256": require_sha(expect_string(digest_map, "target_contract_sha256"), "target contract digest"),
        "software_catalog_sha256": require_sha(expect_string(digest_map, "software_catalog_sha256"), "software catalog digest"),
        "target_registry_sha256": require_sha(expect_string(digest_map, "target_registry_sha256"), "target registry digest"),
        "container_registry_sha256": require_sha(expect_string(digest_map, "container_registry_sha256"), "container registry digest"),
        "effective_manifest_sha256": require_sha(expect_string(digest_map, "effective_manifest_sha256"), "effective manifest digest"),
        "target_policy_sha256": require_sha(expect_string(digest_map, "target_policy_sha256"), "target policy digest"),
        "spack_lock_path": spack_lock,
        "spack_lock_sha256": lock_bytes.sha256, "status": inputs.status,
    }


def validate_release(data: JsonMap, inputs: ReleaseInputs | None = None) -> None:
    require_schema(data, RELEASE_SCHEMA)
    release_dir = canonical_absolute(expect_string(data, "release_dir"), "release dir")
    release_id = require_identifier(expect_string(data, "release_id"), "release_id")
    require_identifier(expect_string(data, "run_id"), "run_id")
    require_identifier(expect_string(data, "datacenter"), "datacenter")
    require_identifier(expect_string(data, "software_set"), "software_set")
    require_commit(expect_string(data, "chapar_commit"))
    require_sha(expect_string(data, "source_lock_sha256"), "source lock digest")
    require_target(expect_string(data, "target"))
    metadata = expect_string(data, "metadata_path")
    spack_lock = expect_string(data, "spack_lock_path")
    require(metadata == f"{release_dir}/metadata.json", "metadata path mismatch")
    require(spack_lock == f"{release_dir}/spack.lock", "Spack lock is not release-local")
    require(expect_string(data, "status") == "integrity-passed", "release status mismatch")
    require(read_file(metadata, "release metadata").sha256 == require_sha(expect_string(data, "metadata_sha256"), "metadata digest"), "metadata content drift")
    require(read_file(spack_lock, "Spack lock").sha256 == require_sha(expect_string(data, "spack_lock_sha256"), "Spack lock digest"), "Spack lock content drift")
    metadata_json = parse_json(read_file(metadata, "release metadata").content)
    identity = metadata_json.get("identity")
    digests = metadata_json.get("digests")
    if not isinstance(identity, dict) or not isinstance(digests, dict):
        fail("release metadata identity or digests missing")
    identity_map: JsonMap = identity
    digest_map: JsonMap = digests
    require(expect_string(identity_map, "release_id") == release_id, "release metadata ID drift")
    for field in ("selection_sha256", "datacenter_contract_sha256", "target_contract_sha256", "software_catalog_sha256", "target_registry_sha256", "container_registry_sha256", "effective_manifest_sha256", "target_policy_sha256"):
        require(expect_string(data, field) == expect_string(digest_map, field), f"release metadata digest drift: {field}")
    require(expect_string(data, "spack_lock_sha256") == expect_string(digest_map, "release_local_lock_sha256"), "release metadata lock digest drift")
    for name, filename in (("selection_sha256", "selection.json"), ("effective_manifest_sha256", "spack.yaml"), ("target_policy_sha256", "target-policy.yaml")):
        require(expect_string(data, name) == read_file(f"{release_dir}/{filename}", filename).sha256, f"release-local byte drift: {name}")
    if inputs is not None:
        expected = release_data(inputs)
        require(data == expected, "release binding fields do not match expected inputs")
