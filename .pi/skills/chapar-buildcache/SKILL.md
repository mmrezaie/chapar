---
name: chapar-buildcache
description: Modify or debug Chapar buildcache behavior, migration, quarantine, index refresh, and cache publication. Use for docs/buildcache.md, ci/push-buildcache.sh, release.sh migrate-buildcache, or buildcache CI failures.
---

# Chapar Buildcache

Use this playbook for `/resources/chapar/cache/<os>` and binary cache logic.

## Non-Negotiable Policy

- Do not make hpcsim release builds auto-import legacy buildcaches.
- Legacy migration is explicit and one-shot only: `envs/hpcsim/release.sh migrate-buildcache`.
- Do not delete legacy caches during migration.
- Do not overwrite destination payloads during migration.
- Unmarked or incompatible cache payloads must be quarantined before normal builds use the cache.
- Keep layout marker checks aligned with `INSTALL_TREE_PADDED_LENGTH` and `BUILDCACHE_LAYOUT_VERSION`.
- Preserve per-OS cache roots; do not cross-copy Rocky 8/Rocky 9/macOS caches unless explicitly validated by the user.

## Key Files

```text
docs/buildcache.md
envs/hpcsim/release.sh
ci/push-buildcache.sh
.github/workflows/incus-spack-build.yml
etc/system/rocky8/mirrors.yaml
etc/system/rocky9/mirrors.yaml
etc/user/rocky8/mirrors.yaml
etc/user/rocky9/mirrors.yaml
```

## Inspection Commands

```bash
source ./etc/init.sh
spack mirror list
spack config blame mirrors
spack -e envs/hpcsim config blame mirrors
```

For release-helper cache status:

```bash
OS_NAME=rocky8 HPCSIM_ROOT=/resources/chapar/hpcsim \
  CHAPAR_BUILDCACHE_ROOT=/resources/chapar/cache \
  bash envs/hpcsim/release.sh status
```

## Index and Payload Checks

A cache with payloads but no index is invisible to Spack reuse. The release helper should refresh indexes before concretization when needed.

Do not run destructive cache cleanup. If cleanup is requested, require explicit confirmation and document what will be removed.

## Validation

```bash
bash -n envs/hpcsim/release.sh
bash -n ci/push-buildcache.sh
git diff --check
```

If documentation is updated with behavior changes, keep docs in the same commit only when they explain the behavior change; otherwise split commits with `chapar-commit`.
