#!/usr/bin/env bash
# DESCRIPTION: Allocation-only Slurm CPU placement and binding evidence
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:03:00
#SBATCH --job-name=slurm-placement

set -euo pipefail

usage() {
    printf '%s\n' 'Usage: slurm-placement.sbatch [--fixture validation/fixtures/cpu/<case>]'
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
fixture=""

if [ "${1:-}" = --fixture ]; then
    [ "$#" = 2 ] || { usage; exit 2; }
    fixture="$2"
    [ -f "${fixture}/manifest.json" ] || { printf 'CPU fixture manifest is missing: %s\n' "${fixture}" >&2; exit 2; }
elif [ "$#" -ne 0 ]; then
    usage
    exit 2
fi

source "${validation_dir}/lib/verdict.sh"
source "${validation_dir}/lib/result-manifest.sh"
validation_result_init slurm-placement "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

export SLURM_PLACEMENT_FIXTURE="${fixture}"
export SLURM_PLACEMENT_RESULT="${results_dir}/slurm_placement.json"

if [ -n "${fixture}" ]; then
    binding_output=""
elif [ -z "${SLURM_JOB_ID:-}" ]; then
    binding_output=""
else
    command -v srun >/dev/null 2>&1 || validation_resource_unavailable 'srun is unavailable inside the Slurm allocation' mandatory
    cpus_per_task="${SLURM_CPUS_PER_TASK:-1}"
    [[ "${cpus_per_task}" =~ ^[1-9][0-9]*$ ]] || { printf 'invalid SLURM_CPUS_PER_TASK: %s\n' "${cpus_per_task}" >&2; exit 2; }
    binding_output="$(srun --nodes=1 --ntasks=1 --cpus-per-task="${cpus_per_task}" --cpu-bind=verbose bash -c 'grep ^Cpus_allowed_list: /proc/self/status' 2>&1)"
fi
export SLURM_PLACEMENT_BINDING_OUTPUT="${binding_output}"

python3 <<'PY'
import json
import os
import pathlib
import re


def fixture_payload(path):
    return json.loads((pathlib.Path(path) / "manifest.json").read_text(encoding="utf-8"))


fixture = os.environ["SLURM_PLACEMENT_FIXTURE"]
if fixture:
    fixture_data = fixture_payload(fixture)
    observed = fixture_data["slurm_placement"]
    declared = fixture_data["verdicts"]["slurm-placement"]
else:
    binding_output = os.environ["SLURM_PLACEMENT_BINDING_OUTPUT"]
    match = re.search(r"Cpus_allowed_list:\s*([^\s]+)", binding_output)
    observed = {
        "allocation": bool(os.environ.get("SLURM_JOB_ID")),
        "job_id": os.environ.get("SLURM_JOB_ID", ""),
        "node_list": os.environ.get("SLURM_NODELIST", ""),
        "cpus_on_node": os.environ.get("SLURM_CPUS_ON_NODE", os.environ.get("SLURM_JOB_CPUS_PER_NODE", "")),
        "cpus_per_task": os.environ.get("SLURM_CPUS_PER_TASK", "1"),
        "binding_cpus": match.group(1) if match else "",
        "binding_output": binding_output,
    }
    declared = ""

failures = []
if not observed.get("allocation"):
    verdict = "SKIP"
elif not str(observed.get("job_id", "")):
    failures.append("allocation evidence has no Slurm job ID")
elif not str(observed.get("node_list", "")):
    failures.append("allocation evidence has no Slurm node list")
elif not str(observed.get("cpus_on_node", "")):
    failures.append("allocation evidence has no allocated CPU count")
elif not str(observed.get("cpus_per_task", "")):
    failures.append("allocation evidence has no CPUs-per-task value")
elif not str(observed.get("binding_cpus", "")):
    failures.append("Slurm step did not expose a CPU binding mask")
verdict = "FAIL" if failures else "PASS" if observed.get("allocation") else "SKIP"
if declared and verdict != declared:
    failures.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {
    "fixture": bool(fixture), "observed": observed, "verdict": verdict,
    "failures": failures,
    "architecture_allocation_proof": False,
    "scope": "This suite verifies placement only for the current allocation. It does not prove that Slurm allocated a requested CPU architecture.",
}
pathlib.Path(os.environ["SLURM_PLACEMENT_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

verdict="$(python3 -c "import json; print(json.load(open('${results_dir}/slurm_placement.json'))['verdict'])")"
reason="$(python3 -c "import json; value=json.load(open('${results_dir}/slurm_placement.json')); print('; '.join(value['failures']))")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    SKIP) validation_resource_unavailable 'Slurm placement requires an existing Slurm allocation; no allocation claim is made' optional ;;
esac

printf 'Slurm placement evidence written to %s\n' "${results_dir}" >&2
