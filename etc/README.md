# Chapar Spack Configuration

Spack configuration is split into **system** and **user** scopes, while each
user keeps upstream Spack in `~/.local/opt/spack`. Chapar keeps policy and
environments outside that checkout.

## Directory Layout

```text
etc/
|-- system/                 # System scope shared by all users on a machine
|   |-- include.yaml        # Routes rocky9/rocky10, linux fallback, base
|   |-- base/               # Cross-platform settings
|   |   |-- concretizer.yaml
|   |   |-- config.yaml
|   |   |-- mirrors.yaml
|   |   |-- packages.yaml   # Virtual providers and shared package policy
|   |   `-- repos.yaml
|   |-- rocky9/             # Rocky 9 compiler, ccache, libc externals, buildcache mirror
|   |-- rocky10/            # Rocky 10 compiler, ccache, libc externals, buildcache mirror
|   `-- linux/              # Generic Linux fallback
`-- user/                   # User scope for per-user paths and overrides
    |-- include.yaml
    |-- base/
    |   |-- config.yaml
    |   `-- modules.yaml
    |-- rocky9/
    `-- rocky10/
```

## Scope Precedence

Spack applies scopes in this order, from low to high precedence:

| # | Scope | Default Path | Purpose |
|---|-------|--------------|---------|
| 1 | defaults | `$SPACK_ROOT/etc/spack/defaults/` | Factory settings |
| 2 | system | `/etc/spack/` | Machine-wide policy |
| 3 | site | `$SPACK_ROOT/etc/spack/site/` | Per-instance settings |
| 4 | user | `~/.spack/` | Per-user settings |
| 5 | spack | `$SPACK_ROOT/etc/spack/` | Spack checkout settings |
| 6 | environment | `spack.yaml` | hpcsim environment policy |
| 7 | command line | `-C` or `--config-scope` | Release-time overrides |

This repository provides scopes 2 and 4. `envs/hpcsim/release.sh` uses a
temporary command-line scope to direct installs and modules into
`${HPCSIM_ROOT}/<os>` and to control buildcache autopush while using
`${CHAPAR_BUILDCACHE_ROOT}/<os>`.

The tracked scopes do not reference legacy sectioned environments. The current
workflow uses only `envs/hpcsim` plus OS-specific scope overlays.

## Initialization

Install upstream Spack once per user:

```bash
bash /path/to/chapar/etc/install-spack.sh
```

Initialize a shell with this checkout's scopes:

```bash
source /path/to/chapar/etc/init.sh
```

The initializer sources `envs/hpcsim/hpcsim-site.env` when present, sets
`SPACK_USER_CONFIG_PATH`, `SPACK_SYSTEM_CONFIG_PATH`, and a fast local
`SPACK_USER_CACHE_PATH`. The active Rocky scopes attach the shared
`chapar-buildcache` mirror under `${CHAPAR_BUILDCACHE_ROOT}/<os>` so hpcsim and
user installs can share one configured binary cache. It also exports shared
ccache variables rooted at `${CHAPAR_CCACHE_ROOT}/<os>`. If environment modules
are available and a current hpcsim release exists for the detected OS, it adds
the resolved release module path to `MODULEPATH`.

## Platform Routing

Both system and user scopes use this include pattern:

```yaml
include:
- path: rocky9
  optional: true
  when: os == "rocky9"
- path: rocky10
  optional: true
  when: os == "rocky10"
- path: linux
  optional: true
  when: platform == "linux"
- path: base
```

OS overlays appear before `base`, so OS-specific settings override shared
defaults when necessary.

## External Package Policy

Use OS externals sparingly. The hpcsim environment should mostly depend on
Spack-built packages so Rocky 9 and Rocky 10 stay as similar as practical.

Expected system externals:

- Rocky: system GCC, `glibc`, and `ccache`. CUDA should be built by Spack for hpcsim GPU packages.

Do not add ordinary link-time dependencies such as OpenSSL, zlib, libpng, curl,
OpenBLAS, HDF5, or NetCDF as generic OS externals. Add such externals only for a
documented site reason and only when development headers, libraries, and
pkg-config/CMake metadata are guaranteed to match.

## hpcsim Releases

Build a release without touching active module trees:

```bash
bash envs/hpcsim/release.sh build 2026-05-02
```

Validate modules from that exact release:

```bash
bash envs/hpcsim/release.sh module-use 2026-05-02
```

Promote only after validation succeeds:

```bash
bash envs/hpcsim/release.sh promote 2026-05-02
```

Default release layout:

- Install store: `${HPCSIM_ROOT}/<os>/store`
- Modules: `${HPCSIM_ROOT}/<os>/releases/<release-id>/modulefiles`
- Active release symlink: `${HPCSIM_ROOT}/<os>/current`
- Buildcache: `${CHAPAR_BUILDCACHE_ROOT}/<os>`
- ccache: `${CHAPAR_CCACHE_ROOT}/<os>`

Public deployments can set `CHAPAR_INSTALL_TREE_ROOT` and `CHAPAR_MODULE_ROOT`
in the ignored site env file. With the default shared-root projection, package
prefixes include architecture, compiler, package, version, and hash.
`release.sh publish-modules <release-id>` updates `${CHAPAR_MODULE_ROOT}/<arch>`
as a symlink to the selected release-local module tree without changing
`${HPCSIM_ROOT}/<os>/current`. `release.sh promote <release-id>` updates both
`current` and the shared module symlink when `CHAPAR_MODULE_ROOT` is set.
The `<arch>` name is the actual generated module architecture. Generic builds use
targets such as `linux-rocky9-x86_64_v4`; CPU-specific builds use targets such as
`linux-rocky9-zen5`.

The store or configured install tree is shared and package prefixes include
hashes. Module trees are release-specific until `publish-modules` or `promote`
updates a public pointer. This allows new modules and packages to be added
without rewriting the module tree used by already-running jobs.

hpcsim module names are user-facing and must stay `{name}/{version}` with no
hash suffixes. Release module generation is limited to explicit environment
roots; duplicate dependency-only concrete specs must not force hashes into module
names. If root specs collide on `{name}/{version}`, fix the roots before
publishing the release.

Release module generation also adds runtime policy for CUDA-aware MPI modules.
Open MPI suppresses CUDA plugin load warnings only on non-GPU nodes.
Intel MPI/libfabric expose a release-local CUDA driver stub only on non-GPU nodes
so CPU-only commands can load CUDA-enabled libfabric without requiring the real
NVIDIA driver library. GPU nodes continue to use the real driver.

Release builds attach the matching per-OS buildcache as an unsigned binary
mirror in their generated Spack scope, so previously pushed binaries are
preferred before falling back to source builds. The generated scope uses the same
`chapar-buildcache` mirror name as the system/user scopes so it can override
`autopush` for CI without moving the cache. See `docs/buildcache.md` for the
reasoning, unsigned-cache policy, and explicit one-time legacy-cache migration
rules.

## Validation Commands

Check active scopes and merged settings:

```bash
spack config scopes -p
spack -e envs/hpcsim config get config
spack -e envs/hpcsim config get packages
spack -e envs/hpcsim config get modules
spack config blame packages
```

Check the detected platform and OS:

```bash
spack arch
spack arch --platform
```

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CHAPAR_SPACK_ROOT` | `~/.local/opt/spack` | Override the Spack checkout path |
| `SPACK_ROOT` | `~/.local/opt/spack` | Set by `etc/init.sh` before sourcing Spack |
| `SPACK_SYSTEM_CONFIG_PATH` | `/etc/spack/` | Override system scope location |
| `SPACK_USER_CONFIG_PATH` | `~/.spack/` | Override user scope location |
| `SPACK_USER_CACHE_PATH` | `/tmp/$USER/spack-cache` | Fast local cache root from `etc/init.sh` |
| `CHAPAR_INSTALL_MODE` | `home` | `home` or `public`; chooses the release root when `HPCSIM_ROOT` is unset |
| `CHAPAR_HOME_ROOT` | `~/.spack/chapar` | Private default root for local Chapar env outputs, modules, and caches |
| `HPCSIM_HOME_ROOT` | `$CHAPAR_HOME_ROOT/envs/hpcsim` | User-owned hpcsim release root |
| `HPCSIM_PUBLIC_ROOT` | empty | Site/public hpcsim release root for `CHAPAR_INSTALL_MODE=public` |
| `HPCSIM_ROOT` | mode-dependent | Effective hpcsim release root |
| `CHAPAR_HPCSIM_ROOT` | `$HPCSIM_ROOT` | hpcsim root used when adding promoted modules |
| `CHAPAR_SHARED_CACHE_ROOT` | `$CHAPAR_HOME_ROOT/cache` | Parent namespace for buildcache and ccache roots |
| `CHAPAR_BUILDCACHE_ROOT` | `$CHAPAR_SHARED_CACHE_ROOT/buildcache` | Shared Spack binary buildcache root |
| `CHAPAR_CCACHE_ROOT` | `$CHAPAR_SHARED_CACHE_ROOT/ccache` | Shared compiler ccache root |
| `CHAPAR_INSTALL_TREE_ROOT` | empty | Optional shared Spack install tree root; empty uses `${HPCSIM_ROOT}/<os>/store` |
| `CHAPAR_INSTALL_TREE_PROJECTION` | mode-dependent | Install-tree projection; shared roots default to architecture/compiler/package/version/hash |
| `CHAPAR_MODULE_ROOT` | empty | Optional promoted module root containing `<arch>` symlinks to release-local modulefiles |
| `OS_NAME` | auto-detected | `rocky9` or `rocky10` for release commands |
| `SPACK_INSTALL_ARGS` | empty | Extra args for `spack install` in release builds |
