# Validation Framework Research Findings

**Date:** 2026-07-26
**Scope:** Compare Chapar's validation against industry standards from Google, Meta, NVIDIA, and HPC centers.

---

## 1. Industry Validation Patterns

### 1.1 Google — Cluster Health Scanner (CHS)

Open-source at `github.com/GoogleCloudPlatform/cluster-health-scanner`. Targets GKE and Slurm clusters with A3/A4 GPU machine types.

**Architecture:**
- **Health Runner** — a Helm-deployed K8s controller that schedules health checks as K8s Jobs on labeled nodes, collects results as node labels, and (optionally) taints failing nodes.
- **Blast Mode** — runs N health checks in parallel across different node pairs.
- **Slurm integration** — a prolog script (`a_chs_gpu_health_check_hcs.sh`) runs per-job; failure drains the node.

**Health checks:**

| Check | What it validates | Node count |
|-------|-------------------|------------|
| GPU check | DCGM diagnostics (R_LEVEL 1–4) via `dcgmi diag` | 1 |
| NCCL check | Pairwise NCCL all_reduce bandwidth between node pairs | 2 |
| Neper check | Network performance eval (TCP/UDP/RR) | 2 |
| Straggler detection | Network traffic pattern resembling LLM pipeline parallelism | N (configurable) |
| Tinymax check | End-to-end LLM training run via Maxtext | 1+ |

**Key insight:** CHS runs *continuously* (every 5 min by default), not on-demand. Failed checks taint nodes. The straggler detection and end-to-end ML training check (Tinymax) are unique.

---

### 1.2 NVIDIA — DGX / BasePOD Validation

NVIDIA validates at multiple levels:

**DCGM Diagnostics** (formerly NVVS, superseded by `dcgmi diag`):
- **Level 1** (~2.5s): Software checks only
- **Level 2** (~2.5min): PCIe+NVLink, GPU memory, memory bandwidth
- **Level 3** (~10–35min): Diagnostic + targeted stress + targeted power + nvbandwidth + NCCL tests (single-node)
- **Level 4** (~45min–2.25hr): Level 3 + memtest (memory stress)

**Multi-Node Diagnostics (mndiag):**
- Coordinates stress tests across nodes via centralized DCGM hostengine
- Uses `mnubergemm` — a distributed GEMM benchmark stressing NVLink between nodes
- Validates IMEX channels for MNNVL domains

**NCCL Tests:**
- `all_reduce_perf`, `all_gather_perf`, `reduce_scatter_perf`, `broadcast_perf`, `reduce_perf`, `alltoall_perf`, `sendrecv_perf`
- Run with `-c 10` (correctness checking) across message sizes 8B–1GB
- Works single-node (NVLink) and multi-node (InfiniBand/RoCE)

**aicr (AI Cluster Recipe) — Three-Phase Validation:**

| Phase | What it checks | Mechanism |
|-------|----------------|-----------|
| Deployment | GPU Operator, DRA driver, Kubeflow Trainer installed and healthy | K8s API probes |
| Conformance | DRA support, gang scheduling, autoscaling, secure access | K8s capability checks |
| Performance | NCCL all-reduce bus bandwidth (fabric-aware variants) | Kubeflow TrainJob + `all_reduce_perf` |

Three NCCL check variants:
- `nccl-all-reduce-bw` — auto-detect (what NCCL picks)
- `nccl-all-reduce-bw-net` — force NET transport (EFA/RoCE), asserts the fabric actually carried traffic
- `nccl-all-reduce-bw-nvls` — force NVLS transport (MNNVL), catches silent fallback

**ISV NCP Validation Suite** (`github.com/NVIDIA/ISV-NCP-Validation-Suite`):
- Host checks: GPU connectivity, driver, OS, NCCL, NVLink, InfiniBand, Ethernet, CPU/NUMA, PCI bus
- Cluster checks: K8s health, node count, GPU operator installation
- Workload tests: NCCL (single-/multi-node), GPU stress, NIM inference + GenAI-Perf

---

### 1.3 Meta — GPU Cluster Monitoring (GCM)

Open-source at `github.com/facebookresearch/gcm`. Powers FAIR AI workloads across 100K+ GPUs.

**Health checks (20+ specialized):**

| Check | What it validates |
|-------|-------------------|
| `check-iblink` | InfiniBand link state from sysfs vs JSON manifest. Detects: MISBIND, LINK_RATE_MISMATCH, LINK_NOT_UP, FIRMWARE_MISMATCH, LINK_BAD_STATE, MLX5_MISMATCH |
| `check-dcgmi` | DCGM diagnostics |
| `check-nvidia-smi` | GPU count, running processes, XID errors |
| `check-storage` | Disk usage (with critical threshold) |
| `check-process` | Zombie/runaway processes |
| `check-nvlink` | NVLink topology and status |

**Architecture:**
- Checks run as Slurm prolog/epilog hooks — validated before every job
- Results go to OpenTelemetry sinks + log files
- MANIFEST_FILE per node defines expected hardware (PCI layout, firmware versions, link rates)
- **Passive monitoring**: NVML telemetry collected continuously via `gcm nvml_monitor`
- **Arcadia**: End-to-end AI system simulator for cluster design decisions

**Key insight:** Meta focuses on *manifest-driven* validation — each node has a JSON file describing expected PCI layout, IB firmware, link rates. `check-iblink` compares runtime sysfs against manifest and categorizes issues by severity (OK/WARN/CRITICAL). The `check-iblink` also validates link *operational state* (`operstate`), not just physical state.

---

### 1.4 Lambda — Continuous Validation

Production service, documented at `docs.lambda.ai/managed-kubernetes/continuous-validation/`.

**Two-tier architecture:**

**Passive (always-on):**

| Condition | Failure detected |
|-----------|------------------|
| `GpuXid` | Critical NVIDIA XID errors (dmesg) |
| `GpuSXid` | Uncorrectable fabric errors |
| `GpuTemperature` | Thermal anomalies (DCGM) |
| `GpuRemappedRows` | Pending row remappings needing reset |
| `GpuNvlink` | NVLink/NVSwitch connectivity loss |
| `GpuCount` | Missing accelerator hardware |
| `GpuInfiniband` | IB port degradation |
| `GpuLinkWidth` | PCIe bus width degradation |
| `ReadonlyFilesystem` | Host OS storage faults |
| `NodeConnectivityError` | Network interface drops |

**Active (CronJob on idle nodes):**
- DCGM diag level 3
- gpu-burn + gpu-fryer (15-min thermal stress)
- nvbandwidth (PCIe Gen/width)
- MPI all-reduce across nodes (NVLink + NVSwitch + InfiniBand)
- Network isolation: `NCCL_P2P_DISABLE=1` + `ib_write_bw`
- `fio` on shared storage

**Key insight:** Lambda uses a **PriorityClass** (lowest priority) so validation pods are preempted by tenant workloads — validation is always opportunistic. Passive checks feed into a deterministic remediation loop: detect → isolate (cordon) → drain → power-cycle → re-validate → resume.

---

### 1.5 Together — Health Checks

Documented at `docs.together.ai/docs/health-checks`.

**Threshold-based pass/fail:**

| Test | Metric | Threshold | Configuration |
|------|--------|-----------|---------------|
| Single-Node NCCL | Avg bus bandwidth | ≥ 300 GB/s | 8-GPU, 32 GiB message |
| Multi-Node NCCL | Avg bus bandwidth | ≥ 330 GB/s | All GPUs across nodes |
| IB Write Bandwidth | Reported write bw | ≥ 320 Gb/s | 8 MiB, 2s duration |
| NVBandwidth CPU→GPU | Host-to-device bw | ≥ 30 GB/s | Averaged across 8 GPUs |
| NVBandwidth GPU→CPU | Device-to-host bw | ≥ 30 GB/s | Averaged across 8 GPUs |
| NVBandwidth latency | GPU-CPU latency | ≤ 2000 ns | SM latency, 8-GPU avg |
| Storage seq read | Bandwidth | ≥ 10 GiB/s | fio 1MiB, 64 jobs |
| Storage seq write | Bandwidth | ≥ 5 GiB/s | fio 1MiB, 64 jobs |

**Passive checks:** GPU fell off bus, thermal throttling, fatal XID errors.

**Key insight:** Together uses *absolute performance thresholds* for pass/fail. New nodes run acceptance tests before joining cluster.

---

### 1.6 CoreWeave / Straggler-Shield

Open-source at `github.com/justin-oleary/straggler-shield`. K8s DaemonSet that intercepts GPU nodes before Slurm resumes them.

**Validation pipeline per GPU:**
1. **Pre-flight**: Check nvidia-smi for uncorrectable ECC + idle temperature (>70°C → quarantine)
2. **GEMM pulse**: 5× FP32 2048×2048 matmul → mean latency + CV
3. **P2P ring check**: 100 MiB `cudaMemcpyPeer` across adjacent GPU pairs in ring order
4. **Clock validation**: Post-pulse SM clock ≥ 50% of device max

**Auto-calibrated thresholds by GPU arch:**

| Check | H100 | A100 | B200 |
|-------|------|------|------|
| Mean GEMM latency | 35 ms | 100 ms | 15 ms |
| Coefficient of variation | 20% | 20% | 20% |
| P2P bandwidth | 5 GB/s | 5 GB/s | 5 GB/s |

**Key insight:** This is the only framework that detects *fail-slow* behavior — nodes where mean latency looks acceptable but high variance (CV > 20%) indicates intermittent throttling. The P2P ring check validates NVLink *segment by segment*.

---

### 1.7 AMD / ROCm — Cluster Validation Framework

Documented at `instinct.docs.amd.com`. K8s CronJob-based:
1. Candidate node selection via node labels
2. Single-node ROCm Validation Suite (RVS) or AGFHC
3. Multi-node RCCL collectives (AllReduce, ReduceScatter)
4. Performance threshold comparison vs existing benchmarks
5. Label nodes as `passed`/`failed`

---

## 2. Chapar Current Coverage

### 2.1 What We Have (Good Foundation)

| Area | Tests | What runs |
|------|-------|-----------|
| **Binary presence** | `integrity-test.sbatch` (47 checks) | Module loads, binary on PATH, compiler version |
| **Single-node hardware** | `node-smoke.sbatch` | likwid MEM_DP, nvbandwidth memcpy+P2P, PAPI L2_TCM, cuda-memtest, hwloc/lscpu |
| **GPU stress** | `gpu-stress.sbatch` | cuda-memtest (10 passes), gpu-burn (8h) |
| **IB pairwise** | `ib-pairwise.sbatch` | OSU latency/bw/bibw, qperf, ib_write_bw |
| **MPI collectives** | `mpi-collective.sbatch` | IMB-MPI1 (Allreduce/Alltoall/Bcast), OSU collectives, NCCL all_reduce |
| **Transport paths** | `transport.sbatch` | UCX devices/transports, OMPI MCA, libfabric providers, UCX perftest, NCCL probe |
| **MPI RDMA integrity** | `openmpi-{cpu,gpu}`, `intelmpi-{cpu,gpu}` | Sendrecv ring with data integrity check (CPU + CUDA-aware) |
| **Framework comms** | `frameworks.sbatch` | PyTorch distributed all_reduce (MPI backend) with correctness verification |
| **I/O** | `io.sbatch` | IOR POSIX/MPI-IO, mdtest, h5bench, fio |
| **HPC benchmarks** | `hpc-challenge.sbatch` | HPL, HPCG, STREAM, BabelStream |
| **Profiling** | `profiling.sbatch` | 10 profiler interpositions over osu_latency |
| **Outlier detection** | `validation/analyze/outliers.py` | MAD-based robust z-score, per-suite parsers for OSU/IOR/NCCL/nvbandwidth/likwid/HPL/HPCG/cuda-memtest/torch |

### 2.2 What We Actually Validate at Runtime

The `outliers.py` parser is well-structured and extensible, but:

1. **No pass/fail thresholds** — the outlier detector flags anomalies but doesn't determine pass/fail
2. **No node tainting** — results don't feed back into scheduling
3. **No historical baselines** — every run is independent with no trend detection
4. **No real-time alerts** — analysis is a CLI tool, not a service

---

## 3. Gap Analysis

### 3.1 Critical Gaps (Industry Standard, We Don't Do)

| # | Capability | Industry reference | Risk |
|---|-----------|-------------------|------|
| 1 | **Continuous / periodic validation** | CHS runs every 5 min; Lambda hourly; Meta per-job prolog | Silent degradation between tests |
| 2 | **Node auto-drain on failure** | CHS taints nodes; Lambda cordons; Meta drains via Slurm | Bad node keeps receiving jobs |
| 3 | **Fail-slow / straggler detection** | Straggler-Shield (GEMM CV); CHS straggler check; Meta desync debug | Nodes pass latency checks but stall AllReduce barriers |
| 4 | **NVLink P2P ring segment check** | Straggler-Shield ring; DGX BasePOD PCIe/NVLink diag | Broken single NVLink segment missed by throughput-only tests |
| 5 | **NCCL transport fabric assertion** | NVIDIA aicr asserts NET/NVLS transport actually used | Silent fallback to Socket transport is undetected |
| 6 | **DCGM diagnostics (not just cuda-memtest)** | NVIDIA DCGM diag level 2/3; Google CHS GPU check | No PCIe replay, NVLink CRC, targeted power/stress checks |
| 7 | **InfiniBand link quality validation** | Meta check-iblink: sysfs vs manifest, firmware, rate, operstate | Only measures bw; misses degraded links, firmware mismatch |
| 8 | **Multi-node coordinated GPU stress** | NVIDIA mndiag (mnubergemm) | Stress tests are per-node only |
| 9 | **End-to-end ML training validation** | Google Tinymax (Maxtext); NVIDIA aicr inference | No actual model training run as validation |
| 10 | **Historical baseline + trend detection** | Lambda Prometheus metrics; Meta Arcadia | Outliers are single-snapshot only |

### 3.2 Moderate Gaps

| # | Capability | Industry reference | Risk |
|---|-----------|-------------------|------|
| 11 | **Pass/fail performance thresholds** | Together publishes exact thresholds (e.g., ≥300 GB/s NCCL, ≥320 Gb/s IB) | No answer to "what is a passing bandwidth?" |
| 12 | **Manifest-based validation** | Meta check-iblink JSON manifest; NVIDIA snapshot | No golden config to compare runtime against |
| 13 | **PCIe link width/speed test** | NVIDIA NVVS PCIe plugin; Lambda GpuLinkWidth | Degraded PCIe (x1 instead of x16) goes undetected |
| 14 | **ECC row remap monitoring** | Lambda GpuRemappedRows; Straggler-Shield pre-flight | Pending remappings that need a reset accumulate silently |
| 15 | **XID error monitoring** | Lambda GpuXid; Together passive | Fatal driver errors may be noticed only when jobs fail |
| 16 | **NUMA binding validation** | MPI binding correctness (map-by socket) | Jobs may cross NUMA without warning |
| 17 | **Huge pages / memory config** | Kernel boot params verification | Memory fragmentation affects large model loads |
| 18 | **Storage cross-node consistency** | Checksum verification across mounts | Silent file corruption across shared FS |

### 3.3 Strengths (Industry Parity or Ahead)

| Strength | Details |
|----------|---------|
| **MPI RDMA data integrity** | Custom MPI ring test with end-to-end data verification (CPU+GPU) — more thorough than most industry tests |
| **Transport path enumeration** | UCX + libfabric + NCCL transport probe is comprehensive |
| **Multi-MPI support** | Open MPI and Intel MPI both validated, CPU and GPU variants |
| **Profiler interposition** | 10 profilers validated end-to-end — unusual breadth |
| **Outlier analysis** | MAD-based robust z-score with 9 suite-specific parsers — well designed |
| **Test infrastructure** | Slurm-native, environment-variable-configurable, results-organized — good for a self-built system |
| **Coverage breadth** | Covers more areas than any single industry framework (IB + MPI + GPU + I/O + profiling + frameworks) |

---

## 4. Recommended Additions (Priority Order)

### Tier 1: Highest Impact

1. **Continuous passive monitoring daemon** (ala Lambda, Meta)
   - Watch `nvidia-smi` for XID errors
   - Watch `/sys/class/infiniband/*/ports/*/{state,rate,fw_ver}` for link quality
   - Watch `/sys/kernel/debug/gpu*/remapped_rows` for pending GPU remaps
   - Watch `dmesg` for PCIe errors, NVLink CRC errors
   - Watch `nvidia-smi` for thermal throttling
   - Export to Prometheus metrics endpoint

2. **Node-drain integration**
   - On health check failure, run `scontrol update nodename=... state=DRAIN` with reason
   - Re-integrate on successful re-test (like Slurm prolog scripts)

3. **Fail-slow GPU detection** (ala Straggler-Shield)
   - Add GEMM pulse (FP32 matmul) with CV analysis to `node-smoke.sbatch`
   - Add CUDA Memcpy P2P ring check per adjacent GPU pair
   - Add post-pulse clock validation (SM clock ≥ 50% max)

4. **NCCL transport fabric assertion**
   - Verify which NCCL transport was selected (NCCL_DEBUG=INFO, grep for selected transport)
   - Assert the expected fabric (e.g., IB/verbs for hi-nic clusters) — fail on silent Socket fallback

### Tier 2: High Impact

5. **DCGM diagnostics integration**
   - Replace manual `cuda-memtest` with `dcgmi diag -r 2` as baseline
   - Add `dcgmi diag -r 3` as extended (weekly) check

6. **Manifest-based InfiniBand validation** (ala Meta check-iblink)
   - Define a JSON manifest per node type describing expected PCI layout, IB firmware, link rates
   - Validate runtime sysfs against manifest
   - Flag: LINK_RATE_MISMATCH, FIRMWARE_MISMATCH, LINK_NOT_UP, MISBIND

7. **Pass/fail threshold map**
   - Define per-GPU-architecture threshold tables (like Together)
   - NCCL: ≥X GB/s bus bandwidth for node pair
   - IB: ≥X Gb/s write bandwidth
   - GPU→CPU bandwidth: ≥X GB/s
   - Storage: ≥X GiB/s sequential read/write

### Tier 3: Medium Impact

8. **History-backed trend detection**
   - Store results in time-series DB (Prometheus, or CSV archive)
   - Compute Z-score against N-day rolling window, not single-snapshot median
   - Alert on drift without requiring multiple concurrent nodes

9. **End-to-end ML training check**
   - Submit a small distributed training job (e.g., a tiny GPT-2 or image classification)
   - Validate convergence within expected iteration count
   - Measure throughput for regression detection

10. **NUMA binding validation**
    - Verify Open MPI `--map-by` correctness: check that rank N maps to GPU N's local NUMA domain
    - Validate using `hwloc` + `nvidia-smi` topology

11. **PCIe link width verification**
    - Use `nvidia-smi -q -d PCI` or `dcgmi diag -r 2` to validate PCIe Gen × Width
    - Flag if not running at expected speed (e.g., x16 Gen5)

12. **Memory configuration audit**
    - Check `vm.nr_hugepages`, `transparent_hugepage`, `kernel.shmmax`
    - Validate consistency across nodes

---

## 5. Outlier Detection Architecture Recommendations

### Current State (Chapar)
- MAD-based robust z-score
- CLI-only, single-run
- No historical baseline
- No threshold pass/fail

### Recommended Evolution

```
┌─────────────────────────────────────────────────┐
│                Validation Results                │
│  (Slurm job outputs → validation/results/)      │
└──────────────────┬──────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────┐
│            Result Ingestor (new)                 │
│  • Parse all suite outputs (already done)        │
│  • Store to time-series DB (PostgreSQL/Timescale)│
│  • Store to parquet for batch analysis           │
└──────────────────┬──────────────────────────────┘
                   │
        ┌──────────┴──────────┐
        ▼                     ▼
┌──────────────────┐  ┌─────────────────────────┐
│  Real-time Alert  │  │  Batch Anomaly Detector  │
│  (Prometheus +    │  │  (Airflow / cron)        │
│   AlertManager)   │  │                          │
│                   │  │  • Rolling 7-day MAD Z   │
│  • XID threshold  │  │  • Week-over-week drift  │
│  • IB link drop   │  │  • Node rank regression  │
│  • Temperature    │  │  • Cross-node consistency│
│  • ECC row remap  │  │  • Report generation     │
└──────────────────┘  └─────────────────────────┘
        │                       │
        ▼                       ▼
┌─────────────────────────────────────────────────┐
│               Action Layer (new)                 │
│  • scontrol drain node (critical failures)       │
│  • Slack/email notification                      │
│  • Grafana dashboard update                      │
│  • Ticketing system integration                  │
└─────────────────────────────────────────────────┘
```

### Key Metrics to Track

| Category | Metric | Threshold method |
|----------|--------|-----------------|
| GPU health | Uncorrectable ECC errors | > 0 → drain |
| GPU health | Pending row remaps | > threshold → drain |
| GPU health | SM clock ratio (post-pulse / max) | < 50% → drain |
| GPU health | XID errors in last 24h | > 0 → alert |
| NVLink | P2P bandwidth per adjacent pair | < baseline × 0.8 → flag |
| NVLink | CRC errors | > 0 → alert |
| InfiniBand | Link rate vs expected | mismatch → drain |
| InfiniBand | Link state != ACTIVE | drain |
| InfiniBand | Firmware vs manifest | mismatch → warn |
| NCCL | Bus bandwidth (2-node pair) | < rolling 7d median × 0.8 |
| NCCL | Transport selected | assert NET/NVLS fabric |
| Memory BW | STREAM triad GB/s | < baseline × 0.85 |
| PCIe | Link width/speed | degraded → drain |
| I/O | IOR write bandwidth | < baseline × 0.7 |
| I/O | mdtest file create/s | < baseline × 0.7 |

---

## 6. Summary

| Dimension | Chapar Status | Industry Standard | Gap |
|-----------|--------------|-------------------|-----|
| Test coverage breadth | Good (covers all areas shallowly) | Broad + deep | Depth on specific items |
| MPI RDMA data integrity | Excellent (custom ring test) | Basic OSU only | None — ahead |
| Transport enumeration | Excellent (UCX+libfabric+NCCL) | Not typically done | None — ahead |
| Profiling validation | Excellent (10 profilers) | Not typically done | None — ahead |
| Outlier analysis | Good (MAD z-score) | Growing | No historical baseline |
| Continuous monitoring | None | Standard (all major clouds) | **Critical** |
| Node auto-drain | None | Standard (CHS, Lambda, Meta) | **Critical** |
| Fail-slow detection | None | Emerging standard | **Critical** |
| DCGM integration | Minimal (cuda-memtest only) | Standard (diag level 2/3) | **High** |
| IB link quality | None | Meta check-iblink | **High** |
| Pass/fail thresholds | None | Together, Lambda, NVIDIA | **High** |
| NCCL fabric assertion | None | NVIDIA aicr | **High** |
| PCIe width verification | None | Standard (NVVS/Lambda) | Medium |
| ECC monitoring | None | Lambda, Straggler-Shield | Medium |
| Historical trends | None | Lambda Prometheus | Medium |
| End-to-end ML training | None | Google Tinymax | Medium |
| Manifest-driven validation | None | Meta check-iblink | Medium |
