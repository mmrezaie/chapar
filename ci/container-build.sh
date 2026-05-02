#!/usr/bin/env bash
set -euo pipefail

: "${REPO_URL:?REPO_URL is required}"
: "${GIT_REF:?GIT_REF is required}"
: "${REPO_DIR:=/root/workspace/chapar}"
: "${FLAVOR:=canary}"
: "${SECTION:=all}"
: "${OS_NAME:=rocky9}"
: "${PUSH_BUILDCACHE:=true}"
: "${RESOURCES_ROOT:=/resources/chapar}"
: "${RUN_ID:=manual}"
: "${PUSH_BUILDCACHE_SCRIPT:=./ci/push-buildcache.sh}"
: "${SPACK_INSTALL_ARGS:=-p 1}"
: "${CHAPAR_UPDATE_SPACK:=false}"

case "${OS_NAME}" in
    macos|darwin) SECTIONS=(toolchain devtools python mpi libs benchmarks profiling) ;;
    *) SECTIONS=(toolchain devtools python mpi libs gpu benchmarks profiling) ;;
esac
read -r -a SPACK_INSTALL_ARGS_ARRAY <<< "${SPACK_INSTALL_ARGS}"

case "${FLAVOR}" in
    canary) BASE_ENV="skipper-canary" ;;
    prod) BASE_ENV="skipper" ;;
    *) echo "ERROR: FLAVOR must be canary or prod, got ${FLAVOR}" >&2; exit 1 ;;
esac

case "${SECTION}" in
    all|full|toolchain|devtools|python|mpi|libs|gpu|benchmarks|profiling) ;;
    *) echo "ERROR: unsupported SECTION ${SECTION}" >&2; exit 1 ;;
esac

RUN_ROOT="${RESOURCES_ROOT}/runs/${RUN_ID}/${OS_NAME}/${FLAVOR}/${SECTION}"
LOG_DIR="${RUN_ROOT}/logs"
ENV_DIR="${RUN_ROOT}/concrete-envs"
mkdir -p "${LOG_DIR}" "${ENV_DIR}"
exec > >(tee -a "${LOG_DIR}/build.log") 2>&1

echo "==> Chapar CI build"
echo "    os:       ${OS_NAME}"
echo "    flavor:   ${FLAVOR}"
echo "    section:  ${SECTION}"
echo "    ref:      ${GIT_REF}"
echo "    repo dir: ${REPO_DIR}"
echo "    output:   ${RUN_ROOT}"

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

SPACK_ROOT="${CHAPAR_SPACK_ROOT:-${HOME}/.local/opt/spack}"
if [ ! -r "${SPACK_ROOT}/share/spack/setup-env.sh" ]; then
    bash ./etc/install-spack.sh
elif [ "${CHAPAR_UPDATE_SPACK}" = "true" ]; then
    bash ./etc/install-spack.sh --update
fi

source ./etc/init.sh
spack --version | tee "${RUN_ROOT}/spack-version.txt"

build_env() {
    local env_name="$1"
    local env_path="./envs/${env_name}"

    spack -e "${env_path}" concretize -f
    spack -e "${env_path}" install "${SPACK_INSTALL_ARGS_ARRAY[@]}"
}

refresh_modules() {
    local env_name="$1"
    local delete_tree="${2:-false}"
    local env_path="./envs/${env_name}"
    local refresh_args=(-y)
    local root_specs=()

    while IFS= read -r root_spec; do
        root_specs+=("${root_spec}")
    done < <(spack -e "${env_path}" find -r -H)

    if [ "${#root_specs[@]}" -eq 0 ]; then
        echo "==> No environment roots to refresh Tcl modulefiles for: ${env_name}"
        return
    fi

    if [ "${delete_tree}" = "true" ]; then
        refresh_args+=(--delete-tree)
    fi

    echo "==> Refreshing Tcl modulefiles for environment roots: ${env_name}"
    spack -e "${env_path}" module tcl refresh "${refresh_args[@]}" "${root_specs[@]}"
}

ENV_NAMES=()
case "${SECTION}" in
    all)
        for env_section in "${SECTIONS[@]}"; do
            ENV_NAMES+=("${BASE_ENV}-${env_section}")
        done
        ENV_NAMES+=("${BASE_ENV}")
        ;;
    full)
        ENV_NAMES+=("${BASE_ENV}")
        ;;
    *)
        ENV_NAMES+=("${BASE_ENV}-${SECTION}")
        ;;
esac

for env_name in "${ENV_NAMES[@]}"; do
    echo "==> Building Spack environment: ${env_name}"
    build_env "${env_name}"
done

MODULE_ENV_NAMES=()
case "${SECTION}" in
    all) MODULE_ENV_NAMES+=("${BASE_ENV}") ;;
    *) MODULE_ENV_NAMES+=("${ENV_NAMES[@]}") ;;
esac

DELETE_MODULE_TREE=false
case "${SECTION}" in
    all|full) DELETE_MODULE_TREE=true ;;
esac

for env_name in "${MODULE_ENV_NAMES[@]}"; do
    refresh_modules "${env_name}" "${DELETE_MODULE_TREE}"
done

if [ "${PUSH_BUILDCACHE}" = "true" ]; then
    for env_name in "${ENV_NAMES[@]}"; do
        bash "${PUSH_BUILDCACHE_SCRIPT}" \
            --env-path "./envs/${env_name}" \
            --os "${OS_NAME}" \
            --flavor "${FLAVOR}" \
            --resources-root "${RESOURCES_ROOT}"
    done
fi

for env_name in "${ENV_NAMES[@]}"; do
    cp "envs/${env_name}/spack.yaml" "${ENV_DIR}/${env_name}.spack.yaml"
    if [ -f "envs/${env_name}/spack.lock" ]; then
        cp "envs/${env_name}/spack.lock" "${ENV_DIR}/${env_name}.spack.lock"
    fi
done

echo "==> Chapar CI build completed"
