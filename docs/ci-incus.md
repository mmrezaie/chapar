# Incus Spack CI

Chapar builds Rocky Linux Spack environments through a manual GitHub Actions workflow that controls persistent Incus builder containers. The containers are stopped after each job by default, but are not deleted, so Spack source caches, clones, and package state can be reused.

## Builder Host

Run the GitHub Actions self-hosted runner on the machine that can control Incus and mount or access the NAS resources export.

Required host setup:

- `incus` CLI installed and authenticated.
- A self-hosted GitHub Actions runner registered for this repository.
- The NAS resources export available on the host at `/resources`, or another path passed as `resources_source`.
- Enough local storage and CPU/RAM for the Rocky8/Rocky9 build containers.

Builder package/repository requirements are tracked in `docs/ci-rocky-builder-dependencies.md`.

The workflow defaults to `runs-on: self-hosted`. If your runner uses another label, set `runner_label` when manually dispatching the workflow.

## Containers

The wrapper uses these persistent containers by default:

- `chapar-rocky8-builder`
- `chapar-rocky9-builder`

The default images are:

- Rocky8: `images:rockylinux/8`
- Rocky9: `images:rockylinux/9`

Override images from the runner environment if needed:

```bash
export ROCKY8_IMAGE=images:rockylinux/8
export ROCKY9_IMAGE=images:rockylinux/9
```

If the Incus server is remote, pass its remote name through the workflow `incus_remote` input or local `--incus-remote` option.

## Resources Mount

On `kraken`, the NAS VM exports `/mnt/resources`. The current host-side CI mount is:

```bash
sudo mkdir -p /resources
sudo mount -t nfs -o vers=4.2 10.151.98.25:/mnt/resources /resources
```

The Rocky builder containers are unprivileged Incus containers. Their root user maps to host UID/GID `100000`, so the CI output directory must be writable by that mapped identity:

```bash
mkdir -p /resources/chapar
incus exec nas -- chown 100000:1003 /mnt/resources/chapar
incus exec nas -- chmod 2775 /mnt/resources/chapar
```

Verify from the host and containers:

```bash
findmnt /resources
incus exec chapar-rocky9-builder -- touch /resources/chapar/.write-test
incus exec chapar-rocky9-builder -- rm -f /resources/chapar/.write-test
```

## Manual Workflow

Open GitHub Actions, select `Incus Spack Build`, then use `Run workflow`.

Inputs:

- `os`: `rocky9`, `rocky8`, or `all`.
- `flavor`: `canary` or `prod`.
- `section`: `all`, `full`, or one section environment.
- `git_ref`: optional branch, tag, or SHA. Empty means the workflow branch/tag.
- `push_buildcache`: publish successful outputs to the NAS buildcache.
- `spack_install_args`: arguments passed to `spack install`, default `-p 1 --fail-fast`.
- `keep_running`: leave the builder container running after the job.
- `runner_label`: self-hosted runner label, default `self-hosted`.
- `incus_remote`: optional Incus remote name.
- `resources_source`: host path mounted into the container as `/resources`.
- `resources_root`: output root inside the container, default `/resources/chapar`.

## Local Invocation

From a checkout on the Incus control host:

```bash
ci/incus-build.sh --os rocky9 --flavor canary --section all
ci/incus-build.sh --os rocky9 --flavor canary --section gpu --push-buildcache false
ci/incus-build.sh --os all --flavor prod --section full --incus-remote my-incus
```

Useful overrides:

```bash
CONTAINER_PREFIX=chapar-test ci/incus-build.sh --os rocky9 --flavor canary --section toolchain
RESOURCES_SOURCE=/mnt/resources ci/incus-build.sh --os rocky9 --flavor canary --section all
```

## Output Layout

The default output root is `/resources/chapar` inside the container.

Buildcache destinations:

- `/resources/chapar/buildcache/rocky8/canary`
- `/resources/chapar/buildcache/rocky8/prod`
- `/resources/chapar/buildcache/rocky9/canary`
- `/resources/chapar/buildcache/rocky9/prod`

Per-run logs and concrete environment files:

- `/resources/chapar/runs/<run-id>/<os>/<flavor>/<section>/logs/build.log`
- `/resources/chapar/runs/<run-id>/<os>/<flavor>/<section>/commit.txt`
- `/resources/chapar/runs/<run-id>/<os>/<flavor>/<section>/spack-version.txt`
- `/resources/chapar/runs/<run-id>/<os>/<flavor>/<section>/concrete-envs/*.spack.yaml`
- `/resources/chapar/runs/<run-id>/<os>/<flavor>/<section>/concrete-envs/*.spack.lock`

## Build Behavior

Each job copies the current CI scripts into the selected container, bootstraps baseline Rocky packages with `dnf`, clones or updates the Chapar repository in `/root/workspace/chapar`, checks out the requested ref, sources `./etc/init.sh`, then runs the matching Make target.

Target mapping:

- `section=all`: `make canary` or `make prod`.
- `section=full`: `make canary-full` or `make prod-full`.
- `section=<name>`: `make canary-<name>` or `make prod-<name>`.

When `push_buildcache` is true, the job runs `spack buildcache push --unsigned --update-index` and writes to the matching NAS buildcache directory. For `section=all`, it publishes each section environment and the full integration environment.
