# NHC Integration Plan for Chapar

## Why NHC, Not CHS

| | NHC (LBNL) | CHS (Google) |
|---|---|---|
| **Scope** | Node-level infrastructure health | Cluster-level GPU fabric performance |
| **Tests** | 45 checks: CPU, RAM, storage, IB, processes, filesystems, GPU | 5 checks: DCGM, NCCL bw, network bw, stragglers, ML training |
| **What it answers** | "Is this node configured correctly?" | "Is this cluster fast enough to train a model?" |
| **Slurm integration** | Native — HealthCheckProgram= in slurm.conf | K8s-native + Slurm prolog shim |
| **Langage** | Bash | Go + Python |
| **Fit for Chapar** | Direct — same infrastructure validation philosophy | Application-level performance validation (future scope) |

Chapar is about infrastructure validation — ensuring the software stack builds correctly, 
modules load, binaries run, and node hardware is healthy. NHC aligns with this. CHS validates 
whether the infrastructure can train a model at a given speed — that's a future concern.

## NHC Development Branch

The upstream repo github.com/mej/nhc has a dev branch with active development. 
We track dev to get the latest check scripts and features.

## Integration Architecture

```
chapar/
├── extern/
│   └── nhc/                    ← git submodule tracking mej/nhc@dev
│       ├── scripts/             ← NHC built-in check modules (45+ checks)
│       ├── src/                 ← NHC source code (C + autotools)
│       ├── configure            ← autotools build system
│       └── Makefile
├── validation/
│   ├── run                      ← existing test runner
│   ├── tests/*.sbatch           ← existing multi-node / Slurm tests
│   └── nhc/
│       ├── nhc.conf             ← Chapar-specific NHC configuration
│       ├── scripts/
│       │   ├── check_chapar_module_load.nhc
│       │   ├── check_chapar_gpu_health.nhc
│       │   ├── check_chapar_integrity.nhc
│       │   └── check_chapar_ib_link.nhc
│       └── README.md
├── etc/
│   └── slurm/
│       └── prolog.d/
│           └── 99-nhc-check
└── docs/
    └── nhc-integration-plan.md
```

## Implementation Steps

### 1. Add NHC as git submodule
```bash
git submodule add -b dev https://github.com/mej/nhc.git extern/nhc
```
Update later with: `git submodule update --remote extern/nhc`

### 2. Build NHC from source
```bash
cd extern/nhc
autoreconf -i
./configure --prefix=/usr --sysconfdir=/etc
make -j
sudo make install
```
Installs: /usr/sbin/nhc, /etc/nhc/nhc.conf, /etc/nhc/scripts/*.nhc

### 3. Create Chapar NHC config
`validation/nhc/nhc.conf` with hardware checks (CPU, RAM, IB, MCE), filesystem checks 
(NFS mount), process checks (slurmd, sshd), GPU health (nvidia-smi), and custom 
Chapar module load checks.

### 4. Create custom NHC check scripts
Four scripts in validation/nhc/scripts/:
- check_chapar_module_load.nhc — verifies key modules (gcc, openmpi, cuda) load
- check_chapar_gpu_health.nhc — nvidia-smi ECC + temperature check
- check_chapar_ib_link.nhc — IB sysfs state=ACTIVE check
- check_chapar_integrity.nhc — full module integrity test wrapper

### 5. Add deployment script
ci/deploy-nhc-config.sh — copies config and custom checks to /etc/nhc/

### 6. Add Slurm prolog integration
etc/slurm/prolog.d/99-nhc-check — runs nhc before every job, drains node on failure

Configure slurm.conf:
```
HealthCheckProgram=/usr/sbin/nhc
HealthCheckInterval=1800
HealthCheckNodeState=IDLE
Prolog=/etc/slurm/prolog.d/99-nhc-check
```

### 7. Wire into CI
Post-build deployment step in the future CI pipeline (see
docs/ci-github-actions.md); no workflow exists yet.

## NHC vs Chapar's Existing Tests

| NHC Check | Chapar Equivalent | Notes |
|-----------|------------------|-------|
| check_hw_cpuinfo | (not covered) | New — CPU socket/core/thread validation |
| check_hw_physmem | (not covered) | New — RAM size validation |
| check_hw_ib | ib-link-check.sbatch | Overlap — both check sysfs |
| check_hw_mcelog | (not covered) | New — MCE error monitoring |
| check_fs_mount | (not covered) | New — filesystem mount validation |
| check_ps_daemon | (not covered) | New — daemon existence check |
| check_nvsmi_healthmon | node-smoke nvidia-smi | Overlap |
| check_chapar_module_load | integrity-test.sbatch | Wrapper |

NHC adds 5 new infrastructure checks Chapar doesn't do at all.

## Deployment
```bash
cd extern/nhc && autoreconf -i && ./configure --prefix=/usr --sysconfdir=/etc && make -j && sudo make install
bash ci/deploy-nhc-config.sh
nhc  # test
```

## Roadmap
Phase 1: NHC integration with basic checks (CPU, RAM, IB, GPU, modules) — NOW
Phase 2: Continuous passive monitoring (XID errors, IB link drops, ECC)
Phase 3: Node auto-drain via Slurm prolog
Phase 4: Prometheus metrics export from NHC
Phase 5: Multi-node coordinated tests (NCCL, MPI) — CHS-like
