#!/usr/bin/env bash
#SBATCH --job-name=chapar-hpcsim
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:10:00
#SBATCH --output=chapar-hpcsim-%j.out

set -euo pipefail

SUBMIT_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"

: "${CHAPAR_HPCSIM_IMAGE:=${SUBMIT_DIR}/containers/out/hpcsim-rocky9.sif}"
: "${CHAPAR_HPCSIM_ROOT:=/resources/share/hpcsim}"
: "${CHAPAR_HPCSIM_COMMAND:=module avail}"
: "${CHAPAR_RESOURCES_BIND:=/resources:/resources}"
: "${CHAPAR_APPTAINER_NV:=auto}"

if ! type module >/dev/null 2>&1; then
    if [ -r /etc/profile.d/modules.sh ]; then
        # shellcheck disable=SC1091
        . /etc/profile.d/modules.sh
    elif [ -r /usr/share/Modules/init/bash ]; then
        # shellcheck disable=SC1091
        . /usr/share/Modules/init/bash
    fi
fi

if ! command -v apptainer >/dev/null 2>&1; then
    if type module >/dev/null 2>&1; then
        module load apptainer 2>/dev/null || true
    fi
fi

command -v apptainer >/dev/null 2>&1 || {
    printf 'ERROR: apptainer command not found on the Slurm node\n' >&2
    exit 1
}

[ -r "${CHAPAR_HPCSIM_IMAGE}" ] || {
    printf 'ERROR: missing Apptainer image: %s\n' "${CHAPAR_HPCSIM_IMAGE}" >&2
    exit 1
}

gpu_args=()
case "${CHAPAR_APPTAINER_NV}" in
    true)
        gpu_args+=(--nv)
        ;;
    false)
        ;;
    auto)
        if command -v nvidia-smi >/dev/null 2>&1 || [ -e /dev/nvidiactl ]; then
            gpu_args+=(--nv)
        fi
        ;;
    *)
        printf 'ERROR: CHAPAR_APPTAINER_NV must be auto, true, or false\n' >&2
        exit 1
        ;;
esac

srun apptainer exec \
    "${gpu_args[@]}" \
    --bind "${CHAPAR_RESOURCES_BIND}" \
    --bind "${SUBMIT_DIR}:${SUBMIT_DIR}" \
    --env "CHAPAR_HPCSIM_ROOT=${CHAPAR_HPCSIM_ROOT}" \
    --env CHAPAR_HPCSIM_OS=rocky9 \
    --pwd "${SUBMIT_DIR}" \
    "${CHAPAR_HPCSIM_IMAGE}" \
    bash --login -c "${CHAPAR_HPCSIM_COMMAND}"
