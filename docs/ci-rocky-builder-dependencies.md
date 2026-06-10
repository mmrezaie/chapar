# Rocky Builder Dependencies

This document records the host/container setup needed for the Rocky Incus hpcsim builders, and should be kept aligned with `ci/bootstrap-rocky.sh`.

## Tested Smoke Path

Use this host-side smoke command to exercise the current Incus build path:

```bash
ci/incus-build.sh \
  --os rocky9 \
  --release-id smoke-local-rocky9 \
  --run-id smoke-local-rocky9 \
  --publish-buildcache false \
  --keep-running
```

The current hpcsim workflow builds the full `envs/hpcsim` environment instead
of an old sectioned subset. The compiler/toolkit policy selects the Spack-built
GCC 15 compiler stack and CUDA 13 root.

CUDA is expected to be installed by Spack for hpcsim GPU builds rather than provided by the host/container. The builders do not need a local CUDA toolkit or a GPU to build CUDA-dependent packages, though runtime GPU Direct behavior still depends on NVIDIA drivers, GPUs, and fabric hardware on the target nodes.

Intel oneAPI packages, including Intel MPI and any future Intel compiler root, must also come from Spack instead of OS RPM repositories. The hpcsim compiler policy currently selects GCC 15 for builds; do not install OS Intel compiler RPMs just to provision an Incus builder.

Artifacts are written under:

```text
/resources/chapar/hpcsim/rocky9/runs/smoke-local-rocky9
/resources/chapar/cache/buildcache/rocky9
/resources/chapar/cache/ccache/rocky9
```

## Enabled Repositories

The base Rocky images provide `BaseOS`, `AppStream`, and `Extras`. Additional repositories are limited to:

- Rocky9/Rocky10: enable `crb`.
- EPEL: required for `ccache`.

Do not add CUDA, Intel oneAPI, or GitHub CLI RPM repositories to hpcsim builders. The build process must not depend on them.

The bootstrap commands are:

```bash
dnf -y install dnf-plugins-core

# Rocky9/Rocky10
dnf config-manager --set-enabled crb

dnf -y install epel-release
```

## Required RPM Packages

Install these packages in both Rocky 9 and Rocky 10 builders:

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
```

## Why These Extras Matter

- `ccache` is required because `etc/system/base/config.yaml` enables Spack ccache support.
- System GCC and `glibc` are modeled as Rocky externals; ordinary build tools and link-time libraries are intentionally not modeled as externals.
- Intel oneAPI compiler RPMs are intentionally not installed or modeled as externals. hpcsim currently constrains compiler virtuals to GCC; if an Intel compiler root becomes required, add the Spack `intel-oneapi-compilers` package to the environment instead of adding an OS repo.
- `libtool` is built by Spack because packages such as PulseAudio link against `libltdl`; modeling the OS command-line tool as a generic external can miss the development library metadata.
- `zlib-api` is constrained to Spack `zlib-ng+compat` on Rocky so libpng and other consumers see matching headers, libraries, and pkg-config metadata.
- Link-time dependency libraries such as OpenSSL, zlib, libpng, and curl are intentionally not declared as generic Rocky externals; Spack should build those unless a site-specific external is explicitly modeled with development metadata available.
- `gh` is not required by the build itself and is intentionally not installed in the builder baseline.
- `nfs-utils` supports resource/NAS access and diagnostics.
- `${CHAPAR_BUILDCACHE_ROOT}/<os>` and `${CHAPAR_CCACHE_ROOT}/<os>` must be writable by trusted Chapar builders and users because Rocky scopes use `autopush: true` for the shared binary buildcache and Chapar exports shared ccache settings.

## XPMEM Policy

Do not enable UCX `+xpmem` in the generic Incus CI environments. Spack's preferred `xpmem@2.6.5-36` builds a Linux kernel module by default and needs kernel sources for the running kernel. The Rocky containers share the Incus host kernel, so Rocky `kernel-devel` packages do not match the active Fedora host kernel and the build fails at configure time.

If a production cluster needs XPMEM, install and load the kernel module on matching compute-node kernels and model it as a site-specific external instead of building it in the portable CI buildcache.

## CI Install Concurrency

Spack-built Intel oneAPI packages, such as Intel MPI, can share Intel installer cache state under `/var/intel/installercache`. Running multiple oneAPI installs concurrently corrupted that cache during testing. The container CI driver therefore defaults to serialized package installation:

```bash
SPACK_INSTALL_ARGS="-p 1"
```

Override `SPACK_INSTALL_ARGS` only when you know the selected hpcsim build does not contain Spack-built Intel oneAPI installers or another package with shared global installer state.

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
