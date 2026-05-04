# Chapar Spack Configuration

Spack configuration is split into **system** and **user** scopes, with OS
user's `~/.local/opt/spack`; Chapar keeps policy and environments outside that
checkout.

## Directory Layout

```text
etc/
|-- system/                 # System scope shared by all users on a machine
|   |-- include.yaml        # Routes rocky8/rocky9/macos, linux fallback, base
|   |-- base/               # Cross-platform settings
|   |   |-- concretizer.yaml
|   |   |-- config.yaml
|   |   |-- mirrors.yaml
|   |   |-- packages.yaml   # Virtual providers and shared package policy
|   |   `-- repos.yaml
|   |-- rocky8/             # Rocky 8 compiler, ccache, libc externals
|   |-- rocky9/             # Rocky 9 compiler, ccache, libc externals
|   |-- macos/              # macOS compiler and ccache externals
|   `-- linux/              # Generic Linux fallback
`-- user/                   # User scope for per-user paths and overrides
    |-- include.yaml
    |-- base/
    |   |-- config.yaml
    |   `-- modules.yaml
    |-- rocky8/
    |-- rocky9/
    `-- macos/
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
`/resources/share/hpcsim/<os>`.

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

The initializer sets `SPACK_USER_CONFIG_PATH`, `SPACK_SYSTEM_CONFIG_PATH`, and a
fast local `SPACK_USER_CACHE_PATH`. If environment modules are available and a
current hpcsim release exists for the detected OS, it adds the resolved release
module path to `MODULEPATH`.

## Platform Routing

Both system and user scopes use this include pattern:

```yaml
include:
- path: rocky8
  optional: true
  when: os == "rocky8"
- path: rocky9
  optional: true
  when: os == "rocky9"
- path: macos
  optional: true
  when: platform == "darwin"
- path: linux
  optional: true
  when: platform == "linux"
- path: base
```

OS overlays appear before `base`, so OS-specific settings override shared
defaults when necessary.

## External Package Policy

Use OS externals sparingly. The hpcsim environment should mostly depend on
Spack-built packages so Rocky8, Rocky9, and macOS stay as similar as practical.

Expected system externals:

- Rocky: system GCC, `glibc`, `ccache`, and the site CUDA toolkit on GPU Rocky9 builders.
- macOS: Apple Clang, Homebrew GCC/GFortran, and optionally `ccache`.

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

Release layout:

- Install store: `/resources/share/hpcsim/<os>/store`
- Modules: `/resources/share/hpcsim/<os>/releases/<release-id>/modulefiles`
- Active release symlink: `/resources/share/hpcsim/<os>/current`
- Buildcache: `/resources/share/hpcsim/<os>/buildcache`

The store is shared per OS and package prefixes include hashes. Module trees are
release-specific. This allows new modules and packages to be added without
rewriting the module tree used by already-running jobs.

Release builds attach the matching per-OS buildcache as an unsigned binary
mirror in their generated Spack scope, so previously pushed binaries are
preferred before falling back to source builds.

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
| `HPCSIM_ROOT` | `/resources/share/hpcsim` | Shared hpcsim release root |
| `CHAPAR_HPCSIM_ROOT` | `/resources/share/hpcsim` | Shared hpcsim root used when adding promoted modules |
| `OS_NAME` | auto-detected | `rocky8`, `rocky9`, or `macos` for release commands |
| `SPACK_INSTALL_ARGS` | empty | Extra args for `spack install` in release builds |
| `CHAPAR_ALLOW_UNSAFE_HPCSIM_ROOT` | `false` | Allow non-standard absolute `HPCSIM_ROOT` values for local tests |
