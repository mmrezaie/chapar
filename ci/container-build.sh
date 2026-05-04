#!/usr/bin/env bash
set -euo pipefail

: "${REPO_URL:?REPO_URL is required}"
: "${GIT_REF:?GIT_REF is required}"
: "${REPO_DIR:=/root/workspace/chapar}"
: "${OS_NAME:=rocky9}"
: "${HPCSIM_ROOT:=/resources/share/hpcsim}"
: "${RUN_ID:=manual}"
: "${RELEASE_ID:=${RUN_ID}}"
: "${PUBLISH_CURRENT:=false}"
: "${PUBLISH_BUILDCACHE:=true}"
: "${PUSH_BUILDCACHE_SCRIPT:=./ci/push-buildcache.sh}"
: "${PREPARE_HPCSIM_ROOT_SCRIPT:=./ci/prepare-hpcsim-root.sh}"
: "${SPACK_INSTALL_ARGS:=-p 1}"
: "${CHAPAR_UPDATE_SPACK:=false}"

case "${OS_NAME}" in
    rocky8|rocky9|macos) ;;
    *) echo "ERROR: OS_NAME must be rocky8, rocky9, or macos, got ${OS_NAME}" >&2; exit 1 ;;
esac

case "${PUBLISH_CURRENT}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_CURRENT must be true or false" >&2; exit 1 ;;
esac

case "${PUBLISH_BUILDCACHE}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_BUILDCACHE must be true or false" >&2; exit 1 ;;
esac

OS_ROOT="${HPCSIM_ROOT}/${OS_NAME}"
RUN_ROOT="${OS_ROOT}/runs/${RUN_ID}"
LOG_DIR="${RUN_ROOT}/logs"
ENV_DIR="${RUN_ROOT}/concrete-envs"
bash "${PREPARE_HPCSIM_ROOT_SCRIPT}"
mkdir -p "${LOG_DIR}" "${ENV_DIR}"
exec > >(tee -a "${LOG_DIR}/build.log") 2>&1

echo "==> hpcsim CI build"
echo "    os:                ${OS_NAME}"
echo "    release:           ${RELEASE_ID}"
echo "    publish current:   ${PUBLISH_CURRENT}"
echo "    publish buildcache: ${PUBLISH_BUILDCACHE}"
echo "    ref:               ${GIT_REF}"
echo "    repo dir:          ${REPO_DIR}"
echo "    hpcsim root:       ${HPCSIM_ROOT}"
echo "    output:            ${RUN_ROOT}"

mkdir -p "$(dirname "${REPO_DIR}")"
if [ -d "${REPO_DIR}/.git" ]; then
    cd "${REPO_DIR}"
    if git remote get-url origin >/dev/null 2>&1; then
        git remote set-url origin "${REPO_URL}"
    else
        git remote add origin "${REPO_URL}"
    fi
    git fetch --all --prune
else
    git clone "${REPO_URL}" "${REPO_DIR}"
    cd "${REPO_DIR}"
fi

if git show-ref --verify --quiet "refs/remotes/origin/${GIT_REF}"; then
    git checkout -B "${GIT_REF}" "origin/${GIT_REF}"
    git pull --ff-only origin "${GIT_REF}"
else
    git checkout "${GIT_REF}"
fi

git rev-parse HEAD | tee "${RUN_ROOT}/commit.txt"
printf '%s\n' "${RELEASE_ID}" > "${RUN_ROOT}/release-id.txt"

SPACK_ROOT="${CHAPAR_SPACK_ROOT:-${HOME}/.local/opt/spack}"
if [ ! -r "${SPACK_ROOT}/share/spack/setup-env.sh" ]; then
    bash ./etc/install-spack.sh
elif [ "${CHAPAR_UPDATE_SPACK}" = "true" ]; then
    bash ./etc/install-spack.sh --update
fi

source ./etc/init.sh
spack --version | tee "${RUN_ROOT}/spack-version.txt"

export HPCSIM_ROOT OS_NAME SPACK_INSTALL_ARGS PUBLISH_BUILDCACHE
bash ./envs/hpcsim/release.sh build "${RELEASE_ID}"

if [ "${PUBLISH_BUILDCACHE}" = "true" ]; then
    bash "${PUSH_BUILDCACHE_SCRIPT}" \
        --env-path ./envs/hpcsim \
        --os "${OS_NAME}" \
        --hpcsim-root "${HPCSIM_ROOT}"
fi

if [ "${PUBLISH_CURRENT}" = "true" ]; then
    bash ./envs/hpcsim/release.sh promote "${RELEASE_ID}"
fi

cp envs/hpcsim/spack.yaml "${ENV_DIR}/hpcsim.spack.yaml"
if [ -f envs/hpcsim/spack.lock ]; then
    cp envs/hpcsim/spack.lock "${ENV_DIR}/hpcsim.spack.lock"
fi

echo "==> hpcsim CI build completed"
