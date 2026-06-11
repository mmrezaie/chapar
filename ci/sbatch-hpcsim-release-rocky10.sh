#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --hint=nomultithread
#SBATCH -J hpcsim-release-rocky10
#SBATCH -o slogs/%x_%j.out
#SBATCH -e slogs/%x_%j.err

set -euo pipefail

: "${CHAPAR_ROOT:=$HOME/chapar}"
: "${OS_NAME:=rocky10}"
: "${RELEASE_ID:=${OS_NAME}-$(date +%Y%m%d%H%M%S)}"
: "${PUBLISH_CURRENT:=false}"
: "${PUBLISH_MODULES:=true}"
: "${PUBLISH_BUILDCACHE:=true}"

case "${OS_NAME}" in
    rocky10) ;;
    *) echo "ERROR: this wrapper is only for OS_NAME=rocky10; use ci/sbatch-hpcsim-update-release.sh for ${OS_NAME}" >&2; exit 2 ;;
esac

export CHAPAR_ROOT OS_NAME RELEASE_ID PUBLISH_CURRENT PUBLISH_MODULES PUBLISH_BUILDCACHE
exec bash "${CHAPAR_ROOT}/ci/sbatch-hpcsim-update-release.sh"
