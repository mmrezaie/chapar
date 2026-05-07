#!/usr/bin/env bash
set -euo pipefail

: "${HPCSIM_ROOT:=/resources/share/hpcsim}"
: "${CHAPAR_BUILDCACHE_ROOT:=/resources/chapar/cache}"
: "${OS_NAME:?OS_NAME is required}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

validate_hpcsim_root() {
    local home_root="${HOME}/resources/share/hpcsim"

    case "${HPCSIM_ROOT}" in
        /*) ;;
        *) die "HPCSIM_ROOT must be an absolute path: ${HPCSIM_ROOT}" ;;
    esac

    case "${HPCSIM_ROOT}" in
        /|*'/../'*|*/..|*'/./'*|*/.|*[!A-Za-z0-9._/+-]*)
            die "HPCSIM_ROOT is not an approved simple shared hpcsim path: ${HPCSIM_ROOT}"
            ;;
    esac

    case "${HPCSIM_ROOT}" in
        /resources/share/hpcsim|/resources/share/hpcsim/*|/resources/chapar/hpcsim|/resources/chapar/hpcsim/*|"${home_root}"|"${home_root}"/*)
            ;;
        *)
            if [ "${CHAPAR_ALLOW_UNSAFE_HPCSIM_ROOT:-false}" != "true" ]; then
                die "HPCSIM_ROOT must be under /resources/share/hpcsim, /resources/chapar/hpcsim, or ${home_root}; set CHAPAR_ALLOW_UNSAFE_HPCSIM_ROOT=true for local testing"
            fi
            ;;
    esac
}

validate_buildcache_root() {
    local home_root="${HOME}/resources/chapar/cache"

    case "${CHAPAR_BUILDCACHE_ROOT}" in
        /*) ;;
        *) die "CHAPAR_BUILDCACHE_ROOT must be an absolute path: ${CHAPAR_BUILDCACHE_ROOT}" ;;
    esac

    case "${CHAPAR_BUILDCACHE_ROOT}" in
        /|*'/../'*|*/..|*'/./'*|*/.|*[!A-Za-z0-9._/+-]*)
            die "CHAPAR_BUILDCACHE_ROOT is not an approved simple shared cache path: ${CHAPAR_BUILDCACHE_ROOT}"
            ;;
    esac

    case "${CHAPAR_BUILDCACHE_ROOT}" in
        /resources/chapar/cache|/resources/chapar/cache/*|"${home_root}"|"${home_root}"/*)
            ;;
        *)
            if [ "${CHAPAR_ALLOW_UNSAFE_BUILDCACHE_ROOT:-false}" != "true" ]; then
                die "CHAPAR_BUILDCACHE_ROOT must be under /resources/chapar/cache or ${home_root}; set CHAPAR_ALLOW_UNSAFE_BUILDCACHE_ROOT=true for local testing"
            fi
            ;;
    esac
}

case "${OS_NAME}" in
    rocky8|rocky9|macos) ;;
    *) die "OS_NAME must be rocky8, rocky9, or macos, got ${OS_NAME}" ;;
esac

validate_hpcsim_root
validate_buildcache_root

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "ERROR: cannot create ${HPCSIM_ROOT} or ${CHAPAR_BUILDCACHE_ROOT}; root privileges or passwordless sudo are required" >&2
        exit 1
    fi
}

owner_uid="$(id -u)"
owner_gid="$(id -g)"
os_root="${HPCSIM_ROOT}/${OS_NAME}"
buildcache_dir="${CHAPAR_BUILDCACHE_ROOT}/${OS_NAME}"

if ! mkdir -p \
    "${buildcache_dir}" \
    "${os_root}/releases" \
    "${os_root}/runs" \
    "${os_root}/store" 2>/dev/null; then
    run_as_root mkdir -p \
        "${buildcache_dir}" \
        "${os_root}/releases" \
        "${os_root}/runs" \
        "${os_root}/store"

    run_as_root chown "${owner_uid}:${owner_gid}" \
        "${HPCSIM_ROOT}" \
        "${CHAPAR_BUILDCACHE_ROOT}" \
        "${buildcache_dir}" \
        "${os_root}" \
        "${os_root}/releases" \
        "${os_root}/runs" \
        "${os_root}/store" || true

    run_as_root chmod 2775 \
        "${HPCSIM_ROOT}" \
        "${CHAPAR_BUILDCACHE_ROOT}" \
        "${buildcache_dir}" \
        "${os_root}" \
        "${os_root}/releases" \
        "${os_root}/runs" \
        "${os_root}/store" || true
fi

if [ ! -w "${os_root}" ]; then
    echo "ERROR: ${os_root} is not writable by $(id -un) after preparation" >&2
    exit 1
fi

if [ ! -w "${buildcache_dir}" ]; then
    echo "ERROR: ${buildcache_dir} is not writable by $(id -un) after preparation" >&2
    exit 1
fi
