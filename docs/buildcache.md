# Buildcache contract

Buildcache paths and publication permission come from the verified target
contract and resolver-produced selection. `envs/software/spack.yaml` owns
software policy; no site env file, ambient cache variable, or historical
environment manifest is authoritative.

The path taxonomy distinguishes:

- `writable_buildcache`: tuple-scoped durable output;
- `seed_mirror`: ordered read-only input that never receives autopush;
- `spack_build_stage` and resolver/image staging: temporary run-scoped paths.

`ci/push-buildcache.sh` accepts `selection.json`, its SHA-256, and the exact
target contract. Plan is the default. Execute mode additionally requires the
contract to allow publication and uses the selection-local effective manifest.
Normal release workflows never auto-import legacy caches.

Migration is plan-only, copy-only, non-overwriting, and non-deleting. Execution
requires separate operator approval and target-platform validation. This work
does not approve migration, cleanup, or retirement of any cache or of immutable
legacy shadow/canary roots `/resources/chapar/vlad` and
`/resources/chapar/hpcsim`.

The disposable offline flow in `README.md` is the canonical runnable sequence.
Future platform gates cover filesystem sharing, projection/padded-length
compatibility, index refresh, binary reuse, ownership, and publication.
Offline contract and selection behavior is verified; target-platform behavior
not validated.
