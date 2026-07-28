# Incus Chapar Environment CI

Chapar builds Spack environments through self-hosted GitHub Actions runners
running in persistent Incus containers. The current production matrix covers
Rocky 9 and Rocky 10 for `hpcsim`, but the CI entrypoints accept `ENV_NAME` and
`ENV_PATH` so future environments can use the same concretize/build path.

## Builder Host

Run the Incus containers on a machine that can mount or access the resources
export.

Required host setup:

- `incus` CLI installed and authenticated.
- Builder containers registered as self-hosted GitHub Actions runners for each supported OS.
- The resources export available on the host at `/resources` and mounted into containers as `/resources`.
- Enough local storage and CPU/RAM for the Rocky 9/Rocky 10 build containers.

Builder package requirements are tracked in
`docs/ci-rocky-builder-dependencies.md`.

## Containers

Default persistent containers:

- `chapar-rocky9-builder`
- `chapar-rocky10-builder`

Register them with these labels:

- `chapar-rocky9-builder`: `chapar,rocky9`
- `chapar-rocky10-builder`: `chapar,rocky10`

The current default images are:

- Rocky9: `images:rockylinux/9`
- Rocky10: `images:rockylinux/10`

`ci/incus-build.sh` also has explicit image hooks for future Ubuntu and AlmaLinux
builders. Add matching bootstrap scripts and runner labels before enabling those
OS names in the GitHub Actions matrix.

## Runner Registration

Create a short-lived registration token from GitHub repository Settings,
Actions, Runners, New self-hosted runner. Register both containers from the
Incus control host:

```bash
export GITHUB_RUNNER_TOKEN=<registration-token>
ci/register-incus-runner.sh --container chapar-rocky9-builder
ci/register-incus-runner.sh --container chapar-rocky10-builder
```

The helper installs the GitHub runner under `/opt/actions-runner`, creates an
`actions` user with passwordless sudo, registers the runner, and starts it as a
service.

## Per-Environment Workflow Files

The CI is split into three workflow files:

- **`incus-spack-build.yml`** &mdash; the reusable engine. It declares a
  `workflow_call` trigger and defines the actual build strategy and steps. No
  environment-specific logic; callers pass `env_name`, `env_path`, and all
  inputs.
- **`incus-spack-build-hpcsim.yml`** &mdash; caller for the `hpcsim`
  environment. Push-triggered only on `envs/hpcsim/**` and related CI paths.
- **`incus-spack-build-vlad.yml`** &mdash; caller for the `vlad` environment.
  Push-triggered only on `envs/vlad/**`.

To run a manual build, open the GitHub Actions tab, select the specific
environment's workflow (e.g. "Incus Chapar Environment Build (hpcsim)"), and
click `Run workflow`.

## Resources Mount

On the Incus host, mount the resources export at `/resources`:

```bash
sudo mkdir -p /resources
sudo mount -t nfs -o vers=4.2 <nfs-server>:/<export-path> /resources
```

The default CI environment output root is the workflow `env_root` input. For
hpcsim, the legacy `hpcsim_root` input remains an alias when `env_root` is empty.
The current Incus builders use this writable resources tree by default for
hpcsim:

```text
/resources/chapar/hpcsim
```

For production releases, pre-create the site NAS path with suitable ACLs and
pass it as the workflow `env_root` input, or prefer `ci/submit-env-build.sh` on
the target Slurm cluster. hpcsim release builds still use the ignored
`envs/hpcsim/hpcsim-site.env` site file when release mode is selected.

## Manual Workflow

Open GitHub Actions, select `Incus Chapar Environment Build`, then use
`Run workflow`.

Inputs:

- `os`: `all`, `rocky9`, or `rocky10`.
- `env_name`: environment name, default `hpcsim`.
- `env_path`: Spack environment path. Empty means `envs/<env_name>`.
- `build_action`: `concretize` or `build`.
- `build_mode`: `auto`, `release`, or `spack`. `auto` uses `release.sh` when the selected environment has one and the action is `build`; otherwise it uses direct Spack commands.
- `release_id`: optional release ID. Empty means the workflow run ID.
- `git_ref`: optional branch, tag, or SHA. Empty means the workflow ref.
- `publish_current`: promote after release-mode builds, updating the current symlink and any configured shared module symlink.
- `publish_modules`: update only the configured shared module symlink after release-mode builds.
- `publish_buildcache`: push to `<buildcache_root>/<os>`.
- `spack_ref`: Spack branch, tag, or SHA. The default is pinned for cache stability.
- `spack_install_args`: arguments passed to `spack install`, default `-j 8 -p 4`.
  `-j 8` allows 8 total compile jobs via the POSIX jobserver (shared across
  concurrently building packages). `-p 4` allows at most 4 packages to build at
  once. The builder has 28 CPUs, so this is a balanced setting.
- `runner_label`: common custom runner label, default `chapar`.
- `env_root`: shared output root. Empty means `/resources/chapar/<env_name>`.
- `hpcsim_root`: legacy hpcsim output-root alias used only when `env_root` is empty.
- `install_tree_root`: shared cross-environment install tree root, default
  `/resources/chapar/install` (one tree per OS+arch across all environments).
- `buildcache_root`: shared binary cache root, default `/resources/chapar/buildcache`
  (one cache per OS across all environments).
- `ccache_root`: shared compiler ccache root, default `/resources/chapar/cache/ccache`.

`buildcache_root` and `ccache_root` should stay outside environment output roots
so test builds and public release builds at the same site share artifact caches
without coupling them to a mutable release tree.

All per-environment caller workflows share `concurrency.group:
chapar-incus-builders` with `cancel-in-progress: false`. This means only one
build runs at a time across all environments on the self-hosted runner. If a
build is in progress and another workflow is triggered, the new one queues and
waits for the running build to finish before starting.

## Local Invocation

From a checkout on the Incus control host:

```bash
ci/incus-build.sh --os rocky9 --release-id 2026-05-02
ci/incus-build.sh --os all --release-id 2026-05-02 --publish-current true
ci/incus-build.sh --os rocky9 --release-id smoke --publish-buildcache false
ci/incus-build.sh --env-name hpcsim --os rocky9 --build-action concretize --build-mode spack
```

Useful overrides:

```bash
CONTAINER_PREFIX=chapar-test ci/incus-build.sh --os rocky9 --release-id smoke
RESOURCES_SOURCE=/mnt/resources ci/incus-build.sh --os all --release-id 2026-05-02
CHAPAR_ENV_ROOT=/resources/chapar/myenv ci/incus-build.sh --env-name myenv --env-path envs/myenv --os rocky9 --build-mode spack
```

## Output Layout

Default hpcsim CI output:

- `/resources/chapar/hpcsim/rocky9/store`
- `/resources/chapar/hpcsim/rocky9/<arch>/releases/<release-id>`
- `/resources/chapar/hpcsim/rocky9/<arch>/current`
- `/resources/chapar/hpcsim/rocky9/<arch>/modulefiles`
- `/resources/chapar/hpcsim/rocky10/store`
- `/resources/chapar/hpcsim/rocky10/<arch>/releases/<release-id>`
- `/resources/chapar/hpcsim/rocky10/<arch>/current`
- `/resources/chapar/hpcsim/rocky10/<arch>/modulefiles`
- `/resources/chapar/install/linux-<os>-<arch>` (shared install tree, when configured)
- `/resources/chapar/buildcache/rocky9`
- `/resources/chapar/buildcache/rocky10`
- `/resources/chapar/cache/ccache/rocky9`
- `/resources/chapar/cache/ccache/rocky10`

Per-run logs and concrete environment files:

- `<env_root>/<os>/runs/<run-id>/logs/build.log`
- `<env_root>/<os>/runs/<run-id>/commit.txt`
- `<env_root>/<os>/runs/<run-id>/spack-version.txt`
- `<env_root>/<os>/runs/<run-id>/spack-commit.txt`
- `<env_root>/<os>/runs/<run-id>/release-id.txt`
- `<env_root>/<os>/runs/<run-id>/concrete-envs/<env_name>.spack.yaml`
- `<env_root>/<os>/runs/<run-id>/concrete-envs/<env_name>/`
- `<env_root>/<os>/runs/<run-id>/concrete-envs/<env_name>.spack.lock`

## Build Behavior

Each job bootstraps baseline OS packages, updates the checked-out Chapar
repository to the requested ref, sources `./etc/init.sh`, and either runs direct
Spack commands:

```bash
spack -e <env_path> concretize -f
spack -e <env_path> install <spack_install_args>
```

or, for release-mode environments such as hpcsim, runs:

```bash
bash envs/hpcsim/release.sh build <release-id>
```

The hpcsim release helper adds `<buildcache_root>/<os>` as the unsigned
`chapar-buildcache` binary mirror before concretization and install. After
`spack install` completes, each environment's `release.sh` runs an explicit
`spack buildcache push --unsigned --update-index` against that mirror. This
guarantees all newly built binaries are pushed to the shared cache and the
index is refreshed. A subsequent run automatically reuses them through Spack's
default `--use-buildcache package:auto,dependencies:auto`. This was verified by
a real two-run proof: the first run populated the binary cache, and the second
extracted those cached binaries instead of rebuilding from source. The release
helper also exports `CCACHE_DIR=<ccache_root>/<os>` and keeps `CCACHE_TEMPDIR`
local to the job.

If a previous run populated the cache but exited before writing an index, the
release helper refreshes the index before concretization. CI also sets
`CHAPAR_CONCRETIZE_TIMEOUT=3600` so a solver stall fails in the build step
instead of consuming the full 24-hour workflow timeout. The release helper raises
that guardrail to at least 3 hours for Rocky 9 and Rocky 10 because the Rocky
solves are larger than the generic CI default.

Legacy cache migration is not part of normal builds. Run
`envs/hpcsim/release.sh migrate-buildcache` explicitly when retiring older
`<hpcsim_root>/<os>/buildcache` paths into `<buildcache_root>/<os>`. The
explicit migration only considers the selected `HPCSIM_ROOT`; do not cross-copy
caches from another install root unless their prefixes are known to relocate.
Unmarked pre-padding caches are rejected by migration and quarantined from the
destination before release builds use the cache. Keep this behavior aligned with
`docs/buildcache.md`.

Release modules are generated only for explicit hpcsim root specs and are named
`{name}/{version}`. hpcsim module names must not include Spack hashes; if two
root specs would collide, the release helper fails so the roots can be fixed
instead of exposing hashed module names.

CI sets `SPACK_USER_CACHE_PATH` under `/var/tmp/chapar-spack-cache/<os>` so
Spack source, misc, and concretization caches can persist across runs without
using the shared NFS store.

If `publish_current` is true, CI promotes the release after the build completes.
When `publish_current` is false and `publish_modules` is true, CI runs
`publish-modules` instead so a shared module root can advance without changing
the per-OS `current` symlink.
