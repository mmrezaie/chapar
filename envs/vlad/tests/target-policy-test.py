#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import importlib.machinery
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Final, NamedTuple

import yaml

SPACK_COMMIT: Final = "fff95dd9aed0af7c7a8252adbef5623fcd4187f7"
PACKAGES_COMMIT: Final = "65f3228ea2533e8413c17661a3a0db3636269631"
REFERENCE_ROOT: Final = Path("/Users/mrez/workspace/chapar/.omo/evidence/references")
EXPECTED_REQUIRE: Final = [{"spec": "target=x86_64_v4", "when": "target=x86_64"}, {"spec": "target=aarch64", "when": "target=aarch64"}]
EXPECTED_RULES: Final = [("zlib", "one_of", "REQUIRE_YAML", ("target=x86_64_v4",), "target=x86_64", "DEFAULT", None), ("zlib", "one_of", "REQUIRE_YAML", ("target=aarch64",), "target=aarch64", "DEFAULT", None)]
type YamlValue = None | bool | int | float | str | list["YamlValue"] | dict[str, "YamlValue"]
type RuleView = tuple[str, str, str, tuple[str, ...], str, str, str | None]
class PinnedSources(NamedTuple): spack: Path; packages: Path


class PolicyError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PolicyError(message)


def load_yaml(path: Path) -> YamlValue:
    try:
        value: YamlValue = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        raise PolicyError(f"malformed YAML: {path}: {error}") from error
    require(value is not None, f"malformed YAML: {path}: empty document")
    return value


def as_mapping(value: YamlValue, label: str) -> dict[str, YamlValue]:
    require(isinstance(value, dict), f"{label} must be a mapping")
    return value


def as_list(value: YamlValue, label: str) -> list[YamlValue]:
    require(isinstance(value, list), f"{label} must be a list")
    return value


def validate_structure(yaml_path: Path, targets_path: Path) -> dict[str, YamlValue]:
    root = as_mapping(load_yaml(yaml_path), "document")
    spack = as_mapping(root.get("spack"), "spack")
    packages = as_mapping(spack.get("packages"), "spack.packages")
    all_policy = as_mapping(packages.get("all"), "spack.packages.all")
    require("target" not in all_policy, "unconditional Vlad target remains")
    requirements = as_list(all_policy.get("require"), "spack.packages.all.require")
    require(requirements == EXPECTED_REQUIRE, "architecture requirements do not match exact policy")
    registry = as_mapping(load_yaml(targets_path), "target registry")
    targets = as_mapping(registry.get("targets"), "target registry targets")
    x86 = as_mapping(targets.get("linux-x86_64-v4"), "x86 target")
    arm = as_mapping(targets.get("linux-aarch64-gb300"), "arm target")
    require(x86.get("native_arch") == "x86_64" and x86.get("spack_target") == "x86_64_v4", "x86 target registry mismatch")
    require(arm.get("native_arch") == "aarch64" and arm.get("spack_target") == "aarch64", "arm target registry mismatch")
    return packages


def git_head(path: Path) -> str:
    environment = os.environ | {"GIT_MASTER": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_TERMINAL_PROMPT": "0"}
    result = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], check=False, capture_output=True, text=True, timeout=10, env=environment)
    require(result.returncode == 0, f"source is not an exact Git checkout: {path}")
    return result.stdout.strip()


def add_clingo_path() -> None:
    try:
        import clingo  # noqa: F401
        if hasattr(clingo, "Symbol"):
            return
        del sys.modules["clingo"]
    except ImportError:
        suffixes = importlib.machinery.EXTENSION_SUFFIXES[0]
        root = Path.home() / ".spack" / "bootstrap" / "store"
        candidates = sorted(path for path in root.glob("**/site-packages/clingo*") if path.name.endswith(suffixes))
        require(bool(candidates), "clingo module unavailable while bootstrap is disabled")
        sys.path.insert(0, str(candidates[-1].parent))
        try:
            import clingo  # noqa: F401
        except ImportError as error:
            raise PolicyError("compatible clingo module unavailable while bootstrap is disabled") from error


def inject_failure(point: str) -> None:
    if os.environ.get("TARGET_POLICY_TEST_INJECT") == point:
        raise PolicyError(f"injected {point} failure")


def validate_with_spack(yaml_path: Path, packages: dict[str, YamlValue], sources: PinnedSources) -> None:
    require(git_head(sources.spack) == SPACK_COMMIT, "wrong Spack source commit")
    require(git_head(sources.packages) == PACKAGES_COMMIT, "wrong spack-packages source commit")
    exact_packages_path = sources.packages / "repos" / "spack_repo" / "builtin"
    require((exact_packages_path / "repo.yaml").is_file(), "pinned package repository is malformed")
    sys.path.insert(0, str(sources.spack / "lib" / "spack"))
    os.environ["SPACK_DISABLE_LOCAL_CONFIG"] = "true"
    add_clingo_path()

    def deny_network(event: str, _arguments: tuple[str | int | bytes | None, ...]) -> None:
        if event in {"socket.connect", "socket.connect_ex", "socket.getaddrinfo"}:
            raise PolicyError(f"network access attempted: {event}")

    sys.addaudithook(deny_network)
    import spack.caches
    import spack.config
    import spack.concretize
    import spack.platforms
    import spack.repo
    import spack.spec
    import spack.util.spack_yaml as syaml
    from spack.solver.requirements import RequirementParser

    with yaml_path.open(encoding="utf-8") as stream:
        actual = syaml.load_config(stream)
    require(actual["spack"]["packages"]["all"]["require"] == EXPECTED_REQUIRE, "Spack YAML loader saw different requirements")
    bootstrap_scope = spack.config.InternalConfigScope("target-policy-offline", data={"bootstrap": {"enable": False, "sources": []}, "compilers": [], "concretizer": {"targets": {"granularity": "generic", "host_compatible": False}}})
    packages_dict = copy.deepcopy(packages)
    test_platform = spack.platforms.Test()
    test_platform.binary_formats = ["elf"]
    for target in ("x86_64", "x86_64_v4", "aarch64"):
        test_platform.add_target(target, spack.vendor.archspec.cpu.TARGETS[target])
    previous_path = spack.repo.PATH
    previous_scopes = tuple(spack.config.CONFIG.scopes.items())
    config_identity = id(spack.config.CONFIG)
    try:
        spack.repo.enable_repo(spack.repo.RepoPath())
        with spack.config.CONFIG.override(bootstrap_scope):
            inject_failure("setup")
            with spack.config.CONFIG.override("packages", packages_dict), spack.repo.use_repositories(str(exact_packages_path), override=True):
                package_class = spack.repo.PATH.get_pkg_class("zlib")
                package = package_class(spack.spec.Spec("zlib"))
                parsed = RequirementParser(spack.config.CONFIG).rules_from_require(package)
                rules: list[RuleView] = [(rule.pkg_name, rule.policy, rule.origin.name, tuple(str(item) for item in rule.requirements), str(rule.condition), rule.kind.name, rule.message) for rule in parsed]
                require(rules == EXPECTED_RULES, "malformed RequirementRule output")
                inject_failure("parser")
                if os.environ.get("TARGET_POLICY_TEST_REMOVE_X86_RULE") == "1":
                    override_scope = spack.config.CONFIG.matching_scopes(r"^overrides-")[-1].name
                    spack.config.CONFIG.set("packages:all:require", EXPECTED_REQUIRE[1:], scope=override_scope)
                with spack.platforms.use_platform(test_platform):
                    test_platform.default = "x86_64"
                    x86 = spack.concretize.concretize_one("compiler-wrapper")
                    inject_failure("concretization")
                    test_platform.default = "aarch64"
                    arm = spack.concretize.concretize_one("compiler-wrapper")
                require(str(x86.target) == "x86_64_v4", "positive x86 concrete target mismatch")
                require(str(arm.target) == "aarch64", "positive arm concrete target mismatch")
                require(str(x86.target) != str(arm.target), "reciprocal concrete target mismatch")
    finally:
        spack.repo.PATH.disable()
        spack.repo.PATH = previous_path
        require(id(spack.config.CONFIG) == config_identity and tuple(spack.config.CONFIG.scopes.items()) == previous_scopes and spack.repo.PATH is previous_path, "Spack global state was not restored")


def concrete_targets(value: YamlValue) -> list[str]:
    matches: list[str] = []
    if isinstance(value, dict):  # noqa: IF_VARIANT_OK - recursive YAML union boundary
        target = value.get("target")
        if isinstance(target, str):
            matches.append(target)
        elif isinstance(target, dict) and isinstance(target.get("name"), str):
            matches.append(target["name"])
        for child in value.values():
            matches.extend(concrete_targets(child))
    elif isinstance(value, list):
        for child in value:
            matches.extend(concrete_targets(child))
    return matches


def concrete_target(value: YamlValue) -> str:
    root = as_mapping(value, "concrete YAML")
    require(set(root) == {"spec"}, "concrete YAML structure mismatch")
    spec = as_mapping(root["spec"], "concrete YAML spec")
    require(set(spec) in ({"nodes"}, {"_meta", "nodes"}), "concrete YAML structure mismatch")
    nodes = as_list(spec["nodes"], "concrete YAML nodes")
    require(bool(nodes), "concrete YAML target absent")
    targets: list[str] = []
    for value_node in nodes:
        node = as_mapping(value_node, "concrete YAML node")
        direct = node.get("target")
        if direct is not None:
            selected = as_mapping(direct, "concrete YAML node target").get("name")
        else:
            require(node.get("arch") is not None, "concrete YAML target absent")
            selected = as_mapping(node["arch"], "concrete YAML node arch").get("target")
        require(isinstance(selected, str), "concrete YAML target malformed")
        require(concrete_targets(node) == [selected], "concrete YAML target ambiguity")
        targets.append(selected)
    require(len(set(targets)) == 1, "concrete YAML target ambiguity")
    return targets[0]


def run_self_test() -> None:
    script = Path(__file__).resolve()
    with tempfile.TemporaryDirectory(prefix="vlad-target-policy-") as directory:
        root = Path(directory)
        targets = root / "targets.json"
        targets.write_text(json.dumps({"targets": {"linux-x86_64-v4": {"native_arch": "x86_64", "spack_target": "x86_64_v4"}, "linux-aarch64-gb300": {"native_arch": "aarch64", "spack_target": "aarch64"}}}), encoding="utf-8")
        malformed, wrong, missing, valid = (root / name for name in ("malformed.yaml", "wrong.yaml", "missing.yaml", "valid.yaml"))
        for path, content in ((malformed, "spack: [\n"), (wrong, "spack:\n  packages:\n    all:\n      target: [x86_64_v4]\n"), (missing, "spack:\n  packages:\n    all: {}\n"), (valid, "spack:\n  packages:\n    all:\n      require:\n      - spec: target=x86_64_v4\n        when: target=x86_64\n      - spec: target=aarch64\n        when: target=aarch64\n")):
            path.write_text(content, encoding="utf-8")
        concrete: dict[str, Path] = {}
        for name, content in (("exact", "spec:\n  nodes:\n  - {name: zlib, target: {name: x86_64_v4}}\n"), ("ambiguous", "spec:\n  nodes:\n  - {name: zlib, target: {name: x86_64_v4}}\n  - {name: dependency, target: {name: aarch64}}\n"), ("conflicting", "spec:\n  nodes:\n  - {name: zlib, target: {name: x86_64_v4}, arch: {target: aarch64}}\n"), ("absent", "spec:\n  nodes:\n  - {name: zlib}\n"), ("malformed-target", "spec:\n  nodes:\n  - {name: zlib, target: {name: 7}}\n"), ("wrong-target", "spec:\n  nodes:\n  - {name: zlib, target: {name: x86_64}}\n"), ("unrelated", "target: {name: x86_64_v4}\nspec:\n  nodes:\n  - {name: zlib, target: {name: x86_64_v4}}\n")):
            concrete[name] = root / f"concrete-{name}.yaml"; concrete[name].write_text(content, encoding="utf-8")
        spack_source = REFERENCE_ROOT / "spack" / SPACK_COMMIT
        packages_source = REFERENCE_ROOT / "spack-packages" / PACKAGES_COMMIT
        pinned = ["--spack-source", str(spack_source), "--spack-packages-source", str(packages_source), str(valid), str(targets)]
        cases = [
            ([str(malformed), str(targets)], "malformed YAML", {}),
            ([str(wrong), str(targets)], "unconditional Vlad target remains", {}),
            ([str(missing), str(targets)], "spack.packages.all.require must be a list", {}),
            (["--internal-case", "malformed-rule"], "malformed RequirementRule output", {}),
            (["--internal-case", "positive-mismatch"], "positive x86 concrete target mismatch", {}),
            (["--internal-case", "reciprocal-mismatch"], "reciprocal concrete target mismatch", {}),
            (["--spack-source", str(root), "--spack-packages-source", str(root), str(valid), str(targets)], "source is not an exact Git checkout", {}),
            (["--spack-source", str(script.parents[3]), "--spack-packages-source", str(script.parents[3]), str(valid), str(targets)], "wrong Spack source commit", {}),
            (pinned, "positive x86 concrete target mismatch", {"TARGET_POLICY_TEST_REMOVE_X86_RULE": "1"}),
            (pinned, "injected setup failure", {"TARGET_POLICY_TEST_INJECT": "setup"}),
            (pinned, "injected parser failure", {"TARGET_POLICY_TEST_INJECT": "parser"}),
            (pinned, "injected concretization failure", {"TARGET_POLICY_TEST_INJECT": "concretization"}),
            (["--assert-concrete-yaml", str(concrete["ambiguous"]), "--expected-target", "x86_64_v4"], "concrete YAML target ambiguity", {}),
            *[(["--assert-concrete-yaml", str(concrete[name]), "--expected-target", "x86_64_v4"], reason, {}) for name, reason in (("conflicting", "concrete YAML target ambiguity"), ("absent", "concrete YAML target absent"), ("malformed-target", "concrete YAML target malformed"), ("wrong-target", "concrete YAML target mismatch"), ("unrelated", "concrete YAML structure mismatch"))],
        ]
        for arguments, expected, overrides in cases:
            child = subprocess.run([sys.executable, str(script), *arguments], check=False, capture_output=True, text=True, timeout=120, env=os.environ | overrides)
            require(child.returncode != 0 and expected in child.stderr, f"self-test child did not reject {expected}")
        exact_child = subprocess.run([sys.executable, str(script), "--assert-concrete-yaml", str(concrete["exact"]), "--expected-target", "x86_64_v4"], check=False, capture_output=True, text=True, timeout=30)
        require(exact_child.returncode == 0 and "concrete target: x86_64_v4" in exact_child.stdout, "self-test exact concrete target failed")
    print(f"self-test passed: {len(cases)} intended child failures")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spack-source", type=Path)
    parser.add_argument("--spack-packages-source", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--assert-concrete-yaml", type=Path)
    parser.add_argument("--expected-target")
    parser.add_argument("--internal-case", choices=("malformed-rule", "positive-mismatch", "reciprocal-mismatch"))
    parser.add_argument("yaml", type=Path, nargs="?")
    parser.add_argument("targets", type=Path, nargs="?")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.self_test:
            run_self_test()
        elif args.internal_case == "malformed-rule":  # noqa: IF_VARIANT_OK - argparse mode dispatch
            require(False, "malformed RequirementRule output")
        elif args.internal_case == "positive-mismatch":  # noqa: IF_VARIANT_OK - argparse mode dispatch
            require(False, "positive x86 concrete target mismatch")
        elif args.internal_case == "reciprocal-mismatch":
            require(False, "reciprocal concrete target mismatch")
        elif args.assert_concrete_yaml:
            require(bool(args.expected_target), "--expected-target is required")
            require(args.expected_target == concrete_target(load_yaml(args.assert_concrete_yaml)), "concrete YAML target mismatch")
            print(f"concrete target: {args.expected_target}")
        else:
            require(args.yaml is not None and args.targets is not None, "YAML and target registry paths are required")
            packages = validate_structure(args.yaml, args.targets)
            require((args.spack_source is None) == (args.spack_packages_source is None), "both pinned source paths are required together")
            if args.spack_source is not None and args.spack_packages_source is not None:
                with tempfile.TemporaryDirectory(prefix="vlad-spack-cache-") as cache:
                    os.environ["SPACK_USER_CACHE_PATH"] = cache
                    validate_with_spack(args.yaml, packages, PinnedSources(args.spack_source, args.spack_packages_source))
            print("Vlad target policy: x86_64 -> x86_64_v4; aarch64 -> aarch64")
        return 0
    except PolicyError as error:
        print(f"target-policy-test: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
