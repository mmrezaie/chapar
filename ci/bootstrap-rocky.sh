#!/usr/bin/env bash
set -euo pipefail

if ! command -v dnf >/dev/null 2>&1; then
    echo "ERROR: this bootstrap script expects a Rocky/RHEL container with dnf" >&2
    exit 1
fi

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
    libtool \
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

source /etc/os-release
case "${VERSION_ID%%.*}" in
    8) as_root dnf config-manager --set-enabled powertools || true ;;
    9) as_root dnf config-manager --set-enabled crb || true ;;
esac

as_root dnf -y install epel-release
as_root dnf -y install ccache

if ! command -v gh >/dev/null 2>&1; then
    as_root dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
    as_root dnf -y install gh
fi

git config --global --add safe.directory '*' || true
