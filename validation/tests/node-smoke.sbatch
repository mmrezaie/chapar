#!/bin/bash
# DESCRIPTION: Per-node hardware smoke test (memory bandwidth, GPU P2P, PAPI counters, cuda-memtest, topology)
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:15:00
#SBATCH --gres=gpu:1
#SBATCH -J node-smoke
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
RESULTS_DIR="${RESULTS_ROOT}/node-smoke/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST:-$(hostname)}"
mkdir -p "${RESULTS_DIR}"

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_LIKWID:-likwid}" \
    "${CHAPAR_MODULE_PAPI:-papi}" \
    "${CHAPAR_MODULE_CUDA:-cuda/13}" \
    "${CHAPAR_MODULE_NVBANDWIDTH:-nvbandwidth}" \
    "${CHAPAR_MODULE_CUDA_MEMTEST:-cuda-memtest}" \
    "${CHAPAR_MODULE_HWLOC:-hwloc}"

# ── likwid memory bandwidth ────────────────────────────────────
echo "=== likwid MEM_DP ===" >&2
likwid-perfctr -C 0 -g MEM_DP -O "${RESULTS_DIR}/likwid_mem.csv" likwid-bench

# ── nvbandwidth memcpy + P2P ───────────────────────────────────
echo "=== nvbandwidth memcpy + p2p ===" >&2
nvbandwidth --test=memcpy --test=p2p --mode=aggregate \
    -o "${RESULTS_DIR}/nvbw.csv"

# ── PAPI counter availability ──────────────────────────────────
echo "=== PAPI L2_TCM ===" >&2
papi_command_line -e PAPI_L2_TCM > "${RESULTS_DIR}/papi_l2.txt"

# ── Per-GPU cuda-memtest ───────────────────────────────────────
echo "=== cuda-memtest (per GPU) ===" >&2
GPU_COUNT="${SLURM_GPUS_ON_NODE:-$(nvidia-smi -L 2>/dev/null | wc -l)}"
for g in $(seq 0 $((GPU_COUNT - 1))); do
    echo "  GPU ${g} …" >&2
    CUDA_VISIBLE_DEVICES="${g}" \
        cuda-memtest --report-mem-errors \
        --num-passes=1 \
        > "${RESULTS_DIR}/cuda_memtest_gpu${g}.log"
done

# ── nvidia-smi health ───────────────────────────────────────────
echo "=== nvidia-smi health ===" >&2
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,ecc.errors.volatile.total,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits \
        > "${RESULTS_DIR}/nvidia_smi_health.csv" 2>/dev/null || true
    if [ -f "${RESULTS_DIR}/nvidia_smi_health.csv" ] && [ -s "${RESULTS_DIR}/nvidia_smi_health.csv" ]; then
        export CSV_PATH="${RESULTS_DIR}/nvidia_smi_health.csv" PROM_PATH="${RESULTS_DIR}/nvidia_smi_health.prom"
        python3 -c "
import csv, os

def num(v):
    v = v.strip()
    try:
        float(v)
        return v
    except ValueError:
        return ''

with open(os.environ['CSV_PATH']) as f:
    rows = [r for r in csv.reader(f) if len(r) >= 7]
lines = []
for r in rows:
    g = r[0].strip(); n = r[1].strip(); lbl = f'gpu=\"{g}\",name=\"{n}\"'
    t = num(r[2]); p = num(r[3]); e = num(r[4]); ggen = num(r[5]); gw = num(r[6])
    if t: lines.append(f'nvidia_gpu_temperature{{{lbl}}} {t}')
    if p: lines.append(f'nvidia_gpu_power_draw{{{lbl}}} {p}')
    if e: lines.append(f'nvidia_gpu_ecc_errors_volatile{{{lbl}}} {e}')
    if ggen: lines.append(f'nvidia_gpu_pcie_link_gen{{{lbl}}} {ggen}')
    if gw: lines.append(f'nvidia_gpu_pcie_link_width{{{lbl}}} {gw}')
if lines:
    header = ['# HELP nvidia_gpu_temperature GPU temperature (C)', '# TYPE nvidia_gpu_temperature gauge',
              '# HELP nvidia_gpu_power_draw GPU power draw (W)', '# TYPE nvidia_gpu_power_draw gauge',
              '# HELP nvidia_gpu_ecc_errors_volatile Volatile ECC error count', '# TYPE nvidia_gpu_ecc_errors_volatile gauge',
              '# HELP nvidia_gpu_pcie_link_gen Current PCIe link generation', '# TYPE nvidia_gpu_pcie_link_gen gauge',
              '# HELP nvidia_gpu_pcie_link_width Current PCIe link width', '# TYPE nvidia_gpu_pcie_link_width gauge']
    with open(os.environ['PROM_PATH'], 'w') as f:
        f.write('\\n'.join(header + lines) + '\\n')
    print('Prometheus metrics written')
" 2>&1 | tee -a "${RESULTS_DIR}/node-smoke.log"
    fi
else
    echo "  nvidia-smi not found (expected on non-GPU nodes)" >&2
fi

# ── Topology reports ───────────────────────────────────────────
echo "=== hwloc topology ===" >&2
srun -n 1 --ntasks=1 hwloc-info --topology \
    > "${RESULTS_DIR}/hwloc_topology.txt"

echo "=== lscpu ===" >&2
srun -n 1 --ntasks=1 lscpu > "${RESULTS_DIR}/lscpu.txt"

echo "Node-smoke results written to ${RESULTS_DIR}" >&2
