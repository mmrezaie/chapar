---
name: chapar-release-helper
description: Modify or debug the selection-bound Chapar release helper at envs/software/release.sh, including plan, staging, promotion, modules, release metadata, and local-lock custody.
---

# Chapar release helper

The helper accepts resolver-produced `selection.json`, its exact digest, and
adjacent effective manifest/target policy. Ambient release/cache/module paths,
profiles, checkout locks, and site values are not authority.

Preserve atomic tuple-scoped staging/final paths, immutable release metadata,
one module tree, exact root modules, release-local lock custody, and digest
bindings to all registries/contracts. Promotion and publication must remain
contract-controlled. Never discover or mutate `/resources/chapar/vlad` or
`/resources/chapar/hpcsim`; they are immutable legacy shadow/canary roots.

Validate shell syntax, the release plan fixture, negative digest/path/metadata
cases, and `git diff --check`. Use only `plan` in an agent session. Native
concretization, build, promotion, module use, cache publication, and migration
are deferred platform gates requiring explicit approval. Offline contract and
selection behavior is verified; target-platform behavior not validated.
