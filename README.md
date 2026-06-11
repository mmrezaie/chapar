# Chapar

Chapar is a reproducible Spack setup for building site-managed HPC software
environments. The current production environment is `hpcsim` on Rocky Linux 9
and Rocky Linux 10.

Each user keeps upstream Spack in `~/.local/opt/spack`, following Spack's
standard source-checkout workflow. Chapar keeps site policy, package choices,
module layout, and environment definitions outside the Spack repository.

## Goals

- Keep each environment policy under `envs/<name>` with a clear `spack.yaml`
  entry point that humans can review without jumping across generated state.
- Prefer Spack-built dependencies over OS-provided libraries and tools.
- Keep only necessary externals for compilers, libc, ccache, and unavoidable
  platform runtime pieces.
- Default local outputs to `~/.spack/chapar`, and require explicit site
  configuration for public roots such as `/resources` or `/shared`.
- Share one configured Spack buildcache and one compiler ccache across home test
  builds and public release builds.

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
|   `-- hpcsim/         # hpcsim spack.yaml, release helper, and site template
|-- containers/         # Packer/Apptainer recipes by env and OS
|-- validation/         # Runtime validation programs and Slurm examples
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

For a shared cluster, copy `envs/hpcsim/hpcsim-site.env.example` to
`envs/hpcsim/hpcsim-site.env` and fill in that local file before building. The
real `hpcsim-site.env` is ignored by Git so datacenter paths, group names, and
security-policy details do not leak between clusters or into development
machines.

Verify the active configuration:

```bash
spack --version
spack config scopes -p
spack arch
spack config blame packages
```

## Building hpcsim

`envs/hpcsim` is the current production Chapar environment. Future environments
should follow the same `envs/<name>/spack.yaml` entry-point convention. Stale
local `envs/skipper*` directories from older workflows are ignored and can be
removed; they are not referenced by the current CI, release helper, or Spack
scopes. The top-level `envs/hpcsim/spack.yaml` contains the hpcsim root specs,
package requirements, and module policy for Rocky 9 and Rocky 10.

For local validation with the active Spack scopes:

```bash
spack -e envs/hpcsim concretize -f
spack -e envs/hpcsim install --only-concrete
```

The release helper performs root-only module refreshes. Do not refresh modules
from every `spack find -c -H` result; that includes dependency-only specs and
can collide with hpcsim's hashless `{name}/{version}` module names.

For home testing or public deployment, use the release helper or Slurm submit
helper. They build packages into the configured install tree and write modules
into a release-specific staging tree:

```bash
bash envs/hpcsim/release.sh build rocky9-20260610
bash envs/hpcsim/release.sh module-use rocky9-20260610
bash envs/hpcsim/release.sh promote rocky9-20260610
```

On the hpcsim Rocky Slurm builders, use the OS-specific sbatch wrapper directly.
The Rocky 9 wrapper contains the default partition set, timestamped release ID,
buildcache publication, module-publication policy, and exclusive-node CPU
detection. It reserves one exclusive node and uses that node's allocated CPU
count for `spack install`:

```bash
sbatch ci/sbatch-hpcsim-release-rocky9.sh
```

The wrapper defaults to `PUBLISH_CURRENT=false` and `PUBLISH_MODULES=true`, so a
successful build updates `${CHAPAR_MODULE_ROOT}/<arch>` without changing
`${HPCSIM_ROOT}/<os>/current`. Command-line `sbatch` options can still override
the wrapper's `#SBATCH` defaults when a site needs a different partition or core
count. The submit helper remains available when you want to choose values on the
command line:

```bash
ci/submit-hpcsim-release.sh \
  --os rocky9 \
  --partition <partition> \
  --publish-current false \
  --publish-modules true
```

Default home release layout:

```text
~/.spack/chapar/envs/hpcsim/<os>/store
~/.spack/chapar/envs/hpcsim/<os>/releases/<release-id>
~/.spack/chapar/envs/hpcsim/<os>/current -> releases/<release-id>
$CHAPAR_BUILDCACHE_ROOT/<os>
$CHAPAR_CCACHE_ROOT/<os>
```

Public sites can keep release metadata under `$HPCSIM_PUBLIC_ROOT/<os>` while
placing package prefixes and promoted module symlinks in shared top-level roots:

```bash
CHAPAR_INSTALL_MODE=public
HPCSIM_PUBLIC_ROOT=/share/base
CHAPAR_INSTALL_TREE_ROOT=
CHAPAR_INSTALL_TREE_PROJECTION=
CHAPAR_MODULE_ROOT=/share/base/modulefiles
```

With an empty `CHAPAR_INSTALL_TREE_ROOT`, package prefixes stay under the padded
per-OS store such as `/share/base/rocky9/store`. Run `publish-modules` to update
`/share/base/modulefiles/linux-rocky9-x86_64_v4` as a symlink to the selected
release's module tree without changing `${HPCSIM_ROOT}/<os>/current`.
The published architecture name comes from the generated release module
directory. A generic Rocky 9 build publishes `linux-rocky9-x86_64_v4`; a
CPU-specific build publishes its concrete target such as `linux-rocky9-zen5`.

Supported OS names are `rocky9` and `rocky10`. The helper auto-detects the OS,
or you can set `OS_NAME` explicitly:

```bash
OS_NAME=rocky9 bash envs/hpcsim/release.sh build rocky9-20260610
```

When `RELEASE_ID` is not set, the hpcsim-specific sbatch wrappers default to
`<os>-YYYYMMDDHHMMSS`, for example `rocky9-20260611172030`. The generic
environment sbatch wrapper defaults to `<env>-<os>-YYYYMMDD`.

## Loading Modules

After `etc/init.sh`, the promoted shared module path is added automatically when
`CHAPAR_MODULE_ROOT` points at a matching `linux-<os>-*` symlink. Otherwise, the
current hpcsim module tree is added when `${HPCSIM_ROOT}/<os>/current` exists. To
print the exact command for a specific release:

```bash
bash envs/hpcsim/release.sh module-use rocky9-20260610
```

The helper resolves the release directory before printing `module use`. That
keeps long-running jobs tied to the release they loaded instead of the mutable
`current` symlink.

hpcsim module names are always `{name}/{version}` with no hash suffixes. Hashes
belong in Spack store prefixes and buildcache records, not in user-facing module
names. If two root specs would produce the same module name, fix the root specs;
dependency-only duplicate concrete specs are excluded from release module
generation.

Release-generated MPI modules adapt to CPU and GPU nodes without changing the
CUDA-aware build. On non-GPU nodes, `openmpi` suppresses harmless CUDA plugin
load warnings, while `intel-oneapi-mpi` and `libfabric` expose a release-local
CUDA driver-stub directory so CPU-only commands can start when the real NVIDIA
driver libraries are absent. On GPU nodes, the modules leave the real NVIDIA
driver path in control. Releases fail before publication if Intel MPI/libfabric
modules are present but the required CUDA driver stubs cannot be generated.

## Safe Deployment Model

New builds must not overwrite active module trees. The release helper builds in
`releases/.<release-id>.staging.<pid>`, then renames that staging tree to
`releases/<release-id>` only after install and module generation succeed.

`publish-modules` updates only the matching architecture symlink below
`CHAPAR_MODULE_ROOT`; use it when users should load modules from a stable shared
module root instead of `${HPCSIM_ROOT}/<os>/current`. `promote` updates the
per-OS `current` symlink and, when `CHAPAR_MODULE_ROOT` is set, the shared module
symlink too. Both commands idempotently ensure generated modulefiles carry the
current MPI runtime policy before updating public pointers. Do not run `spack uninstall`, `spack gc`, or manual cleanup against
the configured install tree while users may still have jobs running from older
releases.

Rollback is switching the public pointer back to an older release. For shared
module roots, republish the module symlink; for `current`-based deployments,
promote the older release:

```bash
# Shared module-root deployments:
bash envs/hpcsim/release.sh publish-modules <previous-release-id>

# current symlink deployments:
bash envs/hpcsim/release.sh promote <previous-release-id>
```

## Buildcache

Buildcache and ccache output are per OS and intentionally live outside the
hpcsim release root:

```text
$CHAPAR_BUILDCACHE_ROOT/rocky9
$CHAPAR_BUILDCACHE_ROOT/rocky10
$CHAPAR_CCACHE_ROOT/rocky9
$CHAPAR_CCACHE_ROOT/rocky10
```

The `chapar-buildcache` mirror is configured in Chapar's Rocky system scopes
with `CHAPAR_BUILDCACHE_ROOT`, not in `envs/hpcsim/spack.yaml`, so hpcsim
releases and ordinary user installs can reuse the same configured cache. The
release helper also exports `CCACHE_DIR=${CHAPAR_CCACHE_ROOT}/<os>` and keeps
`CCACHE_TEMPDIR` job-local.

Release builds add a temporary higher-precedence scope with the same mirror name
and cache location. That scope honors `PUBLISH_BUILDCACHE`, allowing CI to turn
publishing off without changing global read access. Existing binaries are reused
when their concrete hashes match; missing binaries are built from source. When
publishing is enabled, source-built packages are pushed as they complete and the
buildcache index is refreshed on exit so a later rebuild can reuse partial
progress.

Legacy cache migration is explicit, not part of normal release builds. Run
`envs/hpcsim/release.sh migrate-buildcache` once per OS when retiring older
hpcsim cache paths into `${CHAPAR_BUILDCACHE_ROOT}/<os>`. The migration only reads
the selected `HPCSIM_ROOT`'s `<os>/buildcache`; avoid cross-copying caches from
another install root unless their prefixes are known to relocate. It uses a
lock, does not overwrite destination files, does not delete old caches, writes a
completion sentinel, and refreshes the index after migration. Unmarked
pre-padding caches are not migrated by default because they can fail relocation
into the current padded store; unmarked destination payloads are quarantined
before release builds use the cache. See
`docs/buildcache.md` before changing this policy.

Push explicitly only when repairing or backfilling a buildcache outside the
release path:

```bash
ci/push-buildcache.sh --env-path envs/hpcsim --os rocky9
```

## Configuration Model

Chapar uses normal Spack configuration scopes:

- `etc/system`: shared policy for a machine or site.
- `etc/system/base`: common providers, source mirrors, concretizer policy, repos, and
  other shared settings.
- `etc/system/rocky9`, `etc/system/rocky10`: OS-specific bootstrap compiler,
  libc, ccache externals, and the shared buildcache mirror rooted at
  `CHAPAR_BUILDCACHE_ROOT`.
- `etc/user`: per-user paths and optional user-local settings.
- `envs/hpcsim/spack.yaml`: hpcsim root specs, package requirements, and module
  policy.

Both `etc/system/include.yaml` and `etc/user/include.yaml` route to the matching
OS overlay first and then to shared `base` config.

## External Package Policy

Rocky overlays intentionally avoid modeling ordinary link-time libraries such as
OpenSSL, zlib, libpng, curl, OpenBLAS, HDF5, or NetCDF as OS externals. Spack
should build those unless a site-specific external is explicitly modeled with
matching development metadata.

Expected externals are:

- OS/bootstrap compilers.
- `glibc` on Rocky.
- CUDA should be built by Spack for hpcsim GPU packages, not modeled as a host external.
- `ccache` where the platform enables Spack ccache support.

## CI

Rocky builds use existing self-hosted Incus runners with labels `chapar,rocky9`
and `chapar,rocky10`. The workflow matrix can build Rocky 9 and Rocky 10 in parallel
because concurrency is scoped per OS.

Manual workflow inputs include `env_name`, `env_path`, `build_action`,
`build_mode`, `release_id`, `publish_current`, `publish_buildcache`,
`spack_ref`, `spack_install_args`, `env_root`, `buildcache_root`, and
`ccache_root`. The legacy `hpcsim_root` input remains as an alias for hpcsim
jobs when `env_root` is empty.
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
