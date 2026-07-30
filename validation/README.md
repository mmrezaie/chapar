# Validation

This directory contains runtime validation tests for HPC/AI clusters running Chapar-built software environments. Tests validate hardware, interconnects, MPI/NCCL transports, I/O, profilers, and ML frameworks on real cluster hardware.

## Quick Start

```bash
# List all available tests
./validation/run list

# Run a single test
./validation/run node-smoke

# Run all tests
./validation/run all

# Select one capability profile tier from a validated site profile
./validation/run --profile capability --site-profile validation/config/cluster-site.yaml

# Inspect a CPU-only developer profile without submitting Slurm work
CHAPAR_DRY_RUN=1 ./validation/run --profile capability \
  --site-profile validation/fixtures/profiles/cpu-only-developer.yaml

# See options
./validation/run --help
```

Tests submit Slurm batch jobs by default. If already inside a Slurm allocation, they run inline.

## Available Tests

### Hardware Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `node-smoke` | Memory bandwidth (likwid), GPU P2P (nvbandwidth), PAPI counters, cuda-memtest, hwloc/lscpu topology | 1 | 1 | 15m |
| `cpu-platform` | CPU vendor, ISA/features, NUMA/PCI inventory, `.chapar-arch`, and ELF ISA compatibility | 1 | — | 3m |
| `slurm-placement` | Allocation-only CPU count and `srun --cpu-bind` placement evidence | 1 | — | 3m |
| `gpu-stress` | Per-GPU cuda-memtest and optional gpu-burn (8h) | 1 | 1 | 8h |
| `gpu-topology` | Profile-selected NVIDIA inventory, NVLink/NVSwitch topology, and error evidence | 1 | all | 5m |
| `nvlink-p2p` | Full-GPU CUDA P2P, NVLink counter deltas, and batch-visible Fabric Manager state | 1 | all | 10m |
| `hpc-challenge` | HPL, HPCG, STREAM, BabelStream benchmarks | 1 | — | 4h |

### Node Health Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `gemm-pulse` | Repeated GPU GEMM; flags throttling/fail-slow via coefficient of variation | 1 | 1 | 5m |
| `ib-link-check` | Validates IB HCA count, link state, width, speed against `config/network.yaml` | 1 | — | 2m |
| `rdma-link-check` | Profile-selected HCA model, firmware, PCI/netdev, link, addressing, counters, and bounded verbs evidence | 1 | — | 3m |
| `nccl-transport-check` | Full-GPU `nccl-tests` all_reduce; separately asserts intra-node P2P/NVLS and inter-node network transport | 1 | all | 5m |

These tests emit machine-readable verdicts (`PASS`/`WARN`/`FAIL`/`SKIP`) as JSON
plus Prometheus exposition files (`.prom`) suitable for a node_exporter
textfile collector. They exit `77` when the required hardware is absent.

### Interconnect Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `ib-pairwise` | OSU latency/bandwidth/bidirectional, qperf, optional ib_write_bw | 2 | — | 30m |
| `mpi-collective` | IMB-MPI1 (Allreduce/Alltoall/Bcast), OSU collectives, NCCL all_reduce | 4 | 1 | 1h |
| `transport` | UCX device/transport listing, Open MPI MCA params, libfabric providers, NCCL transport probe | 2 | 1 | 30m |

### MPI/RDMA Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `openmpi-cpu` | Open MPI CPU Sendrecv ring test | 2 | — | 10m |
| `openmpi-gpu` | Open MPI GPU (CUDA-aware) Sendrecv ring test | 2 | 1 | 10m |
| `intelmpi-cpu` | Intel MPI CPU Sendrecv ring test | 2 | — | 10m |
| `intelmpi-gpu` | Intel MPI GPU (CUDA-aware) Sendrecv ring test | 2 | 1 | 10m |

The MPI RDMA tests verify end-to-end RDMA data integrity across nodes. The GPU variants additionally validate CUDA-aware MPI transport.

### I/O Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `io` | Legacy POSIX/MPI-IO IOR, mdtest metadata, h5bench HDF5, fio | 4 | — | 1h |
| `storage-burnin` | Bounded IOR, mdtest, h5bench, and fio against runner-resolved job scratch | 1 | — | 20m |
| `vast` | Configured mount identity plus cross-rank namespace/checksum correctness before bounded storage burn-in | 2 | — | 25m |

### Software Stack Validation

| Test | Description | Nodes | GPUs | Time |
|------|-------------|-------|------|------|
| `profiling` | Validates profiler interposition (caliper, darshan, mpip, ipm, extrae, hpctoolkit, tau, scorep, scalasca, likwid) | 2 | — | 30m |
| `frameworks` | PyTorch distributed all_reduce with MPI backend + mpi4py | 2 | 1 | 30m |

## Environment Configuration

Tests use sensible defaults for module versions and resource requests. Override
any setting via environment variables. The node health tests additionally read
cluster-specific expectations (IB link manifest, expected NCCL transport) from
`validation/config/network.yaml`; edit that file to match your cluster.

### Runtime Dependency Feasibility

The hpcsim training runtime is **blocked as of 2026-07-30**. Do not select
`training-ddp`, `frameworks`, `gemm-pulse`, or the PyTorch path in
`nccl-transport-check` as required hpcsim coverage. `envs/hpcsim/spack.yaml`
does not contain a `py-torch` root, and no retained evidence proves a
CUDA-enabled PyTorch build or `import torch` on either Rocky 9 or Rocky 10.
The closest recorded build attempt is the disabled Vlad root, whose comment
records a wheel-build hang with GCC 15 and CUDA 13. The local development
Spack metadata recognizes `py-torch` but cannot satisfy `cuda@13`; this Darwin
result is not a substitute for Rocky concretization.

Task 6 remains blocked until the same candidate root passes all of these steps
without an overlay or training container:

1. Add `py-torch+cuda+nccl` with hpcsim's existing CUDA architecture list and
   `^cuda@13` on a temporary branch. Do not add `+mpi` or `py-mpi4py` for NCCL
   DDP; those are required only by the existing MPI-backend `frameworks` test.
2. Run both sanctioned concretization commands:

   ```bash
   ci/incus-build.sh --os rocky9 --env-name hpcsim --env-path envs/hpcsim --build-action concretize
   ci/incus-build.sh --os rocky10 --env-name hpcsim --env-path envs/hpcsim --build-action concretize
   ```

3. Build each result through the release surface; never run a direct
   `spack install`:

   ```bash
   ci/incus-build.sh --os rocky9 --env-name hpcsim --env-path envs/hpcsim --build-action build
   ci/incus-build.sh --os rocky10 --env-name hpcsim --env-path envs/hpcsim --build-action build
   ```

4. In a real GPU allocation, load the resulting immutable release and record
   the import, followed by a bounded CUDA tensor operation. A CPU import or an
   Incus build without an allocated GPU is not runtime proof:

   ```bash
   python3 -c 'import torch; print(torch.__version__, torch.version.cuda); assert torch.cuda.is_available()'
   ```

DCGM is also not an hpcsim dependency. NVIDIA DCGM supports an unprivileged
`dcgmi` client connected to a site-managed privileged `nv-hostengine` over an
allowlisted TCP endpoint (normally port 5555) or a Unix socket writable by the
validation account. Embedded mode does not borrow hostengine privileges. The
current Spack package set has no `dcgm`/`nvidia-dcgm` package, and Chapar has no
site hostengine endpoint or permission contract, so no DCGM root or `dcgmi`
command may be assumed. Privileged host diagnostics remain site-managed.

The selected validation tiers have the following command contract. A selected
required tier must fail its feasibility check when a listed command is absent;
later scripts must not silently downgrade it to optional behavior.

| Area | Required commands/imports | Provider and current status |
|------|---------------------------|-----------------------------|
| NCCL training and PyTorch GPU checks | `python3`, `import torch`, `torch.distributed`, CUDA, NCCL | `py-torch` is blocked and is not an hpcsim root; Task 6 cannot proceed |
| Existing MPI framework test | PyTorch above, MPI backend, `import mpi4py`, `srun` | Requires `py-torch+mpi` and `py-mpi4py`; neither is an hpcsim root, and NCCL DDP does not need them |
| CPU/NUMA topology | `lscpu`, `findmnt`, `lsblk`, `taskset`, `hwloc-info`, `lstopo`, `numactl` | hwloc and numactl are roots; util-linux commands are an explicit host prerequisite and are not supplied by an hpcsim root |
| RDMA inventory | `ibv_devinfo`, `ibv_devices`, `rdma`, `ip`, `ethtool`, `ibstat`, `ibdev2netdev` | Requires validated rdma-core/iproute2/ethtool/infiniband-diags or site OFED tools; current scripts use sysfs and do not prove these commands |
| Fabric discovery with elevated query permission | `iblinkinfo`, `ibnetdiscover`, `show_gids` | Site/OFED prerequisite; run only when the profile grants fabric-query access |
| RDMA benchmarks | `ib_write_bw`, `ib_read_bw`, latency variants, `qperf`, OSU latency/bandwidth tools, `ucx_perftest` | qperf, OSU, and UCX are roots; only optional `ib_write_bw` is used today, and the current Spack package set has no `perftest` package |
| MPI/NCCL benchmarks | `IMB-MPI1`, `osu_allreduce`, `osu_alltoall`, `all_reduce_perf`, `mpirun`/`srun` | Existing hpcsim roots: intel-mpi-benchmarks, osu-micro-benchmarks, nccl-tests, Open MPI |
| Storage and filesystem clients | `findmnt`, `stat`, `sha256sum`, `fio`, `ior`, `mdtest`, optional `h5bench`; `nfsstat`/`mount.nfs` for NFS | Benchmark modules are roots; util-linux/coreutils and filesystem-specific clients are host prerequisites; VAST control-plane tools remain optional and site-supplied |
| GPU inventory and health | `nvidia-smi`, cuda-memtest, nvbandwidth, optional `dcgmi` client | Driver supplies `nvidia-smi`; cuda-memtest and nvbandwidth are roots; DCGM is blocked as described above |
| HPC benchmark suites | `xhpl`, `hpcgbench`/`hpcg`/`xhpcg`, `stream_c.exe`, `babelStream` | Existing hpcsim roots: hpl, hpcg, stream, babelstream |

This inventory describes command ownership, not hardware proof. RDMA, GPU,
filesystem, and multi-node behavior still require matching Slurm allocations.

### Site Profile Contract

`config/cluster-profile.schema.json` defines the versioned, fail-closed
contract that a future Slurm validation runner will require before it submits a
suite. Copy `config/cluster-site.yaml.example` to `config/cluster-site.yaml`
and fill in site-local values; the real profile is ignored by Git.

The profile explicitly declares the supported Rocky OS, CPU vendor, and
architecture, including generic `aarch64` and NVIDIA Grace (`cpu_platform: nvidia-grace`,
`aarch64`, and `cpu_vendor: nvidia`). An accelerator is explicit and can be `none` with
`gpus_per_node: 0` for CPU-only systems. Each selected `capability`, `node`,
`fabric`, `storage`, `accelerator`, or `full` tier independently declares its
suite subset, required capabilities, bounded resources and edges, partition
class, and unavailable/threshold policy. A selected tier requiring a capability
that its profile does not advertise is invalid.

Run exactly one declared tier with:

```bash
./validation/run --profile <capability|node|fabric|storage|accelerator|full> \
  --site-profile validation/config/cluster-site.yaml
```

The launcher validates the complete profile and every declared tier before it
submits any suite. It then runs only the selected tier's suite manifests,
exports its unavailable and threshold policies, and passes the validated profile
as `VALIDATION_SITE_PROFILE`. A missing required capability is a fail-closed
configuration error. Every unselected suite and non-required or unavailable
capability is recorded as `SKIP` in a non-authoritative selection record beneath
`RESULTS_ROOT/profile-selection/`; the selected suite manifests record an
actual optional-resource `SKIP` under a tier's `unavailable_policy: skip`.

Selection records contain only `job-scratch` and `managed-results` logical
storage target IDs and never resolve paths from the profile. Storage suites
still require a runner-owned allowlist and explicit path-resolution variables.
Existing `list`, direct single-suite, and `all` commands remain unchanged.

Offline fixtures exercise the launcher without Slurm submission:

```bash
bash validation/tests/test-run-profile-fixtures.sh
```

The CPU-only developer fixture selects only `cpu-platform` and has no GPU,
RDMA, or VAST capability. The mismatch fixture requires RDMA without
advertising it and must be rejected.

NVIDIA topology suites require `VALIDATION_SITE_PROFILE` at runtime. Its
`hardware.gpus_per_node` and `topology.gpu` object select the expected GPU
models, PCIe/NVLink/NVSwitch path, required NVLS use, and minimum P2P
bandwidth. The suites request an exclusive full-GPU node and record sanitized
parsed evidence only. `gpu-topology` validates inventory and link state;
`nvlink-p2p` compares NVLink error counters before and after the CUDA P2P
test; `nccl-transport-check` uses `all_reduce_perf`, not PyTorch. IB, RoCE,
and Socket assertions are made only for multi-node NCCL output.

GPU fixtures are non-authoritative parser checks and do not exercise CUDA,
NCCL, Fabric Manager, or Slurm:

```bash
bash validation/tests/gpu-topology.sbatch --fixture validation/fixtures/gpu/nvlink
bash validation/tests/nvlink-p2p.sbatch --fixture validation/fixtures/gpu/nvswitch-nvls
bash validation/tests/nccl-transport-check.sbatch --fixture validation/fixtures/gpu/ib
bash validation/tests/test-gpu-fixtures.sh
```

`cpu-platform` and `slurm-placement` are available profile suites. The former
belongs in CPU capability coverage; the latter belongs in a Slurm-enabled node
tier. CPU inventory can establish the ISA compatibility of a release's
`.chapar-arch` and selected ELF files, but it never infers a microarchitecture
from ELF metadata. `slurm-placement` only records binding evidence for its
current allocation. It skips rather than claiming Slurm placement when no
allocation exists, and it never proves that Slurm allocated a requested CPU
architecture.

Fixture manifests cover Intel x86, AMD x86, NVIDIA Grace, and generic aarch64,
plus ELF mismatch and unallocated placement cases. They exercise declared
verdicts without submission and are non-authoritative manual evidence:

```bash
bash validation/tests/cpu-platform.sbatch --fixture validation/fixtures/cpu/intel-x86
bash validation/tests/slurm-placement.sbatch --fixture validation/fixtures/cpu/nvidia-grace
bash validation/tests/test-cpu-platform-fixtures.sh
```

For a real placement check, submit through `./validation/run slurm-placement`
or invoke the batch script from an existing allocation. Do not treat fixture
output, a direct CPU inventory, or a host ELF header as proof of a Slurm
architecture allocation.

`rdma-link-check` requires `VALIDATION_SITE_PROFILE` for live InfiniBand runs.
Its `topology.rdma` policy selects HCA name/model/firmware/PCI/netdev patterns,
active port link properties, error-counter limits, and two-node verbs bounds.
It inventories batch-visible sysfs and RDMA tooling but records no fabric
topology claim. `iblinkinfo` and `ibnetdiscover` run only when
`fabric_query_authorized: true`; their absence is recorded as non-authoritative
batch visibility, not inferred topology. `ib-pairwise` consumes the same
profile-selected HCA instead of a fixed device name and remains the suite that
performs bounded two-node benchmark work.

RDMA fixtures are parser and policy checks only. They do not exercise verbs,
fabric discovery, or a Slurm allocation:

```bash
bash validation/tests/rdma-link-check.sbatch --fixture validation/fixtures/rdma/connectx8-match
bash validation/tests/test-rdma-fixtures.sh
```

It does not contain commands, environment fragments, filesystem paths, or
aliases. Instead, it may select only the `job-scratch` and `managed-results`
storage target IDs. A runner must resolve those IDs through its own allowlisted,
ownership-checked storage configuration before use.

`storage-burnin` is intentionally unavailable outside that runner contract. The
runner must resolve and pass `STORAGE_BURNIN_TARGET=job-scratch`, the absolute
non-symlink `STORAGE_BURNIN_TARGET_ROOT`, `VALIDATION_STORAGE_RESOLVED_TARGET`,
`VALIDATION_STORAGE_POLICY_RESOLVED=1`, and a distinct
`VALIDATION_STORAGE_RESULTS_TARGET=managed-results` with its absolute root.
The suite rejects overlap with its result storage, creates one private
sentinel-owned `mktemp` directory, and removes only that directory. It also
requires a runner-owned h5bench template with `@WORK_DIR@` and `@MAX_BYTES@`
placeholders so h5bench cannot choose an unbounded or external destination.
Use the no-I/O fixtures to check the guards:

```bash
bash validation/tests/storage-burnin.sbatch --fixture invalid-target
bash validation/tests/storage-burnin.sbatch --fixture controlled-smoke
```

`vast` is a mounted-filesystem correctness gate ahead of the same bounded
storage burn-in. Its runner resolves the safe `job-scratch` target and passes
the expected mount class (`vast`, `nfs`, or `generic`), source identity,
filesystem types, and required mount options through environment variables.
The checked-in profile retains only logical storage target IDs: no export path,
tenant identifier, or credential belongs in Git. The suite reads `findmnt -T`
and `stat -f`, observes `nfsstat -m` only when the configured mount is NFS, and
never calls a VAST control-plane command. Before it invokes `storage-burnin`,
one task per allocated node proves a shared marker, cross-rank payload checksums,
rename visibility, and delete visibility inside a sentinel-owned directory.
Fixtures are parser and correctness checks only; they never mount a filesystem,
contact a VAST control plane, submit Slurm work, or run a benchmark:

```bash
bash validation/tests/vast.sbatch --fixture validation/fixtures/storage/vast
bash validation/tests/test-vast-fixtures.sh
```

Validate the example and fail-closed fixtures without a Slurm allocation:

```bash
bash validation/config/test-cluster-profile.sh
```

### Module Overrides

Each software module has a `CHAPAR_MODULE_<NAME>` variable. Set it to override which module version loads:

```bash
# Use a different CUDA version
CHAPAR_MODULE_CUDA=cuda/12.8 ./validation/run node-smoke

# Use a different Open MPI
CHAPAR_MODULE_OPENMPI=openmpi/5.0.7 ./validation/run ib-pairwise
```

Complete list of module variables:

| Variable | Default | Used By |
|----------|---------|---------|
| `CHAPAR_MODULE_CUDA` | cuda/13 | GPU tests |
| `CHAPAR_MODULE_OPENMPI` | openmpi/5 | MPI tests |
| `CHAPAR_MODULE_UCX` | ucx/1.20.1 | transport |
| `CHAPAR_MODULE_NCCL` | nccl/2.29.7-1 | mpi-collective, transport |
| `CHAPAR_MODULE_NCCL_TESTS` | nccl-tests | mpi-collective, transport |
| `CHAPAR_MODULE_LIBFABRIC` | libfabric/2 | transport |
| `CHAPAR_MODULE_HWLOC` | hwloc | node-smoke |
| `CHAPAR_MODULE_LIKWID` | likwid | node-smoke |
| `CHAPAR_MODULE_PAPI` | papi | node-smoke |
| `CHAPAR_MODULE_NVBANDWIDTH` | nvbandwidth | node-smoke |
| `CHAPAR_MODULE_CUDA_MEMTEST` | cuda-memtest | node-smoke, gpu-stress |
| `CHAPAR_MODULE_OSU_MICRO_BENCHMARKS` | osu-micro-benchmarks | ib-pairwise, mpi-collective |
| `CHAPAR_MODULE_INTEL_MPI_BENCHMARKS` | intel-mpi-benchmarks | mpi-collective |
| `CHAPAR_MODULE_QPERF` | qperf | ib-pairwise |
| `CHAPAR_MODULE_IOR` | ior | io |
| `CHAPAR_MODULE_MDTEST` | mdtest | io |
| `CHAPAR_MODULE_H5BENCH` | h5bench | io |
| `CHAPAR_MODULE_FIO` | fio | io |
| `CHAPAR_MODULE_HPL` | hpl | hpc-challenge |
| `CHAPAR_MODULE_HPCG` | hpcg | hpc-challenge |
| `CHAPAR_MODULE_STREAM` | stream | hpc-challenge |
| `CHAPAR_MODULE_BABELSTREAM` | babelstream | hpc-challenge |
| `CHAPAR_MODULE_OPENBLAS` | openblas | hpc-challenge |
| `CHAPAR_MODULE_PY_TORCH` | py-torch | frameworks |
| `CHAPAR_MODULE_PY_MPI4PY` | py-mpi4py | frameworks |
| `CHAPAR_MODULE_INTEL_ONEAPI_MPI` | intel-oneapi-mpi | intelmpi-* tests |
| `CHAPAR_MODULE_CALIPER` | caliper | profiling |
| `CHAPAR_MODULE_DARSHAN` | darshan-runtime | profiling |
| `CHAPAR_MODULE_MPIP` | mpip | profiling |
| `CHAPAR_MODULE_IPM` | ipm | profiling |
| `CHAPAR_MODULE_EXTRABE` | extrae | profiling |
| `CHAPAR_MODULE_HPCTOOLKIT` | hpctoolkit | profiling |
| `CHAPAR_MODULE_TAU` | tau | profiling |
| `CHAPAR_MODULE_SCOREP` | scorep | profiling |
| `CHAPAR_MODULE_SCALASCA` | scalasca | profiling |
| `CHAPAR_MODULE_LIKWID_PROF` | likwid | profiling |

### Resource Overrides

| Variable | Effect | Example |
|----------|--------|---------|
| `CHAPAR_PARTITION` | Slurm partition | `CHAPAR_PARTITION=gpu ./validation/run node-smoke` |
| `CHAPAR_NODES` | Override node count | `CHAPAR_NODES=8 ./validation/run mpi-collective` |
| `CHAPAR_TIME` | Override time limit | `CHAPAR_TIME=02:00:00 ./validation/run hpc-challenge` |

### Runtime Overrides

| Variable | Effect | Example |
|----------|--------|---------|
| `CHAPAR_KEEP_MODULES=1` | Skip `module purge` — use pre-loaded environment | `CHAPAR_KEEP_MODULES=1 ./validation/run node-smoke` |
| `CHAPAR_DRY_RUN=1` | Print what would run without executing | `CHAPAR_DRY_RUN=1 ./validation/run all` |
| `RESULTS_ROOT` | Custom results directory | `RESULTS_ROOT=/shared/results ./validation/run node-smoke` |

### MPI RDMA Test Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `MPI_RDMA_BYTES` | 8388608 | Message size in bytes |
| `MPI_RDMA_ITERS` | 100 | Ring iterations |
| `MPI_LAUNCHER` | mpirun | MPI launcher command |
| `MPI_LAUNCHER_ARGS` | (varies by MPI) | Launcher arguments |

### Profiling Test Override

```bash
# Select a specific profiler
PROFILER=tau ./validation/run profiling
PROFILER=scorep ./validation/run profiling
```

## Results

Each test writes results to `validation/results/<test>/<job-id>/<node>/`. The directory contains per-command output files named after each command and is ignored by Git.

### Result Manifest Modes

Direct `./validation/run <suite>` and direct `sbatch validation/tests/<suite>.sbatch`
invocations use `VALIDATION_RESULT_MODE=manual` by default. They receive a
generated `manual-...` run ID and write a suite manifest with
`provenance.ci_authoritative: false`; it is useful local evidence but cannot be
selected as CI evidence.

A CI runner must set `VALIDATION_RESULT_MODE=runner` and externally assign both
`VALIDATION_RUN_ID` and timezone-aware `VALIDATION_RUN_ISSUED_AT`. Runner mode
rejects missing, stale, and duplicate IDs. CI consumers must use the
runner-manifest validator, not merely schema validation, so manual manifests
remain non-authoritative. Suites never create tier manifests; a post-job
collector owns those using Slurm accounting data.

To analyze results with MAD-based outlier detection:

```bash
python3 validation/analyze/outliers.py --suite node-smoke --threshold 2.0 \
  --results-dir validation/results/node-smoke/
```

### Protected Slurm CI Orchestration

`Slurm Infrastructure Validation` is a separate manual and scheduled workflow,
not part of the Incus builder workflow. It always checks out the default-branch
commit and uses protected capability-labelled environment/runner pairs for
NVIDIA NVLink, NVIDIA NVSwitch, InfiniBand/ConnectX-8, RoCEv2/ConnectX-8,
VAST, Intel x86, AMD x86, NVIDIA Grace ARM, generic aarch64, and multi-node
pools. Configure required reviewers, branch restrictions, and environment
secrets for every pair in GitHub; the workflow file cannot grant those
protections.

The dispatch surface has only four fixed choice inputs: a runner-owned profile
key, environment key, immutable release alias, and tier. It intentionally has
no partition, QOS, node, path, command, artifact, or promotion input. The
workflow matrix selects the actual tier for the protected profile. The runner
must provide an administrator-owned, non-symlink JSON policy through
`CI_VALIDATION_POLICY_FILE`. Each policy entry must bind the logical profile to
the same protected GitHub Environment, dedicated runner label, required
capabilities, allowed tiers, expected node/edge coverage, site profile, release
root and ID, and fixed partition, QOS, and wall-time values. Its real profile
and all site paths stay outside Git.

`ci/submit-validation.sh` stages the checked-out Git SHA under the protected
source root and resolves exactly `<release-root>/<os>/linux-<os>-<arch>/releases/<id>`.
It refuses releases without immutable `chapar_source_sha` and `spack_source_sha`
metadata, so the current release helper must be extended before live CI is
enabled. The runner exports a unique runner-mode result ID and the immutable
release directory, then submits only fixed `sbatch` arguments from the policy.

Suite manifests are not scheduler authority. The post-job collector alone
requires the exact `sbatch --parsable` ID, bounded polling, `sacct` state
`COMPLETED`, `ExitCode=0:0`, allocation TRES at least matching the selected
tier, and expected node/edge coverage before it validates every
runner-authoritative suite manifest and writes a tier manifest. It persists the
capability inventory, module versions, raw `scontrol`/`sacct` output, profile
digest, suite manifests, raw technical logs, and coverage report in the
restricted result root. It cancels only that parsed job ID on timeout,
interruption, or collector failure.

Raw scheduler output, hostnames, GUID/GID values, mount identities, suite logs,
and detailed results remain under the service-owned site results root. GitHub
receives only a non-symlink, 1 MiB-bounded aggregate JSON and Prometheus count
file, retained for seven days. No raw logs are uploaded. Run the static fixture
without Slurm using:

```bash
bash ci/test-submit-validation.sh
```

Promotion integration is deliberately absent. A future gate requires a
site-owned baseline sign-off and a separate protected configuration change; it
must not be exposed as a workflow input.

## Adding a New Test

1. Create `validation/tests/<name>.sbatch` using an existing test as a template
2. Start with `# DESCRIPTION: One-line description of what this validates`
3. Add `#SBATCH` directives for default resources
4. Set up the results directory (use the standard pattern from existing tests)
5. Use `CHAPAR_MODULE_<NAME>` variables for module loads
6. Run commands that write output to `$RESULTS_DIR`

The test passes if it exits 0. Exit code `77` means the test was skipped
because its hardware requirements are not met on the node (reported as `SKIP`
by `./validation/run all`, not a failure). Any other non-zero exit is a
failure.

## Output Artifacts

Results are collected under `validation/results/<test>/<run-id>/<nodelist>/`:

```
validation/results/
├── node-smoke/
│   └── 20260725T120000/
│       └── node01/
│           ├── likwid_mem.csv
│           ├── nvbw.csv
│           ├── cuda_memtest_gpu0.log
│           └── ...
├── ib-pairwise/
│   └── ...
└── ...
```
