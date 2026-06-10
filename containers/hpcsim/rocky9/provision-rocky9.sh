#!/usr/bin/env bash
set -euo pipefail

: "${CHAPAR_PACKAGE_LIST:=/tmp/chapar-rocky9-packages.txt}"

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        printf 'ERROR: root privileges or sudo are required for %s\n' "$*" >&2
        exit 1
    fi
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "${value}"
}

packages=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(trim "${line}")"
    [ -n "${line}" ] || continue
    packages+=("${line}")
done < "${CHAPAR_PACKAGE_LIST}"

[ "${#packages[@]}" -gt 0 ] || {
    printf 'ERROR: no packages found in %s\n' "${CHAPAR_PACKAGE_LIST}" >&2
    exit 1
}

as_root dnf -y makecache
as_root dnf -y install dnf-plugins-core
as_root dnf config-manager --set-enabled crb
as_root dnf -y install epel-release
as_root dnf -y install "${packages[@]}"

as_root install -d -m 0755 /resources/chapar/hpcsim /resources/chapar/cache/buildcache /resources/chapar/cache/ccache
as_root chmod 0755 /usr/local/bin/chapar-hpcsim-entrypoint
if [ -r /etc/profile.d/zz-chapar-hpcsim.sh ]; then
    as_root chmod 0644 /etc/profile.d/zz-chapar-hpcsim.sh
fi

as_root dnf -y clean all
as_root rm -rf /var/cache/dnf /tmp/chapar-rocky9-packages.txt
