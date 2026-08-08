---
name: chapar-buildcache
description: Modify or debug selection-bound Chapar buildcache planning, seed mirrors, publication, indexing, quarantine, or migration policy.
---

# Chapar buildcache

Buildcache authority comes from the verified target contract and selection.
Distinguish writable tuple-scoped buildcache, ordered read-only seed mirrors,
ccache, and run-scoped build stages. Never infer these from ambient variables,
a site file, or an old environment.

Normal releases do not auto-import legacy caches. Migration remains plan-only,
copy-only, non-overwriting, and non-deleting until separately approved and
validated. Do not clean, migrate, or retire any cache or immutable legacy
shadow/canary root (`/resources/chapar/vlad`, `/resources/chapar/hpcsim`).

Validate `ci/push-buildcache.sh` syntax and its selection-bound plan/negative
fixtures. Platform publication, index refresh, binary reuse, filesystem layout,
ownership, padded-length compatibility, and migration execution are deferred.
Offline contract and selection behavior is verified; target-platform behavior
not validated.
