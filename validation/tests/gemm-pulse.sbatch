#!/usr/bin/env bash
# DESCRIPTION: GPU GEMM pulse - detect throttling via repeated matmul + coefficient of variation
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:05:00
#SBATCH --job-name=gemm-pulse

set -euo pipefail

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_id="${SLURM_JOB_ID:-$(date -u +%Y%m%dT%H%M%S)}"
node="${SLURM_NODELIST:-$(hostname -s)}"
RESULTS_DIR="${RESULTS_ROOT:-${validation_dir}/results}/gemm-pulse/${run_id}/${node}"
mkdir -p "${RESULTS_DIR}"

# Load modules
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge 2>/dev/null || true
fi
module load "${CHAPAR_MODULE_CUDA:-cuda/13}" "${CHAPAR_MODULE_PY_TORCH:-py-torch}" 2>/dev/null || {
    echo "WARNING: Could not load cuda/py-torch modules. Trying direct execution..." >&2
}

python3 - << 'PYEOF' > "${RESULTS_DIR}/gemm_pulse.json"
import json, sys, statistics

try:
    import torch
except ImportError:
    print(json.dumps({"error": "PyTorch not available", "verdict": "SKIP"}))
    sys.exit(0)

try:
    device = torch.device('cuda:0')
    torch.cuda.get_device_properties(device)
except (RuntimeError, AssertionError):
    print(json.dumps({"error": "CUDA device not available", "verdict": "SKIP"}))
    sys.exit(0)

# Warmup
a = torch.randn(1024, 1024, device=device)
b = torch.randn(1024, 1024, device=device)
for _ in range(3):
    c = a @ b
torch.cuda.synchronize()

# Measure
times = []
for _ in range(10):
    start = torch.cuda.Event(enable_timing=True)
    end = torch.cuda.Event(enable_timing=True)
    start.record()
    c = a @ b
    end.record()
    torch.cuda.synchronize()
    times.append(start.elapsed_time(end))

mean = statistics.mean(times)
std = statistics.stdev(times) if len(times) > 1 else 0.0
cv = (std / mean * 100) if mean > 0 else 0.0

if cv > 15:
    verdict = "FAIL"
elif cv > 5:
    verdict = "WARN"
else:
    verdict = "PASS"

result = {
    "mean_ms": round(mean, 3),
    "median_ms": round(statistics.median(times), 3),
    "std_ms": round(std, 3),
    "cv_pct": round(cv, 3),
    "iterations": len(times),
    "min_ms": round(min(times), 3),
    "max_ms": round(max(times), 3),
    "gpu_name": torch.cuda.get_device_name(0),
    "matrix_size": "1024x1024",
    "dtype": "float32",
    "verdict": verdict,
}
print(json.dumps(result, indent=2))
PYEOF

# Generate Prometheus output
python3 -c "
import json
with open('${RESULTS_DIR}/gemm_pulse.json') as f:
    d = json.load(f)
if 'error' in d:
    exit(0)
lines = []
lines.append('# HELP gemm_pulse_cv_pct Coefficient of variation of GEMM execution time (%). >5=WARN, >15=FAIL')
lines.append('# TYPE gemm_pulse_cv_pct gauge')
lines.append(f'gemm_pulse_cv_pct{{gpu=\"0\",node=\"{node}\"}} {d[\"cv_pct\"]}')
lines.append('# HELP gemm_pulse_mean_ms Mean GEMM execution time (ms)')
lines.append('# TYPE gemm_pulse_mean_ms gauge')
lines.append(f'gemm_pulse_mean_ms{{gpu=\"0\",node=\"{node}\"}} {d[\"mean_ms\"]}')
lines.append('# HELP gemm_pulse_verdict GEMM pulse test verdict (0=PASS, 1=WARN, 2=FAIL)')
lines.append('# TYPE gemm_pulse_verdict gauge')
verdict_code = {'PASS': 0, 'WARN': 1, 'FAIL': 2}.get(d.get('verdict','PASS'), 0)
lines.append(f'gemm_pulse_verdict{{gpu=\"0\",node=\"{node}\"}} {verdict_code}')
with open('${RESULTS_DIR}/gemm_pulse.prom', 'w') as f:
    f.write('\\n'.join(lines) + '\\n')
print('Prometheus metrics written')
" 2>&1 | tee -a "${RESULTS_DIR}/gemm_pulse.log"

cat "${RESULTS_DIR}/gemm_pulse.json"
echo "Results: ${RESULTS_DIR}" >&2

verdict=$(python3 -c "import json; print(json.load(open('${RESULTS_DIR}/gemm_pulse.json')).get('verdict', 'FAIL'))")
case "$verdict" in
    SKIP)
        echo "SKIP: GPU/PyTorch not available on this node" >&2
        exit 77
        ;;
    FAIL)
        echo "FAIL: GEMM timing variation exceeds threshold (see ${RESULTS_DIR}/gemm_pulse.json)" >&2
        exit 1
        ;;
esac
