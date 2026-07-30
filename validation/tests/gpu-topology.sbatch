#!/usr/bin/env bash
# DESCRIPTION: NVIDIA GPU inventory, NVLink/NVSwitch topology, and counter evidence
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --time=00:05:00
#SBATCH --job-name=gpu-topology

set -euo pipefail

usage() {
    printf '%s\n' 'Usage: gpu-topology.sbatch [--fixture validation/fixtures/gpu/<case>]'
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
validation_result_init gpu-topology "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

export GPU_TOPOLOGY_FIXTURE="${fixture}"
export GPU_TOPOLOGY_PROFILE="${VALIDATION_SITE_PROFILE:-}"
export GPU_TOPOLOGY_RESULT="${results_dir}/gpu_topology.json"
export GPU_TOPOLOGY_PROM="${results_dir}/gpu_topology.prom"
export GPU_TOPOLOGY_NODE="${node}"

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


def load_profile(fixture_data):
    if fixture_data:
        return fixture_data.get("profile", {})
    profile_path = os.environ["GPU_TOPOLOGY_PROFILE"]
    if not profile_path:
        return {}
    import yaml
    with open(profile_path, encoding="utf-8") as stream:
        return yaml.safe_load(stream) or {}


fixture_path = os.environ["GPU_TOPOLOGY_FIXTURE"]
fixture_data = json.loads((pathlib.Path(fixture_path) / "manifest.json").read_text(encoding="utf-8")) if fixture_path else {}
profile = load_profile(fixture_data)
fixture_observed = fixture_data.get("topology_observed", {})
available = fixture_observed.get("commands", {})
if fixture_path:
    inventory_text = fixture_observed.get("nvidia_smi_l", "")
    topology_text = fixture_observed.get("topo_m", "")
    status_text = fixture_observed.get("nvlink_status", "")
    error_text = fixture_observed.get("nvlink_errors", "")
else:
    inventory_text = command("nvidia-smi", "-L")
    topology_text = command("nvidia-smi", "topo", "-m")
    status_text = command("nvidia-smi", "nvlink", "-s")
    error_text = command("nvidia-smi", "nvlink", "-e")
    counter_text = command("nvidia-smi", "nvlink", "-c")
    available = {"nvidia-smi": inventory_text is not None}

hardware = profile.get("hardware", {})
accelerator = hardware.get("accelerator", {})
gpu_policy = profile.get("topology", {}).get("gpu", {})
expected_count = hardware.get("gpus_per_node")
vendor = accelerator.get("vendor")
errors = []
warnings = []
if not profile:
    errors.append("VALIDATION_SITE_PROFILE is required for live GPU validation")
elif accelerator.get("kind") != "gpu" or vendor != "nvidia":
    verdict = "SKIP"
    errors = []
else:
    required_policy = {"models", "interconnect", "minimum_links_per_gpu", "minimum_p2p_gbps", "require_nvls"}
    missing_policy = sorted(required_policy - set(gpu_policy))
    if not isinstance(expected_count, int) or expected_count < 2:
        errors.append("profile must select at least two GPUs per node")
    if missing_policy:
        errors.append(f"profile GPU topology is missing: {','.join(missing_policy)}")
    if fixture_path:
        full_allocation = fixture_observed.get("full_gpu_allocation", False)
    else:
        visible = [value for value in os.environ.get("CUDA_VISIBLE_DEVICES", "").split(",") if value]
        full_allocation = bool(os.environ.get("SLURM_JOB_ID")) and os.environ.get("SLURM_GPUS_ON_NODE") == str(expected_count) and len(visible) == expected_count
    if not full_allocation:
        errors.append("full profile-selected GPU allocation is required")
    if not available.get("nvidia-smi", inventory_text is not None):
        errors.append("required command unavailable: nvidia-smi")
    models = []
    for line in (inventory_text or "").splitlines():
        match = re.match(r"GPU\s+\d+:\s*([^()]+)", line)
        if match:
            models.append(match.group(1).strip())
    if inventory_text is not None and isinstance(expected_count, int) and len(models) != expected_count:
        errors.append(f"GPU inventory count: expected={expected_count}, got={len(models)}")
    expected_models = gpu_policy.get("models", [])
    if expected_models and any(not any(expected in model for expected in expected_models) for model in models):
        errors.append("GPU model does not match profile")
    link_tokens = re.findall(r"\bNV\d+\b", topology_text or "")
    active_links = len(re.findall(r"\b(?:Active|Up)\b", status_text or "", re.IGNORECASE))
    interconnect = gpu_policy.get("interconnect")
    if interconnect == "nvlink" and (not isinstance(expected_count, int) or not link_tokens or active_links < expected_count * gpu_policy.get("minimum_links_per_gpu", 0)):
        errors.append("NVLink topology/status does not satisfy the profile")
    if interconnect == "nvswitch" and not re.search(r"NVSwitch|NV\d+", f"{topology_text}\n{status_text}", re.IGNORECASE):
        errors.append("NVSwitch topology is not observed")
    if re.search(r"ERR!|Error", error_text or "", re.IGNORECASE):
        errors.append("NVLink error status is reported")
    verdict = "FAIL" if errors else "WARN" if warnings else "PASS"

declared = fixture_data.get("verdicts", {}).get("gpu-topology", "")
if declared and verdict != declared:
    errors.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {
    "fixture": bool(fixture_path), "node": os.environ["GPU_TOPOLOGY_NODE"],
    "expected_gpu_count": expected_count, "observed_gpu_count": len(models) if inventory_text is not None else 0,
    "models": models, "interconnect": gpu_policy.get("interconnect", ""),
    "nvlink_topology_tokens": len(link_tokens) if 'link_tokens' in locals() else 0,
    "active_links": active_links if 'active_links' in locals() else 0,
    "nvlink_counter_snapshot_present": bool(counter_text) if 'counter_text' in locals() else False,
    "artifacts_sanitized": True, "verdict": verdict, "failures": errors, "warnings": warnings,
}
pathlib.Path(os.environ["GPU_TOPOLOGY_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
pathlib.Path(os.environ["GPU_TOPOLOGY_PROM"]).write_text(
    "# HELP chapar_gpu_topology_inventory GPUs observed against the profile\n"
    "# TYPE chapar_gpu_topology_inventory gauge\n"
    f'chapar_gpu_topology_inventory{{node="{payload["node"]}"}} {payload["observed_gpu_count"]}\n', encoding="utf-8")
PY

verdict="$(python3 -c "import json; print(json.load(open('${results_dir}/gpu_topology.json'))['verdict'])")"
reason="$(python3 -c "import json; value=json.load(open('${results_dir}/gpu_topology.json')); print('; '.join(value['failures'] or value['warnings']))")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
    SKIP) validation_resource_unavailable 'profile does not select an NVIDIA GPU topology suite' optional ;;
esac

printf 'GPU topology evidence written to %s\n' "${results_dir}" >&2
