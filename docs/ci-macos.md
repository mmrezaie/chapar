# macOS Spack CI

Chapar builds macOS canary environments on a native macOS self-hosted GitHub Actions runner. Do not use Docker for macOS artifacts: Docker Desktop and Colima run Linux VMs on macOS, so Spack would build Linux binaries, not Darwin/macOS module trees.

## Runner Model

Use a native runner on the macOS host with these labels:

- `self-hosted`
- `chapar`
- `macos`
- `arm64`

The workflow target is `.github/workflows/macos-spack-build.yml`. It builds the `skipper-canary` environments and writes Spack installs/modules through the existing canary location policy:

- `~/privatemodules/skipper-canary/bin`
- `~/privatemodules/skipper-canary/modulefiles`
- `~/privatemodules/skipper-canary/lmods`
- `~/privatemodules/chapar-runs/runs/<run-id>/macos/canary/<section>`
- `~/privatemodules/chapar-runs/buildcache/macos/canary` when buildcache publishing is enabled

The workflow uses a dedicated Spack checkout at `~/.local/opt/spack-chapar-macos` so canary CI can track the requested `spack_ref` without modifying a user's normal `~/.local/opt/spack` checkout.

## Register Runner

Create a short-lived self-hosted runner token from GitHub repository Settings, Actions, Runners, New self-hosted runner. Then run:

```bash
export GITHUB_RUNNER_TOKEN=<registration-token>
ci/register-macos-runner.sh --token "${GITHUB_RUNNER_TOKEN}"
```

The helper downloads the latest GitHub Actions runner for the current macOS architecture, configures it as `chapar-macos-builder`, and starts it as a launchd service.

Verify the service from the runner directory:

```bash
cd ~/actions-runner/chapar
./svc.sh status
```

## Bootstrap

The workflow runs:

```bash
ci/bootstrap-macos.sh
```

The script verifies Xcode command line tools, Homebrew, GCC/GFortran 15, ccache, GNU build tools, environment modules, and creates `~/privatemodules` directories. Missing Homebrew packages are installed idempotently.

For manual setup:

```bash
xcode-select --install
brew install gcc ccache cmake ninja pkgconf autoconf automake libtool bison flex gettext openssl@3 make gawk gnu-sed coreutils diffutils findutils grep rsync texinfo modules
```

## Workflow

Manual dispatch inputs:

- `section`: `full`, `all`, or one section such as `mpi`, `libs`, or `benchmarks`.
- `git_ref`: optional Chapar branch, tag, or SHA.
- `spack_ref`: Spack branch, tag, or SHA. Default is `develop` for canary freshness.
- `push_buildcache`: optional local file buildcache under `~/privatemodules/chapar-runs`.
- `spack_install_args`: default `-p 1 --fail-fast`.
- `resources_root`: run/buildcache root. Empty means `~/privatemodules/chapar-runs`.

The push fallback is path-filtered to `.github/macos-spack-build.trigger` and validates the canary `mpi` section on branch `chapar-goes-macos`.

## Thunderbolt Networking

Stock macOS does not expose Linux verbs/RDMA-CM devices for Thunderbolt Bridge. In practice, Thunderbolt Bridge is an IP interface, so MPI should use TCP over that interface rather than true RDMA verbs.

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

If you use OpenMPI's TCP BTL path instead of OFI, select the Thunderbolt interface explicitly:

```bash
export OMPI_MCA_pml=ob1
export OMPI_MCA_btl=self,tcp
export OMPI_MCA_btl_tcp_if_include=<thunderbolt-interface>
```

True RDMA validation still requires a platform that exposes a supported RDMA stack to user space. The macOS CI validates buildability and high-speed IP MPI readiness, not Linux-style InfiniBand/RoCE verbs behavior.
