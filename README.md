# Chapar

Chapar is a reproducible Spack setup for building similar HPC software
environments on macOS, Rocky Linux 8, and Rocky Linux 9.

The repository keeps upstream Spack as a pinned submodule in `spack/` and keeps
all local customization in this repository. Do not edit files under `spack/`
for site policy, user paths, package preferences, module layout, or environment
definitions.

## Goals

- Use the same Spack source checkout for every user and supported OS.
- Keep upstream Spack clean so it can be updated or reset independently.
- Share one environment definition while allowing OS-specific compiler,
  external package, target, and filesystem differences.
- Let users generate their own installs and module trees without modifying the
  shared Spack source.

## Layout

```text
.
|-- spack/              # Upstream Spack source, pinned as a git submodule
|-- etc/
|   |-- init.sh         # Shell initializer for this checkout
|   |-- system/         # Shared Spack system scope and OS overlays
|   |-- user/           # User Spack scope and OS overlays
|   `-- README.md       # Detailed config-scope documentation
|-- envs/
|   `-- skipper/        # Example shared Spack environment
`-- docs/               # Supporting documentation and presentation material
```

## Quick Start

Clone this repository with the pinned Spack submodule:

```bash
git clone --recurse-submodules <chapar-repo-url> chapar
cd chapar
```

If the repository was cloned without submodules, initialize Spack afterward:

```bash
git submodule update --init --recursive
```

Initialize the shell from this checkout:

```bash
export SPACK_ROOT="$PWD/spack"
source ./etc/init.sh
```

The explicit `SPACK_ROOT` makes every user source the same Spack checkout from
this repository, even if another `spack` command exists earlier on `PATH`.

Verify the active configuration:

```bash
spack --version
spack config scopes -p
spack arch
spack config blame config
```

## Building The Shared Environment

Use the shared environment under `envs/skipper`:

```bash
spack -e envs/skipper concretize -f
spack -e envs/skipper install --fail-fast
spack -e envs/skipper module tcl refresh -y
```

The environment has OS overlays:

```text
envs/skipper/rocky8/
envs/skipper/rocky9/
envs/skipper/macos/
```

Those overlays are selected by Spack `when:` rules in `envs/skipper/spack.yaml`.
Use them for platform-specific targets or package constraints only. Keep common
specs, variants, and module policy in the top-level environment file whenever
possible.

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
overlays. Run this on each real machine after initialization to discover local
externals:

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

The goal is similar environments, not byte-identical concrete specs across
different operating systems. The shared Spack source, shared package repo pin,
shared environment specs, and shared policy make the environments comparable;
OS overlays capture unavoidable platform differences.

## Customization Rules

- Do not modify `spack/` for Chapar policy.
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
