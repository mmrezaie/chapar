---
name: chapar-buildcache
description: Modify or debug Chapar buildcache or shared ccache behavior, migration, quarantine, index refresh, and cache publication for hpcsim or future Spack environments. Use for docs/buildcache.md, ci/push-buildcache.sh, release helper migration, or buildcache CI failures.
---

# Chapar Buildcache

Use this playbook for `${CHAPAR_BUILDCACHE_ROOT}/<os>`,
`${CHAPAR_CCACHE_ROOT}/<os>`, and cache logic used by Chapar Spack environments.
The current release-helper implementation is hpcsim-specific, but the cache
policy is project-wide and should remain usable by future environments.

## Non-Negotiable Policy

- Do not make normal release/build workflows auto-import legacy buildcaches.
- Legacy migration must be explicit and one-shot only. Today that command is
  `envs/hpcsim/release.sh migrate-buildcache` for hpcsim.
- Do not delete legacy caches during migration.
- Do not overwrite destination payloads during migration.
- Unmarked or incompatible cache payloads must be quarantined before normal
  builds use the cache.
- Keep layout marker checks aligned with `INSTALL_TREE_PADDED_LENGTH` and
  `BUILDCACHE_LAYOUT_VERSION` where those helpers are used.
- Preserve per-OS cache roots; do not cross-copy Rocky 9/Rocky 10 caches
  unless explicitly validated by the user.
- Future environments should reuse the per-OS Chapar cache and ccache roots
  unless the user explicitly designs a separate cache namespace.
- Site-specific cache paths, groups, and publication policy belong in ignored
  `envs/hpcsim/hpcsim-site.env`, not tracked YAML.

## Key Files

```text
docs/buildcache.md
envs/hpcsim/release.sh              # current hpcsim release/cache helper
ci/push-buildcache.sh
.github/workflows/incus-spack-build.yml
etc/system/rocky9/mirrors.yaml
etc/system/rocky10/mirrors.yaml
envs/hpcsim/hpcsim-site.env.example
```

For future environments, inspect their workflow/build helper before assuming the
hpcsim paths or variable names apply.

## Inspection Commands

```bash
source ./etc/init.sh
ENV_PATH=envs/hpcsim        # or envs/<future-env>
spack mirror list
spack config blame mirrors
spack -e "${ENV_PATH}" config blame mirrors
```

For hpcsim release-helper cache status:

```bash
OS_NAME=rocky9 bash envs/hpcsim/release.sh status
```

## Index and Payload Checks

A cache with payloads but no index is invisible to Spack reuse. Build helpers
should refresh indexes before concretization when needed.

Do not run destructive cache cleanup. If cleanup is requested, require explicit
confirmation and document what will be removed.

## Validation

```bash
bash -n envs/hpcsim/release.sh
bash -n ci/push-buildcache.sh
git diff --check
```

If the change targets a future environment helper, validate that helper with
`bash -n` as well.

If documentation is updated with behavior changes, keep docs in the same commit
only when they explain the behavior change; otherwise split commits with
`chapar-commit`.
