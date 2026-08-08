from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from .core import (
    BUILDER_SCHEMA,
    DIR_FLAGS,
    RELEASE_SCHEMA,
    REMOTE,
    SOURCE_SCHEMA,
    JsonMap,
    ReleaseInputs,
    Sha256,
    opened_path,
    parse_json,
    read_file,
    receipt,
    require,
    write_exclusive_json,
)
from .evidence import (
    expect_child_failure,
    faccess,
    mutated,
    require_directory_identity,
    require_owner_mode,
    seal_evidence,
    verify_empty_evidence,
)
from .image_receipts import runtime_data, validate_builder, validate_runtime
from .release import release_data, validate_release, validate_source


def self_test() -> None:
    require(hasattr(os, "fork"), "setup error: receipt self-test requires POSIX fork")
    cases: list[str] = []
    with tempfile.TemporaryDirectory(prefix="vlad-receipt-self-test-") as temp:
        root = Path(temp).resolve()
        payload = root / "payload"
        payload.write_bytes(b"stable bytes\n")
        digest = hashlib.sha256(payload.read_bytes()).hexdigest()
        symlink = root / "symlink"
        symlink.symlink_to(payload)
        cases.append(expect_child_failure("symlink-component", lambda: read_file(str(symlink), "symlink"), "symlink"))
        duplicate = b'{"schema":"x","nested":{"a":1,"a":2}}'
        cases.append(expect_child_failure("recursive-duplicate-key", lambda: parse_json(duplicate), "duplicate JSON key: a"))
        output = root / "receipt.json"
        data: JsonMap = {"directory_identity": "1:2"}
        write_exclusive_json(str(output), data)
        cases.append(expect_child_failure("receipt-o-excl-collision", lambda: write_exclusive_json(str(output), data), "File exists"))
        require(read_file(str(output), "self-test receipt", 0o444).sha256 == hashlib.sha256(output.read_bytes()).hexdigest(), "self-test receipt digest drift")
        require(digest == hashlib.sha256(b"stable bytes\n").hexdigest(), "stable descriptor hash failed")
        replaced = root / "replaced"
        replaced.mkdir()
        with opened_path(str(replaced), final_directory=True) as fd:
            identity = os.fstat(fd).st_ino
            replaced.rmdir()
            replaced.mkdir()
            require(os.fstat(fd).st_ino == identity and os.stat(replaced).st_ino != identity, "replacement race fixture failed")
        cases.append("component-replacement-open-descriptor")

        source_root = root / "source-checkout"
        source_lock = source_root / "containers/images/sources-lock.json"
        source_lock.parent.mkdir(parents=True)
        source_lock.write_text('{"status":"fixture"}\n', encoding="utf-8")
        git_env = {
            "PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LANG": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_AUTHOR_NAME": "Fixture Author",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture Committer",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        subprocess.run(["/usr/bin/git", "init", "--initial-branch=fixture", str(source_root)], check=True, capture_output=True, env=git_env)
        subprocess.run(["/usr/bin/git", "-C", str(source_root), "add", "containers/images/sources-lock.json"], check=True, capture_output=True, env=git_env)
        subprocess.run(["/usr/bin/git", "-C", str(source_root), "commit", "-m", "fixture source"], check=True, capture_output=True, env=git_env)
        subprocess.run(["/usr/bin/git", "-C", str(source_root), "remote", "add", "origin", REMOTE], check=True, capture_output=True, env=git_env)
        commit = subprocess.run(["/usr/bin/git", "--no-pager", "--no-replace-objects", "-C", str(source_root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True, env=git_env).stdout.strip()
        source_data: JsonMap = {
            "schema": SOURCE_SCHEMA, "approved_by": "fixture-approver",
            "approved_at": "2026-08-05T12:00:00Z", "change_ticket": "fixture-ticket",
            "chapar_remote": REMOTE, "chapar_commit": commit,
            "source_lock_path": str(source_lock),
            "source_lock_sha256": hashlib.sha256(source_lock.read_bytes()).hexdigest(),
        }
        validate_source(source_data, str(source_root), "fixture-approver", "fixture-ticket")
        cases.append("source-schema-happy")
        unknown_source = {**source_data, "unknown": "rejected"}
        cases.append(expect_child_failure("source-unknown-key", lambda: validate_source(unknown_source, str(source_root), "fixture-approver", "fixture-ticket"), "key set mismatch"))
        cases.append(expect_child_failure("source-wrong-identity", lambda: validate_source(mutated(source_data, "schema", RELEASE_SCHEMA), str(source_root), "fixture-approver", "fixture-ticket"), "wrong schema identity"))
        cases.append(expect_child_failure("source-wrong-time", lambda: validate_source(mutated(source_data, "approved_at", "2026-08-05 12:00:00"), str(source_root), "fixture-approver", "fixture-ticket"), "RFC3339 UTC"))
        cases.append(expect_child_failure("source-no-dot-git-remote", lambda: validate_source(mutated(source_data, "chapar_remote", "https://github.com/nscaledev/chapar"), str(source_root), "fixture-approver", "fixture-ticket"), "chapar_remote mismatch"))
        cases.append(expect_child_failure("source-unrelated-remote", lambda: validate_source(mutated(source_data, "chapar_remote", "https://example.invalid/chapar.git"), str(source_root), "fixture-approver", "fixture-ticket"), "chapar_remote mismatch"))
        cases.append(expect_child_failure("source-noncanonical-path", lambda: validate_source(mutated(source_data, "source_lock_path", str(source_root) + "/./containers/images/sources-lock.json"), str(source_root), "fixture-approver", "fixture-ticket"), "source_lock_path mismatch"))
        cases.append(expect_child_failure("source-lock-hash-drift", lambda: validate_source(mutated(source_data, "source_lock_sha256", "0" * 64), str(source_root), "fixture-approver", "fixture-ticket"), "source lock content mismatch"))

        build_root = root / "build"
        release_dir = root / "vlad/linux/releases/release-1"
        release_dir.mkdir(parents=True)
        spack_lock = release_dir / "spack.lock"
        spack_lock.write_text('{"lock":"fixture"}\n', encoding="utf-8")
        (release_dir / "selection.json").write_text('{"selection":"fixture"}\n', encoding="utf-8")
        (release_dir / "spack.yaml").write_text('spack:\n  specs: []\n', encoding="utf-8")
        (release_dir / "target-policy.yaml").write_text('target: fixture\n', encoding="utf-8")
        fixture_digests = {name: "c" * 64 for name in ("datacenter_contract_sha256", "target_contract_sha256", "software_catalog_sha256", "target_registry_sha256", "container_registry_sha256")}
        fixture_digests.update({name: hashlib.sha256((release_dir / filename).read_bytes()).hexdigest() for name, filename in (("selection_sha256", "selection.json"), ("effective_manifest_sha256", "spack.yaml"), ("target_policy_sha256", "target-policy.yaml"))})
        fixture_digests["release_local_lock_sha256"] = hashlib.sha256(spack_lock.read_bytes()).hexdigest()
        metadata = release_dir / "metadata.json"
        metadata.write_text(json.dumps({"identity": {"datacenter": "example-lab", "software_set": "vlad", "target": "linux-x86_64-v4", "release_id": "release-1", "run_id": "run-1"}, "digests": fixture_digests}) + "\n", encoding="utf-8")
        validation_root = root / "validation"
        validation_root.mkdir()
        release_path = validation_root / "release-binding.json"
        release_inputs_fixture = ReleaseInputs(str(release_path), str(release_dir), str(metadata), str(spack_lock), "a" * 40, "b" * 64, "linux-x86_64-v4", "release-1", "integrity-passed")
        release_json = release_data(release_inputs_fixture)
        write_exclusive_json(str(release_path), release_json)
        validate_release(receipt(str(release_path))[0], release_inputs_fixture)
        cases.append("release-schema-happy")
        cases.append(expect_child_failure("release-wrong-status", lambda: validate_release(mutated(release_json, "status", "promoted")), "release status mismatch"))
        cases.append(expect_child_failure("release-unknown-key", lambda: validate_release({**release_json, "unknown": "rejected"}), "key set mismatch"))
        wrong_release_dir = root / "vlad/linux/releases/wrong-release"
        wrong_release_dir.mkdir(parents=True)
        wrong_metadata = wrong_release_dir / "metadata.json"
        wrong_metadata.write_text('{}\n', encoding="utf-8")
        cases.append(expect_child_failure("release-wrong-metadata", lambda: release_data(ReleaseInputs(str(root / "wrong.json"), str(wrong_release_dir), str(wrong_metadata), str(spack_lock), "a" * 40, "b" * 64, "linux-x86_64-v4", "release-1", "integrity-passed")), "Spack lock must be release-local"))

        image_bytes = b"sealed image bytes"
        image_sha = hashlib.sha256(image_bytes).hexdigest()
        image_dir = root / f"candidates/linux-x86_64-v4/image-1/{image_sha}"
        image_dir.mkdir(parents=True)
        image = image_dir / "nvidia-vlad.sqsh"
        image.write_bytes(image_bytes)
        image.chmod(0o444)
        builder_path = validation_root / "builder-handoff.json"
        builder_json: JsonMap = {
            "schema": BUILDER_SCHEMA, "build_root": str(build_root),
            "chapar_commit": "a" * 40, "source_lock_sha256": "b" * 64,
            "release_binding": str(release_path),
            "release_binding_sha256": hashlib.sha256(release_path.read_bytes()).hexdigest(),
            "target": "linux-x86_64-v4", "image_id": "image-1",
            "image_path": str(image), "image_sha256": image_sha,
            "image_size": len(image_bytes), "validation_root": str(validation_root),
        }
        validate_builder(builder_json)
        write_exclusive_json(str(builder_path), builder_json)
        cases.append("builder-schema-happy")
        cases.append(expect_child_failure("builder-image-hash-drift", lambda: validate_builder(mutated(builder_json, "image_sha256", "0" * 64)), "builder image digest mismatch"))
        cases.append(expect_child_failure("builder-receipt-unknown-key", lambda: validate_builder({**builder_json, "unknown": "rejected"}), "key set mismatch"))

        validator_image_root = root / "validator-images"
        validator_image_dir = validator_image_root / f"linux-x86_64-v4/image-1/{image_sha}"
        validator_image_dir.mkdir(parents=True)
        validator_image = validator_image_dir / image.name
        validator_image.write_bytes(image_bytes)
        validator_image.chmod(0o444)
        validator_root = root / "validator-receipts"
        receipt_root = validator_root / f"linux-x86_64-v4/image-1/{image_sha}"
        receipt_root.mkdir(parents=True)
        preflight = receipt_root / "runtime-preflight.json"
        smoke = receipt_root / "pyxis-smoke.txt"
        preflight.write_text('{"status":"pass"}\n', encoding="utf-8")
        smoke.write_text("smoke passed\n", encoding="utf-8")
        runtime_path = receipt_root / "receipt.json"
        runtime_args = argparse.Namespace(
            builder_handoff=str(builder_path), builder_handoff_sha256=hashlib.sha256(builder_path.read_bytes()).hexdigest(),
            release_binding=str(release_path), target="linux-x86_64-v4", sha256=image_sha,
            validator_root=str(validator_root), validator_image_root=str(validator_image_root),
            image=str(validator_image), output=str(runtime_path), preflight=str(preflight), smoke_output=str(smoke),
        )
        runtime_json = runtime_data(runtime_args)
        write_exclusive_json(str(runtime_path), runtime_json)
        runtime_verify_args = argparse.Namespace(
            runtime_receipt=str(runtime_path), builder_handoff=str(builder_path),
            builder_handoff_sha256=runtime_args.builder_handoff_sha256,
            release_binding=str(release_path), target="linux-x86_64-v4",
        )
        validate_runtime(runtime_json, runtime_verify_args)
        cases.append("runtime-schema-happy")
        cases.append(expect_child_failure("runtime-wrong-status", lambda: validate_runtime(mutated(runtime_json, "status", "failed"), runtime_verify_args), "runtime status must be passed"))
        cases.append(expect_child_failure("runtime-receipt-self-path-drift", lambda: validate_runtime(mutated(runtime_json, "runtime_receipt_path", str(root / "other.json")), runtime_verify_args), "self-path mismatch"))
        cases.append(expect_child_failure("runtime-preflight-hash-drift", lambda: validate_runtime(mutated(runtime_json, "runtime_preflight_sha256", "0" * 64), runtime_verify_args), "runtime preflight drift"))
        cases.append(expect_child_failure("receipt-digest-drift", lambda: receipt(str(runtime_path), "0" * 64), "receipt SHA-256 mismatch"))

        capture = root / "capture.txt"
        cli_path = Path(__file__).resolve().parents[1] / "verify-vlad-source-approval.py"
        capture_child = subprocess.run([sys.executable, str(cli_path), "--run-and-capture", "--output", str(capture), "--", sys.executable, "-c", "print('captured')"], check=False, capture_output=True, text=True)
        require(capture_child.returncode == 0 and capture.read_text(encoding="utf-8") == "captured\n", f"run-and-capture CLI failed: {capture_child.stderr}")
        cases.append("run-and-capture-cli")
        collision_child = subprocess.run([sys.executable, str(cli_path), "--run-and-capture", "--output", str(capture), "--", sys.executable, "-c", "print('overwrite')"], check=False, capture_output=True, text=True)
        require(collision_child.returncode == 1 and "File exists" in collision_child.stderr, "capture O_EXCL collision failed for wrong reason")
        cases.append("run-and-capture-o-excl")

        evidence = root / "evidence"
        evidence.mkdir()
        evidence_file = evidence / "proof.txt"
        evidence_file.write_text("proof\n", encoding="utf-8")
        original = evidence.stat()
        identity = f"{original.st_dev}:{original.st_ino}"
        seal_args = argparse.Namespace(seal_evidence_directory=str(evidence), expected_directory_identity=identity, file_mode="0444", directory_mode="0555")
        seal_evidence(seal_args)
        cases.append("seal-evidence-happy")
        cases.append(expect_child_failure("sealed-identity-drift", lambda: require_directory_identity(evidence.stat(), "0:0", "sealed directory"), "identity drift"))
        sealed_bytes = read_file(str(evidence_file), "sealed evidence", 0o444)
        cases.append(expect_child_failure("sealed-hash-drift", lambda: require(sealed_bytes.sha256 == Sha256("0" * 64), "sealed file digest mismatch"), "sealed file digest mismatch"))
        cases.append(expect_child_failure("publisher-role-denial", lambda: require_owner_mode(evidence_file.stat(), os.geteuid() + 1, 0o444, "sealed file"), "owner/mode mismatch"))
        cases.append(expect_child_failure("writable-evidence-ancestor", lambda: require_owner_mode(root.stat(), 0, 0o555, "evidence ancestor"), "owner/mode mismatch"))
        evidence.chmod(0o755)
        evidence.rename(root / "evidence-old")
        evidence.mkdir()
        cases.append(expect_child_failure("post-seal-directory-replacement", lambda: seal_evidence(argparse.Namespace(seal_evidence_directory=str(evidence), expected_directory_identity=identity, file_mode="0444", directory_mode="0555")), "identity drift"))
        preseal = root / "preseal"
        preseal.mkdir()
        preseal_info = preseal.stat()
        preseal_identity = f"{preseal_info.st_dev}:{preseal_info.st_ino}"
        preseal.rmdir()
        preseal.mkdir()
        cases.append(expect_child_failure("pre-seal-directory-replacement", lambda: seal_evidence(argparse.Namespace(seal_evidence_directory=str(preseal), expected_directory_identity=preseal_identity, file_mode="0444", directory_mode="0555")), "identity drift"))

        if sys.platform.startswith("linux"):
            cases.append(expect_child_failure("linux-evidence-role-setup", lambda: verify_empty_evidence(str(preseal), "validator"), "owner role"))
        else:
            for label in ("linux-faccess-setup-error", "evidence-cli-boundary-setup-error"):
                setup_case = expect_child_failure(label, lambda: faccess(os.open("/", DIR_FLAGS), os.W_OK), "require Linux")
                print(f"SETUP-UNSUPPORTED:{setup_case}: platform={sys.platform}")
    print("Vlad receipt and evidence self-test passed: " + ",".join(cases))
