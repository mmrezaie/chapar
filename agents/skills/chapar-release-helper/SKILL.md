---
name: chapar-release-helper
description: Modify or debug Chapar's current hpcsim release helper envs/hpcsim/release.sh. Use for hpcsim release builds, staging/promote logic, module refresh, generated Spack scopes, and release metadata. For generic package/env edits, use chapar-spack-env-change.
---

# Chapar hpcsim Release Helper

Use this playbook before editing `envs/hpcsim/release.sh`. This skill is
intentionally hpcsim-specific because that is the release helper that exists
today. If a future environment gets its own release helper, copy the invariants
that apply but inspect that helper's own paths and variables first.

## Invariants

- Build into a staging directory: `releases/.<release-id>.staging.<pid>`.
- Publish a release only by atomically moving staging to `releases/<release-id>`
  after install, module generation, and manifest writing succeed.
- Promotion only updates the per-OS `current` symlink atomically.
- Never rewrite active module trees used by running jobs.
- The shared Spack store is per OS; module trees are release-local.
- Release command-line Spack scope must be temporary and cleaned up.
- hpcsim user-facing module names are hashless `{name}/{version}`.
- Refresh modules only for explicit concrete environment roots, not dependencies.
- Fail on duplicate root module names instead of adding hash suffixes.

## Generated Scope Responsibilities

`make_scope` controls release-only:

- install tree root and padded length
- module roots under staging release directory
- buildcache mirror and autopush
- cache/stage directories

Do not move release-only policy into persistent system/user scopes unless the
user explicitly requests a persistent behavior change.

## Safe Validation

Always run:

```bash
bash -n envs/hpcsim/release.sh
git diff --check -- envs/hpcsim/release.sh
```

For non-destructive path/status checks:

```bash
OS_NAME=rocky9 bash envs/hpcsim/release.sh status
```

Do not run build/promote commands unless explicitly asked.

## Buildcache Interactions

If changing cache layout, migration, index refresh, autopush, or quarantine
behavior, use `chapar-buildcache` too.

## CUDA/MPI Interactions

If changing `install_cuda_libfabric_specs`, CUDA target/stub handling, UCX, Open
MPI, or libfabric behavior, use `chapar-cuda-gdr-transport` too.
