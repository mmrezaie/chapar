#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/register-nemoclaw-runner.sh --token TOKEN [options]

Options:
  --repo-url URL           GitHub repository URL (default: https://github.com/nscaledev/chapar)
  --runner-name NAME       GitHub runner name (default: chapar-nemoclaw-cve-checker)
  --labels LABELS          Comma-separated labels (default: chapar,nemoclaw,cve-checker)
  --runner-dir PATH        Runner install directory (default: /opt/actions-runner/chapar-cve-checker)
  --runner-version VER     Actions runner version; defaults to GitHub's latest release
  -h, --help               Show this help

This registers the nemoclaw VM as a dedicated GitHub Actions runner so it appears
in the repository runner UI. The runner user has no sudo and is separate from
the sandboxed chapar-cve-agent systemd service user.
USAGE
}

TOKEN="${GITHUB_RUNNER_TOKEN:-}"
REPO_URL="${GITHUB_REPOSITORY_URL:-https://github.com/nscaledev/chapar}"
RUNNER_NAME="chapar-nemoclaw-cve-checker"
LABELS="chapar,nemoclaw,cve-checker"
RUNNER_DIR="/opt/actions-runner/chapar-cve-checker"
RUNNER_VERSION="${RUNNER_VERSION:-}"
RUNNER_USER="chapar-gh-runner"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --token) TOKEN="$2"; shift 2 ;;
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --runner-name) RUNNER_NAME="$2"; shift 2 ;;
        --labels) LABELS="$2"; shift 2 ;;
        --runner-dir) RUNNER_DIR="$2"; shift 2 ;;
        --runner-version) RUNNER_VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ -n "${TOKEN}" ] || { echo "ERROR: --token or GITHUB_RUNNER_TOKEN is required" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this helper as root on the nemoclaw VM" >&2
    exit 1
fi

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    echo "ERROR: /etc/os-release is required" >&2
    exit 1
fi

case "${ID:-}" in
    ubuntu|debian) ;;
    *) echo "ERROR: this helper expects Ubuntu/Debian, got ${ID:-unknown}" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64) RUNNER_ARCH="x64" ;;
    aarch64|arm64) RUNNER_ARCH="arm64" ;;
    *) echo "ERROR: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    git \
    gzip \
    libicu-dev \
    python3 \
    tar

if ! id "${RUNNER_USER}" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --comment "Chapar GitHub CVE runner" "${RUNNER_USER}"
fi

run_as_runner() {
    runuser -u "${RUNNER_USER}" -- "$@"
}

mkdir -p "${RUNNER_DIR}"
chown "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

if [ -z "${RUNNER_VERSION}" ]; then
    RUNNER_VERSION="$(python3 - <<'PY'
import json
import urllib.request

with urllib.request.urlopen("https://api.github.com/repos/actions/runner/releases/latest") as response:
    print(json.load(response)["tag_name"].lstrip("v"))
PY
    )"
fi

archive="/tmp/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
curl -fsSL "${url}" -o "${archive}"
tar -xzf "${archive}" -C "${RUNNER_DIR}"
chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

cd "${RUNNER_DIR}"
if [ -f .service ]; then
    ./svc.sh stop || true
    ./svc.sh uninstall || true
fi
if [ -f .runner ]; then
    run_as_runner ./config.sh remove --unattended --token "${TOKEN}" || rm -f .runner .credentials .credentials_rsaparams
fi

run_as_runner ./config.sh \
    --unattended \
    --url "${REPO_URL}" \
    --token "${TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${LABELS}" \
    --work _work \
    --replace

./svc.sh install "${RUNNER_USER}"
if [ -f .service ]; then
    systemctl enable "$(cat .service)"
fi
./svc.sh start
./svc.sh status || true
