# Chapar

Chapar is a reproducible Spack setup for building similar HPC software
environments on macOS, Rocky Linux 8, and Rocky Linux 9.

Each user keeps upstream Spack in `~/.local/opt/spack`, following Spack's
standard source-checkout workflow. Chapar does not vendor Spack. It keeps all
site policy, user paths, package preferences, module layout, and environment
definitions outside the Spack repository.

## Goals

- Use the same per-user Spack install path on every supported OS.
- Keep upstream Spack clean so it can be updated independently.
- Share one environment definition while allowing OS-specific compiler,
  external package, target, and filesystem differences.
- Let users generate their own installs and module trees without modifying the
  upstream Spack checkout.

## Layout

```text
.
|-- etc/
|   |-- install-spack.sh # Installs upstream Spack under ~/.local/opt/spack
|   |-- init.sh         # Shell initializer for this checkout
|   |-- system/         # Shared Spack system scope and OS overlays
|   |-- user/           # User Spack scope and OS overlays
|   `-- README.md       # Detailed config-scope documentation
|-- envs/
|   `-- skipper/        # Example shared Spack environment
`-- docs/               # Supporting documentation and presentation material
```

## Quick Start

Clone this repository:

```bash
git clone <chapar-repo-url> chapar
cd chapar
```

Install upstream Spack once for the current user if it is not already present:

```bash
bash ./etc/install-spack.sh
```

Then initialize the shell from this checkout:

```bash
source ./etc/init.sh
```

`etc/init.sh` loads Spack from `~/.local/opt/spack` and binds Spack's system and
user configuration scopes to this Chapar checkout. It does not modify the Spack
checkout.

Verify the active configuration:

```bash
spack --version
spack config scopes -p
spack arch
spack config blame config
```

## Compiler Discovery

Before concretizing on a new machine, confirm which compiler the OS actually
provides. On RPM-based Linux systems such as Fedora and Rocky, install and
check the system compiler packages first:

```bash
sudo dnf install gcc gcc-c++ gcc-gfortran
rpm -q gcc gcc-c++ gcc-gfortran
gcc -dumpfullversion -dumpversion
g++ -dumpfullversion -dumpversion
gfortran -dumpfullversion -dumpversion || true
```

Then let Spack record the detected compiler in the user scope:

```bash
spack compiler find --scope user /usr/bin
spack external find --scope user gcc
spack config blame packages
```

This is especially important on non-Rocky Linux systems such as Fedora. Fedora
44 does not provide Rocky 8's `gcc@8.5.0`, so it should rely on discovered
user-scope compiler entries or a Fedora-specific overlay instead of the Rocky
8/Rocky 9 system overlays.

## Building The Shared Environment

Use the Rocky Linux production environment under `envs/skipper`:

```bash
spack -e envs/skipper concretize -f
spack -e envs/skipper install
spack -e envs/skipper module tcl refresh -y
```

`skipper` is intended for Rocky Linux 8 and Rocky Linux 9 production builds and
keeps its install and module roots under `/share/base`.

For canary builds, use `envs/skipper-canary`. It keeps the same package specs
but loads install roots, module roots, build stages, and cache locations from
`envs/skipper-canary/locations.yaml`:

```bash
spack -e envs/skipper-canary concretize -f
spack -e envs/skipper-canary install
spack -e envs/skipper-canary module tcl refresh -y
```

## Long-Term Buildcache

Active builds should use the local tmpfs/user cache paths for performance. On
systems where `/share/base` is slow, do not keep `/share/base/buildcache` in the
default mirror list; otherwise every install can spend time checking or reading
large binary tarballs over the slow mount.

After a successful build, push binaries explicitly for long-term reuse:

```bash
mkdir -p /share/base/buildcache
spack -e envs/skipper-canary buildcache push --unsigned --update-index file:///share/base/buildcache
```

When you want to consume that archive explicitly, add it as a user-scope binary
mirror for that session or user:

```bash
spack mirror add --scope user --type binary --unsigned shared-buildcache file:///share/base/buildcache
spack -e envs/skipper-canary install --use-buildcache=auto
```

Remove it from the hot path when you are done using the slow archive:

```bash
spack mirror remove --scope user shared-buildcache
```

Both environments have OS overlays:

```text
envs/skipper/rocky8/
envs/skipper/rocky9/
envs/skipper-canary/rocky8/
envs/skipper-canary/rocky9/
envs/skipper-canary/macos/
```

Those overlays are selected by Spack `when:` rules in each environment's
`spack.yaml`. Use them for platform-specific targets or package constraints
only. Keep common specs, variants, and module policy in the top-level
environment file whenever possible.

## Configuration Model

Chapar uses normal Spack configuration scopes:

- `etc/system`: shared policy for a machine or site.
- `etc/system/base`: common providers, mirrors, concretizer policy, repos, and
  other shared settings.
- `etc/system/rocky8`, `etc/system/rocky9`, `etc/system/macos`: OS-specific
  externals and compiler definitions.
- `etc/user`: per-user install roots, module roots, caches, and build stages.
- `envs/skipper`: environment-level specs and release-specific settings.

Both `etc/system/include.yaml` and `etc/user/include.yaml` route to the matching
OS overlay first and then to shared `base` config.

## OS Notes

Rocky Linux 8 and Rocky Linux 9 should keep system-provided packages such as
`glibc`, system compilers, and basic build tools in their own `packages.yaml`
overlays. Rocky 8 uses system GCC `8.5.0`; Rocky 9 uses system GCC 11, commonly
`11.5.0` on current Rocky 9 point releases. Run this on each real machine after
initialization to discover local externals:

```bash
spack external find --scope system
```

macOS should keep Apple Clang, Homebrew GCC, SDK-provided libraries, and
Homebrew tools in the macOS overlay. Users should install command line tools
and any expected Homebrew dependencies before concretizing:

```bash
xcode-select --install
brew install gcc ccache
```

Native macOS GitHub Actions runners are documented in `docs/ci-macos.md`.
Docker on macOS builds Linux artifacts, so use a native runner for Darwin module
trees under `~/privatemodules`.

The goal is similar environments, not byte-identical concrete specs across
different operating systems. The shared package repo pin, shared environment
specs, and shared policy make the environments comparable; OS overlays capture
unavoidable platform differences.

## Build Parallelism

Chapar sets Spack's `config:build_jobs` to a high ceiling in
`etc/system/base/config.yaml`. Spack automatically clamps that value to the
number of CPUs available on the host, including CPU affinity limits when
supported, so package builds use all available cores by default.

Users can still override this for a single command:

```bash
spack -e envs/skipper install -j 8
```

## Customization Rules

- Do not modify `~/.local/opt/spack` for Chapar policy.
- Put shared machine or site settings in `etc/system`.
- Put user paths and user-local settings in `etc/user`.
- Put environment package lists in `envs/<name>/spack.yaml`.
- Put OS-specific differences in `rocky8`, `rocky9`, or `macos` overlays.
- Prefer adding a new overlay or config file over patching upstream Spack.

## Shared Deployment

For a shared cluster, an administrator can link the system scope:

```bash
sudo ln -sfn /path/to/chapar/etc/system /etc/spack
```

Individual users can link the user scope:

```bash
ln -sfn /path/to/chapar/etc/user ~/.spack
```

For development or isolated testing, sourcing `etc/init.sh` is usually simpler
because it binds both scopes to this checkout without requiring installation
under `/etc`.

## Release Workflow

The `envs/skipper/release.sh` helper builds canary releases into isolated roots,
then promotes them by updating symlinks after validation:

```bash
bash envs/skipper/release.sh build 2026-04-24
bash envs/skipper/release.sh test-hints 2026-04-24
bash envs/skipper/release.sh promote 2026-04-24 --yes
```

See `etc/README.md` for detailed scope precedence, deployment options, and
validation commands.
