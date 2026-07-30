#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/../lib/intelmpi-pmi.sh"

temporary="$(mktemp -d)"
cleanup() { rm -rf -- "${temporary}"; }
trap cleanup EXIT

library="${temporary}/libpmi2.so"
: > "${library}"
MPI_LAUNCHER=srun

unset I_MPI_PMI_LIBRARY
SLURM_PMI_LIBRARY="${library}"
configure_intelmpi_srun_pmi
[ "${I_MPI_PMI_LIBRARY}" = "${library}" ]

unset I_MPI_PMI_LIBRARY SLURM_PMI_LIBRARY
SLURM_ROOT="${temporary}"
mkdir -p "${SLURM_ROOT}/lib"
mv "${library}" "${SLURM_ROOT}/lib/libpmi.so"
configure_intelmpi_srun_pmi
[ "${I_MPI_PMI_LIBRARY}" = "${SLURM_ROOT}/lib/libpmi.so" ]

printf '%s\n' 'Intel MPI PMI discovery: explicit environment and Slurm runtime prefixes verified'
