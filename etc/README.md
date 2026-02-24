# Chapar Spack Configuration

Spack configuration split into **system** and **user** scopes, each supporting
**Linux** and **macOS** via `include.yaml` platform routing (Spack >= v1.0).

## Directory Layout

```
etc/
├── system/                 # System scope — shared by ALL users on the machine
│   ├── include.yaml        # Routes to ${platform}/ then base/
│   ├── base/               # Cross-platform settings
│   │   ├── concretizer.yaml
│   │   ├── config.yaml     # System-level config (build_jobs, ccache, environments_root, …)
│   │   ├── mirrors.yaml
│   │   ├── packages.yaml   # Virtual providers, permissions (no externals here)
│   │   └── repos.yaml
│   ├── darwin/             # macOS-only externals
│   │   └── packages.yaml
│   └── linux/              # Linux-only externals
│       └── packages.yaml
│
└── user/                   # User scope — per-user settings
    ├── include.yaml        # Routes to ${platform}/ then base/
    ├── base/               # Cross-platform user settings
    │   ├── config.yaml     # install_tree, template_dirs, build_stage, …
    │   └── modules.yaml    # Module generation (tcl/lmod roots, naming)
    ├── darwin/             # macOS user overrides (add files as needed)
    └── linux/              # Linux user overrides (add files as needed)
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

### System Scope (all users)

Copy or symlink `etc/system/` contents to the system config path. This
requires root/admin access since it lives outside any user's home directory.

```bash
# Default location
sudo cp -r etc/system/* /etc/spack/

# Or use a custom path and export the variable in your shell profile
export SPACK_SYSTEM_CONFIG_PATH=/opt/spack/config/system
sudo cp -r etc/system/* "$SPACK_SYSTEM_CONFIG_PATH"/
```

On a shared HPC cluster this is typically managed by the sysadmin. All users
who source the same Spack installation will pick up these settings.

### User Scope (single user)

Copy or symlink `etc/user/` contents to your personal Spack config directory.

```bash
# Default location
cp -r etc/user/* ~/.spack/

# Or use a custom path
export SPACK_USER_CONFIG_PATH=~/my-spack-config
cp -r etc/user/* "$SPACK_USER_CONFIG_PATH"/
```

Each user can have their own copy and customize install paths, module roots,
etc. without affecting other users.

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

Each scope has an `include.yaml` that tells Spack to load platform-specific
overrides first, then fall back to `base/`:

```yaml
include:
- path: "${platform}"
  optional: true
- path: base
```

`${platform}` resolves to `darwin` on macOS and `linux` on Linux. The
`optional: true` flag means Spack won't error if the platform directory is
missing — it just skips it.

Because `${platform}` appears **above** `base` in the include list, platform
settings take precedence over base settings when there are conflicts.

You can check your current platform with:

```bash
spack arch --platform
```

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
