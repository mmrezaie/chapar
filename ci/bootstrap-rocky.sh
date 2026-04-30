#!/usr/bin/env bash
set -euo pipefail

if ! command -v dnf >/dev/null 2>&1; then
    echo "ERROR: this bootstrap script expects a Rocky/RHEL container with dnf" >&2
    exit 1
fi

dnf -y makecache

dnf -y install \
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
    8) dnf config-manager --set-enabled powertools || true ;;
    9) dnf config-manager --set-enabled crb || true ;;
esac

dnf -y install epel-release
dnf -y install ccache

if ! command -v gh >/dev/null 2>&1; then
    dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
    dnf -y install gh
fi

git config --global --add safe.directory '*' || true
