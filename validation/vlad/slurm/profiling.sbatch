#!/bin/bash
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --time=00:30:00
#SBATCH -J vlad-profiling
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

source validation/harness/resolve_test_dir.sh

# ── Runtime knobs ──────────────────────────────────────────────
: "${PROFILER:=caliper}"
: "${VLAD_TEST_DIR:=$(resolve_test_dir "${SLURM_SUBMIT_DIR:-$PWD}" "validation/vlad" "vlad")}"

RESULTS_DIR="${VLAD_TEST_DIR}/results/profiling/$(date -u +%Y%m%dT%H%M%S)/${SLURM_NODELIST}"
mkdir -p "${RESULTS_DIR}"

# ── Profiler enum validation ───────────────────────────────────
case "${PROFILER}" in
    caliper|darshan|mpip|ipm|extrae|hpctoolkit|tau|scorep|scalasca|likwid)
        ;;
    *)
        echo "ERROR: invalid PROFILER=${PROFILER}. Must be one of: caliper|darshan|mpip|ipm|extrae|hpctoolkit|tau|scorep|scalasca|likwid" >&2
        exit 1
        ;;
esac

# ── Environment ────────────────────────────────────────────────
source validation/harness/load_env.sh
load_env_from_config validation/config/vlad.yaml --needs openmpi osu-micro-benchmarks
module load "${PROFILER}"

# ── Profile osu_latency ────────────────────────────────────────
echo "=== Profiling osu_latency with ${PROFILER} ===" >&2

case "${PROFILER}" in
    caliper)
        LD_PRELOAD="$(spack location -i caliper)/lib/libcaliper.so" \
            srun -n 2 osu_latency > "${RESULTS_DIR}/caliper.log"
        ;;
    darshan)
        LD_PRELOAD="$(spack location -i darshan-runtime)/lib/libdarshan.so" \
            srun -n 2 osu_latency > "${RESULTS_DIR}/darshan.log"
        ;;
    mpip)
        LD_PRELOAD="$(spack location -i mpip)/lib/libmpiP.so" \
            srun -n 2 osu_latency > "${RESULTS_DIR}/mpip.log"
        ;;
    ipm)
        LD_PRELOAD="$(spack location -i ipm)/lib/libipm.so" \
            srun -n 2 osu_latency > "${RESULTS_DIR}/ipm.log"
        ;;
    extrae)
        LD_PRELOAD="$(spack location -i extrae)/lib/libmpitrace.so" \
            srun -n 2 osu_latency > "${RESULTS_DIR}/extrae.log"
        ;;
    hpctoolkit)
        srun -n 2 hpcrun -o "${RESULTS_DIR}/hpcrun-db" \
            osu_latency > "${RESULTS_DIR}/hpctoolkit.log" 2>&1
        ;;
    tau)
        srun -n 2 tau_exec -T mpi,cupti \
            osu_latency > "${RESULTS_DIR}/tau.log" 2>&1
        ;;
    scorep)
        srun -n 2 scorep-run --sampling --mca=mpi -- \
            osu_latency > "${RESULTS_DIR}/scorep.log" 2>&1
        ;;
    scalasca)
        srun -n 2 scorep-run --sampling --mca=mpi -- osu_latency \
            && scalasca -analyze osu_latency \
            > "${RESULTS_DIR}/scalasca.log" 2>&1
        ;;
    likwid)
        srun -n 2 likwid-perfctr -C 0 -g MEM_DP -O \
            osu_latency > "${RESULTS_DIR}/likwid.log"
        ;;
esac

echo "Profiling results written to ${RESULTS_DIR}" >&2
