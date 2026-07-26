#!/usr/bin/env bash
set -euo pipefail

chapar_env_root_was_set=""
chapar_home_root_was_set=""
[ -n "${CHAPAR_ENV_ROOT:-}" ] && chapar_env_root_was_set="true"
[ -n "${CHAPAR_HOME_ROOT:-}" ] && chapar_home_root_was_set="true"

: "${REPO_URL:?REPO_URL is required}"
: "${GIT_REF:?GIT_REF is required}"
: "${REPO_DIR:=/root/workspace/chapar}"
: "${OS_NAME:=rocky9}"
: "${ENV_NAME:=hpcsim}"
: "${ENV_PATH:=envs/${ENV_NAME}}"
: "${CHAPAR_ENV_ROOT:=}"
: "${CHAPAR_ENV_ACTION:=build}"
: "${CHAPAR_ENV_BUILD_MODE:=auto}"
: "${CHAPAR_RELEASE_SCRIPT:=}"
: "${HPCSIM_ROOT:=}"
: "${CHAPAR_BUILDCACHE_ROOT:=}"
: "${CHAPAR_CCACHE_ROOT:=}"
: "${RUN_ID:=manual}"
: "${RELEASE_ID:=${RUN_ID}}"
: "${PUBLISH_CURRENT:=false}"
: "${PUBLISH_MODULES:=false}"
: "${PUBLISH_BUILDCACHE:=true}"
: "${PUSH_BUILDCACHE_SCRIPT:=./ci/push-buildcache.sh}"
: "${PREPARE_HPCSIM_ROOT_SCRIPT:=./ci/prepare-hpcsim-root.sh}"
: "${SPACK_INSTALL_ARGS:=-p 1}"
: "${CHAPAR_UPDATE_SPACK:=false}"

if [ "${ENV_NAME}" = "hpcsim" ]; then
    site_config="${CHAPAR_SITE_CONFIG:-${REPO_DIR}/envs/hpcsim/hpcsim-site.env}"
else
    site_config="${CHAPAR_SITE_CONFIG:-${REPO_DIR}/${ENV_PATH}/${ENV_NAME}-site.env}"
fi
if [ -r "${site_config}" ]; then
    # shellcheck disable=SC1090
    . "${site_config}"
fi
[ -n "${CHAPAR_ENV_ROOT:-}" ] && chapar_env_root_was_set="true"
[ -n "${CHAPAR_HOME_ROOT:-}" ] && chapar_home_root_was_set="true"

: "${CHAPAR_INSTALL_MODE:=home}"
: "${CHAPAR_HOME_ROOT:=${HOME}/.spack/chapar}"
: "${HPCSIM_HOME_ROOT:=${CHAPAR_HOME_ROOT}/envs/hpcsim}"
: "${HPCSIM_PUBLIC_ROOT:=}"
: "${CHAPAR_SHARED_CACHE_ROOT:=${CHAPAR_HOME_ROOT}/cache}"
: "${CHAPAR_BUILDCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/buildcache}"
: "${CHAPAR_CCACHE_ROOT:=${CHAPAR_SHARED_CACHE_ROOT}/ccache}"

case "${ENV_NAME}" in
    ""|.|..|*/*|*[!A-Za-z0-9._-]*) echo "ERROR: ENV_NAME must match [A-Za-z0-9._-]+, got ${ENV_NAME}" >&2; exit 1 ;;
esac

case "${ENV_PATH}" in
    envs/*) ;;
    *) echo "ERROR: ENV_PATH must be under envs/: ${ENV_PATH}" >&2; exit 1 ;;
esac

case "${OS_NAME}" in
    ""|.|..|*/*|*[!A-Za-z0-9._-]*) echo "ERROR: OS_NAME must match [A-Za-z0-9._-]+, got ${OS_NAME}" >&2; exit 1 ;;
esac

case "${CHAPAR_ENV_ACTION}" in
    concretize|build) ;;
    *) echo "ERROR: CHAPAR_ENV_ACTION must be concretize or build, got ${CHAPAR_ENV_ACTION}" >&2; exit 1 ;;
esac

case "${CHAPAR_ENV_BUILD_MODE}" in
    auto|release|spack) ;;
    *) echo "ERROR: CHAPAR_ENV_BUILD_MODE must be auto, release, or spack, got ${CHAPAR_ENV_BUILD_MODE}" >&2; exit 1 ;;
esac

if [ "${ENV_NAME}" = "hpcsim" ] && [ -z "${HPCSIM_ROOT}" ]; then
    case "${CHAPAR_INSTALL_MODE}" in
        home) HPCSIM_ROOT="${HPCSIM_HOME_ROOT}" ;;
        public)
            [ -n "${HPCSIM_PUBLIC_ROOT}" ] || { echo "ERROR: HPCSIM_PUBLIC_ROOT is required when CHAPAR_INSTALL_MODE=public" >&2; exit 1; }
            HPCSIM_ROOT="${HPCSIM_PUBLIC_ROOT}"
            ;;
        *) echo "ERROR: CHAPAR_INSTALL_MODE must be home or public, got ${CHAPAR_INSTALL_MODE}" >&2; exit 1 ;;
    esac
fi

if [ -z "${CHAPAR_ENV_ROOT}" ]; then
    if [ "${ENV_NAME}" = "hpcsim" ]; then
        CHAPAR_ENV_ROOT="${HPCSIM_ROOT}"
    else
        CHAPAR_ENV_ROOT="${CHAPAR_HOME_ROOT}/envs/${ENV_NAME}"
    fi
fi

if [ "${ENV_NAME}" = "hpcsim" ]; then
    HPCSIM_ROOT="${CHAPAR_ENV_ROOT}"
elif [ "${chapar_env_root_was_set}" = "true" ] && [ "${chapar_home_root_was_set}" != "true" ]; then
    CHAPAR_HOME_ROOT="${CHAPAR_ENV_ROOT}/${OS_NAME}"
fi

case "${PUBLISH_CURRENT}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_CURRENT must be true or false" >&2; exit 1 ;;
esac

case "${PUBLISH_MODULES}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_MODULES must be true or false" >&2; exit 1 ;;
esac

case "${PUBLISH_BUILDCACHE}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_BUILDCACHE must be true or false" >&2; exit 1 ;;
esac

OS_ROOT="${CHAPAR_ENV_ROOT}/${OS_NAME}"
RUN_ROOT="${OS_ROOT}/runs/${RUN_ID}"
LOG_DIR="${RUN_ROOT}/logs"
ENV_DIR="${RUN_ROOT}/concrete-envs"
if [ "${ENV_NAME}" = "hpcsim" ] && [ -n "${PREPARE_HPCSIM_ROOT_SCRIPT}" ]; then
    HPCSIM_ROOT="${HPCSIM_ROOT}" \
    CHAPAR_BUILDCACHE_ROOT="${CHAPAR_BUILDCACHE_ROOT}" \
    CHAPAR_CCACHE_ROOT="${CHAPAR_CCACHE_ROOT}" \
    bash "${PREPARE_HPCSIM_ROOT_SCRIPT}"
else
    mkdir -p "${CHAPAR_ENV_ROOT}" "${OS_ROOT}" "${RUN_ROOT}"
fi
mkdir -p "${LOG_DIR}" "${ENV_DIR}"
exec > >(tee -a "${LOG_DIR}/build.log") 2>&1

echo "==> Chapar environment CI build"
echo "    env:               ${ENV_NAME}"
echo "    env path:          ${ENV_PATH}"
echo "    action:            ${CHAPAR_ENV_ACTION}"
echo "    mode:              ${CHAPAR_ENV_BUILD_MODE}"
echo "    os:                ${OS_NAME}"
echo "    release:           ${RELEASE_ID}"
echo "    publish current:   ${PUBLISH_CURRENT}"
echo "    publish modules:   ${PUBLISH_MODULES}"
echo "    publish buildcache: ${PUBLISH_BUILDCACHE}"
echo "    ref:               ${GIT_REF}"
echo "    repo dir:          ${REPO_DIR}"
echo "    env root:          ${CHAPAR_ENV_ROOT}"
echo "    chapar home root:  ${CHAPAR_HOME_ROOT}"
echo "    buildcache root:   ${CHAPAR_BUILDCACHE_ROOT}"
echo "    ccache root:       ${CHAPAR_CCACHE_ROOT}"
echo "    spack user cache:  ${SPACK_USER_CACHE_PATH:-}"
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
git -C "${SPACK_ROOT}" rev-parse HEAD | tee "${RUN_ROOT}/spack-commit.txt"

if [ ! -r "${ENV_PATH}/spack.yaml" ]; then
    echo "ERROR: missing Spack environment: ${ENV_PATH}/spack.yaml" >&2
    exit 1
fi

build_mode="${CHAPAR_ENV_BUILD_MODE}"
if [ "${build_mode}" = "auto" ]; then
    if [ "${CHAPAR_ENV_ACTION}" = "build" ] && [ -x "${ENV_PATH}/release.sh" ]; then
        build_mode="release"
    else
        build_mode="spack"
    fi
fi

case "${build_mode}" in
    release)
        [ "${CHAPAR_ENV_ACTION}" = "build" ] || { echo "ERROR: release mode only supports CHAPAR_ENV_ACTION=build" >&2; exit 1; }
        release_script="${CHAPAR_RELEASE_SCRIPT:-./${ENV_PATH}/release.sh}"
        [ -x "${release_script}" ] || { echo "ERROR: missing executable release helper: ${release_script}" >&2; exit 1; }
        export HPCSIM_ROOT CHAPAR_BUILDCACHE_ROOT CHAPAR_CCACHE_ROOT CHAPAR_INSTALL_TREE_ROOT OS_NAME SPACK_INSTALL_ARGS PUBLISH_BUILDCACHE CHAPAR_MODULE_ROOT PUBLISH_MODULES
        promote_flag=""
        if [ "${PUBLISH_CURRENT}" = "true" ]; then
            promote_flag="--promote"
        fi
        bash "${release_script}" build "${RELEASE_ID}" ${promote_flag}
        if [ "${PUBLISH_CURRENT}" != "true" ] && [ "${PUBLISH_MODULES}" = "true" ]; then
            bash "${release_script}" publish-modules "${RELEASE_ID}" || true
        fi
        ;;
    spack)
        spack -e "${ENV_PATH}" concretize -f
        if [ "${CHAPAR_ENV_ACTION}" = "build" ]; then
            spack -e "${ENV_PATH}" install ${SPACK_INSTALL_ARGS}
            spack -e "${ENV_PATH}" module tcl refresh -y
        fi
        ;;
esac

cp "${ENV_PATH}/spack.yaml" "${ENV_DIR}/${ENV_NAME}.spack.yaml"
mkdir -p "${ENV_DIR}/${ENV_NAME}"
cp "${ENV_PATH}/spack.yaml" "${ENV_DIR}/${ENV_NAME}/spack.yaml"
if [ -f "${ENV_PATH}/spack.lock" ]; then
    cp "${ENV_PATH}/spack.lock" "${ENV_DIR}/${ENV_NAME}.spack.lock"
fi

echo "==> Chapar environment CI build completed"
