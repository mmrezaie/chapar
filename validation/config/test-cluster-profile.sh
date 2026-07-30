#!/usr/bin/env bash
set -euo pipefail

config_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "${config_dir}/cluster-profile.schema.json" "${config_dir}/cluster-site.yaml.example" <<'PY'
import copy
import json
import sys

import jsonschema
import yaml

schema_path, example_path = sys.argv[1:]
with open(schema_path, encoding="utf-8") as schema_file:
    schema = json.load(schema_file)
with open(example_path, encoding="utf-8") as example_file:
    example = yaml.safe_load(example_file)

validator = jsonschema.Draft202012Validator(schema)


def errors(document):
    failures = list(validator.iter_errors(document))
    available = set(document.get("available_capabilities", []))
    for tier_name, tier in document.get("tiers", {}).items():
        unsupported = set(tier["required_capabilities"]) - available
        if unsupported:
            failures.append(
                ValueError(f"{tier_name} requires unsupported capabilities: {sorted(unsupported)}")
            )
    return sorted(failures, key=lambda error: str(error))


def require_valid(document, name):
    failures = errors(document)
    if failures:
        raise AssertionError(f"{name} was rejected: {failures[0].message}")


def require_invalid(document, name):
    failures = errors(document)
    if not failures:
        raise AssertionError(f"{name} was unexpectedly accepted")


require_valid(example, "sanitized example")

invalid_rdma = copy.deepcopy(example)
invalid_rdma["topology"]["rdma"]["max_benchmark_edges"] = 0
require_invalid(invalid_rdma, "RDMA profile with unbounded benchmark edge count")

missing_gpu_topology = copy.deepcopy(example)
del missing_gpu_topology["topology"]["gpu"]
require_invalid(missing_gpu_topology, "NVIDIA profile missing GPU topology")

missing_baseline = copy.deepcopy(example)
del missing_baseline["baseline_policy"]
require_invalid(missing_baseline, "profile missing mandatory baseline policy")

unallowlisted_storage = copy.deepcopy(example)
unallowlisted_storage["safe_storage"]["roots"][0]["target"] = "arbitrary-path"
require_invalid(unallowlisted_storage, "profile with non-allowlisted storage target")

command_injection = copy.deepcopy(example)
command_injection["command"] = "sbatch validation/tests/node-smoke.sbatch"
require_invalid(command_injection, "profile with command field")

environment_fragment = copy.deepcopy(example)
environment_fragment["safe_storage"]["roots"][0]["relative_directory"] = "${RESULTS_ROOT}"
require_invalid(environment_fragment, "profile with environment fragment")

cpu_only = copy.deepcopy(example)
cpu_only["platform"] = {
    "operating_system": "rocky10",
    "architecture": "aarch64",
    "cpu_vendor": "nvidia",
    "cpu_platform": "nvidia-grace",
}
cpu_only["hardware"]["gpus_per_node"] = 0
cpu_only["hardware"]["accelerator"] = {"kind": "none"}
cpu_only["topology"] = {
    "node_bounds": {"minimum": 1, "maximum": 1},
    "edges": [],
    "fabric": "ethernet",
    "max_hops": 0,
}
cpu_only["available_capabilities"] = ["cpu"]
cpu_only["tiers"] = {"capability": cpu_only["tiers"]["capability"]}
cpu_only["baseline_policy"]["metrics"] = ["cpu-throughput"]
require_valid(cpu_only, "CPU-only NVIDIA Grace capability profile")

unsupported_capability = copy.deepcopy(cpu_only)
unsupported_capability["tiers"]["capability"]["required_capabilities"].append("rdma")
require_invalid(unsupported_capability, "tier requiring unavailable RDMA")

roce = copy.deepcopy(example)
roce["topology"]["fabric"] = "roce"
del roce["topology"]["rdma"]
roce["topology"]["roce"] = {
    "endpoint": {
        "hca_pattern": "mlx5_[0-9]+", "port": 1, "netdev": "ens5f0",
        "vlan_netdev": "ens5f0.120", "vlan_id": 120,
        "address_pattern": r"10\\.20\\.120\\.[0-9]+", "gid_type": "RoCE v2",
        "mtu": 9000, "pfc_max_counter_delta": {"rx_prio3_pause": 0},
        "ecn_max_counter_delta": {"np_ecn_marked_roce_packets": 0},
        "retransmit_max_counter_delta": {"roce_retransmitted_packets": 0},
    },
    "max_benchmark_edges": 1, "minimum_bandwidth_gbps": 100,
    "maximum_latency_us": 5,
}
roce["tiers"]["fabric"]["selected_suites"] = ["rocev2-pairwise"]
roce["tiers"]["fabric"]["resources"]["max_edges"] = 1
require_valid(roce, "RoCEv2 profile with a bounded endpoint tuple")

invalid_roce = copy.deepcopy(roce)
invalid_roce["topology"]["roce"]["endpoint"]["vlan_id"] = 0
require_invalid(invalid_roce, "RoCEv2 profile with an invalid VLAN ID")

print("cluster profile contract: example, CPU-only, and RoCEv2 fixtures accepted; fail-closed fixtures rejected")
PY
