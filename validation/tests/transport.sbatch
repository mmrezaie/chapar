#!/bin/bash
# DESCRIPTION: Transport path validation (UCX, Open MPI, libfabric, NCCL debug)
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --time=00:30:00
#SBATCH --gres=gpu:1
#SBATCH -J vlad-transport
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
RESULTS_DIR="${RESULTS_ROOT}/transport/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Runtime knobs ──────────────────────────────────────────────
: "${EXTERNAL_UCX_PERFTEST:=external/ucx-perftest/ucx_perftest}"
: "${EXTERNAL_PERFTEST:=external/perftest/ib_write_bw}"
: "${NCCL_DEBUG:=INFO}"

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_OPENMPI:-openmpi/5}" \
    "${CHAPAR_MODULE_CUDA:-cuda/13}" \
    "${CHAPAR_MODULE_UCX:-ucx}" \
    "${CHAPAR_MODULE_LIBFABRIC:-libfabric}" \
    "${CHAPAR_MODULE_HWLOC:-hwloc}" \
    "${CHAPAR_MODULE_NCCL_TESTS:-nccl-tests}" \
    "${CHAPAR_MODULE_NCCL:-nccl}"

# ── Evidence collection ────────────────────────────────────────
# These probes must not abort the tier: the capability assertions at the end
# are the verdict, and they report missing evidence far more usefully than a
# `set -e` abort partway through collection.
echo "=== ucx_info devices ===" >&2
ucx_info -d > "${RESULTS_DIR}/ucx_devices.txt" 2>&1 || true

echo "=== ucx_info build config ===" >&2
# -b reports the installed config.h, which is where mlx5/gdrcopy support shows
# up. There is no `ucx_info -t`; the old call errored into the evidence file.
ucx_info -b > "${RESULTS_DIR}/ucx_build.txt" 2>&1 || true

# ── Open MPI MCA parameter dump ────────────────────────────────
echo "=== ompi_info params ===" >&2
ompi_info --param all all > "${RESULTS_DIR}/ompi_params.txt" 2>&1 || true

# ── libfabric provider listing ─────────────────────────────────
echo "=== fi_info ===" >&2
# Plain fi_info lists every discovered provider. `fi_info -d` takes a required
# domain argument, so the old call exited non-zero and, with `set -e`, aborted
# the tier before any probe below it ran.
fi_info > "${RESULTS_DIR}/libfabric_providers.txt" 2>&1 || true
fi_info -l > "${RESULTS_DIR}/libfabric_provider_list.txt" 2>&1 || true

# ── External UCX perftest — validates CUDA transport selection ─
if [ -x "${VALIDATION_DIR}/${EXTERNAL_UCX_PERFTEST}" ]; then
    echo "=== ucx_perftest CUDA tag_lat ===" >&2
    srun -n 2 --ntasks-per-node=1 \
        "${VALIDATION_DIR}/${EXTERNAL_UCX_PERFTEST}" \
        -c 0 -t tag_lat -n 10000 -b cuda \
        > "${RESULTS_DIR}/ucx_perftest.log" 2>&1 || true
else
    echo "WARNING: ucx_perftest not found — skipping CUDA transport validation" >&2
fi

# ── External perftest — raw verbs bandwidth ────────────────────
if [ -x "${VALIDATION_DIR}/${EXTERNAL_PERFTEST}" ]; then
    echo "=== ib_write_bw ===" >&2
    srun -n 2 --ntasks-per-node=1 \
        "${VALIDATION_DIR}/${EXTERNAL_PERFTEST}" \
        -d mlx5_0 --report_gbits \
        > "${RESULTS_DIR}/ib_write_bw.log" 2>&1 || true
else
    echo "WARNING: ib_write_bw not found — skipping raw verbs probe" >&2
fi

# ── NCCL transport selection probe ─────────────────────────────
echo "=== NCCL all_reduce (transport probe) ===" >&2
NCCL_DEBUG="${NCCL_DEBUG}" srun -n 2 --ntasks-per-node=1 \
    "$(find "$(spack location -i nccl-tests 2>/dev/null || echo /usr)" \
        -name all_reduce_perf -print -quit)" \
    -b 8 -e 128M -f 2 -g 1 \
    > "${RESULTS_DIR}/nccl_transport.txt" 2>&1 || true

# ── GPU topology evidence ──────────────────────────────────────
echo "=== nvidia-smi topo ===" >&2
nvidia-smi topo -m > "${RESULTS_DIR}/gpu_topology.txt" 2>&1 || true

# ── Stack capability assertions ────────────────────────────────
# Every probe above ends in `|| true`, so this tier used to collect evidence and
# always exit 0. These assertions check that the *software stack* can reach the
# fabric efficiently, which is separate from nccl-transport-check asserting
# which fabric this particular site selected.
echo "=== transport capability assertions ===" >&2
python3 - "${RESULTS_DIR}" > "${RESULTS_DIR}/transport_capability.json" << 'PYEOF'
import json
import re
import sys
from pathlib import Path

results = Path(sys.argv[1])


def read(name: str) -> str:
    try:
        return (results / name).read_text(errors="replace")
    except OSError:
        return ""


devices = read("ucx_devices.txt") + read("ucx_build.txt")
providers = read("libfabric_providers.txt") + read("libfabric_provider_list.txt")
nccl = read("nccl_transport.txt")
topology = read("gpu_topology.txt")

ucx_transports = set(re.findall(r"Transport:\s*(\S+)", devices))
fi_providers = set(re.findall(r"provider:\s*(\S+)", providers))
link_layers = {layer.upper() for layer in re.findall(r"\[\d+\][\w.:]+/(RoCE|IB)\b", nccl)}

checks: list[dict[str, object]] = []


def check(name: str, ok: bool, detail: str, *, fatal: bool = True) -> None:
    checks.append({"check": name, "ok": ok, "fatal": fatal, "detail": detail})


# rc_mlx5/dc_mlx5/ud_mlx5 exist only when UCX was built +mlx5_dv. Their absence
# on a ConnectX fabric means UCX fell back to generic rc_verbs/ud_verbs and that
# +dc bought nothing, because Dynamic Connection lives only in dc_mlx5.
accelerated = {t for t in ucx_transports if t.endswith("_mlx5")}
check(
    "ucx_mlx5_accelerated_transports",
    bool(accelerated),
    f"mlx5 transports: {sorted(accelerated) or 'none -- UCX lacks +mlx5_dv or no mlx5 device is present'}",
)
# cuda_ipc is the intra-node GPU path and rides NVLink/NVSwitch where present.
check(
    "ucx_cuda_ipc_nvlink_path",
    "cuda_ipc" in ucx_transports,
    "cuda_ipc present" if "cuda_ipc" in ucx_transports else "cuda_ipc missing -- UCX is not CUDA-aware",
)
# gdr_copy is the GPUDirect RDMA low-latency path.
check(
    "ucx_gdrcopy_path",
    "gdr_copy" in ucx_transports,
    "gdr_copy present" if "gdr_copy" in ucx_transports else "gdr_copy missing -- no GPUDirect RDMA",
)
check(
    "libfabric_verbs_provider",
    any(p.startswith("verbs") for p in fi_providers),
    f"providers: {sorted(fi_providers) or 'none'}",
)
# shm is libfabric's intra-node provider; without it same-node ranks fall back
# to the verbs loopback.
check(
    "libfabric_shm_provider",
    any(p.startswith("shm") for p in fi_providers),
    "shm present" if any(p.startswith("shm") for p in fi_providers) else "shm missing -- no node-local provider",
)
check(
    "nccl_rdma_link_layer",
    bool(link_layers),
    f"NCCL link layers: {sorted(link_layers) or 'none observed -- NCCL may have used TCP'}",
)

# NVLink is only expected where the node actually has more than one GPU.
topology_links = re.findall(r"\bNV\d+\b", topology)
gpu_count = len(re.findall(r"^GPU\d+", topology, re.MULTILINE))
check(
    "nvlink_present",
    bool(topology_links) or gpu_count < 2,
    f"{len(topology_links)} NVLink edges across {gpu_count} GPUs",
    fatal=gpu_count >= 2,
)

fabric = "RoCE" if "ROCE" in link_layers else "IB" if "IB" in link_layers else "unknown"
failures = [item for item in checks if not item["ok"] and item["fatal"]]
warnings = [item for item in checks if not item["ok"] and not item["fatal"]]
print(
    json.dumps(
        {
            "observed_fabric": fabric,
            "ucx_transports": sorted(ucx_transports),
            "libfabric_providers": sorted(fi_providers),
            "checks": checks,
            "verdict": "FAIL" if failures else "WARN" if warnings else "PASS",
        },
        indent=2,
    )
)
PYEOF

cat "${RESULTS_DIR}/transport_capability.json"
CAPABILITY_VERDICT="$(python3 -c "
import json
with open('${RESULTS_DIR}/transport_capability.json') as handle:
    document = json.load(handle)
for item in document['checks']:
    if not item['ok']:
        print('{}: {}'.format('FAIL' if item['fatal'] else 'WARN', item['detail']), file=__import__('sys').stderr)
print(document['verdict'])
")"

echo "Transport probe results written to ${RESULTS_DIR}" >&2

if [ "${CAPABILITY_VERDICT}" = "FAIL" ]; then
    echo "FAIL: transport stack is not built for efficient RDMA (see ${RESULTS_DIR}/transport_capability.json)" >&2
    exit 1
fi
