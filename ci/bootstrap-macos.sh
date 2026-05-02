#!/usr/bin/env bash
set -euo pipefail

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || die "bootstrap-macos.sh must run on macOS"

if ! xcode-select -p >/dev/null 2>&1; then
    die "Xcode command line tools are missing; run: xcode-select --install"
fi

if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is required for the native macOS runner"
fi

brew_prefix="$(brew --prefix)"
export PATH="${brew_prefix}/bin:${brew_prefix}/opt/make/libexec/gnubin:${PATH}"

packages=(
    autoconf
    automake
    bison
    ccache
    cmake
    coreutils
    diffutils
    findutils
    flex
    gawk
    gcc
    gettext
    git
    gnu-sed
    grep
    libtool
    m4
    make
    modules
    ninja
    openssl@3
    pkgconf
    python@3.12
    rsync
    texinfo
)

missing=()
for package in "${packages[@]}"; do
    if ! brew list --versions "${package}" >/dev/null 2>&1; then
        missing+=("${package}")
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    brew update
    brew install "${missing[@]}"
fi

if [ -d /resources/share ] && [ -w /resources/share ]; then
    mkdir -p /resources/share/hpcsim/macos
fi

command -v gcc-15 >/dev/null 2>&1 || die "Homebrew gcc-15 is missing"
command -v g++-15 >/dev/null 2>&1 || die "Homebrew g++-15 is missing"
command -v gfortran >/dev/null 2>&1 || die "Homebrew gfortran is missing"
command -v "${brew_prefix}/opt/m4/bin/m4" >/dev/null 2>&1 || die "Homebrew m4 is missing"
command -v "${brew_prefix}/opt/python@3.12/bin/python3.12" >/dev/null 2>&1 || die "Homebrew python@3.12 is missing"
if [ ! -x "${brew_prefix}/bin/ccache" ]; then
    brew link ccache >/dev/null 2>&1 || true
fi
[ -x "${brew_prefix}/bin/ccache" ] || die "ccache is missing at ${brew_prefix}/bin/ccache"
ccache_version="$("${brew_prefix}/bin/ccache" --version)"
ccache_version="${ccache_version%%$'\n'*}"
m4_version="$("${brew_prefix}/opt/m4/bin/m4" --version)"
m4_version="${m4_version%%$'\n'*}"

echo "macOS:       $(sw_vers -productVersion)"
echo "arch:        $(uname -m)"
echo "brew:        ${brew_prefix}"
echo "gcc:         $(gcc-15 -dumpfullversion)"
echo "gfortran:    $(gfortran -dumpfullversion)"
echo "m4:          ${m4_version}"
echo "python:      $("${brew_prefix}/opt/python@3.12/bin/python3.12" --version)"
echo "ccache:      ${ccache_version}"
echo "hpcsim root: ${HPCSIM_ROOT:-/resources/share/hpcsim}"
