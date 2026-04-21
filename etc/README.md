# Chapar Spack Configuration

Spack configuration split into **system** and **user** scopes, with OS overlays
for **rocky8**, **rocky9**, and **macOS** (Spack >= v1.0).

## Directory Layout

```
etc/
├── system/                 # System scope — shared by ALL users on the machine
│   ├── include.yaml        # Routes rocky8/rocky9/macos, then linux fallback, then base/
│   ├── base/               # Cross-platform settings
│   │   ├── concretizer.yaml
│   │   ├── config.yaml     # System-level config (build_jobs, ccache, environments_root, …)
│   │   ├── mirrors.yaml
│   │   ├── packages.yaml   # Virtual providers, permissions (no externals here)
│   │   └── repos.yaml
│   ├── rocky8/             # Rocky Linux 8 OS-specific settings
│   │   └── packages.yaml
│   ├── rocky9/             # Rocky Linux 9 OS-specific settings
│   │   └── packages.yaml
│   ├── macos/              # macOS OS-specific settings
│   │   └── packages.yaml
│   ├── darwin/             # macOS-only externals
│   │   └── packages.yaml
│   └── linux/              # Linux-only externals
│       └── packages.yaml
│
└── user/                   # User scope — per-user settings
    ├── include.yaml        # Routes rocky8/rocky9/macos, then linux fallback, then base/
    ├── base/               # Cross-platform user settings
    │   ├── config.yaml     # install_tree, template_dirs, build_stage, …
    │   └── modules.yaml    # Module generation (tcl/lmod roots, naming)
    ├── rocky8/             # Rocky Linux 8 user overrides
    │   └── config.yaml
    ├── rocky9/             # Rocky Linux 9 user overrides
    │   └── config.yaml
    ├── macos/              # macOS user overrides
    │   └── config.yaml
    ├── darwin/             # Platform-level macOS overrides (optional)
    └── linux/              # Platform-level Linux overrides (optional)
```

## Spack Scope Precedence (low → high)

| # | Scope       | Default Path                        | Purpose                        |
|---|-------------|-------------------------------------|--------------------------------|
| 1 | defaults    | `$SPACK_ROOT/etc/spack/defaults/`   | Factory settings (don't edit)  |
| 2 | **system**  | `/etc/spack/`                       | Machine-wide, all users        |
| 3 | site        | `$SPACK_ROOT/etc/spack/site/`       | Per-instance settings          |
| 4 | **user**    | `~/.spack/`                         | Per-user settings              |
| 5 | spack       | `$SPACK_ROOT/etc/spack/`            | Top-level instance override    |
| 6 | environment | `spack.yaml`                        | Environment-specific           |
| 7 | command line| `-C` / `--config-scope`             | Highest precedence             |

Higher-precedence scopes override lower ones. This repo provides configs for
scopes **2 (system)** and **4 (user)**.

## How to Deploy

### Project Init Script (Recommended)

If you want to keep the upstream Spack repository unmodified and still use this
repo's `etc/` config with a fast tmp cache, initialize your shell with:

```bash
source /path/to/chapar/etc/init.sh
```

This script:

- sources Spack from `SPACK_ROOT`, the in-repo `spack/`, or `spack` on `PATH`
- sets `SPACK_USER_CONFIG_PATH` to `chapar/etc/user`
- sets `SPACK_SYSTEM_CONFIG_PATH` to `chapar/etc/system`
- defaults `SPACK_USER_CACHE_PATH` to `/tmp/$USER/spack-cache`
- creates the cache directory if it does not exist

### System Scope (all users)

Use a symlink so updates in this repo are picked up immediately (no copy step).
This requires root/admin access since it lives outside any user's home
directory.

```bash
# Default location (recommended)
sudo ln -sfn /path/to/chapar/etc/system /etc/spack

# Custom location
export SPACK_SYSTEM_CONFIG_PATH=/opt/spack/config/system
sudo ln -sfn /path/to/chapar/etc/system "$SPACK_SYSTEM_CONFIG_PATH"
```

On a shared HPC cluster this is typically managed by the sysadmin. All users
who source the same Spack installation will pick up these settings.

### User Scope (single user)

Use a symlink so user-scope updates are always in sync with this repo.

```bash
# Default location
ln -sfn /path/to/chapar/etc/user ~/.spack

# Custom location
export SPACK_USER_CONFIG_PATH=~/my-spack-config
ln -sfn /path/to/chapar/etc/user "$SPACK_USER_CONFIG_PATH"
```

Each user can have their own copy and customize install paths, module roots,
etc. without affecting other users.

### One-Command Linking Helper

From the repo root:

```bash
# Link user scope
bash ./etc/link-scopes.sh --user

# Link system scope (needs sudo)
sudo bash ./etc/link-scopes.sh --system
```

Or link both at once:

```bash
sudo bash ./etc/link-scopes.sh --all
```

When run with `sudo`, the helper links system scope under `/etc/spack` and links
user scope for the original invoking user (`$SUDO_USER`), not root.

### Quick Validation

After deploying, verify the merged configuration:

```bash
# See all active scopes and their paths
spack config scopes -p

# View merged config for any section
spack config get config
spack config get packages
spack config get concretizer

# Trace which scope each setting comes from
spack config blame config
```

## Platform Routing via include.yaml

Each scope has an `include.yaml` that tells Spack to load OS-specific overlays
first, then a Linux fallback overlay, then fall back to `base/`:

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

The OS overlays (`rocky8`, `rocky9`, and `macos`) are selected first when the
`when:` condition matches. The Linux platform fallback is included only when
`platform == "linux"`. The `optional: true` flag means Spack won't error if an
included directory is missing and just skips it.

Because OS and platform overlays appear **above** `base` in the include list,
their settings take precedence over base settings when there are conflicts.
This include layout works the same whether scopes are copied or symlinked.

You can check your current platform with:

```bash
spack arch --platform
```

## Skipper Canary Release Workflow

When `envs/skipper` changes, use an isolated release root first, validate it,
then promote it by switching symlinks. This avoids touching currently deployed
packages during testing.

For Rocky 8/9 overlays in this repo, skipper currently targets `x86_64_v4`.

```bash
# 1) Build canary release in isolated roots
bash envs/skipper/release.sh build 2026-04-21

# 2) Load canary module tree and run validations
bash envs/skipper/release.sh test-hints 2026-04-21

# 3) Promote only after validation succeeds
bash envs/skipper/release.sh promote 2026-04-21 --yes
```

Release layout:

- Install prefixes: `/share/base/releases/<release-id>/bin`
- Modules: `/share/base/releases/<release-id>/modulefiles`
- Active release symlink: `/share/base/current`
- Compatibility links updated on promote:
  `/share/base/bin`, `/share/base/modulefiles`, `/share/base/lmods`

## What Goes Where

| Setting                    | Scope    | Why                                               |
|----------------------------|----------|----------------------------------------------------|
| External packages          | system   | Externals depend on what's installed on the machine |
| Virtual providers          | system   | Org-wide policy (prefer openblas, openmpi, etc.)   |
| Mirrors                    | system   | Shared infrastructure                              |
| Repos                      | system   | Shared package repositories                        |
| Concretizer policy         | system   | Consistent solver behavior across users            |
| build_jobs, ccache         | system   | Machine resources, shared tool availability        |
| environments_root          | system   | Shared environment storage                         |
| install_tree (user paths)  | user     | Each user installs to their own directory          |
| Module roots               | user     | Each user generates modules in their own tree      |
| build_stage, caches        | user     | Per-user temp and cache directories                |

## Linux Packages

The `etc/system/linux/packages.yaml` ships as a skeleton based on a typical
RHEL/Rocky 8 system. After deploying, run `spack external find` on your
actual Linux machine and update the file with accurate versions and paths:

```bash
spack external find --scope system
```

## Environment Variables Reference

| Variable                     | Default         | Purpose                              |
|------------------------------|-----------------|--------------------------------------|
| `SPACK_SYSTEM_CONFIG_PATH`   | `/etc/spack/`   | Override system scope location       |
| `SPACK_USER_CONFIG_PATH`     | `~/.spack/`     | Override user scope location         |
| `SPACK_USER_CACHE_PATH`      | `~/.spack/`     | Override user cache location         |
| `SPACK_DISABLE_LOCAL_CONFIG` | (unset)         | Set to `true` to disable system+user |
