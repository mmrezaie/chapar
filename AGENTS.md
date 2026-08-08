# AGENTS.md — Chapar

## Repository rules

- This is the nscale-internal development line. It contains no
  `.github/workflows/`; `docs/ci-github-actions.md` is proposal-only.
- Keep the primary checkout at the repository root and linked worktrees under
  `foobar/<name>/`. Inspect `git worktree list --porcelain` before worktree
  operations and never remove a dirty worktree without explicit approval.
- Never modify `spack/`, generated `.spack-env/` content, lockfiles, or caches.
- Do not add/override `spack_repo/` recipes unless explicitly requested.
- Dependency policy uses major versions unless a root has a reviewed exact
  compatibility requirement. Use Spack-built GCC 15, latest Intel compiler,
  latest MPI (prefer Open MPI), and latest LLVM major. Preserve CUDA/GDR-aware
  UCX, Open MPI, libfabric, GDRCopy, NCCL, and NVSHMEM policy.
- Ubuntu 24.04 builders must not rely on OS CUDA Toolkit, oneAPI compiler/MPI,
  or GitHub CLI packages for software delivery.
- Human-only attribution applies to every harness. Never add AI/tool co-author,
  sign-off, assistance, generated-with, author, body, or collaborator credit.
  Never bypass or weaken `.githooks/commit-msg`.
- Do not stage, commit, push, or open a PR without explicit user approval.

## Single authority and selection flow

- `envs/software/spack.yaml` is the only active software root/package-policy
  catalog. Root provenance composes `vlad`, `hpcsim`, and union `all`.
- `containers/images/targets.json` owns target facts;
  `containers/images/containers.json` owns public container facts.
- Cookiecutter generates reviewed desired-state snapshots at
  `datacenters/<id>/datacenter.json` and
  `datacenters/<id>/targets/<target>/contract.json`. The committed example is
  disposable and there is no active contract/site value.
- `tools/chapar_resolve.py` requires catalog, both registries, data-center and
  target contracts, data-center/software-set/target, release ID, run ID, and a
  new output directory. It emits `selection.json`, exact effective
  `spack.yaml`, and `target-policy.yaml`, prints the selection digest, and the
  operator records that value as adjacent `selection.sha256`.
- Release, cache, module, CI, image, validation, and CVE consumers require the
  exact selection and digest. They reject ambient profile, environment, path,
  partition, publication, or site-file authority.
- Never run a direct Spack install. Builds use the selection-bound
  `envs/software/release.sh` versioned release flow only after platform
  approval. Offline work uses `plan` only.
- Run `release.sh` from a clean shell. `etc/init.sh` is for interactive use: it
  exports the `CHAPAR_*` path variables that `reject_ambient_authority` refuses.
  `release.sh` derives every path from `--selection` and pins its own
  `SPACK_SYSTEM_CONFIG_PATH`, user config, and user cache.

The canonical disposable render/resolver/plan command sequence is in
`README.md`. Other docs and skills link to it instead of copying it.

## OS independence

**OS scopes declare what the OS provides; the catalog declares policy.**
`etc/system/<os>/packages.yaml` is limited to the bootstrap compiler external,
libc, and the requirement that lets a bootstrap install use that compiler.
Everything else is Spack-built, so an environment does not depend on what a
given image happens to ship. The catalog names no OS.

`release.sh` bootstraps ccache with the OS external compiler before installing
the staged `gcc` root, so ccache accelerates the compiler build and no builder
needs a system ccache. Spack resolves ccache from PATH with
`which_string(..., required=True)`, so `config:ccache` is written `false` for
that first pass and `true` afterwards.

Two ccache installs are therefore expected and correct: the bootstrap copy built
with the OS compiler, which is a build tool, and the shared catalog root built
with `gcc@15`, which is the delivered module.

## Path and legacy-state policy

Each target contract explicitly classifies paths:

- durable writable: install tree, releases, modulefiles, writable buildcache,
  ccache, container outputs, receipts, evidence;
- ordered read-only: software catalog, target/container registries, source
  lock, optional seed mirror;
- temporary: release, Spack, image, validation, and resolver staging/work.

Mutable outputs are namespaced by the canonical tuple plus release/run identity.
Sharing requires explicit matching opt-ins; seed mirrors are read-only.

`/resources/chapar/vlad` and `/resources/chapar/hpcsim` are immutable legacy
shadow/canary roots. Do not mutate, migrate, clean, promote, delete, or retire
them, and never derive new desired state from them. There is no retirement or
migration approval.

## Container and source custody

Retain public IDs `nvidia-vlad` and `ubuntu-hpcsim`. Retain historical internal
`vlad-image` names only for compatible runtime paths, units, and variables.
Selected releases and images bind tuple, selection/contract/registry digests,
effective manifest, target policy, metadata, and release-local lock bytes.
Injection preserves build-time absolute prefixes and link/run closure; modules
remain opt-in.

`containers/images/sources-lock.json` is globally `blocked`. No real image
build/import/export/publication is permitted until every source category and
platform descriptor is resolved and approved.

## Project skills

Load baseline rules plus the matching focused skill:

| Work | Skill |
|---|---|
| software roots/package policy | `chapar-spack-env-change` |
| solve/concretization debug | `chapar-spack-solve-debug` |
| persistent scopes | `chapar-config-scope-change` |
| selection-bound release helper | `chapar-release-helper` |
| buildcache/migration planning | `chapar-buildcache` |
| images/source custody | `chapar-vlad-image` |
| CUDA/GDR transport | `chapar-cuda-gdr-transport` |
| validation | `chapar-validation` |
| CVE checker | `chapar-cve-checker` |
| commits/pushes/PR prep | `chapar-commit` |
| OpenCode/skill layout | `chapar-opencode-skills` |
| skill authoring | `skill-creator` |

`agents/skills/` is canonical. OpenCode/Codex use `opencode.json`;
`CLAUDE.md` imports this file and `.claude/skills` symlinks to the same catalog.

## Validation boundary

Offline contract and selection behavior is verified; target-platform behavior
not validated. Never claim plan/fixture tests prove target behavior.

Deferred, explicitly approved Ubuntu 24.04/Slurm gates include native
concretization, release build/promotion, shared-filesystem atomicity and
ownership, cache publication/migration, module/integrity execution, hardware
tiers, source-lock completion, Enroot image operations, and final publication.
No such platform command is claimed to have run.

Before any future commit, inspect status/diff/log, split changes by review
context, enable the commit-msg hook without bypass, and present staged groups
for approval. Keep documentation/skills separate from behavior/config unless
inseparable.
