# Rocky Builder Dependencies

This document records the host/container setup that was needed to make the Incus CI smoke path work on the `chapar-rocky9-builder` container, and should be kept aligned with `ci/bootstrap-rocky.sh`.

## Tested Smoke Path

The validated host-side smoke command was:

```bash
ci/incus-build.sh \
  --os rocky9 \
  --flavor canary \
  --section toolchain \
  --git-ref sectionification \
  --repo-url file:///resources/chapar/ci-test/chapar.git \
  --resources-source /resources \
  --resources-root /resources/chapar \
  --run-id smoke-local-rocky9-toolchain-serialized \
  --push-buildcache false \
  --keep-running
```

The test completed successfully on Rocky Linux 9.7 and installed these root toolchain specs:

- `cuda@13.0.2`
- `gcc@13.4.0`
- `gcc@14.3.0`
- `gcc@15.2.0`
- `intel-oneapi-compilers@2023.1.0`
- `intel-oneapi-compilers@2024.1.0`
- `intel-oneapi-compilers@2025.3.1`

Artifacts were written under:

```text
/resources/chapar/runs/smoke-local-rocky9-toolchain-serialized/rocky9/canary/toolchain
```

## Enabled Repositories

The base Rocky images provide `BaseOS`, `AppStream`, and `Extras`. Additional repositories are required:

- Rocky8: enable `powertools`.
- Rocky9: enable `crb`.
- EPEL: required for `ccache`.
- GitHub CLI RPM repo: required for `gh`.

The bootstrap commands are:

```bash
dnf -y install dnf-plugins-core

# Rocky8 only
dnf config-manager --set-enabled powertools

# Rocky9 only
dnf config-manager --set-enabled crb

dnf -y install epel-release
dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
```

## Required RPM Packages

Install these packages in both Rocky8 and Rocky9 builders:

```bash
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

dnf -y install epel-release
dnf -y install ccache
dnf -y install gh
```

## Why These Extras Matter

- `ccache` is required because `etc/system/base/config.yaml` enables Spack ccache support.
- Compilers, `autoconf`, `automake`, `bison`, `flex`, `m4`, `libtool`, `cmake`, `texinfo`, `groff`, and core GNU tools are declared as `/usr` externals in `etc/system/rocky8/packages.yaml` and `etc/system/rocky9/packages.yaml`; if they are missing, Spack may still concretize but later fail during builds.
- Link-time dependency libraries such as OpenSSL, zlib, libpng, and curl are intentionally not declared as generic Rocky externals; Spack should build those unless a site-specific external is explicitly modeled with development metadata available.
- `gh` is not required by the build itself, but is useful for manual debugging and GitHub operations inside persistent builder containers.
- `nfs-utils` supports resource/NAS access and diagnostics.

## XPMEM Policy

Do not enable UCX `+xpmem` in the generic Incus CI environments. Spack's preferred `xpmem@2.6.5-36` builds a Linux kernel module by default and needs kernel sources for the running kernel. The Rocky containers share the Incus host kernel, so Rocky `kernel-devel` packages do not match the active Fedora host kernel and the build fails at configure time.

If a production cluster needs XPMEM, install and load the kernel module on matching compute-node kernels and model it as a site-specific external instead of building it in the portable CI buildcache.

## CI Install Concurrency

The Intel oneAPI offline installers share Intel cache state under `/var/intel/installercache`. Running multiple oneAPI compiler installs concurrently corrupted that cache during testing. The container CI driver therefore defaults to serialized package installation:

```bash
SPACK_INSTALL_ARGS="-p 1"
```

Override `SPACK_INSTALL_ARGS` only when you know a selected section does not contain Intel oneAPI installers or another package with shared global installer state.

For local runs, pass the override through the Incus wrapper:

```bash
ci/incus-build.sh --spack-install-args "-p 4" ...
```

For GitHub Actions, use the manual workflow `spack_install_args` input.

If a failed parallel oneAPI attempt leaves the builder in a bad state, clear only the generated Intel installer cache before retrying:

```bash
incus exec chapar-rocky9-builder -- rm -rf /var/intel/installercache /tmp/root/intel_oneapi_installer
```

## Spack Checkout

The CI container driver installs Spack automatically when `~/.local/opt/spack/share/spack/setup-env.sh` is missing:

```bash
bash ./etc/install-spack.sh
```

The tested Rocky9 builder installed Spack at `/root/.local/opt/spack` and reported:

```text
1.2.0.dev0 (243f50f4025b2e96d6c849009a3d182554385b03)
```
