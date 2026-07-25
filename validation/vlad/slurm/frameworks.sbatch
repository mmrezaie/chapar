#!/bin/bash
# This wrapper confirms that PyTorch's distributed backend runs through the
# Spack-built Open MPI + NCCL stack — validating the actual transport path
# PyTorch jobs will use.
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --time=00:30:00
#SBATCH --gres=gpu:1
#SBATCH -J vlad-frameworks
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

source validation/harness/resolve_test_dir.sh
: "${VLAD_TEST_DIR:=$(resolve_test_dir "${SLURM_SUBMIT_DIR:-$PWD}" "validation/vlad" "vlad")}"

# ── Runtime knobs ──────────────────────────────────────────────
: "${VLAD_OPENMPI_MODULE:=openmpi/5}"

RESULTS_DIR="${VLAD_TEST_DIR}/results/frameworks/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Environment ────────────────────────────────────────────────
source validation/harness/load_env.sh
load_env_from_config validation/config/vlad.yaml --needs cuda openmpi py-torch py-mpi4py

# ── PyTorch distributed all_reduce validation ──────────────────
echo "=== torch.distributed all_reduce (MPI backend) ===" >&2
srun -n 2 --ntasks-per-node=1 python3 - << 'PYEOF' \
    > "${RESULTS_DIR}/framework_comm_check.log" 2>&1

import os
import sys
import time
import json

import torch
import torch.distributed as dist

def framework_comm_check():
    rank = int(os.environ.get("OMPI_COMM_WORLD_RANK",
              os.environ.get("PMI_RANK",
              os.environ.get("SLURM_PROCID",
              os.environ.get("RANK", "-1")))))
    world_size = int(os.environ.get("OMPI_COMM_WORLD_SIZE",
                    os.environ.get("PMI_SIZE",
                    os.environ.get("SLURM_NTASKS",
                    os.environ.get("WORLD_SIZE", "2")))))
    local_rank = int(os.environ.get("OMPI_COMM_WORLD_LOCAL_RANK",
                    os.environ.get("SLURM_LOCALID",
                    os.environ.get("LOCAL_RANK", "0"))))
    nodelist = os.environ.get("SLURM_NODELIST", "unknown")

    if rank < 0:
        print(f"[ERROR] could not determine MPI rank", flush=True)
        sys.exit(1)

    # Pin this rank to a GPU
    ngpus = torch.cuda.device_count()
    gpu_index = local_rank % max(ngpus, 1) if ngpus > 0 else -1
    if gpu_index >= 0:
        torch.cuda.set_device(gpu_index)

    device = torch.device(f"cuda:{gpu_index}" if gpu_index >= 0 else "cpu")

    if rank == 0:
        print(f"world_size={world_size} ngpus_per_node={ngpus}", flush=True)
        print(f"cuda_available={torch.cuda.is_available()} "
              f"cuda_version={torch.version.cuda}", flush=True)

    # Init MPI-backed process group
    dist.init_process_group(backend="mpi", world_size=world_size, rank=rank)
    backend = dist.get_backend()
    if rank == 0:
        print(f"dist_backend={backend}", flush=True)

    # MPI library identification
    try:
        import mpi4py
        mpi4py_ver = mpi4py.__version__
    except Exception:
        mpi4py_ver = "unavailable"
    if rank == 0:
        print(f"mpi4py_version={mpi4py_ver}", flush=True)
        ompi_info = os.environ.get("OMPI_COMM_WORLD_RANK", "")
        print(f"mpi_library=OpenMPI" if ompi_info != "" else "mpi_library=unknown",
              flush=True)

    # All-reduce a CUDA tensor
    tensor_size = 1024 * 1024  # 1M elements = 4 MB float32
    t = torch.ones(tensor_size, device=device, dtype=torch.float32) * (rank + 1)

    torch.cuda.synchronize()
    t0 = time.perf_counter()
    dist.all_reduce(t, op=dist.ReduceOp.SUM)
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - t0

    # Verify (sum of ranks 0..world_size-1) * tensor_size
    expected = sum(range(world_size)) + world_size
    if rank == 0:
        ok = torch.allclose(t, torch.full((tensor_size,), float(expected),
                                          device=device))
        print(f"result {json.dumps({
            'rank': rank,
            'gpu_index': gpu_index,
            'node': nodelist,
            'wall_time_s': round(elapsed, 6),
            'tensor_size_bytes': tensor_size * 4,
            'all_reduce_ok': ok,
        })}", flush=True)

    dist.destroy_process_group()

if __name__ == "__main__":
    framework_comm_check()

PYEOF

echo "Framework-comm results written to ${RESULTS_DIR}" >&2
