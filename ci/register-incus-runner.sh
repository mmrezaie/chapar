#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ci/register-incus-runner.sh --container NAME --token TOKEN [options]

Options:
  --repo-url URL           GitHub repository URL (default: https://github.com/mmrezaie/chapar)
  --runner-name NAME       GitHub runner name (default: container name)
  --labels LABELS          Comma-separated custom labels, for example chapar,rocky9
  --runner-dir PATH        Runner install directory inside the container (default: /opt/actions-runner)
  --runner-version VER     Actions runner version; defaults to GitHub's latest release
  -h, --help               Show this help

The script installs and starts the GitHub Actions runner service inside an
existing Incus Rocky container. The token is the short-lived registration token
from GitHub: repository Settings -> Actions -> Runners -> New self-hosted runner.
USAGE
}

CONTAINER=""
TOKEN="${GITHUB_RUNNER_TOKEN:-}"
REPO_URL="${GITHUB_REPOSITORY_URL:-https://github.com/mmrezaie/chapar}"
RUNNER_NAME=""
LABELS=""
RUNNER_DIR="/opt/actions-runner"
RUNNER_VERSION="${RUNNER_VERSION:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --container) CONTAINER="$2"; shift 2 ;;
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

[ -n "${CONTAINER}" ] || { usage >&2; exit 1; }
[ -n "${TOKEN}" ] || { echo "ERROR: --token or GITHUB_RUNNER_TOKEN is required" >&2; exit 1; }
RUNNER_NAME="${RUNNER_NAME:-${CONTAINER}}"

if [ -z "${LABELS}" ]; then
    case "${CONTAINER}" in
        *rocky8*) LABELS="chapar,rocky8" ;;
        *rocky9*) LABELS="chapar,rocky9" ;;
        *) echo "ERROR: --labels is required when the container name does not include rocky8 or rocky9" >&2; exit 1 ;;
    esac
fi

if [ -z "${RUNNER_VERSION}" ]; then
    RUNNER_VERSION="$(incus exec "${CONTAINER}" -- bash -lc '
        command -v python3 >/dev/null 2>&1 || dnf -y install python3 >/dev/null
        python3 - <<"PY"
import json
import urllib.request

with urllib.request.urlopen("https://api.github.com/repos/actions/runner/releases/latest") as response:
    print(json.load(response)["tag_name"].lstrip("v"))
PY
    ')"
fi

echo "==> Registering GitHub Actions runner"
echo "    container: ${CONTAINER}"
echo "    repo:      ${REPO_URL}"
echo "    name:      ${RUNNER_NAME}"
echo "    labels:    ${LABELS}"
echo "    version:   ${RUNNER_VERSION}"

incus exec "${CONTAINER}" --env "RUNNER_VERSION=${RUNNER_VERSION}" \
    --env "REPO_URL=${REPO_URL}" \
    --env "TOKEN=${TOKEN}" \
    --env "RUNNER_NAME=${RUNNER_NAME}" \
    --env "LABELS=${LABELS}" \
    --env "RUNNER_DIR=${RUNNER_DIR}" \
    -- bash -lc '
set -euo pipefail

dnf -y makecache
dnf -y install curl tar gzip git libicu openssl-libs shadow-utils sudo

if ! id actions >/dev/null 2>&1; then
    useradd -m -s /bin/bash actions
fi
printf "actions ALL=(ALL) NOPASSWD:ALL\n" >/etc/sudoers.d/actions-runner
chmod 0440 /etc/sudoers.d/actions-runner

mkdir -p "${RUNNER_DIR}"
chown actions:actions "${RUNNER_DIR}"

archive="/tmp/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
curl -fsSL "${url}" -o "${archive}"
tar -xzf "${archive}" -C "${RUNNER_DIR}"
chown -R actions:actions "${RUNNER_DIR}"

cd "${RUNNER_DIR}"
if [ -f .service ]; then
    ./svc.sh stop || true
    ./svc.sh uninstall || true
fi
if [ -f .runner ]; then
    sudo -u actions ./config.sh remove --unattended --token "${TOKEN}" || rm -f .runner .credentials .credentials_rsaparams
fi

sudo -u actions ./config.sh \
    --unattended \
    --url "${REPO_URL}" \
    --token "${TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${LABELS}" \
    --work _work \
    --replace

./svc.sh install actions
./svc.sh start
./svc.sh status || true
'
