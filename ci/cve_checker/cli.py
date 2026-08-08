from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Final

from .github_issues import (
    GitHubIssueTarget,
    create_github_issue,
    github_issue_exists,
    issue_title,
)
from .http_client import HttpRequestError
from .models import SEVERITY_ORDER, Finding, JsonObject, Package
from .nemotron import summarize_with_nemotron
from .nvd import NvdQueryOptions, fetch_nvd_findings
from .osv import fetch_osv_findings
from .selection import die, load_json, load_selected_inventory, with_config_aliases

DEFAULT_CONFIG: Final = Path("ci/cve-checker-config.json")
DEFAULT_SPACK_YAML: Final = Path("envs/software/spack.yaml")


@dataclass(frozen=True, slots=True)
class ScanPlan:
    packages: tuple[Package, ...]
    config: JsonObject
    nvd: NvdQueryOptions
    include_osv: bool


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    return default if raw is None else raw.strip().lower() in {"1", "true", "yes", "on"}


def require_proxy_if_requested() -> None:
    if env_bool("CHAPAR_CVE_REQUIRE_PROXY", False) and not (
        os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    ):
        die("CHAPAR_CVE_REQUIRE_PROXY=true but HTTPS_PROXY is not set")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check a selected Chapar software inventory for CVEs"
    )
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--spack-yaml", type=Path, default=DEFAULT_SPACK_YAML)
    parser.add_argument("--selection", type=Path, required=True)
    parser.add_argument("--selection-digest-file", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, default=Path("/var/lib/chapar-cve-checker"))
    parser.add_argument("--github-repo", help="Override GitHub repo owner/name")
    parser.add_argument("--package", action="append", default=[], help="Limit scan to one package name; repeatable")
    parser.add_argument("--max-packages", type=int, default=0, help="Limit number of packages for smoke testing")
    parser.add_argument("--lookback-days", type=int, help="Only query CVEs published within this many days")
    parser.add_argument("--severity-threshold", choices=sorted(SEVERITY_ORDER), help="Minimum severity to report")
    parser.add_argument("--nvd-delay", type=float, help="Delay between NVD requests")
    parser.add_argument("--dry-run", action="store_true", help="Do not create GitHub issues")
    parser.add_argument("--plan", action="store_true", help="Print the verified offline inventory plan")
    parser.add_argument("--live", action="store_true", help="Create GitHub issues")
    parser.add_argument("--no-nemotron", action="store_true", help="Do not call Nemotron for summaries")
    parser.add_argument("--no-osv", action="store_true", help="Skip optional OSV queries")
    return parser.parse_args()


def write_state(state_dir: Path, findings: list[Finding]) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "last_run_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "findings": [
            {
                "package": finding.package.label,
                "cve": finding.cve_id,
                "severity": finding.severity,
                "source": finding.source,
                "url": finding.url,
            }
            for finding in findings
        ],
    }
    (state_dir / "last-run.json").write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def scan_packages(plan: ScanPlan) -> list[Finding]:
    all_findings: dict[tuple[str, str], Finding] = {}
    for package in plan.packages:
        print(f"Checking {package.label}", flush=True)
        try:
            findings = fetch_nvd_findings(package, plan.config, plan.nvd)
        except HttpRequestError as error:
            print(f"WARNING: NVD query failed for {package.label}: {error}", flush=True)
            continue
        for finding in findings:
            all_findings[(finding.package.name, finding.cve_id)] = finding
    if plan.include_osv:
        try:
            for finding in fetch_osv_findings(
                list(plan.packages), plan.config, plan.nvd.threshold
            ):
                all_findings[(finding.package.name, finding.cve_id)] = finding
        except HttpRequestError as error:
            print(f"WARNING: OSV query failed: {error}", flush=True)
    return sorted(all_findings.values(), key=lambda item: (item.package.name, item.cve_id))


def publish_findings(
    findings: list[Finding], target: GitHubIssueTarget
) -> None:
    for finding in findings:
        if github_issue_exists(target.repo, target.token, finding):
            print(f"Issue already exists for {finding.package.label} {finding.cve_id}", flush=True)
            continue
        issue_url = create_github_issue(finding, target)
        print(f"Created issue for {finding.package.label} {finding.cve_id}: {issue_url}", flush=True)


def main() -> int:
    args = parse_args()
    packages, policy = load_selected_inventory(
        args.selection, args.selection_digest_file, args.spack_yaml
    )
    if args.plan:
        print(json.dumps({
            "policy": policy.as_json(),
            "package_count": len(packages),
            "packages": [package.label for package in packages],
        }, sort_keys=True))
        return 0
    require_proxy_if_requested()
    config = load_json(args.config)
    if args.package:
        packages = [package for package in packages if package.name in set(args.package)]
    packages = with_config_aliases(packages, config)
    if args.max_packages > 0:
        packages = packages[:args.max_packages]
    if not packages:
        die("package inventory is empty")

    threshold = args.severity_threshold or str(config.get("severity_threshold", "HIGH")).upper()
    if threshold not in SEVERITY_ORDER:
        die(f"unsupported severity threshold: {threshold}")
    raw_lookback_days = config.get("lookback_days", 30)
    if args.lookback_days is not None:
        lookback_days = args.lookback_days
    elif isinstance(raw_lookback_days, (str, int, float)) and not isinstance(raw_lookback_days, bool):
        lookback_days = int(raw_lookback_days)
    else:
        die("config lookback_days must be an integer")
    if lookback_days > 120:
        die("NVD date windows must be 120 days or less; use --lookback-days 0 to omit date filtering")
    nvd_api_key = os.environ.get("NVD_API_KEY", "").strip() or None
    delay = args.nvd_delay if args.nvd_delay is not None else (0.7 if nvd_api_key else 6.1)
    dry_run = False if args.live else env_bool("CHAPAR_CVE_DRY_RUN", True) or args.dry_run
    print(
        f"Scanning {len(packages)} selected packages; threshold={threshold}; "
        f"lookback_days={lookback_days}; dry_run={dry_run}",
        flush=True,
    )
    findings = scan_packages(ScanPlan(
        packages=tuple(packages),
        config=config,
        nvd=NvdQueryOptions(threshold, lookback_days, delay, nvd_api_key),
        include_osv=not args.no_osv,
    ))
    print(f"Matched {len(findings)} reportable CVE findings", flush=True)
    if not args.no_nemotron:
        findings = [
            replace(finding, nemotron_summary=summarize_with_nemotron(finding))
            for finding in findings
        ]
    write_state(args.state_dir, findings)
    if dry_run:
        for finding in findings:
            print(f"DRY-RUN {issue_title(finding)} {finding.url}", flush=True)
        return 0

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        die("GITHUB_TOKEN is required when --live is used")
    repo = args.github_repo or str(config.get("github_repo", "")).strip()
    if not repo or "/" not in repo:
        die("github_repo must be configured as owner/name")
    raw_labels = config.get("issue_labels", [])
    labels = [str(label) for label in raw_labels] if isinstance(raw_labels, list) else []
    publish_findings(
        findings,
        GitHubIssueTarget(repo, token, policy, tuple(labels)),
    )
    return 0
