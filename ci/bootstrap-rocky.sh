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

# Rocky mirrors intermittently fail metadata downloads; retry before giving up.
dnf_with_retries() {
    local attempt
    for attempt in 1 2 3; do
        if as_root dnf -y "$@"; then
            return 0
        fi
        echo "WARNING: dnf $1 failed (attempt ${attempt}/3); cleaning metadata and retrying in 30s" >&2
        as_root dnf clean all || true
        sleep 30
    done
    as_root dnf -y "$@"
}

as_root dnf clean all
dnf_with_retries makecache

dnf_with_retries install \
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

dnf_with_retries install epel-release
dnf_with_retries install ccache

as_root install -m 0644 etc/profile.d/zz-chapar-hpcsim.sh /etc/profile.d/zz-chapar-hpcsim.sh
as_root install -m 0644 etc/profile.d/zz-chapar-vlad.sh /etc/profile.d/zz-chapar-vlad.sh

# Publish the login scripts to the shared tree as well. Compute nodes (Kraken)
# install a stub that sources /resources/chapar/etc/profile.d/*.sh, so they
# pick up Chapar profile changes on the next login without re-provisioning.
if [ -d /resources/chapar ]; then
    as_root install -d -m 2775 /resources/chapar/etc/profile.d 2>/dev/null \
        || install -d /resources/chapar/etc/profile.d 2>/dev/null || true
    as_root install -m 0644 etc/profile.d/zz-chapar-hpcsim.sh etc/profile.d/zz-chapar-vlad.sh \
        /resources/chapar/etc/profile.d/ 2>/dev/null \
        || install -m 0644 etc/profile.d/zz-chapar-hpcsim.sh etc/profile.d/zz-chapar-vlad.sh \
            /resources/chapar/etc/profile.d/ \
        || echo "WARNING: could not publish profile.d scripts to /resources/chapar/etc/profile.d" >&2
fi

for safe_dir in \
    "${GITHUB_WORKSPACE:-}" \
    /opt/actions-runner/_work/chapar/chapar \
    /root/workspace/chapar; do
    [ -n "${safe_dir}" ] || continue
    git config --global --add safe.directory "${safe_dir}" || true
done
