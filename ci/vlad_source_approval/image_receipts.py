from __future__ import annotations

import argparse
import os

from .core import (
    BUILDER_SCHEMA,
    RUNTIME_SCHEMA,
    JsonMap,
    canonical_absolute,
    expect_integer,
    expect_string,
    read_file,
    receipt,
    require,
    require_commit,
    require_identifier,
    require_schema,
    require_sha,
    require_target,
)
from .release import validate_release


def validate_builder(data: JsonMap, expected_commit: str | None = None) -> None:
    require_schema(data, BUILDER_SCHEMA)
    canonical_absolute(expect_string(data, "build_root"), "build root")
    commit = require_commit(expect_string(data, "chapar_commit"))
    if expected_commit is not None:
        require(commit == require_commit(expected_commit), "builder commit mismatch")
    source_lock_sha = require_sha(expect_string(data, "source_lock_sha256"), "source lock digest")
    release_path = canonical_absolute(expect_string(data, "release_binding"), "release binding")
    release_json, release_file = receipt(release_path)
    validate_release(release_json)
    require(release_file.sha256 == require_sha(expect_string(data, "release_binding_sha256"), "release binding digest"), "release binding digest mismatch")
    require(expect_string(release_json, "chapar_commit") == commit, "release and builder commits differ")
    require(expect_string(release_json, "source_lock_sha256") == source_lock_sha, "release and builder source locks differ")
    require(expect_string(release_json, "spack_lock_path") == f"{expect_string(release_json, 'release_dir')}/spack.lock", "builder release-local lock mismatch")
    target = require_target(expect_string(data, "target"))
    require(expect_string(release_json, "target") == target, "release and builder targets differ")
    require_identifier(expect_string(data, "image_id"), "image_id")
    image_path = canonical_absolute(expect_string(data, "image_path"), "image path")
    image = read_file(image_path, "builder image")
    require(image.sha256 == require_sha(expect_string(data, "image_sha256"), "image digest"), "builder image digest mismatch")
    require(image.size == expect_integer(data, "image_size"), "builder image size mismatch")
    require(image.mode == 0o444, "builder image is not sealed mode 0444")
    expected_suffix = f"/{target}/{expect_string(data, 'image_id')}/{image.sha256}/{os.path.basename(image_path)}"
    require(image_path.endswith(expected_suffix), "builder image is outside target/image/hash custody")
    validation_root = canonical_absolute(expect_string(data, "validation_root"), "validation root")
    require(os.path.dirname(release_path) == validation_root, "release binding is outside validation root")


def builder_data(args: argparse.Namespace) -> JsonMap:
    release_json, release_file = receipt(args.release_binding)
    validate_release(release_json)
    build_root = canonical_absolute(args.build_root, "build root")
    require(expect_string(release_json, "spack_lock_path") == f"{expect_string(release_json, 'release_dir')}/spack.lock", "build does not bind release-local lock")
    image = read_file(args.image, "builder image")
    require(image.sha256 == require_sha(args.image_sha256, "image digest"), "builder image digest mismatch")
    require(image.size == args.image_size and args.image_size > 0, "builder image size mismatch")
    require(image.mode == 0o444, "builder image is not sealed mode 0444")
    validation_root = os.path.dirname(canonical_absolute(args.output, "builder handoff path"))
    data: JsonMap = {
        "schema": BUILDER_SCHEMA, "build_root": build_root,
        "chapar_commit": require_commit(args.chapar_commit),
        "source_lock_sha256": require_sha(args.source_lock_sha256, "source lock digest"),
        "release_binding": canonical_absolute(args.release_binding, "release binding"),
        "release_binding_sha256": release_file.sha256, "target": require_target(args.target),
        "image_id": require_identifier(args.image_id, "image_id"),
        "image_path": canonical_absolute(args.image, "image path"),
        "image_sha256": image.sha256, "image_size": image.size,
        "validation_root": validation_root,
    }
    validate_builder(data)
    return data


def runtime_data(args: argparse.Namespace) -> JsonMap:
    builder_json, builder_file = receipt(args.builder_handoff, args.builder_handoff_sha256)
    validate_builder(builder_json)
    release_path = canonical_absolute(args.release_binding, "release binding")
    require(release_path == expect_string(builder_json, "release_binding"), "runtime release binding mismatch")
    _, release_file = receipt(release_path, expect_string(builder_json, "release_binding_sha256"))
    target = require_target(args.target)
    require(target == expect_string(builder_json, "target"), "runtime target mismatch")
    image_sha = require_sha(args.sha256, "image digest")
    require(image_sha == expect_string(builder_json, "image_sha256"), "runtime image digest differs from builder")
    validator_root = canonical_absolute(args.validator_root, "validator root")
    validator_image_root = canonical_absolute(args.validator_image_root, "validator image root")
    image_path = canonical_absolute(args.image, "runtime image")
    expected_parent = f"{validator_image_root}/{target}/{expect_string(builder_json, 'image_id')}/{image_sha}"
    require(os.path.dirname(image_path) == expected_parent, "runtime image is outside validator custody")
    image = read_file(image_path, "runtime image")
    require(image.sha256 == image_sha and image.size == expect_integer(builder_json, "image_size"), "runtime image bytes differ from builder")
    output = canonical_absolute(args.output, "runtime receipt path")
    preflight = read_file(args.preflight, "runtime preflight")
    smoke = read_file(args.smoke_output, "smoke output")
    return {
        "schema": RUNTIME_SCHEMA, "builder_handoff_sha256": builder_file.sha256,
        "release_binding_sha256": release_file.sha256, "target": target,
        "image_path": image_path, "image_sha256": image_sha,
        "validator_root": validator_root, "validator_image_root": validator_image_root,
        "runtime_receipt_path": output, "runtime_preflight_sha256": preflight.sha256,
        "smoke_output_sha256": smoke.sha256, "status": "passed",
    }


def validate_runtime(data: JsonMap, args: argparse.Namespace) -> None:
    require_schema(data, RUNTIME_SCHEMA)
    require(expect_string(data, "status") == "passed", "runtime status must be passed")
    require(canonical_absolute(expect_string(data, "runtime_receipt_path"), "runtime receipt path") == canonical_absolute(args.runtime_receipt, "runtime receipt path"), "runtime receipt self-path mismatch")
    builder_json, builder_file = receipt(args.builder_handoff, args.builder_handoff_sha256)
    validate_builder(builder_json)
    require(expect_string(data, "builder_handoff_sha256") == builder_file.sha256, "runtime builder digest mismatch")
    release_path = canonical_absolute(args.release_binding, "release binding")
    require(release_path == expect_string(builder_json, "release_binding"), "runtime release path mismatch")
    _, release_file = receipt(release_path, expect_string(builder_json, "release_binding_sha256"))
    require(expect_string(data, "release_binding_sha256") == release_file.sha256, "runtime release digest mismatch")
    target = require_target(args.target)
    require(expect_string(data, "target") == target == expect_string(builder_json, "target"), "runtime target mismatch")
    image_sha = require_sha(expect_string(data, "image_sha256"), "runtime image digest")
    require(image_sha == expect_string(builder_json, "image_sha256"), "runtime and builder image digests differ")
    image_path = canonical_absolute(expect_string(data, "image_path"), "runtime image")
    validator_image_root = canonical_absolute(expect_string(data, "validator_image_root"), "validator image root")
    expected_parent = f"{validator_image_root}/{target}/{expect_string(builder_json, 'image_id')}/{image_sha}"
    require(os.path.dirname(image_path) == expected_parent, "runtime image custody path mismatch")
    image = read_file(image_path, "runtime image")
    require(image.sha256 == image_sha and image.size == expect_integer(builder_json, "image_size"), "runtime image content drift")
    receipt_root = os.path.dirname(canonical_absolute(args.runtime_receipt, "runtime receipt"))
    require(canonical_absolute(expect_string(data, "validator_root"), "validator root") + f"/{target}/{expect_string(builder_json, 'image_id')}/{image_sha}" == receipt_root, "runtime validator root mismatch")
    require(read_file(f"{receipt_root}/runtime-preflight.json", "runtime preflight").sha256 == require_sha(expect_string(data, "runtime_preflight_sha256"), "preflight digest"), "runtime preflight drift")
    require(read_file(f"{receipt_root}/pyxis-smoke.txt", "smoke output").sha256 == require_sha(expect_string(data, "smoke_output_sha256"), "smoke digest"), "smoke output drift")
