---
name: chapar-incus-ci-triage
description: Triage Chapar GitHub Actions Incus hpcsim Rocky 8/Rocky 9 CI failures. Use when an Incus hpcsim Build workflow fails, succeeds on one Rocky version but not the other, or when inspecting self-hosted runner/build logs.
---

# Chapar Incus CI Triage

Use this playbook for `.github/workflows/incus-spack-build.yml` failures.

## First Principles

- Do not guess from the red/green summary alone. Identify the failed job, failed step, commit, inputs, and OS.
- Compare Rocky 8 and Rocky 9 when one succeeds and the other fails.
- Prefer CI artifacts/logs under the configured `HPCSIM_ROOT` over GitHub web log summaries when available.
- Do not change `spack/` or generated lock/cache directories.
- Keep fixes scoped to the failure class: workflow bootstrap, mount/resource validation, Spack setup, concretization, install, buildcache, module refresh, or promotion.

## Required Inspection

```bash
git status --short
git log --oneline -5
gh run list --workflow 'Incus hpcsim Build' --limit 10 \
  --json databaseId,displayTitle,status,conclusion,createdAt,updatedAt,headSha,headBranch,event
```

For the target run:

```bash
gh run view <run-id> --json jobs,conclusion,displayTitle,headSha,headBranch,workflowName,event
```

Look for:

- Which matrix job failed: `Build hpcsim on rocky8` or `Build hpcsim on rocky9`.
- Which step failed: bootstrap, mount verification, or `Run hpcsim build`.
- Whether failure duration suggests timeout. Common clues:
  - ~1 hour: old `CHAPAR_CONCRETIZE_TIMEOUT=3600` guardrail.
  - ~3 hours: Rocky minimum raised to 10800 seconds; Rocky 8 may need more.
  - ~24 hours: workflow-level timeout or a stuck install.

## Logs and Run Outputs

The CI build script writes durable logs under the run root:

```text
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/logs/build.log
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/commit.txt
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/spack-version.txt
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/spack-commit.txt
${HPCSIM_ROOT}/${OS_NAME}/runs/${RUN_ID}/concrete-envs/
```

Defaults from the workflow are:

```text
HPCSIM_ROOT=/resources/chapar/hpcsim
CHAPAR_BUILDCACHE_ROOT=/resources/chapar/cache
```

If GitHub log download is unavailable, say so and use the structured job metadata plus durable build logs if mounted locally.

## Failure Classification

### Bootstrap Rocky dependencies

Inspect `ci/bootstrap-rocky.sh`. Fix only missing RPM/repo setup needed by current CI. Avoid adding heavyweight runtime packages unless the hpcsim workflow needs them.

### Verify hpcsim resources mount

Inspect `ci/prepare-hpcsim-root.sh` and workflow inputs. The resources and buildcache roots must be NFS (`nfs` or `nfs4`) and writable for the OS-specific run/cache directories.

### Concretization timeout/failure

Use `chapar-spack-solve-debug`. Preserve Chapar policy:

- Do not pin dependency minor/patch versions just to make the solver faster.
- Keep CUDA/GDR transport support.
- Put OS-specific constraints in the matching OS scope.

### Install/build failure

Find the package and concrete hash in `build.log`. Check whether the package is a root or dependency, which compiler/provider it used, and whether the failure is OS-specific.

### Buildcache failure

Use `chapar-buildcache`. Do not auto-import legacy caches.

### Module refresh failure

Use `chapar-release-helper`. Modules must be generated only for explicit environment roots and stay hashless `{name}/{version}`.

## Fix Workflow

1. Inspect current branch and local changes.
2. Make the smallest project-config/CI/release-helper change that addresses the classified failure.
3. Validate locally when possible:

```bash
bash -n ci/container-build.sh
bash -n ci/bootstrap-rocky.sh
bash -n envs/hpcsim/release.sh
git diff --check
```

4. If committing, use `chapar-commit`.
5. When asked to run CI, dispatch only the affected OS unless a push already triggered the full matrix.
