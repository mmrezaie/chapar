#!/bin/bash
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --time=00:30:00
#SBATCH -J vlad-profiling
#SBATCH -o %x_%j.out
#SBATCH -e %x_%j.err

set -euo pipefail

resolve_vlad_test_dir() {
    local submit_dir="${SLURM_SUBMIT_DIR:-$PWD}"
    local candidate

    for candidate in "${submit_dir}/validation/vlad" "${submit_dir}/vlad"; do
        [ -d "${candidate}" ] || continue
        printf '%s\n' "${candidate}"
        return 0
    done

    echo "could not locate validation/vlad; set VLAD_TEST_DIR" >&2
    return 1
}

# ── Runtime knobs ──────────────────────────────────────────────
: "${PROFILER:=caliper}"
: "${VLAD_TEST_DIR:=$(resolve_vlad_test_dir)}"

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
module purge
module load openmpi osu-micro-benchmarks
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
