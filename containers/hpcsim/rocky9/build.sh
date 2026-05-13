#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="${CHAPAR_CONTAINER_OUT_DIR:-${CONTAINERS_DIR}/out}"
SIF_PATH="${CHAPAR_HPCSIM_SIF:-${OUT_DIR}/hpcsim-rocky9.sif}"
BASE_ARCHIVE="${CHAPAR_HPCSIM_BASE_ARCHIVE:-${OUT_DIR}/hpcsim-rocky9-base.tar}"
BASE_IMAGE_REPOSITORY="${CHAPAR_HPCSIM_BASE_IMAGE_REPOSITORY:-chapar/hpcsim-rocky9-base}"
BASE_IMAGE_TAG="${CHAPAR_HPCSIM_BASE_IMAGE_TAG:-latest}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'ERROR: required command not found: %s\n' "$1" >&2
        exit 1
    }
}

require_cmd packer
require_cmd apptainer
require_cmd docker

docker info >/dev/null 2>&1 || {
    printf 'ERROR: docker daemon is not available to the current user\n' >&2
    exit 1
}

mkdir -p "${OUT_DIR}"

packer init "${SCRIPT_DIR}/packer"
packer -chdir="${SCRIPT_DIR}/packer" build \
    -var "archive_path=${BASE_ARCHIVE}" \
    -var "image_repository=${BASE_IMAGE_REPOSITORY}" \
    -var "image_tag=${BASE_IMAGE_TAG}" \
    .

[ -r "${BASE_ARCHIVE}" ] || {
    printf 'ERROR: missing Packer Docker archive: %s\n' "${BASE_ARCHIVE}" >&2
    exit 1
}

apptainer_args=()
if [ -n "${CHAPAR_APPTAINER_BUILD_ARGS:-}" ]; then
    read -r -a apptainer_args <<< "${CHAPAR_APPTAINER_BUILD_ARGS}"
fi

apptainer build \
    "${apptainer_args[@]}" \
    --build-arg "base_archive=${BASE_ARCHIVE}" \
    "${SIF_PATH}" \
    "${SCRIPT_DIR}/apptainer/hpcsim-rocky9.def"

printf 'Built %s\n' "${SIF_PATH}"
