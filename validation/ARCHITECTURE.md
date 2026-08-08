# Chapar Validation, Buildcache, Release, and CI/CD Architecture

## 1. Architecture Overview

```
┌────────────────────────────────────────────┐
│ Git Push (envs/<name>/**)                  │
└────────────┬───────────────────────────────┘
             │ triggers
┌────────────▼───────────────────────────────┐
│ GitHub Actions (reusable engine)           │
│ incus-spack-build.yml                      │
│ 1. Bootstrap Incus container               │
│ 2. Source etc/init.sh                      │
│ 3. release.sh build <id> [--promote]       │
│ 4. Run integrity validation                │
└────────────┬───────────────────────────────┘
             │ produces
┌────────────▼───────────────────────────────┐
│ Shared Install Tree (per OS + arch)        │
│ /resources/chapar/install/linux-<os>-<arch>/│
│ + Shared Buildcache                         │
│ /resources/chapar/buildcache/<os>/          │
└────────────┬───────────────────────────────┘
             │ referenced by
┌────────────▼───────────────────────────────┐
│ Per-Environment Releases                   │
│ /resources/chapar/<env>/<os>/              │
│ ├── releases/<id>/modulefiles/             │
│ └── current → releases/<id>/               │
└────────────┬───────────────────────────────┘
             │ visible via
┌────────────▼───────────────────────────────┐
│ module avail (via profile.d scripts)       │
└────────────────────────────────────────────┘
```

## 2. Architecture Decisions

- **Shared install tree per OS+arch**: All environments running on the same OS and
  microarchitecture share one Spack install tree at
  `/resources/chapar/install/linux-<os>-<arch>/`. This avoids redundant builds of
  the same package across environments (e.g., vlad and hpcsim both need `openmpi`
  for Rocky 10 x86_64_v4 — it is built once). The `{architecture}` projection in
  Spack's `install_tree` config handles multiple microarchitectures within the same
  tree (x86_64_v3, v4, zen4, etc.) by subdirectories. When a new build targets a
  different target, Spack creates the subdirectory automatically and avoids
  rebuilding packages that already exist for that target.

- **Shared buildcache per OS**: Buildcaches are content-addressed by DAG hash, so
  one cache per OS is sufficient for all environments. Whether a binary was built
  for vlad or hpcsim is irrelevant — the hash determines reuse.
  Path: `/resources/chapar/buildcache/<os>/` or
  `/resources/chapar/cache/buildcache/<env>/<os>/`. The cache uses
  `padded_length: 256` for patchelf relocation compatibility; without a padded
  path length, patchelf may fail with `CannotGrowString` when relocating
  RPATHs into a longer prefix at install time. All cache entries carry a
  `.chapar-buildcache-layout` marker recording the padded_length they were built
  with.

- **Atomic versioned releases**: Every release goes through a staging → promote
  flow. `release.sh build <id>` creates the release in
  `releases/.<id>.staging.<pid>`, performs the full install, generates
  release-local module files, applies runtime policy, and only then atomically
  renames to `releases/<id>`. Promotion (`--promote` or `release.sh promote <id>`)
  atomically swaps the `current` symlink via POSIX `rename(2)`. Previous releases
  remain under `releases/` for rollback.

- **Stale `current` directory handling**: If a stale regular directory (not a
  symlink) exists at the `current` path — e.g., after a botched manual cleanup or
  NFS race — `cmd_promote()` auto-removes it with `rm -rf` before creating the
  new symlink. This prevents `ln -s` from failing with "File exists".

## 3. Integrity Validation

| Category | Vlad | HPCSIM |
|----------|------|--------|
| Compilers | gcc/15.3.0, cmake, meson, ninja | gcc/15.3.0, cmake |
| MPI | openmpi, pmix | openmpi |
| GPU Toolkit | cuda, cuda-memtest | cuda |
| Communication | ucx, libfabric, nccl | ucx, libfabric |
| Benchmarks | osu-micro-benchmarks, hpl, hpcg, stream, babelstream | osu-micro-benchmarks, hpl, hpcg, stream, babelstream |
| I/O | ior, mdtest, fio | ior, mdtest, fio |
| Profiling | caliper, hpctoolkit, tau, scalasca | caliper, hpctoolkit, tau |
| System | hwloc, papi, numactl, likwid | hwloc, numactl |
| Python | python, py-mpi4py | python |
| **Total** | **27 checks** | **20 checks** |

### What integrity validation checks

- Module loads successfully
- Binary/executable is on PATH and runs (`--version` or equivalent)
- Shared library dependencies are met (no missing `.so` at runtime)
- Key language runtimes work (Python imports, compiler version checks)

### What integrity validation does NOT check (by design)

- GPU device availability or CUDA kernel execution
- InfiniBand/RDMA connectivity or MPI multi-node communication
- NCCL all-reduce or GPU-direct transport paths
- Performance benchmarks or throughput measurements
- I/O subsystem or filesystem performance

These require specialized hardware or multi-node setup and belong in separate deep
validation tiers.

### How to run

```bash
# List available test suites
./validation/run list

# Run integrity validation for a specific environment
ENV_NAME=vlad ./validation/run integrity-test
ENV_NAME=hpcsim ./validation/run integrity-test
```

### Results format

The integrity test writes a JSON summary to
`validation/results/integrity-<env>/<run-id>/<node>/summary.json`:

```json
{
  "env": "vlad",
  "total": 27,
  "passed": 27,
  "failed": 0,
  "results": [
    {"module": "gcc/15.3.0", "check": "compiler runs", "result": "pass"},
    {"module": "cmake", "check": "cmake runs", "result": "pass"}
  ]
}
```

## Deep Validation Tiers

Beyond integrity validation (module load + basic tool execution), deep validation requires specialized hardware and tests the cluster at a hardware level.

### Current Tier

| Test | Hardware | What It Validates | Single-Node? |
|------|----------|-------------------|--------------|
| `gemm-pulse` | 1+ GPU | GPU throttling (coefficient of variation of matmul time) | Yes |
| `nccl-transport-check` | 1+ GPU | NCCL transport selection (IB/Socket/NVLink) assertion | Yes |
| `ib-link-check` | InfiniBand HCA | Link state, width, speed vs expected configuration | Yes |
| node-smoke (nvidia-smi) | 1+ GPU | ECC errors, power draw, temperature, PCIe health | Yes |

### Future Tiers (scripts exist, need multi-node cluster)

| Test | Hardware | What It Validates | Nodes |
|------|----------|-------------------|-------|
| ib-pairwise | 2 nodes, IB | OSU latency/bw, qperf | 2 |
| transport | 2 nodes, IB, 1 GPU | UCX, libfabric, NCCL transport probe | 2 |
| openmpi-gpu | 2 nodes, IB, 1 GPU | CUDA device-buffer MPI RDMA ring | 2 |
| mpi-collective | 4 nodes, IB, 1 GPU | MPI + NCCL collectives | 4 |
| frameworks | 2 nodes, IB, 1 GPU | PyTorch distributed all_reduce | 2 |
| io | 4 nodes | IOR, mdtest consistency | 4 |

### Running Deep Validation

These tests are hardware-dependent and must be submitted to appropriate Slurm partitions. They are NOT part of the CI pipeline.

```bash
# Run GEMM pulse on a GPU node
sbatch validation/tests/gemm-pulse.sbatch

# Run IB link check on a node with InfiniBand
sbatch validation/tests/ib-link-check.sbatch

# Run NCCL transport check
sbatch validation/tests/nccl-transport-check.sbatch

# Run node-smoke with nvidia-smi health metrics
sbatch validation/tests/node-smoke.sbatch
```

### Prometheus Metrics

Deep validation tests and the outlier analyzer produce Prometheus exposition format output (.prom files). These can be collected by a Prometheus node_exporter with the textfile collector:

```bash
# node_exporter textfile collector
node_exporter --collector.textfile.directory=/var/lib/prometheus/node-exporter/

# Copy .prom files from validation results
cp validation/results/gemm-pulse/*/gemm_pulse.prom /var/lib/prometheus/node-exporter/
cp validation/results/node-smoke/*/nvidia_smi_health.prom /var/lib/prometheus/node-exporter/
```

Available metrics:

| Metric | Source | Type |
|--------|--------|------|
| `gemm_pulse_cv_pct` | gemm-pulse | gauge |
| `gemm_pulse_mean_ms` | gemm-pulse | gauge |
| `gemm_pulse_verdict` | gemm-pulse | gauge |
| `nccl_transport_selected` | nccl-transport-check | gauge |
| `nccl_transport_verdict` | nccl-transport-check | gauge |
| `ib_link_status` | ib-link-check | gauge |
| `ib_link_hcas` | ib-link-check | gauge |
| `ib_link_verdict` | ib-link-check | gauge |
| `nvidia_gpu_temperature` | node-smoke | gauge |
| `nvidia_gpu_power_draw` | node-smoke | gauge |
| `nvidia_gpu_ecc_errors_volatile` | node-smoke | gauge |
| `nvidia_gpu_pcie_link_gen` | node-smoke | gauge |
| `nvidia_gpu_pcie_link_width` | node-smoke | gauge |
| `chapar_outlier_zscore` | outliers.py | gauge |
| `chapar_outlier_count` | outliers.py | gauge |
| `chapar_outlier_nodes_total` | outliers.py | gauge |
| `chapar_outlier_groups_analyzed` | outliers.py | gauge |
```

### Verification
```bash
grep -c "Deep Validation Tiers" validation/ARCHITECTURE.md
grep -c "gemm-pulse" validation/ARCHITECTURE.md
grep -c "nccl-transport-check" validation/ARCHITECTURE.md
grep -c "ib-link-check" validation/ARCHITECTURE.md
```

## 4. CI/CD Pipeline

The CI/CD pipeline uses a reusable workflow pattern:

1. **Caller workflows** (`incus-spack-build-vlad.yml`,
   `incus-spack-build-hpcsim.yml`) — each triggers on pushes to `envs/<name>/**`
   and defines env-specific parameters. They delegate to the reusable engine.

2. **Reusable engine** (`incus-spack-build.yml`) — a `workflow_call` template that:
   - Bootstraps the Incus container with Rocky dependencies (`ci/bootstrap-rocky.sh`)
   - Verifies environment resources mount (NFS, permissions, write test)
   - Generates the `<env>-site.env` config for the target environment
   - Sources `etc/init.sh` to activate the Chapar Spack instance
   - Runs `ci/container-build.sh` which dispatches to `release.sh build <id>`
   - Runs integrity validation via `validation/tests/integrity-test.sbatch`

3. **Concurrency**: All callers share the concurrency group
   `chapar-incus-builders` with `cancel-in-progress: false`, ensuring at most one
   container build runs at a time.

### Auto-promote behavior

| Env | Push auto-promote? | Why |
|-----|-------------------|-----|
| vlad | Yes — always promoted | Hardcoded in reusable workflow: `env_name == 'vlad' && 'true'` |
| hpcsim | No — build only | Only promotes via `workflow_dispatch` with `publish_current=true` |

### Environment propagation

Each caller passes env-specific paths (`env_root`, `buildcache_root`,
`ccache_root`, `install_tree_root`). The reusable workflow uses these to generate
the site config and export them to `container-build.sh` → `release.sh`.

## 5. Adding a New Environment

### 7-step checklist

1. **Create `envs/<name>/spack.yaml`** — Spack environment with root specs and
   package policy.
2. **Create `envs/<name>/release.sh`** — Copy from `envs/hpcsim/release.sh` or
   `envs/vlad/release.sh`, search-and-replace the env name. Adjust script-header
   constants (`<NAME>_ROOT`), root resolver function, path calculations, and
   usage text. Keep the stale-directory guard in `cmd_promote()`.
3. **Create `<name>-site.env.example`** — Template for local site roots,
   buildcache, ccache, group policy. Copy from `hpcsim-site.env.example`.
4. **Create `etc/profile.d/zz-chapar-<name>.sh`** — Profile.d script that
   `module use`s the current release directory's modulefiles. Follow the pattern
   in `zz-chapar-vlad.sh` or `zz-chapar-hpcsim.sh`.
5. **Create `.github/workflows/incus-spack-build-<name>.yml`** — CI caller
   workflow. Copy from `incus-spack-build-vlad.yml`, update env name and trigger
   paths.
6. **Add integrity test entries** — Add a `<name>)` case in
   `validation/tests/integrity-test.sbatch` with `check` calls for each root
   module.
7. **Document deployment path convention** — Update this architecture document
   or the env's README with the expected NFS paths.

### Deployment path conventions

- **NFS root**: `/resources/chapar/<name>/` — must reside on an NFS mount shared
  across cluster nodes.
- **OS subdirectory**: `/resources/chapar/<name>/<os>/` (e.g. `rocky9`,
  `rocky10`).
- **Architecture subdirectory**: `<os>/<arch>/` (e.g.
  `linux-rocky10-x86_64_v3`), derived from the generated release content.
- **Release directory**: `<os>/<arch>/releases/<release-id>/` — immutable after
  staging rename. Legacy releases at `<os>/releases/<id>` remain promotable.
- **`current` symlink**: `<os>/<arch>/current → releases/<release-id>` —
  atomically swapped on promote.
- **Stable module path**: `<os>/<arch>/modulefiles →
  current/modulefiles/<arch>` — the user-facing `module use` target.
- **Module artifacts**: `<os>/<arch>/releases/<release-id>/modulefiles/<arch>/`
  (release-local until promotion).
- **Spack install store**: `<os>/store/` (shared across releases; kept at OS
  level because the store path must exist before the arch is known) or the
  cross-environment shared install tree.

## 6. Module File Access

- **At login**: `etc/profile.d/zz-chapar-<name>.sh` scripts (deployed via
  `/etc/profile.d/`) follow the `current` symlink, enumerate architecture
  directories under `modulefiles/`, and add them to `MODULEPATH`. Users get
  transparent access to the current release's modules.

- **In CI**: The integrity test helper
  (`validation/tests/integrity-test.sbatch`) resolves the module path from the
  per-arch `current` symlinks at `/resources/chapar/<env>/<os>/<arch>/current`
  (highest promoted arch wins), falling back to the legacy `<os>/current`
  pointer and then to the newest unpromoted release.

- **Manual**: The stable path for the promoted release:
  ```bash
  module use /resources/chapar/<env>/<os>/linux-<os>-<arch>/modulefiles
  module avail
  ```

## 7. Troubleshooting

### Buildcache not being used

- **Check `signed: false`**: The local buildcache is unsigned. If Spack's mirror
  config has `signed: true`, concretization will skip all local cache entries.
  Verify in the generated scope's `mirrors.yaml`.
- **Check `padded_length`**: Old cache entries built without path padding will
  fail patchelf relocation (`CannotGrowString`) on the current padded install
  tree. The quarantine mechanism in `prepare_buildcache_root()` moves unmarked
  cache payloads to an archive directory automatically. Rebuild or migrate.
- **Rebuild stale entries**: Delete the stale buildcache payloads and let the
  next release build repopulate them.

### Module not found

- **Check the `current` symlink**: Verify
  `/resources/chapar/<env>/<os>/<arch>/current` exists and points to a valid
  release. If it is a regular directory, `release.sh promote` should
  auto-repair it.
- **Check the modulefiles directory**: The release directory should contain
  `modulefiles/<arch>/<name>/<version>`. Run
  `ls /resources/chapar/<env>/<os>/<arch>/modulefiles/` to verify.
- **Source profile**: If modules are not appearing after login, run
  `source /etc/profile.d/zz-chapar-<name>.sh` manually or re-login.

### CI permission errors

- The CI runner creates shared directories with `chmod 2777` on buildcache and
  release roots. If permissions are wrong, `release.sh` warns instead of dying
  (non-root CI users cannot `chmod` NFS directories). Check NFS exports have
  `no_root_squash` if the build container runs as root.

### Stale `current` directory

- If a directory exists at the `current` path instead of a symlink,
  `release.sh promote` will auto-remove it and create the symlink. This recovery
  runs once per promote invocation.

## 8. Future Directions

### Deep validation tiers

Beyond integrity validation, planned deeper tiers:

| Tier | What it checks | Hardware required |
|------|---------------|-------------------|
| **GPU** | CUDA kernel execution, NCCL all-reduce, GPU-direct transport | NVIDIA GPU + driver |
| **Fabric** | InfiniBand/RDMA connectivity, MPI ping-pong latency, bandwidth | InfiniBand HCA + switch |
| **Network** | Multi-node MPI collective correctness | 2+ nodes with fabric |
| **I/O** | Lustre/GPFS throughput, metadata ops, POSIX compliance | Parallel filesystem |
| **Full app** | End-to-end WRF, GROMACS, or custom workflow | Full cluster |

### Outlier detection dashboard

The existing `validation/analyze/outliers.py` script detects performance outliers
from historical results. A planned upgrade would:

1. Store results in a time-series database (InfluxDB or VictoriaMetrics)
2. Surface outlier runs via Grafana dashboards
3. Alert on regressions via configured notification channels

### Continuous monitoring daemon

A long-running daemon on compute nodes would collect and export:

- GPU metrics (via `nvidia-smi` and DCGM)
- Fabric counters (via `ibstat`, `ibdiag`)
- Node health checks (memory ECC, thermal throttling)
- Prometheus /metrics endpoint for cluster-wide aggregation

## 9. Glossary

| Term | Definition |
|------|------------|
| **Integrity validation** | Automated verification that every root module loads and produces a working binary. Runs after every CI build. Does not require GPU or InfiniBand. |
| **Deep validation** | Hardware-dependent testing tiers (GPU kernels, fabric RDMA, multi-node MPI, I/O throughput) that run on dedicated test nodes, not in CI. |
| **Buildcache** | Spack binary cache — a directory tree of prebuilt `.spack` packages addressed by DAG content hash, enabling reuse across builds and environments. |
| **Install tree** | The Spack package store — a flat directory of installed packages at `/resources/chapar/install/linux-<os>-<arch>/` using `{name}-{version}-{hash}` projection with padded paths for patchelf compatibility. |
| **`current` symlink** | A symlink at `<os>/<arch>/current → releases/<release-id>/` that defines the active production release for an architecture. Atomically swapped on promote. |
| **Padded install tree** | An install tree with `__spack_path_placeholder__` directories to ensure a minimum path length, required for patchelf to relocate RPATHs without `CannotGrowString` errors. |
| **`release.sh`** | Bash helper in each `envs/<name>/` directory that implements the atomic versioned release workflow: `build`, `promote`, `publish-modules`, `module-use`, `status`. |
| **Integrity check** | A single module-level assertion within the integrity test: load module, run command, pass/fail. |
| **Outlier detection** | Statistical analysis of historical result data (`validation/analyze/outliers.py`) to flag performance regressions or anomalous behavior in test results. |
