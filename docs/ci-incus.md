# Incus hpcsim CI

Chapar builds Rocky Linux hpcsim releases through self-hosted GitHub Actions
runners running in persistent Incus containers. The Rocky8 and Rocky9 runners
keep their existing labels and can run in parallel because workflow concurrency
is scoped per OS.

## Builder Host

Run the Incus containers on a machine that can mount or access the resources
export.

Required host setup:

- `incus` CLI installed and authenticated.
- Rocky8 and Rocky9 builder containers registered as self-hosted GitHub Actions runners.
- The resources export available on the host at `/resources` and mounted into containers as `/resources`.
- Enough local storage and CPU/RAM for the Rocky8/Rocky9 build containers.

Builder package requirements are tracked in
`docs/ci-rocky-builder-dependencies.md`.

## Containers

Default persistent containers:

- `chapar-rocky8-builder`
- `chapar-rocky9-builder`

Register them with these labels:

- `chapar-rocky8-builder`: `chapar,rocky8`
- `chapar-rocky9-builder`: `chapar,rocky9`

The default images are:

- Rocky8: `images:rockylinux/8`
- Rocky9: `images:rockylinux/9`

## Runner Registration

Create a short-lived registration token from GitHub repository Settings,
Actions, Runners, New self-hosted runner. Register both containers from the
Incus control host:

```bash
export GITHUB_RUNNER_TOKEN=<registration-token>
ci/register-incus-runner.sh --container chapar-rocky8-builder
ci/register-incus-runner.sh --container chapar-rocky9-builder
```

The helper installs the GitHub runner under `/opt/actions-runner`, creates an
`actions` user with passwordless sudo, registers the runner, and starts it as a
service.

## Resources Mount

On the Incus host, mount the resources export at `/resources`:

```bash
sudo mkdir -p /resources
sudo mount -t nfs -o vers=4.2 10.151.98.25:/mnt/resources /resources
```

The default CI hpcsim output root is the existing writable CI resources tree:

```text
/resources/chapar/hpcsim
```

For production releases under `/resources/share/hpcsim`, pre-create that NAS
path with suitable ACLs and pass it as the workflow `hpcsim_root` input.

## Manual Workflow

Open GitHub Actions, select `Incus hpcsim Build`, then use `Run workflow`.

Inputs:

- `os`: `all`, `rocky8`, or `rocky9`.
- `release_id`: optional release ID. Empty means the workflow run ID.
- `git_ref`: optional branch, tag, or SHA. Empty means the workflow ref.
- `publish_current`: update `/resources/share/hpcsim/<os>/current` after build.
- `publish_buildcache`: push to `/resources/chapar/cache/<os>`.
- `spack_ref`: Spack branch, tag, or SHA. The default is pinned for cache stability.
- `spack_install_args`: arguments passed to `spack install`, default `-p 1`.
- `runner_label`: common custom runner label, default `chapar`.
- `hpcsim_root`: shared output root, default `/resources/chapar/hpcsim`.
- `buildcache_root`: shared binary cache root, default `/resources/chapar/cache`.

`hpcsim_root` must stay under `/resources/chapar/hpcsim` or
`/resources/share/hpcsim` unless `CHAPAR_ALLOW_UNSAFE_HPCSIM_ROOT=true` is set
for a controlled local test.

`buildcache_root` should stay at `/resources/chapar/cache` on the NAS export.
It is intentionally outside `hpcsim_root` so all hpcsim releases and ad-hoc user
builds share the same binary artifact pool.
Use `CHAPAR_ALLOW_UNSAFE_BUILDCACHE_ROOT=true` only for controlled local tests
that need a nonstandard absolute cache path.

When `os=all`, GitHub schedules independent Rocky8 and Rocky9 matrix jobs. The
job-level concurrency group includes `matrix.os_name`, so Rocky8 and Rocky9 can
build at the same time while repeated jobs for the same OS remain serialized.

## Local Invocation

From a checkout on the Incus control host:

```bash
ci/incus-build.sh --os rocky9 --release-id 2026-05-02
ci/incus-build.sh --os all --release-id 2026-05-02 --publish-current true
ci/incus-build.sh --os rocky9 --release-id smoke --publish-buildcache false
```

Useful overrides:

```bash
CONTAINER_PREFIX=chapar-test ci/incus-build.sh --os rocky9 --release-id smoke
RESOURCES_SOURCE=/mnt/resources ci/incus-build.sh --os all --release-id 2026-05-02
```

## Output Layout

Default CI output:

- `/resources/chapar/hpcsim/rocky8/store`
- `/resources/chapar/hpcsim/rocky8/releases/<release-id>`
- `/resources/chapar/hpcsim/rocky8/current`
- `/resources/chapar/hpcsim/rocky9/store`
- `/resources/chapar/hpcsim/rocky9/releases/<release-id>`
- `/resources/chapar/hpcsim/rocky9/current`
- `/resources/chapar/cache/rocky8`
- `/resources/chapar/cache/rocky9`

Per-run logs and concrete environment files:

- `/resources/chapar/hpcsim/<os>/runs/<run-id>/logs/build.log`
- `/resources/chapar/hpcsim/<os>/runs/<run-id>/commit.txt`
- `/resources/chapar/hpcsim/<os>/runs/<run-id>/spack-version.txt`
- `/resources/chapar/hpcsim/<os>/runs/<run-id>/spack-commit.txt`
- `/resources/chapar/hpcsim/<os>/runs/<run-id>/release-id.txt`
- `/resources/chapar/hpcsim/<os>/runs/<run-id>/concrete-envs/hpcsim.spack.yaml`
- `/resources/chapar/hpcsim/<os>/runs/<run-id>/concrete-envs/hpcsim.spack.lock`

## Build Behavior

Each job bootstraps baseline Rocky RPM packages, updates the checked-out Chapar
repository to the requested ref, sources `./etc/init.sh`, and runs:

```bash
bash envs/hpcsim/release.sh build <release-id>
```

The release helper adds `/resources/chapar/cache/<os>` as the unsigned
`chapar-buildcache` binary mirror before concretization and install. Matching
cached binaries are reused; only missing concrete hashes build from source. When
`publish_buildcache` is true, newly source-built packages are pushed during the
install and the buildcache index is refreshed on exit.

Legacy cache migration is not part of normal builds. Run
`envs/hpcsim/release.sh migrate-buildcache` explicitly when retiring older
`<hpcsim_root>/<os>/buildcache` paths into `/resources/chapar/cache/<os>`. The
explicit migration only considers the selected `HPCSIM_ROOT`; do not cross-copy
caches from another install root unless their prefixes are known to relocate.
Keep this behavior aligned with `docs/buildcache.md`.

Release modules are generated only for explicit hpcsim root specs and are named
`{name}/{version}`. hpcsim module names must not include Spack hashes; if two
root specs would collide, the release helper fails so the roots can be fixed
instead of exposing hashed module names.

CI sets `SPACK_USER_CACHE_PATH` under `/var/tmp/chapar-spack-cache/<os>` so
Spack source, misc, and concretization caches can persist across runs without
using the shared NFS store.

If `publish_current` is true, CI promotes the release after the build completes.
