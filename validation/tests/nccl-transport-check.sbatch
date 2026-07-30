#!/usr/bin/env bash
# DESCRIPTION: Full-GPU NCCL transport assertion for separate intra-node and inter-node paths
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=00:05:00
#SBATCH --job-name=nccl-transport-check

set -euo pipefail

usage() {
    printf '%s\n' 'Usage: nccl-transport-check.sbatch [--fixture validation/fixtures/gpu/<case>]'
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
fixture=""

if [ "${1:-}" = --fixture ]; then
    [ "$#" = 2 ] || { usage; exit 2; }
    fixture="$2"
    [ -f "${fixture}/manifest.json" ] || { printf 'GPU fixture manifest is missing: %s\n' "${fixture}" >&2; exit 2; }
elif [ "$#" -ne 0 ]; then
    usage
    exit 2
fi

source "${validation_dir}/lib/verdict.sh"
source "${validation_dir}/lib/result-manifest.sh"
validation_result_init nccl-transport-check "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

if [ -z "${fixture}" ] && [ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]; then
    module purge
fi
if [ -z "${fixture}" ]; then
    module load "${CHAPAR_MODULE_CUDA:-cuda/13}" "${CHAPAR_MODULE_NCCL:-nccl}" "${CHAPAR_MODULE_NCCL_TESTS:-nccl-tests}"
fi

export NCCL_TRANSPORT_FIXTURE="${fixture}"
export NCCL_TRANSPORT_PROFILE="${VALIDATION_SITE_PROFILE:-}"
export NCCL_TRANSPORT_RESULT="${results_dir}/nccl_transport_check.json"
export NCCL_TRANSPORT_PROM="${results_dir}/nccl_transport.prom"
export NCCL_TRANSPORT_NODE="${node}"
export NCCL_TRANSPORT_NETWORK_CONFIG="${validation_dir}/config/network.yaml"

python3 <<'PY'
import json
import os
import pathlib
import re
import shutil
import subprocess


def read_yaml(path):
    import yaml
    with open(path, encoding="utf-8") as stream:
        return yaml.safe_load(stream) or {}


fixture_path = os.environ["NCCL_TRANSPORT_FIXTURE"]
fixture_data = json.loads((pathlib.Path(fixture_path) / "manifest.json").read_text(encoding="utf-8")) if fixture_path else {}
if fixture_path:
    profile = fixture_data.get("profile", {})
    observed = fixture_data.get("nccl_observed", {})
    expected_network = fixture_data.get("expected_network", "")
else:
    profile_path = os.environ["NCCL_TRANSPORT_PROFILE"]
    profile = read_yaml(profile_path) if profile_path else {}
    config_path = os.environ["NCCL_TRANSPORT_NETWORK_CONFIG"]
    expected_network = read_yaml(config_path).get("nccl", {}).get("expected_transport", "") if pathlib.Path(config_path).is_file() else ""
    executable = shutil.which("all_reduce_perf")
    gpu_count = profile.get("hardware", {}).get("gpus_per_node", 0)
    if executable and isinstance(gpu_count, int) and gpu_count > 0:
        command = [executable, "-b", "8", "-e", "128M", "-f", "2", "-g", str(gpu_count)]
        if os.environ.get("SLURM_JOB_ID"):
            command = ["srun", "--ntasks-per-node=1", *command]
        completed = subprocess.run(command, check=False, capture_output=True, text=True, env={**os.environ, "NCCL_DEBUG": "INFO", "NCCL_DEBUG_SUBSYS": "INIT,NET,P2P"})
        observed = {"commands": {"all_reduce_perf": True}, "output": completed.stdout + completed.stderr, "exit_code": completed.returncode}
    else:
        observed = {"commands": {"all_reduce_perf": False}, "output": "", "exit_code": 127}

hardware = profile.get("hardware", {})
accelerator = hardware.get("accelerator", {})
gpu_policy = profile.get("topology", {}).get("gpu", {})
expected_count = hardware.get("gpus_per_node")
errors = []
if not profile:
    errors.append("VALIDATION_SITE_PROFILE is required for live GPU validation")
elif accelerator.get("kind") != "gpu" or accelerator.get("vendor") != "nvidia":
    verdict = "SKIP"
else:
    if not observed.get("commands", {}).get("all_reduce_perf", False):
        errors.append("required command unavailable: all_reduce_perf")
    if not isinstance(expected_count, int) or expected_count < 2:
        errors.append("profile must select at least two GPUs per node")
    if fixture_path:
        full_allocation = observed.get("full_gpu_allocation", False)
        nodes = observed.get("nodes", 1)
    else:
        visible = [value for value in os.environ.get("CUDA_VISIBLE_DEVICES", "").split(",") if value]
        full_allocation = bool(os.environ.get("SLURM_JOB_ID")) and os.environ.get("SLURM_GPUS_ON_NODE") == str(expected_count) and len(visible) == expected_count
        nodes = int(os.environ.get("SLURM_JOB_NUM_NODES", "1"))
    if not full_allocation:
        errors.append("full profile-selected GPU allocation is required")
    output = observed.get("output", "")
    if observed.get("exit_code") != 0:
        errors.append(f"all_reduce_perf failed with exit code {observed.get('exit_code')}")
    if re.search(r"\bNVLS\b", output, re.IGNORECASE):
        intra_node = "NVLS"
    elif re.search(r"P2P/NVL|\bNVLink\b", output, re.IGNORECASE):
        intra_node = "NVLink"
    elif re.search(r"P2P/PCI|\bPCIe\b", output, re.IGNORECASE):
        intra_node = "PCIe"
    else:
        intra_node = ""
    if re.search(r"\bRoCE\b", output, re.IGNORECASE):
        network = "RoCE"
    elif re.search(r"NET/(?:IB|IBext)\b|Using network\s*:?[ \t]*IB", output, re.IGNORECASE):
        network = "IB"
    elif re.search(r"NET/Socket\b|Using network\s*:?[ \t]*Socket", output, re.IGNORECASE):
        network = "Socket"
    else:
        network = ""
    expected_intra = "NVLS" if gpu_policy.get("require_nvls") else {"nvlink": "NVLink", "nvswitch": "NVLink", "pcie": "PCIe"}.get(gpu_policy.get("interconnect"), "")
    if expected_intra and intra_node != expected_intra:
        errors.append(f"intra-node NCCL path mismatch: expected={expected_intra}, got={intra_node or 'unobserved'}")
    if nodes > 1 and expected_network and network != expected_network:
        errors.append(f"inter-node NCCL transport mismatch: expected={expected_network}, got={network or 'unobserved'}")
    verdict = "FAIL" if errors else "PASS"

declared = fixture_data.get("verdicts", {}).get("nccl-transport-check", "")
if declared and verdict != declared:
    errors.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {"fixture": bool(fixture_path), "node": os.environ["NCCL_TRANSPORT_NODE"], "expected_gpu_count": expected_count, "intra_node_transport": intra_node if 'intra_node' in locals() else "", "inter_node_transport": network if 'network' in locals() else "", "inter_node_asserted": nodes > 1 if 'nodes' in locals() else False, "artifacts_sanitized": True, "verdict": verdict, "failures": errors}
pathlib.Path(os.environ["NCCL_TRANSPORT_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
transport_code = {"IB": 0, "Socket": 1, "NVLink": 2, "NVLS": 3, "RoCE": 4}.get(payload["inter_node_transport"] or payload["intra_node_transport"], -1)
pathlib.Path(os.environ["NCCL_TRANSPORT_PROM"]).write_text(f'# HELP nccl_transport_selected NCCL selected transport class\n# TYPE nccl_transport_selected gauge\nnccl_transport_selected{{node="{payload["node"]}"}} {transport_code}\n', encoding="utf-8")
PY

verdict="$(python3 -c "import json; print(json.load(open('${results_dir}/nccl_transport_check.json'))['verdict'])")"
reason="$(python3 -c "import json; value=json.load(open('${results_dir}/nccl_transport_check.json')); print('; '.join(value['failures']))")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    SKIP) validation_resource_unavailable 'profile does not select an NVIDIA NCCL suite' optional ;;
esac

printf 'NCCL transport evidence written to %s\n' "${results_dir}" >&2
