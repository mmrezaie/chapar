#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ci.vlad_source_approval.core import (
    ContractError,
    ReleaseInputs,
    fail,
    receipt,
    write_exclusive_json,
)
from ci.vlad_source_approval.evidence import (
    extract_canonical,
    run_and_capture,
    seal_evidence,
    verify_empty_evidence,
    verify_sealed,
)
from ci.vlad_source_approval.image_receipts import (
    builder_data,
    runtime_data,
    validate_builder,
    validate_runtime,
)
from ci.vlad_source_approval.release import (
    release_data,
    validate_release,
    validate_source,
)
from ci.vlad_source_approval.self_test import self_test


def add_release_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--release-dir")
    parser.add_argument("--metadata")
    parser.add_argument("--spack-lock")
    parser.add_argument("--chapar-commit")
    parser.add_argument("--source-lock-sha256")
    parser.add_argument("--target")
    parser.add_argument("--release-id")
    parser.add_argument("--status")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--receipt")
    actions.add_argument("--write-release-binding", dest="write_release_binding")
    actions.add_argument("--verify-release-binding", dest="verify_release_binding")
    actions.add_argument("--write-builder-handoff", dest="write_builder_handoff")
    actions.add_argument("--verify-builder-handoff", dest="verify_builder_handoff")
    actions.add_argument("--write-runtime-receipt", dest="write_runtime_receipt")
    actions.add_argument("--verify-runtime-receipt", dest="verify_runtime_receipt")
    actions.add_argument("--verify-empty-evidence-directory", dest="verify_empty_evidence_directory")
    actions.add_argument("--run-and-capture", action="store_true")
    actions.add_argument("--seal-evidence-directory", dest="seal_evidence_directory")
    actions.add_argument("--verify-sealed-evidence-directory", dest="verify_sealed_evidence_directory")
    actions.add_argument("--extract-canonical-field", action="store_true")
    actions.add_argument("--self-test", action="store_true")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--expected-approved-by")
    parser.add_argument("--expected-change-ticket")
    parser.add_argument("--chapar-root")
    add_release_arguments(parser)
    parser.add_argument("--build-root")
    parser.add_argument("--release-binding")
    parser.add_argument("--image-id")
    parser.add_argument("--image")
    parser.add_argument("--image-sha256")
    parser.add_argument("--image-size", type=int)
    parser.add_argument("--expected-chapar-commit")
    parser.add_argument("--builder-handoff")
    parser.add_argument("--builder-handoff-sha256")
    parser.add_argument("--validator-root")
    parser.add_argument("--validator-image-root")
    parser.add_argument("--preflight")
    parser.add_argument("--smoke-output")
    parser.add_argument("--sha256")
    parser.add_argument("--owner-role")
    parser.add_argument("--output")
    parser.add_argument("--capture-stderr", action="store_true")
    parser.add_argument("--expected-directory-identity")
    parser.add_argument("--file-mode")
    parser.add_argument("--directory-mode")
    parser.add_argument("--expected-file")
    parser.add_argument("--schema", choices=("directory-identity", "sealed-evidence"))
    parser.add_argument("--field")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def required(value: str | int | None, label: str) -> str:
    if type(value) is not str or value == "":
        fail(f"{label} is required")
    return value


def release_inputs(args: argparse.Namespace, output: str) -> ReleaseInputs:
    return ReleaseInputs(output, required(args.release_dir, "release dir"), required(args.metadata, "metadata"), required(args.spack_lock, "Spack lock"), required(args.chapar_commit, "commit"), required(args.source_lock_sha256, "source lock digest"), required(args.target, "target"), required(args.release_id, "release ID"), required(args.status, "status"))


def dispatch(args: argparse.Namespace) -> None:
    if args.self_test:
        self_test()
    elif args.receipt:
        data, _ = receipt(args.receipt, required(args.expected_sha256, "expected digest"))
        validate_source(data, required(args.chapar_root, "chapar root"), required(args.expected_approved_by, "expected approver"), required(args.expected_change_ticket, "expected ticket"))
        print(json.dumps(data, sort_keys=True, separators=(",", ":")))
    elif args.write_release_binding:
        inputs = release_inputs(args, args.write_release_binding)
        data = release_data(inputs)
        write_exclusive_json(inputs.output, data)
        validate_release(receipt(inputs.output)[0], inputs)
    elif args.verify_release_binding:
        inputs = release_inputs(args, args.verify_release_binding)
        data, _ = receipt(inputs.output)
        validate_release(data, inputs)
        print(json.dumps(data, sort_keys=True, separators=(",", ":")))
    elif args.write_builder_handoff:
        args.output = args.write_builder_handoff
        data = builder_data(args)
        write_exclusive_json(args.output, data)
        validate_builder(receipt(args.output)[0])
    elif args.verify_builder_handoff:
        data, _ = receipt(args.verify_builder_handoff, required(args.expected_sha256, "expected digest"))
        validate_builder(data, required(args.expected_chapar_commit, "expected commit"))
        print(json.dumps(data, sort_keys=True, separators=(",", ":")))
    elif args.write_runtime_receipt:
        args.output = args.write_runtime_receipt
        data = runtime_data(args)
        write_exclusive_json(args.output, data)
        verify_args = argparse.Namespace(**vars(args))
        verify_args.runtime_receipt = args.output
        validate_runtime(receipt(args.output)[0], verify_args)
    elif args.verify_runtime_receipt:
        args.runtime_receipt = args.verify_runtime_receipt
        data, _ = receipt(args.runtime_receipt, required(args.expected_sha256, "expected digest"))
        validate_runtime(data, args)
        print(json.dumps(data, sort_keys=True, separators=(",", ":")))
    elif args.verify_empty_evidence_directory:
        print(json.dumps(verify_empty_evidence(args.verify_empty_evidence_directory, required(args.owner_role, "owner role")), sort_keys=True, separators=(",", ":")))
    elif args.run_and_capture:
        if args.command and args.command[0] == "--":
            args.command = args.command[1:]
        run_and_capture(args)
    elif args.seal_evidence_directory:
        seal_evidence(args)
    elif args.verify_sealed_evidence_directory:
        print(json.dumps(verify_sealed(args), sort_keys=True, separators=(",", ":")))
    elif args.extract_canonical_field:
        extract_canonical(args)


def main() -> int:
    try:
        dispatch(parse_args())
    except (ContractError, OSError, subprocess.SubprocessError) as error:
        print(f"Vlad receipt verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
