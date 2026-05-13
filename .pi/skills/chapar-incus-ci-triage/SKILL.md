---
name: chapar-incus-ci-triage
description: Triage Chapar GitHub Actions Incus Spack-environment CI failures, including hpcsim Rocky 8/Rocky 9 builds and future envs/<name> workflows. Use when an Incus Spack build fails, succeeds on one Rocky version but not the other, or when inspecting self-hosted runner/build logs.
---

# Chapar Incus CI Triage

Use this playbook for Incus-backed GitHub Actions that build Chapar Spack
environments. The current workflow is `.github/workflows/incus-spack-build.yml`
for `envs/hpcsim`, but future workflows may target other `envs/<name>`
environments. Identify the environment before changing config.

## First Principles

- Do not guess from the red/green summary alone. Identify the failed workflow,
  job, step, commit, inputs, OS, and target environment.
- Compare Rocky 8 and Rocky 9 when one succeeds and the other fails.
- Prefer durable CI artifacts/logs under the configured run root over GitHub web
  log summaries when available.
- Do not change `spack/` or generated lock/cache directories.
- Keep fixes scoped to the failure class: workflow bootstrap, mount/resource
  validation, Spack setup, concretization, install, buildcache, module refresh,
  or promotion.

## Required Inspection

```bash
git status --short
git log --oneline -5
gh run list --limit 10 \
  --json databaseId,workflowName,displayTitle,status,conclusion,createdAt,updatedAt,headSha,headBranch,event
```

For the target run:

```bash
gh run view <run-id> --json jobs,conclusion,displayTitle,headSha,headBranch,workflowName,event
```

Look for:

- Which workflow failed.
- Which matrix job failed, e.g. `Build hpcsim on rocky8`.
- Which environment is targeted, e.g. `ENV_PATH=envs/hpcsim`.
- Which step failed: bootstrap, mount verification, or the environment build.
- Whether failure duration suggests timeout. Common clues:
  - ~1 hour: old generic `CHAPAR_CONCRETIZE_TIMEOUT=3600` guardrail.
  - ~3 hours: Rocky 9 minimum or older Rocky-wide minimum.
  - ~6 hours: Rocky 8 minimum after the 2026-05 timeout fix.
  - ~24 hours: workflow-level timeout or a stuck install.

## Logs and Run Outputs

For the hpcsim workflow, `ci/container-build.sh` writes durable logs under:

```text
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/logs/build.log
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/commit.txt
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/spack-version.txt
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/spack-commit.txt
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/concrete-envs/
```

Defaults from the hpcsim workflow are:

```text
HPCSIM_ROOT=/resources/chapar/hpcsim
CHAPAR_BUILDCACHE_ROOT=/resources/chapar/cache
ENV_PATH=envs/hpcsim
```

Future environment workflows should have analogous run roots and must be read
from their workflow/build script rather than assumed. If GitHub log download is
unavailable, say so and use structured job metadata plus durable build logs if
mounted locally.

## Failure Classification

### Bootstrap Rocky dependencies

Inspect the bootstrap script used by the workflow, currently
`ci/bootstrap-rocky.sh` for hpcsim. Fix only missing RPM/repo setup needed by
current CI. Avoid adding heavyweight runtime packages unless the target
environment needs them.

### Verify resources mount

Inspect the workflow inputs and preparation script, currently
`ci/prepare-hpcsim-root.sh` for hpcsim. Resources and buildcache roots must be
NFS (`nfs` or `nfs4`) and writable for the OS-specific run/cache directories.

### Concretization timeout/failure

Use `chapar-spack-solve-debug` with the target `ENV_PATH`. Preserve Chapar
policy:

- Do not pin dependency minor/patch versions just to make the solver faster.
- Keep CUDA/GDR transport support for GPU environments.
- Put OS-specific constraints in the matching OS scope.

### Install/build failure

Find the package and concrete hash in `build.log`. Check whether the package is
a root or dependency, which compiler/provider it used, and whether the failure is
OS-specific.

### Buildcache failure

Use `chapar-buildcache`. Do not auto-import legacy caches.

### Module refresh failure

Use `chapar-release-helper` for hpcsim release-helper failures. Modules must be
generated only for explicit environment roots and stay hashless `{name}/{version}`.

## Fix Workflow

1. Inspect current branch and local changes.
2. Identify the target environment and failure class.
3. Make the smallest project-config/CI/release-helper change that addresses the
   classified failure.
4. Validate locally when possible:

```bash
bash -n ci/container-build.sh
bash -n ci/bootstrap-rocky.sh
bash -n envs/hpcsim/release.sh
git diff --check
```

5. If committing, use `chapar-commit`.
6. When asked to run CI, dispatch only the affected OS/environment unless a push
   already triggered the needed workflow.
