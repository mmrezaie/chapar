#!/usr/bin/env bash
set -euo pipefail

if ! command -v dnf >/dev/null 2>&1; then
    echo "ERROR: this bootstrap script expects a Rocky/RHEL container with dnf" >&2
    exit 1
fi

source /etc/os-release
case "${ID}:${VERSION_ID%%.*}" in
    rocky:9|rocky:10) ;;
    *) echo "ERROR: hpcsim Incus builders support only Rocky 9 or Rocky 10, got ${PRETTY_NAME:-${ID} ${VERSION_ID}}" >&2; exit 1 ;;
esac

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "ERROR: root privileges or passwordless sudo are required for $*" >&2
        exit 1
    fi
}

as_root dnf -y makecache

as_root dnf -y install \
    autoconf \
    automake \
    bash \
    binutils \
    bison \
    bzip2 \
    ca-certificates \
    cmake \
    coreutils \
    curl \
    diffutils \
    dnf-plugins-core \
    environment-modules \
    file \
    findutils \
    flex \
    gawk \
    gcc \
    gcc-c++ \
    gcc-gfortran \
    gettext \
    git \
    groff \
    gzip \
    hostname \
    jq \
    m4 \
    make \
    nfs-utils \
    openssl \
    openssh-clients \
    patch \
    perl \
    procps-ng \
    python3 \
    python3-pip \
    rsync \
    sed \
    shadow-utils \
    tar \
    texinfo \
    unzip \
    util-linux \
    which \
    xz \
    zstd

as_root dnf config-manager --set-enabled crb || true

as_root dnf -y install epel-release
as_root dnf -y install ccache

as_root install -m 0644 etc/profile.d/zz-chapar-hpcsim.sh /etc/profile.d/zz-chapar-hpcsim.sh
as_root install -m 0644 etc/profile.d/zz-chapar-vlad.sh /etc/profile.d/zz-chapar-vlad.sh

for safe_dir in \
    "${GITHUB_WORKSPACE:-}" \
    /opt/actions-runner/_work/chapar/chapar \
    /root/workspace/chapar; do
    [ -n "${safe_dir}" ] || continue
    git config --global --add safe.directory "${safe_dir}" || true
done
