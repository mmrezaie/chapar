# vlad — HPC/AI Cluster Validation

vlad is a self-contained HPC/AI cluster validation environment. It contains
benchmarks, profilers, GPU transport probes, and PyTorch+mpi4py framework-comm
validation. This directory contains Slurm sbatch wrappers for each validation
suite, plus an outlier analyzer.

All suites are designed for real multi-node Slurm allocations after a release
has been built and the vlad modules are visible. Each suite writes per-GPU or
per-node output files so the analyzer can pinpoint the exact deviant component.

## Architecture

The validation system uses a three-layer design:

- **Config layer** (`validation/config/<env>.yaml`): Maps symbolic module/tool names to environment-specific paths
- **Test definitions** (`validation/<suite>/tests/<name>.yaml`): YAML files declaring module_needs, resources, commands
- **Execution harness** (`validation/harness/`): Shared scripts for directory resolution, environment loading, results setup, and scheduler-agnostic execution
- **Orchestrator** (`validation/run.py`): Python CLI for test discovery, dispatch, and results collection

## Test Suites

### node-smoke

Per-node hardware smoke test. Runs on every allocated node and tags output
with the node hostname and GPU index.

```bash
sbatch validation/vlad/slurm/node-smoke.sbatch
```

Tests executed on each node:

- `likwid-perfctr -g MEM_DP` — memory bandwidth profile
- `nvbandwidth --test=memcpy --test=p2p` — GPU device and peer bandwidth
- `papi_command_line` — PAPI counter availability
- `CUDA_VISIBLE_DEVICES=$gpu cuda-memtest` — per-GPU memory test, each GPU
  gets its own output file so the analyzer can pin a deviant GPU index
- `hwloc-info` — topology report
- `lscpu` — CPU feature report

**Runtime knobs**

| Variable | Default | Description |
|----------|---------|-------------|
| `SBATCH_PARTITION` | (from site policy) | Slurm partition |

### ib-pairwise

2-node InfiniBand pair validation. Validates the end-to-end verbs/RDMA path
between a node pair.

```bash
sbatch validation/vlad/slurm/ib-pairwise.sbatch
```

Tests executed:

- OSU latency (`osu_latency`)
- OSU bandwidth (`osu_bw`)
- OSU bidirectional bandwidth (`osu_bibw`)
- `qperf` verbs latency and bandwidth
- optional external `ib_write_bw` (when `EXTERNAL_PERFTEST` is set)

**Runtime knobs**

| Variable | Default | Description |
|----------|---------|-------------|
| `MPI_RDMA_BYTES` | `8388608` | Message size in bytes (8 MB) |
| `VLAD_OPENMPI_MODULE` | `openmpi/5` | Open MPI module to load |
| `EXTERNAL_PERFTEST` | (unset) | Set to enable `ib_write_bw` |

### mpi-collective

Multi-node MPI collective sweep. Scales across the full allocation.

```bash
sbatch validation/vlad/slurm/mpi-collective.sbatch
```

Tests executed:

- IMB-MPI1: `Allreduce`, `Alltoall`, `Bcast`
- OSU collectives: `osu_allreduce`, `osu_alltoall`
- `nccl-tests all_reduce_perf` across GPUs

**Runtime knobs**

| Variable | Default | Description |
|----------|---------|-------------|
| `MPI_RANKS` | `4` | Total MPI rank count |
| `NGPUS_PER_RANK` | `1` | GPUs per MPI rank |

### hpc-challenge

Full HPC benchmark sweep on the full partition. Validates LINPACK, conjugate
gradient, STREAM, and mixed-precision AI throughput.

```bash
sbatch validation/vlad/slurm/hpc-challenge.sbatch
```

Tests executed:

- **HPL** — High-Performance LINPACK with user-provided `hpl.dat`
- **HPCG** — High-Performance Conjugate Gradient
- **STREAM** — memory bandwidth benchmark
- **HPL-AI** — mixed-precision HPL-AI benchmark
- **BabelStream** — multi-language memory bandwidth

**Runtime knobs**

| Variable | Default | Description |
|----------|---------|-------------|
| `HPL_DAT_FILE` | `validation/vlad/hpl.dat` | User-provided HPL input deck |
| `HPCG_NX` | `104` | Local grid X dimension |
| `HPCG_NY` | `104` | Local grid Y dimension |
| `HPCG_NZ` | `104` | Local grid Z dimension |
| `HPCG_TIME` | `60` | HPCG run time in seconds |
| `HPLAI_DAT_FILE` | (unset) | User-provided HPL-AI input deck |

### io

POSIX and MPI-IO I/O validation against a generic filesystem path. NOT pinned
to Lustre or VAST — targets `${IO_TEST_DIR:-$SCRATCH}` so the user can point
it at any filesystem.

```bash
sbatch validation/vlad/slurm/io.sbatch
```

Tests executed:

- **IOR** — POSIX and MPIIO backends
- **mdtest** — metadata performance
- **h5bench** — HDF5 I/O kernel benchmark
- **fio** — flexible I/O tester

**Runtime knobs**

| Variable | Default | Description |
|----------|---------|-------------|
| `IO_TEST_DIR` | `$SCRATCH` | Target filesystem path |
| `IOR_BLOCK` | (site default) | IOR block size |
| `IOR_XFER` | (site default) | IOR transfer size |
| `MDTEST_FILES` | (site default) | Files per mdtest process |
| `H5BENCH_CFG` | (unset) | h5bench config file |
| `FIO_CFG` | (unset) | fio job file |

### profiling

Single-profiler-at-a-time enum wrapper. Validates that each profiler can
interpose on a running binary without recompilation — covering LD_PRELOAD,
PMPI, CUPTI, and perf_event interpose mechanisms.

```bash
sbatch validation/vlad/slurm/profiling.sbatch
```

The `PROFILER` variable selects exactly one profiler per run. Each profile
runs `osu_latency` under the profiler and validates the profiler install AND
its binary-only interpose mechanism without recompiling the benchmark.

| `PROFILER` value | Interpose mechanism |
|------------------|---------------------|
| `caliper` | LD_PRELOAD / PMPI |
| `darshan` | LD_PRELOAD / PMPI |
| `mpip` | LD_PRELOAD / PMPI |
| `ipm` | LD_PRELOAD / PMPI |
| `extrae` | LD_PRELOAD / PMPI / CUPTI |
| `hpctoolkit` | LD_PRELOAD / perf_event |
| `tau` | LD_PRELOAD / PMPI / CUPTI |
| `scorep` | LD_PRELOAD / PMPI / CUPTI |
| `scalasca` | LD_PRELOAD / PMPI |
| `likwid` | perf_event |

### gpu-stress

Per-GPU memory and compute stress. Every GPU on every allocated node gets its
own output file.

```bash
sbatch validation/vlad/slurm/gpu-stress.sbatch
```

Tests executed:

- `cuda-memtest` — per-GPU with `CUDA_MEMTEST_PASSES` passes (default 10)
- `gpu-burn` — external GPU compute stress (8 hour duration)

**Runtime knobs**

| Variable | Default | Description |
|----------|---------|-------------|
| `CUDA_MEMTEST_PASSES` | `10` | Passes per GPU |

### transport

Probes which transport each vendor library actually selected at runtime.
Validates that the loaded UCX, Open MPI, libfabric, and NCCL stacks use
the expected GPU-direct transport paths.

```bash
sbatch validation/vlad/slurm/transport.sbatch
```

Tests executed:

- `ucx_info -d` — UCX device listing
- `ucx_info -t` — UCX transport listing
- `ompi_info --param all all` — Open MPI MCA parameter dump
- `fi_info -d` — libfabric provider listing
- optional external `ucx_perftest -b cuda` — validates `cuda_copy`,
  `cuda_ipc`, and `gdr_copy` transport selection
- optional external `ib_write_bw` — raw verbs bandwidth
- `NCCL_DEBUG=INFO nccl-tests all_reduce_perf` — captures NCCL transport
  selection (Ring/Tree/CollNet) and NVLink/IB usage

**Runtime knobs**

| Variable | Default | Description |
|----------|---------|-------------|
| `EXTERNAL_UCX_PERFTEST` | (unset) | Set to enable `ucx_perftest -b cuda` |
| `EXTERNAL_PERFTEST` | (unset) | Set to enable `ib_write_bw` |
| `NCCL_DEBUG` | `INFO` | NCCL debug verbosity |

### frameworks

PyTorch+mpi4py framework-comm validation. Runs `torch.distributed.all_reduce`
over CUDA tensors via Spack-built Open MPI. Confirms the real transport
PyTorch jobs will use runs end-to-end.

```bash
sbatch validation/vlad/slurm/frameworks.sbatch
```

**Requirements:** `py-torch` and `py-mpi4py` modules must be visible from
the loaded Spack environment.

Tests can also be run via `python3 validation/run.py --suite <name>` or `make <name>`.

### Running Tests

Tests can be run through the orchestration layer:

```bash
# List available suites and tests
python3 validation/run.py --list-suites
python3 validation/run.py --list-tests

# Run a single test suite (preferred)
python3 validation/run.py --suite node-smoke

# Run all tests
python3 validation/run.py --all

# Dry-run (print what would be executed without running)
python3 validation/run.py --suite node-smoke --dry-run

# Use a specific environment config (default: validation/config/vlad.yaml)
python3 validation/run.py --suite node-smoke --env validation/config/my-cluster.yaml

# Via Makefile (uses default vlad env)
make -C validation/vlad node-smoke
make -C validation/vlad all

# Direct sbatch (backward compatible)
sbatch validation/vlad/slurm/node-smoke.sbatch
```

### Environment Configuration

The validation system uses environment config files (YAML) to abstract away
cluster-specific module names and tool paths. Each environment has a config
file in `validation/config/`.

```
validation/config/
├── vlad.yaml    # Vlad environment (default)
└── hpcsim.yaml  # HPCsim environment
```

To create a config for a new cluster:
1. Copy an existing config as a template
2. Update `module_map` with the actual module names from your Spack environment
3. Update `tool_map` with paths to external tools
4. Set scheduler defaults (partition, time limits)

```yaml
module_map:
  openmpi: openmpi/5          # map "openmpi" need to "openmpi/5" module
  cuda: cuda/13               # map "cuda" need to "cuda/13" module
  ...
```

### Adding a New Test

Tests are defined as YAML files in `validation/<suite>/tests/`. Each test
YAML declares what it needs and what commands to run:

```yaml
suite: my-new-test
description: What this test validates
severity: error                    # error|warning|info
module_needs: [openmpi, cuda]     # symbolic module names
tool_needs: []                     # external tool names from tool_map
resources:
  nodes: 2
  ntasks: 2
  gpus: 1
  time: "00:30:00"
commands:
  - name: my_command
    cmd: srun -n 2 my-benchmark > "${RESULTS_DIR}/output.log"
    output: output.log
```

Key rules:
- Use `NUM_GPUS` not `SLURM_GPUS_ON_NODE` (harness substitutes at runtime)
- Use `NODELIST` not `SLURM_NODELIST`
- Use `RESULTS_DIR` for output paths
- Use `${TOOL_<name>}` for tool paths from the config
- Mark optional commands with `optional: true` and `optional_check: ...`

## External Tools

The following tools are NOT built by Spack and must be installed separately.
Each is optional — suites skip the tool when its binary is not found on `PATH`.

### perftest

Build from rdma-core headers. Clone `https://github.com/linux-rdma/perftest`,
run `./autogen.sh && ./configure --prefix=/path/to/install && make -j && make install`.
Requires `rdma-core-devel` on Rocky. Provides `ib_write_bw`, `ib_read_bw`,
and other raw verbs benchmarks used by the **ib-pairwise** and **transport**
suites.

### ucx-perftest

Build from `https://github.com/openucx/ucx-perftest` against the Spack
UCX installation. Run `make CUDA_HOME=/path/to/spack/cuda` to enable CUDA
transport validation. Validates that UCX transports (`cuda_copy`, `cuda_ipc`,
`gdr_copy`) engage correctly with CUDA device memory. Used by the **transport**
suite.

### gpu-burn

Simple `make` from `https://github.com/wilicc/gpu-burn`. No configure step.
Requires CUDA toolkit on `PATH`. Multi-GPU burn-in used by the **gpu-stress**
suite (8 hour default duration).

### NVIDIA Nsight Systems / Nsight Compute

`nsys` (Nsight Systems) and `ncu` (Nsight Compute) are available through
`module load cuda`. If the CUDA module does not add them to `PATH`, install
from the NVIDIA Developer site or the CUDA toolkit distribution. Used by
the **profiling** suite when a CUPTI-based profiler is selected.

## Aggregation Workflow

After running one or more suites, the outlier analyzer reads per-suite result
files, builds per-GPU and per-GPU-pair metric matrices, and flags any row with
`|robust z-score| > threshold`. The robust z-score is computed using median
absolute deviation (MAD) across rows.

```bash
python3 validation/vlad/analyze/outliers.py \
  --suite ib-pairwise \
  --threshold 2.0 \
  --results-dir validation/vlad/results/ib-pairwise
```

The analyzer reports **which GPU index on which node** is deviant, so a
system administrator can replace or reseat the specific component without
hunting through raw logs.

Supported suites: `node-smoke`, `ib-pairwise`, `mpi-collective`,
`hpc-challenge`, `io`, `gpu-stress`, `transport`, `frameworks`.
The `profiling` suite is excluded from automated outlier analysis because
profiler overhead and trace sizes are not hardware-deviation signals.

## Future Work

The local execution backend (running tests without Slurm) is planned for a follow-up phase.

- Horovod, DeepSpeed, and NeMo communication profilers for distributed
  training validation
- AMD Omnitrace integration for ROCm-aware transport and profiling suites
- ARM Forge/Map (DDT) and CrayPat vendor-profiler wrappers
- MLPerf submission tooling (logging, result normalization, submission
  packaging)
