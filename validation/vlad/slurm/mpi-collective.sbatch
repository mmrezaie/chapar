#!/bin/bash
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --time=01:00:00
#SBATCH --gres=gpu:1
#SBATCH -J vlad-mpi-collective
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

source validation/harness/resolve_test_dir.sh
: "${VLAD_TEST_DIR:=$(resolve_test_dir "${SLURM_SUBMIT_DIR:-$PWD}" "validation/vlad" "vlad")}"
: "${MPI_RANKS:=4}"
: "${NGPUS_PER_RANK:=1}"
: "${VLAD_OPENMPI_MODULE:=openmpi/5}"

RESULTS_DIR="${VLAD_TEST_DIR}/results/mpi-collective/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

source validation/harness/load_env.sh
load_env_from_config validation/config/vlad.yaml --needs openmpi intel-mpi-benchmarks osu-micro-benchmarks nccl-tests nccl cuda

# IMB-MPI1 collective benchmarks
mpirun -np "${MPI_RANKS:-4}" IMB-MPI1 -npmin 4 Allreduce > "${RESULTS_DIR}/imb_allreduce.log" 2>&1
mpirun -np "${MPI_RANKS:-4}" IMB-MPI1 -npmin 4 Alltoall  > "${RESULTS_DIR}/imb_alltoall.log" 2>&1
mpirun -np "${MPI_RANKS:-4}" IMB-MPI1 -npmin 4 Bcast     > "${RESULTS_DIR}/imb_bcast.log" 2>&1

# OSU collective benchmarks
mpirun -np "${MPI_RANKS:-4}" osu_allreduce > "${RESULTS_DIR}/osu_allreduce.log" 2>&1
mpirun -np "${MPI_RANKS:-4}" osu_alltoall  > "${RESULTS_DIR}/osu_alltoall.log" 2>&1

# NCCL all-reduce performance (optional — GPUs may not be available)
mpirun -np "${MPI_RANKS:-4}" \
    "$(find "$(spack location -i nccl-tests 2>/dev/null || echo /usr)" \
        -name all_reduce_perf -print -quit)" \
    -b 8 -e 128M -f 2 -g "${NGPUS_PER_RANK:-1}" \
    > "${RESULTS_DIR}/nccl_allreduce.log" || true
