#!/bin/bash
# DESCRIPTION: Multi-node MPI collective sweep (IMB-MPI1, OSU collectives, NCCL all_reduce)
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --time=01:00:00
#SBATCH --gres=gpu:1
#SBATCH -J vlad-mpi-collective
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="${RESULTS_ROOT:-$VALIDATION_DIR/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
source "${VALIDATION_DIR}/lib/verdict.sh"
source "${VALIDATION_DIR}/lib/result-manifest.sh"
validation_result_init mpi-collective "${RESULTS_ROOT}" "${node}"
RESULTS_DIR="${VALIDATION_NODE_DIR}"

if ! command -v nvidia-smi >/dev/null 2>&1; then
    validation_resource_unavailable "no NVIDIA GPU available" mandatory
fi

# ── Runtime knobs ──────────────────────────────────────────────
: "${MPI_RANKS:=4}"
: "${NGPUS_PER_RANK:=1}"

# ── Modules ────────────────────────────────────────────────────
if [[ "${CHAPAR_KEEP_MODULES:-0}" != 1 ]]; then
    module purge
fi
module load \
    "${CHAPAR_MODULE_OPENMPI:-openmpi/5}" \
    "${CHAPAR_MODULE_INTEL_MPI_BENCHMARKS:-intel-mpi-benchmarks}" \
    "${CHAPAR_MODULE_OSU_MICRO_BENCHMARKS:-osu-micro-benchmarks}" \
    "${CHAPAR_MODULE_NCCL_TESTS:-nccl-tests}" \
    "${CHAPAR_MODULE_NCCL:-nccl}" \
    "${CHAPAR_MODULE_CUDA:-cuda/13}"

# ── IMB-MPI1 collective benchmarks ─────────────────────────────
mpirun -np "${MPI_RANKS:-4}" IMB-MPI1 -npmin 4 Allreduce > "${RESULTS_DIR}/imb_allreduce.log" 2>&1
mpirun -np "${MPI_RANKS:-4}" IMB-MPI1 -npmin 4 Alltoall  > "${RESULTS_DIR}/imb_alltoall.log" 2>&1
mpirun -np "${MPI_RANKS:-4}" IMB-MPI1 -npmin 4 Bcast     > "${RESULTS_DIR}/imb_bcast.log" 2>&1

# ── OSU collective benchmarks ──────────────────────────────────
mpirun -np "${MPI_RANKS:-4}" osu_allreduce > "${RESULTS_DIR}/osu_allreduce.log" 2>&1
mpirun -np "${MPI_RANKS:-4}" osu_alltoall  > "${RESULTS_DIR}/osu_alltoall.log" 2>&1

# ── NCCL all-reduce performance (optional — GPUs may not be available) ──
mpirun -np "${MPI_RANKS:-4}" \
    "$(find "$(spack location -i nccl-tests 2>/dev/null || echo /usr)" \
        -name all_reduce_perf -print -quit)" \
    -b 8 -e 128M -f 2 -g "${NGPUS_PER_RANK:-1}" \
    > "${RESULTS_DIR}/nccl_allreduce.log" || true

echo "MPI-collective results written to ${RESULTS_DIR}" >&2
