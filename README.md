# Chapar

Chapar is a reproducible Spack setup for building one shared HPC simulation
software environment, `hpcsim`, on macOS, Rocky Linux 8, and Rocky Linux 9.

Each user keeps upstream Spack in `~/.local/opt/spack`, following Spack's
standard source-checkout workflow. Chapar keeps site policy, package choices,
module layout, and environment definitions outside the Spack repository.

## Goals

- Keep one package list in `envs/hpcsim/spack.yaml`.
- Avoid release-tier and package-section environment splits.
- Prefer Spack-built dependencies over OS-provided libraries and tools.
- Keep only necessary externals for compilers, libc, ccache, and unavoidable
  platform runtime pieces.
- Publish shared releases under `/resources/share/hpcsim/<os>` without
  disturbing jobs that already loaded older modules.
- Share one NAS-backed binary buildcache under `/resources/chapar/cache/<os>`
  across hpcsim releases and ad-hoc user installs.

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
|   `-- hpcsim/         # Single shared Spack environment and release helper
`-- docs/               # CI and runner documentation
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

Initialize the shell from this checkout:

```bash
source ./etc/init.sh
```

`etc/init.sh` loads Spack from `~/.local/opt/spack`, binds Spack's system and
user configuration scopes to this Chapar checkout, and adds the current hpcsim
module tree for the detected OS when it exists.

Verify the active configuration:

```bash
spack --version
spack config scopes -p
spack arch
spack config blame packages
```

## Building hpcsim

`envs/hpcsim` is the only supported Chapar environment. Stale local
`envs/skipper*` directories from older workflows are ignored and can be removed;
they are not referenced by the current CI, release helper, or Spack scopes.

For local validation with the active Spack scopes:

```bash
spack -e envs/hpcsim concretize -f
spack -e envs/hpcsim install --only-concrete
```

The release helper performs root-only module refreshes. Do not refresh modules
from every `spack find -c -H` result; that includes dependency-only specs and
can collide with hpcsim's hashless `{name}/{version}` module names.

For shared deployment, use the release helper. It builds packages into a
per-OS shared store and writes modules into a release-specific staging tree:

```bash
bash envs/hpcsim/release.sh build 2026-05-02
bash envs/hpcsim/release.sh module-use 2026-05-02
bash envs/hpcsim/release.sh promote 2026-05-02
```

Default release layout:

```text
/resources/share/hpcsim/<os>/store
/resources/share/hpcsim/<os>/releases/<release-id>
/resources/share/hpcsim/<os>/current -> releases/<release-id>
/resources/chapar/cache/<os>
```

Supported OS names are `rocky8`, `rocky9`, and `macos`. The helper auto-detects
the OS, or you can set `OS_NAME` explicitly:

```bash
OS_NAME=rocky9 bash envs/hpcsim/release.sh build 2026-05-02
```

## Loading Modules

After `etc/init.sh`, the current hpcsim module tree is added automatically when
`/resources/share/hpcsim/<os>/current` exists. To print the exact command for a
specific release:

```bash
bash envs/hpcsim/release.sh module-use 2026-05-02
```

The helper resolves the release directory before printing `module use`. That
keeps long-running jobs tied to the release they loaded instead of the mutable
`current` symlink.

hpcsim module names are always `{name}/{version}` with no hash suffixes. Hashes
belong in Spack store prefixes and buildcache records, not in user-facing module
names. If two root specs would produce the same module name, fix the root specs;
dependency-only duplicate concrete specs are excluded from release module
generation.

## Safe Deployment Model

New builds must not overwrite active module trees. The release helper builds in
`releases/.<release-id>.staging.<pid>`, then renames that staging tree to
`releases/<release-id>` only after install and module generation succeed.

Promotion only updates the per-OS `current` symlink. Do not run `spack uninstall`,
`spack gc`, or manual cleanup against `/resources/share/hpcsim/<os>/store` while
users may still have jobs running from older releases.

Rollback is switching `current` back to an older release:

```bash
bash envs/hpcsim/release.sh promote <previous-release-id>
```

## Buildcache

Buildcache output is per OS and intentionally lives outside the hpcsim release
root:

```text
/resources/chapar/cache/rocky8
/resources/chapar/cache/rocky9
```

The `chapar-buildcache` mirror is configured in Chapar's Rocky system and user
scopes, not in `envs/hpcsim/spack.yaml`, so hpcsim releases and ordinary user
installs reuse the same NAS-backed cache. Rocky user scopes use
`autopush: true`, so successful user builds can populate the shared cache when
NFS permissions allow it.

Release builds add a temporary higher-precedence scope with the same mirror name
and cache location. That scope honors `PUBLISH_BUILDCACHE`, allowing CI to turn
publishing off without changing global read access. Existing binaries are reused
when their concrete hashes match; missing binaries are built from source. When
publishing is enabled, source-built packages are pushed as they complete and the
buildcache index is refreshed on exit so a later rebuild can reuse partial
progress.

Legacy cache migration is explicit, not part of normal release builds. Run
`envs/hpcsim/release.sh migrate-buildcache` once per OS when retiring older
hpcsim cache paths into `/resources/chapar/cache/<os>`. It uses a lock, does not
overwrite destination files, does not delete old caches, writes a completion
sentinel, and refreshes the index after migration. See `docs/buildcache.md`
before changing this policy.

Push explicitly only when repairing or backfilling a buildcache outside the CI
release path:

```bash
ci/push-buildcache.sh --env-path envs/hpcsim --os rocky9
```

## Configuration Model

Chapar uses normal Spack configuration scopes:

- `etc/system`: shared policy for a machine or site.
- `etc/system/base`: common providers, source mirrors, concretizer policy, repos, and
  other shared settings.
- `etc/system/rocky8`, `etc/system/rocky9`, `etc/system/macos`: OS-specific
  bootstrap compiler, libc, and ccache externals. Rocky overlays also attach the
  shared NAS buildcache mirror.
- `etc/user`: per-user paths and optional user-local settings.
- `envs/hpcsim/spack.yaml`: the shared hpcsim package list and module policy.

Both `etc/system/include.yaml` and `etc/user/include.yaml` route to the matching
OS overlay first and then to shared `base` config.

## External Package Policy

Rocky and macOS overlays intentionally avoid modeling ordinary link-time
libraries such as OpenSSL, zlib, libpng, curl, OpenBLAS, HDF5, or NetCDF as OS
externals. Spack should build those unless a site-specific external is explicitly
modeled with matching development metadata.

Expected externals are:

- OS/bootstrap compilers.
- `glibc` on Rocky.
- CUDA should be built by Spack for hpcsim GPU packages, not modeled as a host external.
- Apple Clang and Homebrew GCC/GFortran on macOS.
- `ccache` where the platform enables Spack ccache support.

## CI

Rocky builds use existing self-hosted Incus runners with labels `chapar,rocky8`
and `chapar,rocky9`. The workflow matrix can build Rocky8 and Rocky9 in parallel
because concurrency is scoped per OS.

macOS builds use the existing native macOS self-hosted runner. Docker is not used
for macOS artifacts because it would build Linux binaries.

Manual workflow inputs include `release_id`, `publish_current`,
`publish_buildcache`, `spack_ref`, `spack_install_args`, and `hpcsim_root`.
The default `spack_ref` is pinned to keep concretization and buildcache hashes
stable across rebuilds; override it only when intentionally testing a Spack
update.

## Build Parallelism

Chapar sets Spack's `config:build_jobs` to a high ceiling in
`etc/system/base/config.yaml`. Spack automatically clamps that value to the
number of CPUs available on the host.

Users can still override this for a single command:

```bash
spack -e envs/hpcsim install -j 8
```
