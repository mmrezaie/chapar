#!/usr/bin/env bash
# DESCRIPTION: NCCL transport assertion - verify NCCL selected expected transport (IB/Socket/NVLink)
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:05:00
#SBATCH --job-name=nccl-transport-check

set -euo pipefail

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_file="${validation_dir}/config/network.yaml"
run_id="${SLURM_JOB_ID:-$(date -u +%Y%m%dT%H%M%S)}"
node="${SLURM_NODELIST:-$(hostname -s)}"
RESULTS_DIR="${RESULTS_ROOT:-${validation_dir}/results}/nccl-transport-check/${run_id}/${node}"
mkdir -p "${RESULTS_DIR}"

# Load modules
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge 2>/dev/null || true
fi
module load "${CHAPAR_MODULE_CUDA:-cuda/13}" "${CHAPAR_MODULE_NCCL:-nccl}" 2>/dev/null || {
    echo "WARNING: Could not load cuda/nccl modules" >&2
}

# Read expected transport from config
EXPECTED_TRANSPORT=""
if [ -f "$config_file" ]; then
    EXPECTED_TRANSPORT=$(python3 -c "
import yaml
with open('$config_file') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('nccl', {}).get('expected_transport', ''))
" 2>/dev/null || echo "")
fi

echo "=== NCCL Transport Check ===" >&2
echo "Expected transport: ${EXPECTED_TRANSPORT:-auto-detect}" >&2

# Run NCCL all_reduce with DEBUG output. NCCL writes its debug stream to
# NCCL_DEBUG_FILE; keep Python's own stderr separate so neither clobbers
# the other. The heredoc always exits 0 and encodes the verdict in JSON;
# the shell decides the final exit code from that verdict.
NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET \
NCCL_DEBUG_FILE="${RESULTS_DIR}/nccl_debug.log" \
MASTER_PORT_BASE="$((29500 + ${SLURM_JOB_ID:-0} % 1000))" \
python3 - << 'PYEOF' 2>"${RESULTS_DIR}/python_stderr.log" > "${RESULTS_DIR}/nccl_result.log"
import json, os, sys

try:
    import torch
    import torch.distributed as dist
except ImportError:
    print(json.dumps({"error": "PyTorch not available", "verdict": "SKIP"}))
    sys.exit(0)

os.environ['RANK'] = '0'
os.environ['WORLD_SIZE'] = '1'
os.environ['MASTER_ADDR'] = '127.0.0.1'
os.environ['MASTER_PORT'] = os.environ.get('MASTER_PORT_BASE', '29500')

try:
    if not torch.cuda.is_available():
        print(json.dumps({"error": "CUDA not available", "verdict": "SKIP"}))
        sys.exit(0)

    dist.init_process_group(backend='nccl', rank=0, world_size=1)
    t = torch.ones(1024, device='cuda:0')
    dist.all_reduce(t)
    dist.destroy_process_group()

    print(json.dumps({"result": "AllReduce OK", "verdict": "PASS"}))
except Exception as e:
    print(json.dumps({"error": str(e), "verdict": "FAIL"}))
PYEOF

RUN_VERDICT=$(python3 -c "
import json
try:
    with open('${RESULTS_DIR}/nccl_result.log') as f:
        print(json.load(f).get('verdict', 'FAIL'))
except Exception:
    print('FAIL')
")

if [ "$RUN_VERDICT" = "SKIP" ]; then
    echo "SKIP: $(cat "${RESULTS_DIR}/nccl_result.log")" >&2
    exit 77
fi

# Parse NCCL debug output for the selected transport. Depending on the NCCL
# version the line is "Using network IB", "Using network Socket", or
# "NET/IB : Using ..." / "NET/Socket : Using ...". NCCL versions also differ in
# whether NCCL_DEBUG_FILE is honored, so scan Python stderr too.
#
# RoCEv2 and InfiniBand are both served by NCCL's NET/IB plugin, so the plugin
# name alone cannot tell them apart. The device list carries the link layer:
#   NET/IB : Using [0]mlx5_0:1/RoCE ...   -> RoCEv2
#   NET/IB : Using [0]mlx5_0:1/IB   ...   -> InfiniBand
# Matching only /(IB|Socket)/ reported RoCEv2 clusters as "IB".
SELECTED_TRANSPORT=$(python3 - "$RESULTS_DIR" << 'PYEOF'
import re, sys

text = ""
for name in ("nccl_debug.log", "python_stderr.log"):
    try:
        with open(f"{sys.argv[1]}/{name}") as f:
            text += f.read()
    except OSError:
        pass

# Link layer per device, e.g. "[0]mlx5_0:1/RoCE" or "[3]mlx5_3:1/IB".
link_layers = {layer.upper() for layer in re.findall(r"\[\d+\][\w.:]+/(RoCE|IB)\b", text)}

plugin = ""
match = re.search(r"Using network\s*:?\s*(\S+)", text)
if match:
    plugin = match.group(1)
if not plugin:
    match = re.search(r"NET/(\w+)", text)
    plugin = match.group(1) if match else ""

if "ROCE" in link_layers:
    # A mixed fabric is not something this check should silently average out.
    print("RoCE" if "IB" not in link_layers else "Mixed")
elif "IB" in link_layers:
    print("IB")
elif re.search(r"socket", plugin, re.IGNORECASE):
    print("Socket")
elif re.search(r"ib", plugin, re.IGNORECASE):
    # NET/IB with no device list: the fabric is RDMA but the link layer is
    # unproven, so report the plugin class rather than guessing IB or RoCE.
    print("IBverbs")
elif re.search(r"via P2P|P2P/IPC|NVLS|/NVL\b", text):
    # No network leg at all: every rank pair resolved to intra-node peer
    # access, which is the NVLink/NVSwitch path on these nodes.
    print("NVLink")
else:
    print(plugin)
PYEOF
)
echo "Selected transport: ${SELECTED_TRANSPORT:-<not observed>}" >&2

# Compare with expected
VERDICT="$RUN_VERDICT"
NOTE=""
if [ "$VERDICT" = "PASS" ] && [ -n "$EXPECTED_TRANSPORT" ]; then
    if [ -z "$SELECTED_TRANSPORT" ]; then
        echo "WARN: NCCL did not report a transport. This job runs one rank on one node, so NCCL has no peer to reach and may skip network init entirely. Run the multi-node 'transport' tier to assert the fabric." >&2
        VERDICT="WARN"
        NOTE="transport not observed; single-rank init does not exercise the fabric"
    elif [ "$SELECTED_TRANSPORT" != "$EXPECTED_TRANSPORT" ]; then
        echo "MISMATCH: Expected ${EXPECTED_TRANSPORT}, got ${SELECTED_TRANSPORT}" >&2
        VERDICT="FAIL"
        NOTE="transport mismatch"
    fi
fi

# Write summary JSON
export SUMMARY_NODE="$node" SUMMARY_EXPECTED="$EXPECTED_TRANSPORT" \
       SUMMARY_SELECTED="$SELECTED_TRANSPORT" SUMMARY_VERDICT="$VERDICT" SUMMARY_NOTE="$NOTE"
python3 -c "
import json, os
result = {
    'node': os.environ['SUMMARY_NODE'],
    'expected_transport': os.environ['SUMMARY_EXPECTED'],
    'selected_transport': os.environ['SUMMARY_SELECTED'],
    'verdict': os.environ['SUMMARY_VERDICT'],
}
if os.environ['SUMMARY_NOTE']:
    result['note'] = os.environ['SUMMARY_NOTE']
with open('${RESULTS_DIR}/nccl_transport_check.json', 'w') as f:
    json.dump(result, f, indent=2)
print(json.dumps(result, indent=2))
"

# Write Prometheus output
python3 -c "
import json
with open('${RESULTS_DIR}/nccl_transport_check.json') as f:
    d = json.load(f)
lines = []
lines.append('# HELP nccl_transport_selected NCCL transport class selected (0=IB, 1=Socket, 2=NVLink, 3=RoCE, 4=IBverbs-unknown-link-layer, 5=Mixed, -1=unknown)')
lines.append('# TYPE nccl_transport_selected gauge')
transport_code = {'IB': 0, 'Socket': 1, 'NVLink': 2, 'RoCE': 3, 'IBverbs': 4, 'Mixed': 5}.get(d.get('selected_transport',''), -1)
lines.append(f'nccl_transport_selected{{node=\"{d[\"node\"]}\"}} {transport_code}')
lines.append('# HELP nccl_transport_verdict NCCL transport check verdict (0=PASS, 1=WARN, 2=FAIL)')
lines.append('# TYPE nccl_transport_verdict gauge')
verdict_code = {'PASS': 0, 'WARN': 1}.get(d.get('verdict'), 2)
lines.append(f'nccl_transport_verdict{{node=\"{d[\"node\"]}\"}} {verdict_code}')
with open('${RESULTS_DIR}/nccl_transport.prom', 'w') as f:
    f.write('\\n'.join(lines) + '\\n')
"

echo "Results: ${RESULTS_DIR}" >&2

if [ "$VERDICT" = "FAIL" ]; then
    echo "FAIL: NCCL transport check failed (see ${RESULTS_DIR}/nccl_transport_check.json)" >&2
    exit 1
fi
