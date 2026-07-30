#!/usr/bin/env bash

configure_intelmpi_srun_pmi() {
    local candidate directory root line

    [ "${MPI_LAUNCHER}" = srun ] || return 0
    [ -z "${I_MPI_PMI_LIBRARY:-}" ] || return 0

    for candidate in "${SLURM_PMI_LIBRARY:-}" "${PMI_LIBRARY:-}"; do
        if [ -n "${candidate}" ] && [ -r "${candidate}" ]; then
            export I_MPI_PMI_LIBRARY="${candidate}"
            return 0
        fi
    done

    while IFS= read -r directory; do
        for candidate in "${directory}/libpmi2.so" "${directory}/libpmi.so"; do
            if [ -r "${candidate}" ]; then
                export I_MPI_PMI_LIBRARY="${candidate}"
                return 0
            fi
        done
    done < <(tr ':' '\n' <<<"${LD_LIBRARY_PATH:-}")

    for root in "${SLURM_DIR:-}" "${SLURM_ROOT:-}" "${SLURM_PREFIX:-}" "${PMI_ROOT:-}"; do
        [ -n "${root}" ] || continue
        for directory in "${root}/lib" "${root}/lib64" "${root}/lib/slurm"; do
            for candidate in "${directory}/libpmi2.so" "${directory}/libpmi.so"; do
                if [ -r "${candidate}" ]; then
                    export I_MPI_PMI_LIBRARY="${candidate}"
                    return 0
                fi
            done
        done
    done

    if command -v srun >/dev/null 2>&1; then
        root="$(cd "$(dirname "$(command -v srun)")/.." && pwd -P)"
        for directory in "${root}/lib" "${root}/lib64" "${root}/lib/slurm"; do
            for candidate in "${directory}/libpmi2.so" "${directory}/libpmi.so"; do
                if [ -r "${candidate}" ]; then
                    export I_MPI_PMI_LIBRARY="${candidate}"
                    return 0
                fi
            done
        done
    fi

    if command -v ldconfig >/dev/null 2>&1; then
        while read -r line; do
            case "${line}" in
                *libpmi2.so*'=> '*) candidate="${line##* => }" ;;
                *libpmi.so*'=> '*) candidate="${line##* => }" ;;
                *) candidate="" ;;
            esac
            if [ -n "${candidate}" ] && [ -r "${candidate}" ]; then
                export I_MPI_PMI_LIBRARY="${candidate}"
                return 0
            fi
        done < <(ldconfig -p 2>/dev/null || true)
    fi

    echo "WARNING: MPI_LAUNCHER=srun but I_MPI_PMI_LIBRARY was not set and no PMI library was discovered from the loaded module environment or Slurm runtime." >&2
    echo "WARNING: If Intel MPI reports 'PMI server not found', use MPI_LAUNCHER=mpirun or set I_MPI_PMI_LIBRARY." >&2
}
