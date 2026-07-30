---
name: chapar-release-helper
description: Modify or debug release helpers for any Chapar environment (hpcsim, vlad, or future), e.g. envs/hpcsim/release.sh or envs/vlad/release.sh. Use for release builds, staging/promote logic, module refresh, generated Spack scopes, and release metadata. For generic package/env edits, use chapar-spack-env-change.
---

# Chapar Release Helper

Use this playbook before editing any `envs/<name>/release.sh` (currently
`envs/hpcsim/release.sh` and `envs/vlad/release.sh`). The helpers share the
same structure; inspect the target helper's own paths and variables before
editing, and keep intentional differences (for example, hpcsim-only GCC/LLVM
preinstall or CUDA stub module policy) rather than blindly syncing the files.
For adding a release helper to a new environment, follow the "Adding a New
Environment" checklist in `AGENTS.md`.

## Invariants

- Build into a staging directory: `releases/.<release-id>.staging.<pid>`.
- Publish a release only by atomically moving staging to `releases/<release-id>`
  after install, module generation, and manifest writing succeed.
- Promotion updates the per-OS `current` symlink atomically and may also update
  configured shared module-root symlinks per architecture.
- Never rewrite active module trees used by running jobs.
- The Spack install tree defaults to a per-OS store, but sites may configure a
  shared root with architecture/compiler projections; module trees are
  release-local until promotion.
- Release command-line Spack scope must be temporary and cleaned up.
- User-facing module names are hashless `{name}/{version}`.
- `cmd_promote()` must keep the stale-`current` auto-repair guard: if a plain
  directory (not a symlink) exists at the `current` path, remove it before
  promoting.
- **NEVER run `spack install -e envs/<name>` directly.** Always use `envs/<name>/release.sh build <id> [--promote]`. This rule applies to ALL environments, not just hpcsim.
- Refresh modules only for explicit concrete environment roots, not dependencies.
- Fail on duplicate root module names instead of adding hash suffixes.

## Generated Scope Responsibilities

`make_scope` controls release-only:

- install tree root, projection, and padded length
- module roots under staging release directory
- buildcache mirror and autopush
- cache/stage directories

Do not move release-only policy into persistent system/user scopes unless the
user explicitly requests a persistent behavior change.

## Safe Validation

Always run (for the helper you edited):

```bash
bash -n envs/<name>/release.sh
git diff --check -- envs/<name>/release.sh
```

For non-destructive path/status checks:

```bash
OS_NAME=rocky9 bash envs/<name>/release.sh status
```

Do not run build/promote commands unless explicitly asked.

```bash
# Verify no rogue spack install processes
pgrep -f "spack.*install" 2>/dev/null && echo "WARNING: rogue spack install detected!" || echo "OK: no direct spack install running"
```

## Buildcache Interactions

If changing cache layout, migration, index refresh, autopush, or quarantine
behavior, use `chapar-buildcache` too.

## CUDA/MPI Interactions

If changing `install_cuda_libfabric_specs`, CUDA target/stub handling, UCX, Open
MPI, or libfabric behavior, use `chapar-cuda-gdr-transport` too.
