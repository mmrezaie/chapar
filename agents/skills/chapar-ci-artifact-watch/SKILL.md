---
name: chapar-ci-artifact-watch
description: Inspect live Chapar CI/CD build progress by reading durable filesystem artifact roots directly instead of waiting for GitHub Actions or GitLab UI logs. Use whenever the user asks what is happening with a running, queued, stuck, timed-out, or slow CI build, especially Rocky 9/Rocky 10 hpcsim builds, package installs, modulefile publication, release roots, buildcache roots, ccache roots, or site-specific mounts such as /resources, /Volumes/resources, ~/resources, or another mounted artifact tree.
---

# Chapar CI Artifact Watch

Use this skill when CI/CD web logs are delayed, hidden, truncated, or not enough
to answer build-progress questions. The goal is to inspect the durable files that
the builder writes while it runs, not to wait for the hosted CI interface to time
out.

## Trust Boundary

- Treat CI artifact roots as read-only evidence.
- Do not create, edit, delete, move, chmod, chown, or symlink anything under an
  artifact root.
- Do not run Spack install, release, promote, migration, buildcache push, cache
  cleanup, or module refresh commands against an artifact root.
- Do not assume `/resources` is the only valid path. It is one deployment choice.
- Prefer direct filesystem reads when a relevant artifact root is mounted locally.
- Use GitHub Actions or GitLab only to identify runs, jobs, refs, matrix axes,
  and workflow inputs when direct artifacts are available.

If a write is needed to fix CI, switch to the appropriate Chapar skill for the
code/config change. Keep this skill focused on observation.

## Root Discovery

Find the CI output roots from the job definition and from the files that the job
has already written. Useful signals include:

- Workflow inputs such as `hpcsim_root`, `buildcache_root`, `release_id`, `os`,
  `git_ref`, and site-specific equivalents.
- Job environment variables such as `HPCSIM_ROOT`, `CHAPAR_HPCSIM_ROOT`,
  `CHAPAR_BUILDCACHE_ROOT`, `CHAPAR_CCACHE_ROOT`, `RUN_ID`, `RELEASE_ID`,
  `OS_NAME`, and future environment-specific root names.
- Durable log lines such as `output:`, `store:`, `releases:`, `module:`,
  `buildcache:`, `hpcsim root:`, and `buildcache root:`.
- Release-helper status output that names store, release, modulefile, current,
  and cache paths.
- Concrete environment snapshots copied to a run directory after a successful or
  partially successful build.

Current hpcsim layouts are examples, not hard-coded policy:

```text
<env-root>/<os>/runs/<run-id>/logs/build.log
<env-root>/<os>/runs/<run-id>/commit.txt
<env-root>/<os>/runs/<run-id>/spack-version.txt
<env-root>/<os>/runs/<run-id>/spack-commit.txt
<env-root>/<os>/runs/<run-id>/release-id.txt
<env-root>/<os>/runs/<run-id>/concrete-envs/
<env-root>/<os>/store/
<env-root>/<os>/releases/<release-id>/modulefiles/
<env-root>/<os>/current
<buildcache-root>/<os>/
<ccache-root>/<os>/
```

## Local Path Mapping

Map CI-internal paths to local mount paths before reading artifacts. Examples:

```text
CI path:    /resources/chapar/hpcsim
Local path: /Volumes/resources/chapar/hpcsim

CI path:    /resources/share/hpcsim
Local path: ~/resources/share/hpcsim

CI path:    /site/apps/hpcsim
Local path: /Volumes/site/apps/hpcsim
```

Use existing local directories only. Do not create compatibility symlinks such as
`/resources -> /Volumes/resources`. If no local mount maps to the CI artifact
root, say that direct artifact inspection is unavailable and fall back to CI API
metadata.

## Inspection Workflow

1. Identify the run, job, OS/matrix axis, ref, and workflow inputs with the CI
   API when available.
2. Resolve candidate artifact roots from workflow inputs, job environment, and
   known output lines.
3. Check whether those roots or mount-equivalent paths are locally readable.
4. For each relevant OS/job, inspect the run directory and `logs/build.log`.
5. Compare sibling OS runs when one is progressing and another is stuck.
6. Report the current state, last durable checkpoint, likely phase, and evidence
   paths.

Good evidence to include:

- Run ID, OS, ref, commit, Spack version, and Spack commit.
- Whether the run directory exists yet.
- Whether `build.log` exists and when it was last modified if tooling exposes
  modification time.
- The last `==>` checkpoint and the last non-empty log lines.
- Whether concretization completed.
- Whether install, module generation, buildcache index refresh, or release
  completion messages are present.
- Whether `concrete-envs/`, `releases/<release-id>/modulefiles/`, or `current`
  exists.

## Progress Classification

Use durable log checkpoints rather than elapsed time alone:

```text
No run directory                     The job has not reached the artifact-writing step.
Run directory, no build.log          Bootstrap/root preparation may be running or failed early.
Header and staging only              Release helper started; likely concretizing or blocked before solver output.
`==> Concretized` present            Solver completed; install/cache/module phase follows.
Install/package messages present     Build is installing or fetching binaries.
`Regenerating tcl module files`      Install finished; module generation is running or just completed.
`Release build complete`             Release tree and modulefiles were created.
`hpcsim CI build completed`          Container build script reached the end.
Error/FAILED/Killed/timeout lines    Report the first failing package or phase with nearby context.
```

If GitHub or GitLab says a job is running but the artifact log has not changed
after the last checkpoint, say exactly where the durable evidence stops. Avoid
declaring a solver hang without comparing expected timeout settings and recent
log progress.

## Helper Sandbox

Use the bundled helper when a quick read-only summary is useful:

```bash
python agents/skills/chapar-ci-artifact-watch/scripts/summarize_artifacts.py --run-id <id>
python agents/skills/chapar-ci-artifact-watch/scripts/summarize_artifacts.py --run-id <id> --os rocky10 --local-root /Volumes/resources
python agents/skills/chapar-ci-artifact-watch/scripts/summarize_artifacts.py --run-id <id> --ci-root /resources/chapar/hpcsim --local-root /Volumes/resources
```

The helper is intentionally read-only. It prints summaries to stdout and refuses
to inspect paths outside the candidate artifact roots supplied by defaults,
environment variables, or `--local-root`/`--ci-root` arguments.

Default local roots are only discovery hints:

```text
/resources
/Volumes/resources
~/resources
```

Set `CHAPAR_CI_ARTIFACT_ROOTS` to a colon-separated list for site-specific
mounts. The skill should still reason from CI metadata first, because the root
names can change across home, lab, and production deployments.

## Related Skills

- Use `chapar-incus-ci-triage` after direct artifact inspection identifies a
  concrete failure class in Incus-backed Rocky CI.
- Use `chapar-spack-solve-debug` for solver failures or timeout root cause.
- Use `chapar-buildcache` for cache publication, index, quarantine, or migration
  failures.
- Use `chapar-release-helper` for hpcsim release-helper behavior changes.
