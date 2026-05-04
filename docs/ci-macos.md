# macOS hpcsim CI

Chapar builds macOS hpcsim releases on a native macOS self-hosted GitHub Actions
runner. Do not use Docker for macOS artifacts: Docker Desktop and Colima run
Linux VMs on macOS, so Spack would build Linux binaries.

## Runner Model

Use a native runner on the macOS host with these labels:

- `self-hosted`
- `chapar`
- `macos`
- `arm64`

The workflow target is `.github/workflows/macos-spack-build.yml`. It builds
`envs/hpcsim` and writes releases under the workflow `hpcsim_root` input. When
that input is empty, the macOS runner uses a writable user-local default:

```text
~/resources/share/hpcsim/macos
```

The workflow uses a dedicated Spack checkout at
`~/.local/opt/spack-chapar-macos` so CI can track the requested `spack_ref`
without modifying a user's normal `~/.local/opt/spack` checkout.

## Register Runner

Create a short-lived self-hosted runner token from GitHub repository Settings,
Actions, Runners, New self-hosted runner. Then run:

```bash
export GITHUB_RUNNER_TOKEN=<registration-token>
ci/register-macos-runner.sh --token "${GITHUB_RUNNER_TOKEN}"
```

The helper downloads the latest GitHub Actions runner for the current macOS
architecture, configures it as `chapar-macos-builder`, and starts it as a
launchd service.

## Bootstrap

The workflow runs:

```bash
ci/bootstrap-macos.sh
```

The script verifies Xcode command line tools, Homebrew, GCC/GFortran 15,
ccache, GNU build tools, environment modules, and supporting build utilities.
Missing Homebrew packages are installed idempotently.

Manual setup:

```bash
xcode-select --install
brew install gcc ccache cmake ninja pkgconf autoconf automake libtool m4 bison flex gettext openssl@3 python@3.12 make gawk gnu-sed coreutils diffutils findutils grep rsync texinfo modules
```

## Workflow

Manual dispatch inputs:

- `release_id`: optional release ID. Empty means the workflow run ID.
- `git_ref`: optional Chapar branch, tag, or SHA.
- `spack_ref`: Spack branch, tag, or SHA.
- `publish_current`: update `/resources/share/hpcsim/macos/current` after build.
- `publish_buildcache`: push to `/resources/share/hpcsim/macos/buildcache`.
- `spack_install_args`: arguments passed to `spack install`, default `-p 1`.
- `hpcsim_root`: shared output root. Empty means `~/resources/share/hpcsim`.

The push fallback is path-filtered to hpcsim environment, CI, workflow, and
configuration files.

## Output Layout

- `<hpcsim_root>/macos/store`
- `<hpcsim_root>/macos/releases/<release-id>`
- `<hpcsim_root>/macos/current`
- `<hpcsim_root>/macos/buildcache`
- `<hpcsim_root>/macos/runs/<run-id>`

The release helper adds `<hpcsim_root>/macos/buildcache` as an unsigned binary
mirror before concretization and install. Matching cached binaries are reused;
only missing concrete hashes build from source.

## Thunderbolt Networking

Stock macOS does not expose Linux verbs/RDMA-CM devices for Thunderbolt Bridge.
In practice, Thunderbolt Bridge is an IP interface, so MPI should use TCP over
that interface rather than true RDMA verbs.

Chapar macOS MPI policy uses OpenMPI with libfabric/OFI TCP providers:

```text
libfabric fabrics=tcp,sockets,udp
openmpi fabrics=ofi schedulers=none
```

Runtime examples for Thunderbolt Bridge:

```bash
networksetup -listallhardwareports
export FI_PROVIDER=tcp
export OMPI_MCA_pml=cm
export OMPI_MCA_mtl=ofi
mpirun -np 2 ./osu_latency
```

True RDMA validation still requires a platform that exposes a supported RDMA
stack to user space. The macOS CI validates buildability and high-speed IP MPI
readiness, not Linux-style InfiniBand/RoCE verbs behavior.
