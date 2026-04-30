# Incus Spack CI

Chapar builds Rocky Linux Spack environments through a manual GitHub Actions workflow that runs directly inside persistent Incus builder containers. Each Rocky builder container is registered with GitHub as a self-hosted runner, so GitHub schedules the job onto the matching container and Spack caches, clones, and package state can be reused between runs.

## Builder Host

Run the Incus containers on the machine that can mount or access the NAS resources export.

Required host setup:

- `incus` CLI installed and authenticated.
- Rocky8 and Rocky9 builder containers registered as self-hosted GitHub Actions runners.
- The NAS resources export available on the host at `/resources` and mounted into the containers as `/resources`.
- Enough local storage and CPU/RAM for the Rocky8/Rocky9 build containers.

Builder package/repository requirements are tracked in `docs/ci-rocky-builder-dependencies.md`.

The workflow targets runners with labels `self-hosted`, `chapar`, and either `rocky8` or `rocky9`. If you use a different common label, set `runner_label` when manually dispatching the workflow.

## Containers

Use these persistent containers by default:

- `chapar-rocky8-builder`
- `chapar-rocky9-builder`

Register them with these custom labels:

- `chapar-rocky8-builder`: `chapar,rocky8`
- `chapar-rocky9-builder`: `chapar,rocky9`

The default images are:

- Rocky8: `images:rockylinux/8`
- Rocky9: `images:rockylinux/9`

Override images when creating containers if needed:

```bash
export ROCKY8_IMAGE=images:rockylinux/8
export ROCKY9_IMAGE=images:rockylinux/9
```

## Runner Registration

Create or copy a short-lived registration token from GitHub repository Settings, Actions, Runners, New self-hosted runner. Then register both Incus containers from the Incus control host:

```bash
export GITHUB_RUNNER_TOKEN=<registration-token>
ci/register-incus-runner.sh --container chapar-rocky8-builder
ci/register-incus-runner.sh --container chapar-rocky9-builder
```

The helper installs the GitHub runner under `/opt/actions-runner`, creates an `actions` user with passwordless sudo, registers the runner, and starts it as a service. Passwordless sudo is required because the workflow bootstraps Rocky RPM dependencies before running Spack.

Verify the runners from GitHub or from the containers:

```bash
incus exec chapar-rocky8-builder -- /opt/actions-runner/svc.sh status
incus exec chapar-rocky9-builder -- /opt/actions-runner/svc.sh status
```

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
- `runner_label`: common custom runner label, default `chapar`.
- `resources_root`: output root inside the container, default `/resources/chapar`.

## Local Invocation

The GitHub workflow runs inside the target container. For local debugging from a checkout on the Incus control host, you can still use the Incus wrapper:

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

Each job runs on the matching Rocky self-hosted runner container, bootstraps baseline Rocky packages with `dnf`, updates the checked-out Chapar repository to the requested ref, sources `./etc/init.sh`, concretizes the selected Spack environment, and installs it.

Target mapping:

- `section=all`: all section environments, then the full integration environment.
- `section=full`: only the full integration environment.
- `section=<name>`: only the named section environment.

When `push_buildcache` is true, the job runs `spack buildcache push --unsigned --update-index` and writes to the matching NAS buildcache directory. For `section=all`, it publishes each section environment and the full integration environment.
