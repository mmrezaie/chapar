#!/usr/bin/env bash
# DESCRIPTION: InfiniBand link manifest - validate HCA state, width, speed against expected config
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:02:00
#SBATCH --job-name=ib-link-check

set -euo pipefail

validation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_file="${validation_dir}/config/network.yaml"
node="${SLURM_NODELIST:-$(hostname -s)}"
RESULTS_ROOT="${RESULTS_ROOT:-${validation_dir}/results}"
source "${validation_dir}/lib/verdict.sh"
source "${validation_dir}/lib/result-manifest.sh"
validation_result_init ib-link-check "${RESULTS_ROOT}" "${node}"
RESULTS_DIR="${VALIDATION_NODE_DIR}"

# Read expected values from config
EXPECTED_STATE="ACTIVE"
EXPECTED_WIDTH="4X"
EXPECTED_SPEED="56 Gbps"
EXPECTED_PHYS_STATE="LinkUp"
EXPECTED_HCAS="1"
if [ -f "$config_file" ]; then
    python3 -c "
import yaml
with open('$config_file') as f:
    cfg = yaml.safe_load(f)
ib = cfg.get('infiniband', {})
print(ib.get('expected_state', 'ACTIVE'))
print(ib.get('expected_width', '4X'))
print(ib.get('expected_speed', '56 Gbps'))
print(ib.get('expected_phys_state', 'LinkUp'))
print(ib.get('expected_hcas', 1))
" > "${RESULTS_DIR}/expected.cfg" 2>/dev/null || true
    if [ -s "${RESULTS_DIR}/expected.cfg" ]; then
        EXPECTED_STATE=$(sed -n '1p' "${RESULTS_DIR}/expected.cfg")
        EXPECTED_WIDTH=$(sed -n '2p' "${RESULTS_DIR}/expected.cfg")
        EXPECTED_SPEED=$(sed -n '3p' "${RESULTS_DIR}/expected.cfg")
        EXPECTED_PHYS_STATE=$(sed -n '4p' "${RESULTS_DIR}/expected.cfg")
        EXPECTED_HCAS=$(sed -n '5p' "${RESULTS_DIR}/expected.cfg")
    fi
fi

# The heredoc below reads these from the environment; export before running it.
export EXPECTED_STATE EXPECTED_WIDTH EXPECTED_SPEED EXPECTED_PHYS_STATE EXPECTED_HCAS
export NODE="$node"

echo "=== InfiniBand Link Check ===" >&2
echo "Expected: hcas=${EXPECTED_HCAS} state=${EXPECTED_STATE} phys_state=${EXPECTED_PHYS_STATE} width=${EXPECTED_WIDTH} speed=${EXPECTED_SPEED}" >&2

# Check if IB sysfs exists
SYSFS_IB="/sys/class/infiniband"
if [ ! -d "$SYSFS_IB" ] || [ -z "$(ls -A "$SYSFS_IB" 2>/dev/null)" ]; then
    echo "SKIP: no InfiniBand HCAs found at ${SYSFS_IB}" >&2
    validation_resource_unavailable "no InfiniBand HCA at ${SYSFS_IB}" optional
fi

# Check each HCA
python3 << 'PYEOF' > "${RESULTS_DIR}/ib_link_check.json"
import json, os, re, sys

SYSFS_IB = "/sys/class/infiniband"
EXPECTED_STATE = os.environ.get('EXPECTED_STATE', 'ACTIVE')
EXPECTED_WIDTH = os.environ.get('EXPECTED_WIDTH', '4X')
EXPECTED_SPEED = os.environ.get('EXPECTED_SPEED', '56 Gbps')
EXPECTED_PHYS_STATE = os.environ.get('EXPECTED_PHYS_STATE', 'LinkUp')
try:
    EXPECTED_HCAS = int(os.environ.get('EXPECTED_HCAS', '1'))
except ValueError:
    EXPECTED_HCAS = 1
NODE = os.environ.get('NODE', 'unknown')

state_map = {'1': 'DOWN', '2': 'INIT', '3': 'ARMED', '4': 'ACTIVE', '5': 'ACTIVE_DEFER'}
phys_state_map = {'1': 'NoState', '2': 'Sleep', '3': 'Polling', '4': 'Disabled', '5': 'LinkUp'}

hcas = sorted(os.listdir(SYSFS_IB))
results = {'node': NODE, 'hcas': len(hcas), 'expected_hcas': EXPECTED_HCAS,
           'ports': [], 'checks': [], 'failures': 0, 'verdict': 'PASS'}

if len(hcas) != EXPECTED_HCAS:
    results['checks'].append(f"hca count: expected={EXPECTED_HCAS}, got={len(hcas)}")
    results['failures'] += 1

for hca in hcas:
    ports_dir = f"{SYSFS_IB}/{hca}/ports"
    if not os.path.isdir(ports_dir):
        continue
    for port in sorted(os.listdir(ports_dir)):
        state_path = f"{ports_dir}/{port}/state"
        phys_state_path = f"{ports_dir}/{port}/phys_state"
        rate_path = f"{ports_dir}/{port}/rate"

        port_info = {'hca': hca, 'port': port}

        if os.path.isfile(state_path):
            raw = open(state_path).read().strip()
            code = raw.split()[0].rstrip(':') if raw else '0'
            port_info['state'] = state_map.get(code, raw)
        if os.path.isfile(phys_state_path):
            raw = open(phys_state_path).read().strip()
            code = raw.split()[0].rstrip(':') if raw else '0'
            port_info['phys_state'] = phys_state_map.get(code, raw)
        # IB sysfs exposes width/speed through 'rate', e.g. "56 Gb/sec (4X FDR)"
        if os.path.isfile(rate_path):
            raw = open(rate_path).read().strip()
            port_info['rate'] = raw
            m = re.match(r'([\d.]+)\s*Gb/sec\s*\((\d+X)', raw)
            if m:
                speed = m.group(1)
                speed = speed.rstrip('0').rstrip('.') if '.' in speed else speed
                port_info['speed'] = f"{speed} Gbps"
                port_info['width'] = m.group(2)

        # Compare against expected
        port_info['checks'] = []
        if port_info.get('state') != EXPECTED_STATE:
            port_info['checks'].append(f"state: expected={EXPECTED_STATE}, got={port_info.get('state','?')}")
            results['failures'] += 1
        if port_info.get('phys_state') != EXPECTED_PHYS_STATE:
            port_info['checks'].append(f"phys_state: expected={EXPECTED_PHYS_STATE}, got={port_info.get('phys_state','?')}")
            results['failures'] += 1
        if port_info.get('width') != EXPECTED_WIDTH:
            port_info['checks'].append(f"width: expected={EXPECTED_WIDTH}, got={port_info.get('width','?')}")
            results['failures'] += 1
        if port_info.get('speed') != EXPECTED_SPEED:
            port_info['checks'].append(f"speed: expected={EXPECTED_SPEED}, got={port_info.get('speed','?')}")
            results['failures'] += 1

        results['ports'].append(port_info)

if results['failures'] > 0:
    results['verdict'] = 'FAIL'
print(json.dumps(results, indent=2))
PYEOF

# Read result
cat "${RESULTS_DIR}/ib_link_check.json"

# Write Prometheus output
python3 -c "
import json
with open('${RESULTS_DIR}/ib_link_check.json') as f:
    d = json.load(f)
if d.get('verdict') == 'SKIP':
    exit(0)
lines = []
lines.append('# HELP ib_link_status InfiniBand link status (0=DOWN, 1=ACTIVE)')
lines.append('# TYPE ib_link_status gauge')
for port in d.get('ports', []):
    is_active = 1 if port.get('state') in ('ACTIVE', 'ACTIVE_DEFER') else 0
    lines.append(f'ib_link_status{{node=\"{d[\"node\"]}\",hca=\"{port[\"hca\"]}\",port=\"{port[\"port\"]}\"}} {is_active}')
lines.append('# HELP ib_link_hcas Number of InfiniBand HCAs detected')
lines.append('# TYPE ib_link_hcas gauge')
lines.append(f'ib_link_hcas{{node=\"{d[\"node\"]}\"}} {d.get(\"hcas\", 0)}')
lines.append('# HELP ib_link_verdict IB link check verdict (0=PASS, 1=FAIL)')
lines.append('# TYPE ib_link_verdict gauge')
vc = 0 if d.get('verdict') in ('PASS', 'SKIP') else 1
lines.append(f'ib_link_verdict{{node=\"{d[\"node\"]}\"}} {vc}')
with open('${RESULTS_DIR}/ib_link.prom', 'w') as f:
    f.write('\\n'.join(lines) + '\\n')
"

echo "Results: ${RESULTS_DIR}" >&2

verdict=$(python3 -c "import json; print(json.load(open('${RESULTS_DIR}/ib_link_check.json')).get('verdict', 'FAIL'))")
if [ "$verdict" = "FAIL" ]; then
    validation_threshold_violation "InfiniBand link manifest mismatch"
fi
