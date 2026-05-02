#!/usr/bin/env bash
set -euo pipefail

: "${HPCSIM_ROOT:=/resources/share/hpcsim}"
: "${OS_NAME:?OS_NAME is required}"

case "${OS_NAME}" in
    rocky8|rocky9|macos) ;;
    *) echo "ERROR: OS_NAME must be rocky8, rocky9, or macos, got ${OS_NAME}" >&2; exit 1 ;;
esac

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "ERROR: cannot create ${HPCSIM_ROOT}; root privileges or passwordless sudo are required" >&2
        exit 1
    fi
}

owner_uid="$(id -u)"
owner_gid="$(id -g)"
os_root="${HPCSIM_ROOT}/${OS_NAME}"

if ! mkdir -p \
    "${os_root}/buildcache" \
    "${os_root}/releases" \
    "${os_root}/runs" \
    "${os_root}/store" 2>/dev/null; then
    run_as_root mkdir -p \
        "${os_root}/buildcache" \
        "${os_root}/releases" \
        "${os_root}/runs" \
        "${os_root}/store"

    run_as_root chown "${owner_uid}:${owner_gid}" \
        "${HPCSIM_ROOT}" \
        "${os_root}" \
        "${os_root}/buildcache" \
        "${os_root}/releases" \
        "${os_root}/runs" \
        "${os_root}/store" || true

    run_as_root chmod 2775 \
        "${HPCSIM_ROOT}" \
        "${os_root}" \
        "${os_root}/buildcache" \
        "${os_root}/releases" \
        "${os_root}/runs" \
        "${os_root}/store" || true
fi

if [ ! -w "${os_root}" ]; then
    echo "ERROR: ${os_root} is not writable by $(id -un) after preparation" >&2
    exit 1
fi
