#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SYSTEM_SRC="${REPO_ROOT}/etc/system"
USER_SRC="${REPO_ROOT}/etc/user"

SYSTEM_DST="${SPACK_SYSTEM_CONFIG_PATH:-/etc/spack}"
if [ -n "${SPACK_USER_CONFIG_PATH:-}" ]; then
    USER_DST="${SPACK_USER_CONFIG_PATH}"
elif [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    USER_DST="$(eval echo "~${SUDO_USER}")/.spack"
else
    USER_DST="${HOME}/.spack"
fi

MODE="${1:---all}"

usage() {
    cat <<'EOF'
Usage:
  link-scopes.sh [--all|--user|--system]

Behavior:
  --user     Link user scope to ~/.spack (or SPACK_USER_CONFIG_PATH)
  --system   Link system scope to /etc/spack (or SPACK_SYSTEM_CONFIG_PATH)
  --all      Link both (default)

Existing non-symlink destinations are moved to timestamped backups before
linking.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

replace_with_symlink() {
    local src="$1"
    local dst="$2"
    local backup=""
    local ts

    [ -e "${src}" ] || die "source not found: ${src}"

    if [ -L "${dst}" ]; then
        ln -sfn "${src}" "${dst}"
        return 0
    fi

    if [ -e "${dst}" ]; then
        ts="$(date +%Y%m%d%H%M%S)"
        backup="${dst}.bak.${ts}"
        mv "${dst}" "${backup}"
        echo "Backed up ${dst} -> ${backup}"
    fi

    ln -s "${src}" "${dst}"
}

link_user() {
    replace_with_symlink "${USER_SRC}" "${USER_DST}"
    echo "Linked user scope: ${USER_DST} -> ${USER_SRC}"
}

link_system() {
    if [ "$(id -u)" -ne 0 ] && [ ! -w "$(dirname "${SYSTEM_DST}")" ]; then
        die "system scope requires write access to $(dirname "${SYSTEM_DST}"). Re-run with sudo."
    fi
    replace_with_symlink "${SYSTEM_SRC}" "${SYSTEM_DST}"
    echo "Linked system scope: ${SYSTEM_DST} -> ${SYSTEM_SRC}"
}

case "${MODE}" in
    --all)
        link_user
        link_system
        ;;
    --user)
        link_user
        ;;
    --system)
        link_system
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        die "unknown mode: ${MODE}"
        ;;
esac
