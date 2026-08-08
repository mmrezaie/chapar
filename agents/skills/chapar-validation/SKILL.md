---
name: chapar-validation
description: Modify or debug Chapar cluster validation tests under validation/ — the integrity test, hardware/interconnect/MPI/NCCL/IO sbatch tiers, the validation/run launcher, network.yaml expectations, or outlier analysis. Use when adding a test tier, adding an environment case to integrity-test, changing verdict/Prometheus output, or triaging validation failures.
---

# Chapar Validation

Use this playbook before changing anything under `validation/`.

## Scope

```text
validation/run                      # launcher: list | all | <test> (Slurm submit, or inline in an allocation)
validation/tests/*.sbatch           # one test tier per file
validation/config/network.yaml      # expected IB/NCCL transport properties
validation/analyze/outliers.py      # cross-node outlier detection (+ test_outliers.py)
validation/ARCHITECTURE.md          # design notes
```

## Invariants

- **Integrity test stays hardware-free.** `integrity-test.sbatch` must verify
  module loads, PATH binaries, shared-library resolution, and language runtimes
  WITHOUT requiring GPUs, InfiniBand, or multi-node scheduling. Deeper checks
  belong in the other tiers.
- **Integrity validation gates releases.** CI runs it after every build+promote;
  a failure blocks the release from being production-ready. Do not weaken checks
  to make a build pass — fix the environment or escalate.
- **Exit code 77 means SKIP** (required hardware absent). `validation/run all`
  reports it without failing the run. Keep that convention for new tests.
- **Keep machine-readable outputs stable.** Node-health tiers emit
  PASS/WARN/FAIL/SKIP verdict JSON and Prometheus `.prom` exposition files for a
  node_exporter textfile collector. Do not rename fields or metrics without
  updating consumers.
- Each `*.sbatch` needs a `# DESCRIPTION:` header line — `validation/run list`
  parses it.
- Environment dispatch is a `case "$ENV_NAME"` block inside
  `integrity-test.sbatch`; every environment in `envs/` must have a case with
  one `check` call per root module (see "Adding a New Environment" in
  `AGENTS.md`).
- Expected interconnect properties live in `validation/config/network.yaml`;
  transport tests assert against it rather than hardcoding link speeds or NCCL
  transports.

## Running

```bash
./validation/run list
ENV_NAME=vlad ./validation/run integrity-test
ENV_NAME=hpcsim ./validation/run integrity-test
CHAPAR_DRY_RUN=1 ./validation/run all      # show what would be submitted
```

Tests submit Slurm jobs by default and run inline inside an existing
allocation. Do not submit hardware tiers (gpu-stress, ib-pairwise, etc.) from
an agent session unless the user explicitly asks.

## Validation of Changes

```bash
bash -n validation/run
bash -n validation/tests/<changed>.sbatch
python3 validation/analyze/test_outliers.py   # when touching outliers.py
git diff --check
```
