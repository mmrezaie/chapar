#!/usr/bin/env python3
"""Validation orchestrator — discover YAML test definitions and dispatch to harness."""

import argparse
import glob
import json
import os
import subprocess
import sys
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "harness", "run_test.sh")


def discover_suites():
    """Return {suite_name: [test_names]} mapping."""
    suites = {}
    for tests_dir in glob.glob(os.path.join(HERE, "*", "tests")):
        suite = os.path.basename(os.path.dirname(tests_dir))
        tests = sorted([
            f.replace(".yaml", "")
            for f in os.listdir(tests_dir)
            if f.endswith(".yaml")
        ])
        if tests:
            suites[suite] = tests
    return suites


def get_test_metadata(suite, test_name):
    """Return parsed YAML dict for a test."""
    path = os.path.join(HERE, suite, "tests", f"{test_name}.yaml")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return yaml.safe_load(f)


def check_harness():
    """Verify harness exists and is executable."""
    if not os.path.exists(HARNESS):
        print(f"ERROR: harness not found at {HARNESS}", file=sys.stderr)
        return False
    if not os.access(HARNESS, os.X_OK):
        print(f"WARNING: harness at {HARNESS} is not executable", file=sys.stderr)
    return True


def cmd_list_suites():
    suites = discover_suites()
    for suite, tests in sorted(suites.items()):
        print(f"\n{suite}:")
        for t in tests:
            meta = get_test_metadata(suite, t)
            desc = meta.get("description", "") if meta else ""
            print(f"  - {t}: {desc}")


def cmd_list_tests():
    suites = discover_suites()
    for suite, tests in sorted(suites.items()):
        for t in tests:
            print(f"{suite}:{t}")


def cmd_run_suite(test_name, env_config, scheduler, dry_run):
    suites = discover_suites()
    found = None
    for suite, tests in suites.items():
        if test_name in tests:
            found = (suite, test_name)
            break
    if not found:
        print(f"ERROR: test '{test_name}' not found in any suite", file=sys.stderr)
        sys.exit(1)

    suite, test = found
    meta = get_test_metadata(suite, test)

    # Build harness command
    harness_args = [
        HARNESS,
        "--suite", suite,
        "--env", env_config,
        "--scheduler", scheduler,
    ]
    if dry_run:
        harness_args.append("--dry-run")

    print(f"[run.py] Dispatching: {' '.join(harness_args)}")
    if dry_run:
        # For dry-run, print test info directly
        print(f"  Test: {test}")
        print(f"  Suite: {suite}")
        print(f"  Description: {meta.get('description', '')}")
        print(f"  Severity: {meta.get('severity', 'error')}")
        print(f"  Module needs: {', '.join(meta.get('module_needs', []))}")
        print(f"  Resources: nodes={meta.get('resources', {}).get('nodes', 1)}")
        print(f"  Commands: {len(meta.get('commands', []))}")
        result = subprocess.run(harness_args, capture_output=True, text=True)
        print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        return 0
    else:
        if not check_harness():
            sys.exit(1)
        result = subprocess.run(harness_args)
        return result.returncode


def cmd_run_all(env_config, scheduler, dry_run):
    suites = discover_suites()
    results = {}
    all_ok = True
    for suite in sorted(suites):
        for test in suites[suite]:
            print(f"\n{'=' * 60}")
            print(f"Running: {suite}:{test}")
            print(f"{'=' * 60}")
            rc = cmd_run_suite(test, env_config, scheduler, dry_run)
            results[f"{suite}:{test}"] = "PASS" if rc == 0 else "FAIL"
            if rc != 0:
                meta = get_test_metadata(suite, test)
                if meta and meta.get("severity") in ("warning", "info"):
                    print(f"  [NOTE] {test} failed but severity is "
                          f"'{meta.get('severity')}' — not blocking")
                else:
                    all_ok = False

    print(f"\n{'=' * 60}")
    print("SUMMARY:")
    print(json.dumps(results, indent=2))
    return 0 if all_ok else 1


def main():
    parser = argparse.ArgumentParser(description="Validation orchestrator")
    parser.add_argument("--list-suites", action="store_true",
                        help="List available suites")
    parser.add_argument("--list-tests", action="store_true",
                        help="List all tests")
    parser.add_argument("--suite", help="Run a specific test by name")
    parser.add_argument("--all", action="store_true", dest="run_all",
                        help="Run all tests")
    parser.add_argument("--scheduler", default="slurm",
                        choices=["slurm", "local"])
    parser.add_argument("--env",
                        default=os.path.join(HERE, "config", "vlad.yaml"))
    parser.add_argument("--dry-run", action="store_true",
                        help="Print commands without executing")

    args = parser.parse_args()

    if args.list_suites:
        cmd_list_suites()
    elif args.list_tests:
        cmd_list_tests()
    elif args.suite:
        return cmd_run_suite(args.suite, args.env, args.scheduler,
                             args.dry_run)
    elif args.run_all:
        return cmd_run_all(args.env, args.scheduler, args.dry_run)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
