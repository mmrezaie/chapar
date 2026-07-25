#!/bin/bash
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --time=00:30:00
#SBATCH -J vlad-ib-pairwise
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

source validation/harness/resolve_test_dir.sh
: "${VLAD_TEST_DIR:=$(resolve_test_dir "${SLURM_SUBMIT_DIR:-$PWD}" "validation/vlad" "vlad")}"
: "${SBATCH_PARTITION:=}"
: "${MPI_RDMA_BYTES:=8388608}"
: "${VLAD_OPENMPI_MODULE:=openmpi/5}"
: "${EXTERNAL_PERFTEST:=external/perftest/ib_write_bw}"
: "${MPI_LAUNCHER:=mpirun}"
: "${MPI_LAUNCHER_ARGS:=-np 2 --map-by ppr:1:node --bind-to none}"

source validation/harness/load_env.sh
load_env_from_config validation/config/vlad.yaml --needs openmpi cuda osu-micro-benchmarks qperf

RESULTS_DIR="${VLAD_TEST_DIR}/results/ib-pairwise/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

srun -n 2 --ntasks-per-node=1 osu_latency > "${RESULTS_DIR}/osu_latency.log"
srun -n 2 --ntasks-per-node=1 osu_bw > "${RESULTS_DIR}/osu_bw.log"
srun -n 2 --ntasks-per-node=1 osu_bibw > "${RESULTS_DIR}/osu_bibw.log"

nodes=($(scontrol show hostnames "${SLURM_NODELIST}"))
srun -n 2 --ntasks-per-node=1 bash -c "
    if [ \$SLURM_NODEID -eq 0 ]; then
        peer='${nodes[1]}'
    else
        peer='${nodes[0]}'
    fi
    qperf --verbose \"\$peer\" rc_bw rc_lat
" > "${RESULTS_DIR}/qperf.log"

if [ -x "${VLAD_TEST_DIR}/${EXTERNAL_PERFTEST}" ]; then
    srun -n 2 --ntasks-per-node=1 \
        "${VLAD_TEST_DIR}/${EXTERNAL_PERFTEST}" -a -d mlx5_0 --report_gbits \
        > "${RESULTS_DIR}/ib_write_bw.log"
fi
