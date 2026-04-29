#!/usr/bin/env bash
set -euo pipefail

SPACK_ROOT="${CHAPAR_SPACK_ROOT:-${HOME}/.local/opt/spack}"
SPACK_REPO_URL="${SPACK_REPO_URL:-https://github.com/spack/spack.git}"
SPACK_REF="${SPACK_REF:-}"

usage() {
    cat <<'EOF'
Usage:
  install-spack.sh [--update]

Environment:
  CHAPAR_SPACK_ROOT  Spack checkout path. Default: ~/.local/opt/spack
  SPACK_REPO_URL     Upstream repository URL. Default: https://github.com/spack/spack.git
  SPACK_REF          Optional branch, tag, or commit to check out after cloning

Examples:
  bash etc/install-spack.sh
  SPACK_REF=releases/latest bash etc/install-spack.sh
  bash etc/install-spack.sh --update
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

update_spack() {
    [ -d "${SPACK_ROOT}/.git" ] || die "not a git checkout: ${SPACK_ROOT}"
    git -C "${SPACK_ROOT}" pull --ff-only
}

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
    --update)
        update_spack
        exit 0
        ;;
    "")
        ;;
    *)
        die "unknown argument: ${1}"
        ;;
esac

if [ -e "${SPACK_ROOT}" ]; then
    if [ -r "${SPACK_ROOT}/share/spack/setup-env.sh" ]; then
        echo "Spack already exists at ${SPACK_ROOT}"
        echo "To update it: bash etc/install-spack.sh --update"
        exit 0
    fi
    die "destination exists but is not a Spack checkout: ${SPACK_ROOT}"
fi

mkdir -p "$(dirname "${SPACK_ROOT}")"
git clone --depth=2 "${SPACK_REPO_URL}" "${SPACK_ROOT}"

if [ -n "${SPACK_REF}" ]; then
    git -C "${SPACK_ROOT}" fetch --depth=2 origin "${SPACK_REF}" || true
    git -C "${SPACK_ROOT}" checkout --detach "${SPACK_REF}" || git -C "${SPACK_ROOT}" checkout --detach FETCH_HEAD
fi

echo "Installed Spack at ${SPACK_ROOT}"
echo "Load Chapar with: source /path/to/chapar/etc/init.sh"
