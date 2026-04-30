#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  ci/register-macos-runner.sh --token TOKEN [options]

Options:
  --repo-url URL       GitHub repository URL (default: https://github.com/mmrezaie/chapar)
  --name NAME          Runner name (default: chapar-macos-builder)
  --labels LABELS      Comma-separated labels (default: chapar,macos,arm64)
  --install-dir PATH   Runner install directory (default: ~/actions-runner/chapar)
  --work-dir NAME      Runner work directory name (default: _work)
  --no-service         Configure only; do not install/start the launchd service
  -h, --help           Show this help
USAGE
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

REPO_URL="https://github.com/mmrezaie/chapar"
RUNNER_NAME="chapar-macos-builder"
LABELS="chapar,macos,arm64"
INSTALL_DIR="${HOME}/actions-runner/chapar"
WORK_DIR="_work"
TOKEN=""
INSTALL_SERVICE=true

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --name) RUNNER_NAME="$2"; shift 2 ;;
        --labels) LABELS="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        --no-service) INSTALL_SERVICE=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || die "this helper must run on macOS"
[ -n "${TOKEN}" ] || { usage >&2; die "--token is required"; }

case "$(uname -m)" in
    arm64) runner_arch="arm64" ;;
    x86_64) runner_arch="x64" ;;
    *) die "unsupported macOS architecture: $(uname -m)" ;;
esac

mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

if [ ! -x ./config.sh ]; then
    release_json="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)"
    runner_version="$(printf '%s\n' "${release_json}" | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p' | sed -n '1p')"
    [ -n "${runner_version}" ] || die "could not discover latest GitHub runner version"
    archive="actions-runner-osx-${runner_arch}-${runner_version}.tar.gz"
    curl -fL -o "${archive}" "https://github.com/actions/runner/releases/download/v${runner_version}/${archive}"
    tar xzf "${archive}"
    rm -f "${archive}"
fi

./config.sh \
    --url "${REPO_URL}" \
    --token "${TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${LABELS}" \
    --work "${WORK_DIR}" \
    --unattended \
    --replace

if [ "${INSTALL_SERVICE}" = true ]; then
    ./svc.sh install
    ./svc.sh start
fi

echo "Registered macOS runner ${RUNNER_NAME} with labels ${LABELS}"
