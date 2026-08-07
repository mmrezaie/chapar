#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: containers/images/build-image.sh \
  --base nvidia-vlad --target linux-x86_64-v4 \
  --release-dir /resources/chapar/<env>/<os>/<arch>/releases/<release-id> \
  --image-id <image-id> \
  --datacenter-contract /etc/chapar/datacenter.json \
  --target-contract /etc/chapar/target-contract.json \
  [--enroot-build-root DIR] [--keep-container] [--plan-only]

Layer a promoted Chapar environment release into a digest-locked base image and
export an Enroot squashfs (.sqsh) that Pyxis consumes via
`srun --container-image=<path>`. Each selected container pairs one base image
with one Chapar environment and its own target list:

  --base nvidia-vlad   NVIDIA HPC-benchmarks 26.02 + the selected vlad set.
                        Targets: linux-x86_64-v4,
                        linux-aarch64-gb300.
  --base ubuntu-hpcsim Plain Ubuntu 24.04 + the hpcsim env. hpcsim policy
                        builds its own CUDA/GDR stack via Spack rather than
                        relying on an NVIDIA-branded OS image, so the base
                        stays vendor-neutral. Targets: linux-x86_64-generic.

The immutable release metadata, selection, effective manifest, target policy,
and release-local lock must match the selected contract and global registries.

What is injected: the environment's explicit root specs plus their transitive
link/run dependency closure, each copied to the SAME absolute prefix it was
built at. Spack embeds absolute RPATHs, so a prefix moved to a different path
would not resolve at run time. Build-only dependencies are excluded.

Module precedence: injected modules are reachable only via an explicit
`module load` after `module use`; nothing already present in the base image's
PATH or LD_LIBRARY_PATH is disturbed.

The base image is resolved by digest from sources-lock.json, never by tag: the
lock's floating_input_rule forbids tags as locked values. This script therefore
refuses to run until that lock reaches status "complete", which requires
resolving every locked category's index and per-platform descriptors on a
builder with skopeo (and registry credentials/reachability where the base
requires them).

--plan-only prints the resolved base digest, injection prefix list, and output
path, then exits without importing, mutating, or writing anything. It is the
only mode that is useful on a workstation.
USAGE
}

case "${1:-}" in
-h | --help)
    usage
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PYTHONPATH="${SCRIPT_DIR}" exec python3 - "${SCRIPT_DIR}" "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Final

SCRIPT_DIR = Path(sys.argv[1]).resolve()
sys.argv = [sys.argv[0], *sys.argv[2:]]
from registry import Container, Sources
from release_contract import ContractError, ReleaseRequest, verify_release

TARGETS_PATH = SCRIPT_DIR / "targets.json"
CONTAINERS_PATH = SCRIPT_DIR / "containers.json"
SOURCES_PATH = SCRIPT_DIR / "sources-lock.json"
CATALOG_PATH = SCRIPT_DIR.parents[1] / "envs" / "software" / "spack.yaml"
LOCK_VALIDATOR = SCRIPT_DIR / "tests" / "validate-locks.sh"
PROFILE_SCRIPT: Final = "/etc/profile.d/zz-chapar-image.sh"
DIGEST_RE: Final = re.compile(r"^sha256:[0-9a-f]{64}$")
ID_RE: Final = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
RUNTIME_DEPTYPES: Final = frozenset({"link", "run"})


class BuildError(Exception):
    pass


def fail(message: str) -> None:
    raise BuildError(message)


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    except (OSError, ValueError) as error:
        fail(f"{label} is unreadable or malformed: {error}")
    raise AssertionError("unreachable")


def absolute(raw: str, label: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        fail(f"{label} must be an absolute path: {raw}")
    return Path(os.path.normpath(str(path)))


def run(command: list[str], label: str) -> str:
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
    except FileNotFoundError:
        fail(f"{label} requires a tool that is not on PATH: {command[0]}")
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or "").strip().splitlines()
        tail = detail[-1] if detail else f"exit {error.returncode}"
        fail(f"{label} failed: {tail}")
    return completed.stdout


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        fail(f"required tool is missing from PATH: {name}")
    return path


# ---------------------------------------------------------------- base image --

def resolve_base_descriptor(base: Container, target: str, lock: Sources) -> tuple[str, str]:
    """Return the immutable per-platform descriptor digest for `target`.

    Fails closed unless the lock is complete. Copying fleet-manager's
    `docker://nvcr.io#<image>:<tag>` tag import would violate the lock's
    floating_input_rule, so the digest must come from the lock.
    """
    if lock.status != "complete":
        fail(
            "source lock is not usable for an image build: status="
            f"{lock.status!r}. "
            f"Resolve the {base.base_image} OCI index and per-platform "
            "descriptors on a builder with skopeo and nvcr.io access, then "
            f"re-run {LOCK_VALIDATOR} --require-complete."
        )
    try:
        oci = lock.verified[base.source_lock_category]
        platform = oci["platforms"][target]
        descriptor = platform["descriptor_digest"]
    except (KeyError, TypeError):
        fail(
            f"source lock has no verified platform descriptor for base "
            f"{base.base_image} (category {base.source_lock_category}) "
            f"and target {target}"
        )
    tag = oci.get("tag")
    if oci.get("image") != base.base_image or not isinstance(tag, str) or not tag:
        fail(f"source lock {base.source_lock_category} identity differs from the container registry")
    if not isinstance(descriptor, str) or DIGEST_RE.fullmatch(descriptor) is None:
        fail(f"platform descriptor for {target} is not an immutable sha256 digest")
    return descriptor, tag


def import_base(base: Container, tag: str, descriptor: str, cache_dir: Path, target: str) -> Path:
    """Import the digest-pinned base into a local .sqsh, atomically.

    skopeo copies by digest into an OCI archive first, then enroot imports that
    archive. Going through skopeo keeps the digest exact and avoids depending on
    enroot's registry URI supporting `@sha256:` forms.
    """
    slug = base.base_image.rsplit("/", 1)[-1]
    out = cache_dir / f"{slug}+{tag}-{target}.sqsh"
    if out.exists():
        print(f"==> base already imported: {out.name}")
        return out
    skopeo = require_tool("skopeo")
    enroot = require_tool("enroot")
    cache_dir.mkdir(parents=True, exist_ok=True)
    partial = out.with_suffix(f".sqsh.partial.{os.getpid()}")
    archive = cache_dir / f".oci-archive.{os.getpid()}.tar"
    for stale in (partial, archive):
        stale.unlink(missing_ok=True)
    print(f"==> copying {base.base_image}@{descriptor}")
    run([skopeo, "copy", f"docker://{base.base_image}@{descriptor}", f"oci-archive:{archive}"], "skopeo copy")
    print("==> importing base into enroot")
    run([enroot, "import", "-o", str(partial), f"oci-archive://{archive}"], "enroot import")
    archive.unlink(missing_ok=True)
    # mv within one filesystem is atomic, so a reader never sees a partial base.
    partial.replace(out)
    return out


# ------------------------------------------------------------ release closure --

def runtime_closure(release_dir: Path) -> list[str]:
    """Return the dag hashes of the explicit roots plus their link/run closure.

    Read from the release's own spack.lock rather than by shelling out to spack:
    the image builder is not necessarily the host that built the release, and the
    lock is the immutable record of what was actually installed.
    """
    lock = load_json(release_dir / "spack.lock", "release spack.lock")
    concrete = lock.get("concrete_specs")
    if not isinstance(concrete, dict) or not concrete:
        fail("release spack.lock has no concrete_specs")
    roots = lock.get("roots")
    if not isinstance(roots, list) or not roots:
        fail("release spack.lock has no roots")

    root_hashes = []
    for root in roots:
        digest = root.get("hash") if isinstance(root, dict) else None
        if not isinstance(digest, str) or digest not in concrete:
            fail("release spack.lock root does not name a concrete spec")
        root_hashes.append(digest)

    selected: list[str] = []
    seen: set[str] = set()
    queue = list(root_hashes)
    while queue:
        digest = queue.pop()
        if digest in seen:
            continue
        seen.add(digest)
        selected.append(digest)
        node = concrete.get(digest)
        if not isinstance(node, dict):
            fail(f"release spack.lock references an unknown spec hash: {digest}")
        for edge in node.get("dependencies") or []:
            if not isinstance(edge, dict):
                continue
            # Spack has spelled this key both "type" and "deptypes"/"parameters"
            # across versions; accept whichever the lock carries.
            raw = edge.get("type") or edge.get("deptypes") or (edge.get("parameters") or {}).get("deptypes") or []
            deptypes = {raw} if isinstance(raw, str) else set(raw)
            if not deptypes:
                fail(f"release spack.lock dependency edge has no deptype: {digest}")
            if deptypes & RUNTIME_DEPTYPES:
                child = edge.get("hash") or edge.get("id")
                if isinstance(child, str):
                    queue.append(child)
    return selected


def resolve_prefixes(store: Path, hashes: list[str]) -> list[Path]:
    """Map dag hashes to installed prefixes by hash suffix.

    Chapar's shared install tree uses a flat `{name}-{version}-{hash}`
    projection with padded paths, so globbing for the hash suffix is
    projection-agnostic and needs no spack invocation. A hash that matches
    nothing, or more than one prefix, is fatal rather than skipped.
    """
    if not store.is_dir():
        fail(f"release store root is not a directory: {store}")
    if store.resolve() != store:
        fail(f"release store root contains a symlink component: {store}")
    # Padded install trees (release.sh detect_padded_length) nest the real
    # prefixes under a chain of __spack_path_placeholder__ directories; the
    # metadata's store field records the unpadded root. Descend to the deepest
    # placeholder before globbing, mirroring release.sh.
    while (store / "__spack_path_placeholder__").is_dir():
        store = store / "__spack_path_placeholder__"
    index: dict[str, list[Path]] = {}
    for entry in store.iterdir():
        if entry.is_symlink():
            fail(f"release store contains a symlinked prefix: {entry}")
        suffix = entry.name.rsplit("-", 1)[-1]
        if entry.is_dir():
            index.setdefault(suffix, []).append(entry)
    prefixes: list[Path] = []
    missing: list[str] = []
    for digest in hashes:
        matches = index.get(digest, [])
        if len(matches) > 1:
            fail(f"store has multiple prefixes for hash {digest}")
        if not matches:
            missing.append(digest)
            continue
        prefixes.append(matches[0])
    if missing:
        fail(
            f"{len(missing)} spec(s) in the runtime closure are not installed in "
            f"{store} (first: {missing[0]}). The release is incomplete for imaging."
        )
    return sorted(prefixes)


# ------------------------------------------------------------------ injection --

def rootfs_path(data_path: Path, container: str, absolute_target: Path) -> Path:
    return data_path / container / str(absolute_target).lstrip("/")


def inject(data_path: Path, container: str, prefixes: list[Path], modules_root: Path, arch: str, module_root: str, software_set: str) -> None:
    print(f"==> injecting {len(prefixes)} prefixes at their build-time paths")
    for prefix in prefixes:
        destination = rootfs_path(data_path, container, prefix)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            continue
        # -a preserves mode, symlinks, and times. Modes matter: a plain copy
        # under a restrictive umask breaks non-owner execution under Pyxis.
        run(["cp", "-a", str(prefix), str(destination)], f"injecting {prefix.name}")

    modules_source = modules_root / arch
    if not modules_source.is_dir():
        fail(f"release has no modulefiles for arch {arch}: {modules_source}")
    modules_destination = rootfs_path(data_path, container, Path(module_root)) / arch
    modules_destination.parent.mkdir(parents=True, exist_ok=True)
    if not modules_destination.exists():
        run(["cp", "-a", str(modules_source), str(modules_destination)], "injecting modulefiles")

    # Opt-in by design: `module use` only, never a PATH/LD_LIBRARY_PATH prepend.
    # Anything already on PATH/LD_LIBRARY_PATH in the base image (e.g. the
    # NVIDIA base's own MPI/HPL/NCCL under /workspace) keeps resolving to what
    # it was linked against.
    profile = rootfs_path(data_path, container, Path(PROFILE_SCRIPT))
    profile.parent.mkdir(parents=True, exist_ok=True)
    profile.write_text(
        f"# Chapar {software_set} release, layered into this image.\n"
        "# Deliberately does not alter PATH or LD_LIBRARY_PATH. Run\n"
        f"# `module avail` then `module load <name>` to use the {software_set} stack.\n"
        f'if command -v module >/dev/null 2>&1 && [ -d "{module_root}/{arch}" ]; then\n'
        f'    module use "{module_root}/{arch}"\n'
        "fi\n",
        encoding="utf-8",
    )
    profile.chmod(0o644)


def verify(enroot: str, container: str, arch: str, spack_target: str, base_id: str, module_root: str) -> None:
    print("==> verifying injected tree inside the rootfs")
    if not arch.endswith(spack_target):
        fail(
            f"release arch {arch!r} does not end with the target's spack_target "
            f"{spack_target!r}: this release was not built for the requested "
            "microarchitecture"
        )
    # Base-specific evidence that injection did not disturb the payload the
    # base image exists to provide.
    if base_id == "nvidia-vlad":
        # The NVIDIA HPC-benchmarks base's own HPL entrypoint must survive
        # injection -- confirms we layered vlad on top rather than clobbering it.
        base_check = (
            'case "$(uname -m)" in\n'
            '  x86_64) test -f /workspace/hpl-linux-x86_64/hpl.sh ;;\n'
            '  aarch64) test -f /workspace/hpl-linux-aarch64-gpu/hpl.sh ;;\n'
            'esac\n'
        )
    elif base_id == "ubuntu-hpcsim":
        # Confirms the base is still a genuine, uncorrupted Ubuntu 24.04
        # rootfs after injection -- apt/dpkg intact, correct OS release.
        base_check = (
            'grep -q \'VERSION_ID="24.04"\' /etc/os-release\n'
            'command -v dpkg >/dev/null 2>&1\n'
        )
    else:
        fail(f"no in-image verification defined for base {base_id!r}")
    # NVIDIA_VISIBLE_DEVICES=void keeps enroot's GPU hook from running
    # nvidia-container-cli; verification never needs a GPU. PS1="" keeps the
    # base image's /etc/bash.bashrc from tripping over an unset prompt.
    script = (
        f'set -eu\n'
        f'test -d "{module_root}/{arch}"\n'
        f'test -r "{PROFILE_SCRIPT}"\n'
        f'{base_check}'
        f'count=$(find "{module_root}/{arch}" -type f | wc -l)\n'
        f'[ "$count" -gt 0 ]\n'
        f'echo "verified: $count modulefiles, base payload intact"\n'
    )
    output = run(
        [enroot, "start", "--root", "--rw", "--env", "PS1=", "--env", "NVIDIA_VISIBLE_DEVICES=void",
         container, "bash", "-c", script],
        "in-image verification",
    )
    print("    " + output.strip().splitlines()[-1])


# ----------------------------------------------------------------------- main --

def main() -> int:
    parser = argparse.ArgumentParser(description="Layer a Chapar environment release into a digest-locked base image")
    parser.add_argument("--target", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--release-dir", required=True)
    parser.add_argument("--datacenter-contract", required=True)
    parser.add_argument("--target-contract", required=True)
    parser.add_argument("--image-id", required=True)
    parser.add_argument("--enroot-build-root")
    parser.add_argument("--keep-container", action="store_true")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()

    if ID_RE.fullmatch(args.image_id) is None:
        fail("image id must be a short lowercase identifier")
    release_dir = absolute(args.release_dir, "release dir")
    if not release_dir.is_dir():
        fail(f"release dir is not a directory: {release_dir}")
    datacenter_contract = absolute(args.datacenter_contract, "datacenter contract")
    target_contract = absolute(args.target_contract, "target contract")
    try:
        plan = verify_release(
            ReleaseRequest(
                release_dir,
                args.base,
                args.target,
                CATALOG_PATH,
                TARGETS_PATH,
                CONTAINERS_PATH,
                SOURCES_PATH,
                datacenter_contract,
                target_contract,
            )
        )
    except ContractError as error:
        fail(str(error))
    base = plan.container
    target_spec = plan.target
    store = absolute(plan.roots["install_tree"], "release install tree")
    module_tree = absolute(plan.roots["modulefiles"], "release modulefiles")
    if module_tree.is_symlink():
        fail("release module destination cannot be a symlink")
    module_arches = sorted(path.name for path in module_tree.iterdir() if path.is_dir()) if module_tree.is_dir() else []
    if len(module_arches) != 1:
        fail("release must contain exactly one module destination")
    arch = module_arches[0]
    if not arch.endswith(plan.target.spack_target):
        fail("release module architecture does not match selected target")

    descriptor, tag = resolve_base_descriptor(base, args.target, plan.sources)
    closure = runtime_closure(release_dir)
    prefixes = resolve_prefixes(store, closure)

    artifact_name = f"{args.base}+{tag}-{args.target}.sqsh"
    if args.plan_only:
        print(f"target:        {args.target} ({target_spec.oci_platform}, spack_target={target_spec.spack_target})")
        print(f"base id:       {args.base} (software_set={plan.identity['software_set']})")
        print(f"release:       {plan.identity['release_id']} run={plan.identity['run_id']} arch={arch}")
        print(f"selection:     {plan.selection_sha256}")
        print(f"release lock:  {plan.lock_sha256}")
        print(f"base:          {base.base_image}@{descriptor}")
        print(f"store:         {store}")
        print(f"closure:       {len(prefixes)} runtime prefixes of {len(closure)} closure specs")
        print(f"modules:       {base.module_destination}/{arch} (opt-in via module load)")
        print(f"artifact:      {artifact_name}")
        for prefix in prefixes[:10]:
            print(f"    inject {prefix}")
        if len(prefixes) > 10:
            print(f"    ... and {len(prefixes) - 10} more")
        return 0

    candidate_root = absolute(plan.paths["image_staging"], "selected image staging root")
    work = candidate_root / args.image_id
    if not work.is_dir():
        fail(f"target/image-qualified candidate work root must exist and be writable: {work}")

    enroot = require_tool("enroot")
    build_root = absolute(args.enroot_build_root, "enroot build root") if args.enroot_build_root else work / ".enroot-build"
    for name in ("data", "cache", "temp", "runtime"):
        (build_root / name).mkdir(parents=True, exist_ok=True)
    os.environ["ENROOT_DATA_PATH"] = str(build_root / "data")
    os.environ["ENROOT_CACHE_PATH"] = str(build_root / "cache")
    os.environ["ENROOT_TEMP_PATH"] = str(build_root / "temp")
    os.environ["ENROOT_RUNTIME_PATH"] = str(build_root / "runtime")

    base_sqsh = import_base(base, tag, descriptor, build_root / "cache", args.target)
    container = f"chaparbuild-{args.base}-{args.target}-{os.getpid()}"
    subprocess.run([enroot, "remove", "-f", container], capture_output=True, check=False)
    run([enroot, "create", "--name", container, str(base_sqsh)], "enroot create")
    try:
        inject(build_root / "data", container, prefixes, module_tree, arch, base.module_destination, plan.identity["software_set"])
        verify(enroot, container, arch, target_spec.spack_target, args.base, base.module_destination)
        out = work / artifact_name
        partial = out.with_suffix(f".sqsh.partial.{os.getpid()}")
        partial.unlink(missing_ok=True)
        print(f"==> exporting {out}")
        run([enroot, "export", "-o", str(partial), container], "enroot export")
        partial.replace(out)
    finally:
        if not args.keep_container:
            subprocess.run([enroot, "remove", "-f", container], capture_output=True, check=False)

    digest = run(["sha256sum", str(out)], "hashing artifact").split()[0]
    (work / f"{artifact_name}.sha256").write_text(f"{digest}  {artifact_name}\n", encoding="utf-8")
    print(f"==> {artifact_name}")
    print(f"    sha256 {digest}")
    print(f"    seal with the publisher role, then consume via srun --container-image=<sealed path>")
    return 0


try:
    sys.exit(main())
except BuildError as error:
    print(f"chapar image build failed: {error}", file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    sys.exit(130)
PY
