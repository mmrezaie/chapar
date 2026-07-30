#!/usr/bin/env bash
# DESCRIPTION: Full-GPU NVIDIA CUDA P2P, NVLink counter-delta, and Fabric Manager evidence
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=00:10:00
#SBATCH --job-name=nvlink-p2p

set -euo pipefail

usage() {
    printf '%s\n' 'Usage: nvlink-p2p.sbatch [--fixture validation/fixtures/gpu/<case>]'
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
validation_result_init nvlink-p2p "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

if [ -z "${fixture}" ] && [ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]; then
    module purge
fi
if [ -z "${fixture}" ]; then
    module load "${CHAPAR_MODULE_CUDA:-cuda/13}" "${CHAPAR_MODULE_NVBANDWIDTH:-nvbandwidth}"
fi

export NVLINK_P2P_FIXTURE="${fixture}"
export NVLINK_P2P_PROFILE="${VALIDATION_SITE_PROFILE:-}"
export NVLINK_P2P_RESULT="${results_dir}/nvlink_p2p.json"
export NVLINK_P2P_PROM="${results_dir}/nvlink_p2p.prom"
export NVLINK_P2P_NODE="${node}"

python3 <<'PY'
import json
import os
import pathlib
import re
import subprocess


def command(*args):
    try:
        completed = subprocess.run(args, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return None
    return completed.stdout if completed.returncode == 0 else None


def counter_total(text):
    return sum(int(value) for value in re.findall(r"\d+", text or ""))


fixture_path = os.environ["NVLINK_P2P_FIXTURE"]
fixture_data = json.loads((pathlib.Path(fixture_path) / "manifest.json").read_text(encoding="utf-8")) if fixture_path else {}
if fixture_path:
    profile = fixture_data.get("profile", {})
    observed = fixture_data.get("p2p_observed", {})
else:
    import yaml
    profile_path = os.environ["NVLINK_P2P_PROFILE"]
    profile = yaml.safe_load(open(profile_path, encoding="utf-8")) if profile_path else {}
    error_before = command("nvidia-smi", "nvlink", "-e")
    counter_before = command("nvidia-smi", "nvlink", "-c")
    peer_matrix = command("nvidia-smi", "topo", "-p2p", "r")
    bandwidth = command("nvbandwidth", "--test=p2p", "--mode=aggregate")
    error_after = command("nvidia-smi", "nvlink", "-e")
    counter_after = command("nvidia-smi", "nvlink", "-c")
    fabric_manager = command("systemctl", "is-active", "nvidia-fabricmanager")
    observed = {"commands": {"nvidia-smi": error_before is not None, "nvbandwidth": bandwidth is not None}, "error_before": error_before or "", "error_after": error_after or "", "counter_before": counter_before or "", "counter_after": counter_after or "", "p2p_matrix": peer_matrix or "", "nvbandwidth": bandwidth or "", "fabric_manager": fabric_manager or "unavailable"}

hardware = profile.get("hardware", {})
accelerator = hardware.get("accelerator", {})
gpu_policy = profile.get("topology", {}).get("gpu", {})
expected_count = hardware.get("gpus_per_node")
errors = []
warnings = []
if not profile:
    errors.append("VALIDATION_SITE_PROFILE is required for live GPU validation")
elif accelerator.get("kind") != "gpu" or accelerator.get("vendor") != "nvidia":
    verdict = "SKIP"
else:
    commands = observed.get("commands", {})
    for name in ("nvidia-smi", "nvbandwidth"):
        if not commands.get(name, False):
            errors.append(f"required command unavailable: {name}")
    if not isinstance(expected_count, int) or expected_count < 2:
        errors.append("profile must select at least two GPUs per node")
    if fixture_path:
        full_allocation = observed.get("full_gpu_allocation", False)
    else:
        visible = [value for value in os.environ.get("CUDA_VISIBLE_DEVICES", "").split(",") if value]
        allocated = os.environ.get("SLURM_GPUS_ON_NODE", "")
        full_allocation = bool(os.environ.get("SLURM_JOB_ID")) and allocated == str(expected_count) and len(visible) == expected_count
    if not full_allocation:
        errors.append("full profile-selected GPU allocation is required")
    peer_pairs = len(re.findall(r"\bOK\b", observed.get("p2p_matrix", "")))
    required_pairs = expected_count * (expected_count - 1) if isinstance(expected_count, int) else 0
    if peer_pairs < required_pairs:
        errors.append(f"CUDA P2P matrix is incomplete: expected={required_pairs}, got={peer_pairs}")
    values = [float(value) for value in re.findall(r"(?:bandwidth|GB/s)\D*(\d+(?:\.\d+)?)", observed.get("nvbandwidth", ""), re.IGNORECASE)]
    p2p_bandwidth = max(values) if values else 0.0
    if p2p_bandwidth < float(gpu_policy.get("minimum_p2p_gbps", 0)):
        errors.append(f"CUDA P2P bandwidth below profile minimum: got={p2p_bandwidth}")
    counter_delta = counter_total(observed.get("counter_after", "")) - counter_total(observed.get("counter_before", ""))
    error_delta = counter_total(observed.get("error_after", observed.get("counter_after", ""))) - counter_total(observed.get("error_before", observed.get("counter_before", "")))
    if error_delta > 0:
        errors.append(f"NVLink error counter delta is positive: {error_delta}")
    fabric_manager = observed.get("fabric_manager", "").strip()
    if fabric_manager == "unavailable":
        warnings.append("Fabric Manager status is not visible to the batch user")
    elif gpu_policy.get("interconnect") == "nvswitch" and fabric_manager != "active":
        errors.append(f"Fabric Manager is not active: {fabric_manager}")
    verdict = "FAIL" if errors else "WARN" if warnings else "PASS"

declared = fixture_data.get("verdicts", {}).get("nvlink-p2p", "")
if declared and verdict != declared:
    errors.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {"fixture": bool(fixture_path), "node": os.environ["NVLINK_P2P_NODE"], "expected_gpu_count": expected_count, "p2p_bandwidth_gbps": p2p_bandwidth if 'p2p_bandwidth' in locals() else 0.0, "counter_delta": counter_delta if 'counter_delta' in locals() else 0, "error_counter_delta": error_delta if 'error_delta' in locals() else 0, "fabric_manager": observed.get("fabric_manager", ""), "artifacts_sanitized": True, "verdict": verdict, "failures": errors, "warnings": warnings}
pathlib.Path(os.environ["NVLINK_P2P_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
pathlib.Path(os.environ["NVLINK_P2P_PROM"]).write_text(f'# HELP chapar_nvlink_error_counter_delta NVLink error counter delta\n# TYPE chapar_nvlink_error_counter_delta gauge\nchapar_nvlink_error_counter_delta{{node="{payload["node"]}"}} {payload["counter_delta"]}\n', encoding="utf-8")
PY

verdict="$(python3 -c "import json; print(json.load(open('${results_dir}/nvlink_p2p.json'))['verdict'])")"
reason="$(python3 -c "import json; value=json.load(open('${results_dir}/nvlink_p2p.json')); print('; '.join(value['failures'] or value['warnings']))")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
    SKIP) validation_resource_unavailable 'profile does not select an NVIDIA P2P suite' optional ;;
esac

printf 'NVLink P2P evidence written to %s\n' "${results_dir}" >&2
