#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --hint=nomultithread
#SBATCH -J hpcsim-release
#SBATCH -o slogs/%x_%j.out
#SBATCH -e slogs/%x_%j.err

set -euo pipefail

: "${CHAPAR_ROOT:=$HOME/chapar}"
site_config="${CHAPAR_SITE_CONFIG:-${CHAPAR_ROOT}/envs/hpcsim/hpcsim-site.env}"
if [ -r "${site_config}" ]; then
    # shellcheck disable=SC1090
    . "${site_config}"
fi

detect_build_jobs() {
    local cpus="${SLURM_CPUS_ON_NODE:-}"

    if [ -z "${cpus}" ] && [ -n "${SLURM_JOB_CPUS_PER_NODE:-}" ]; then
        cpus="${SLURM_JOB_CPUS_PER_NODE%%,*}"
        cpus="${cpus%%(*}"
    fi
    if [ -z "${cpus}" ]; then
        cpus="${SLURM_CPUS_PER_TASK:-}"
    fi
    if [ -z "${cpus}" ] && command -v nproc >/dev/null 2>&1; then
        cpus="$(nproc)"
    fi
    case "${cpus}" in
        ''|*[!0-9]*|0) cpus=1 ;;
    esac

    printf '%s\n' "${cpus}"
}

build_jobs="$(detect_build_jobs)"

: "${OS_NAME:?set OS_NAME=rocky9 or OS_NAME=rocky10}"
: "${PUBLISH_CURRENT:=false}"
: "${PUBLISH_MODULES:=false}"
: "${PUBLISH_BUILDCACHE:=true}"
: "${SPACK_INSTALL_ARGS:=-j ${build_jobs}}"
: "${CHAPAR_CONCRETIZE_TIMEOUT:=}"

case "${OS_NAME}" in
    rocky9|rocky10) ;;
    *) echo "ERROR: OS_NAME must be rocky9 or rocky10, got ${OS_NAME}" >&2; exit 2 ;;
esac

case "${PUBLISH_CURRENT}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_CURRENT must be true or false, got ${PUBLISH_CURRENT}" >&2; exit 2 ;;
esac

case "${PUBLISH_MODULES}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_MODULES must be true or false, got ${PUBLISH_MODULES}" >&2; exit 2 ;;
esac

case "${PUBLISH_BUILDCACHE}" in
    true|false) ;;
    *) echo "ERROR: PUBLISH_BUILDCACHE must be true or false, got ${PUBLISH_BUILDCACHE}" >&2; exit 2 ;;
esac

mkdir -p "${CHAPAR_ROOT}/slogs" "$HOME/chapar-diagnostics"
job_id="${SLURM_JOB_ID:-manual}"
release_date="$(date +%Y%m%d%H%M%S)"
: "${RELEASE_ID:=${OS_NAME}-${release_date}}"

diag_dir="$HOME/chapar-diagnostics/${SLURM_JOB_NAME:-hpcsim-release}_${job_id}_${OS_NAME}"
mkdir -p "$diag_dir"
exec > >(tee -a "$diag_dir/run.log") 2>&1

if [ -d /scratch ] && [ -w /scratch ]; then
    fast_base="${CHAPAR_FAST_BASE:-/scratch/$USER/chapar-spack}"
else
    fast_base="${CHAPAR_FAST_BASE:-${TMPDIR:-/tmp}/$USER/chapar-spack}"
fi

fast_root="${fast_base}/${job_id}-${OS_NAME}"
export TMPDIR="${fast_root}/tmp"
export SPACK_USER_CACHE_PATH="${fast_root}/spack-user-cache"
export CCACHE_TEMPDIR="${CCACHE_TEMPDIR:-${fast_root}/ccache-tmp}"
export PIP_CONFIG_FILE=/dev/null
mkdir -p "$TMPDIR" "$SPACK_USER_CACHE_PATH" "$CCACHE_TEMPDIR"

cleanup() {
    status=$?
    echo
    echo "diagnostic dir: $diag_dir"
    echo "fast root: $fast_root"
    echo "chapar root: $CHAPAR_ROOT"
    echo "site config: $site_config"
    echo "os name: $OS_NAME"
    echo "release id: $RELEASE_ID"
    exit "$status"
}
trap cleanup EXIT

cd "$CHAPAR_ROOT"
source "${CHAPAR_ROOT}/etc/init.sh"

echo "started: $(date -Is)"
echo "batch host: $(hostname -f 2>/dev/null || hostname)"
echo "job id: $job_id"
echo "diagnostic dir: $diag_dir"
echo "fast root: $fast_root"
echo "chapar root: $CHAPAR_ROOT"
echo "site config: $site_config"
echo "git head: $(git rev-parse --short HEAD 2>/dev/null || printf unknown)"
echo "os name: $OS_NAME"
echo "release id: $RELEASE_ID"
echo "publish buildcache: $PUBLISH_BUILDCACHE"
echo "publish current: $PUBLISH_CURRENT"
echo "publish modules: $PUBLISH_MODULES"
echo "build jobs: $build_jobs"
echo "spack install args: $SPACK_INSTALL_ARGS"
echo "spack user cache: $SPACK_USER_CACHE_PATH"
echo "ccache dir: ${CCACHE_DIR:-unset}"
echo "ccache temp: ${CCACHE_TEMPDIR:-unset}"
echo

echo "==> Preparing hpcsim roots"
OS_NAME="$OS_NAME" bash ci/prepare-hpcsim-root.sh

echo
echo "==> Release status before build"
OS_NAME="$OS_NAME" bash envs/hpcsim/release.sh status

echo
echo "==> Building hpcsim release for ${OS_NAME}"
OS_NAME="$OS_NAME" \
PUBLISH_BUILDCACHE="$PUBLISH_BUILDCACHE" \
CHAPAR_CONCRETIZE_TIMEOUT="$CHAPAR_CONCRETIZE_TIMEOUT" \
SPACK_INSTALL_ARGS="$SPACK_INSTALL_ARGS" \
bash envs/hpcsim/release.sh build "$RELEASE_ID"

if [ "$PUBLISH_CURRENT" = true ]; then
    echo
    echo "==> Promoting ${OS_NAME} hpcsim release"
    OS_NAME="$OS_NAME" bash envs/hpcsim/release.sh promote "$RELEASE_ID"
elif [ "$PUBLISH_MODULES" = true ]; then
    echo
    echo "==> Publishing ${OS_NAME} hpcsim modules"
    OS_NAME="$OS_NAME" bash envs/hpcsim/release.sh publish-modules "$RELEASE_ID"
fi

echo
echo "==> Module use command for this release"
OS_NAME="$OS_NAME" bash envs/hpcsim/release.sh module-use "$RELEASE_ID"

echo
echo "completed: $(date -Is)"
