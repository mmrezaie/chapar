#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --cpus-per-task=128
#SBATCH --hint=nomultithread
#SBATCH -J hpcsim-release-rocky9
#SBATCH -o slogs/%x_%j.out
#SBATCH -e slogs/%x_%j.err

set -euo pipefail

: "${CHAPAR_ROOT:=$HOME/chapar}"
: "${OS_NAME:=rocky9}"

case "${OS_NAME}" in
    rocky9) ;;
    *) echo "ERROR: this wrapper is only for OS_NAME=rocky9; use ci/sbatch-hpcsim-update-release.sh for ${OS_NAME}" >&2; exit 2 ;;
esac

export CHAPAR_ROOT OS_NAME
exec bash "${CHAPAR_ROOT}/ci/sbatch-hpcsim-update-release.sh"
