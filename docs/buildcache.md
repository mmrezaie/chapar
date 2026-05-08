# Chapar Buildcache Policy

Chapar uses one shared binary buildcache root for Linux VM/NAS builds:

```text
/resources/chapar/cache/<os>
```

Current Rocky targets use:

```text
/resources/chapar/cache/rocky8
/resources/chapar/cache/rocky9
```

macOS CI can use the same root when the NAS is mounted. Its workflow keeps a
user-local default at `~/resources/chapar/cache/macos` so native macOS runners
without the VM/NAS mount do not fail only because the Linux cache path is absent.

The cache is intentionally separate from hpcsim release roots such as
`/resources/share/hpcsim` and `/resources/chapar/hpcsim`. Release trees contain
stores, module trees, run logs, and promotion symlinks. The buildcache is a
cross-release binary artifact pool that should survive release layout changes and
be shared by both hpcsim builds and ad-hoc user installs.

## Scope Placement

Keep the buildcache mirror in Chapar Spack scopes, not in `envs/hpcsim/spack.yaml`.

The Rocky system and user scopes both define the same mirror name,
`chapar-buildcache`, with OS-specific URLs. This makes the cache visible to:

- `spack -e envs/hpcsim install`
- release builds driven by `envs/hpcsim/release.sh`
- ordinary user installs that use Chapar's system/user scopes
- future Chapar environments that inherit the same scopes

Release builds generate a temporary command-line scope with the same mirror name.
That scope points to the same cache location but controls `autopush` through
`PUBLISH_BUILDCACHE`. This prevents higher-precedence user scope settings from
forcing CI/release jobs to publish when the workflow explicitly disables cache
publishing.

Do not move this mirror into an environment file unless the desired behavior is
for only that one environment to see the cache. The intended behavior is broader:
all Chapar installs on the VM/NFS builders should share the cache.

## Mirror Semantics

The mirror uses:

```yaml
source: false
binary: true
signed: false
autopush: true
```

`source: false` keeps `/resources/chapar/cache/<os>` dedicated to Spack binary
cache metadata and binary tarballs. Source mirrors and downloaded source archives
should not be mixed into this NAS binary cache.

`signed: false` matches the current Chapar publishing model, which uses unsigned
buildcache pushes. Do not flip this to `true` without a key rollout plan that
creates signing keys, signs publisher output, installs and trusts public keys on
all builders/users, and defines whether ordinary users are allowed to sign shared
cache entries.

`autopush: true` means ordinary user installs using these scopes can publish
successful builds into the shared cache. This requires trusted NFS permissions.
The security boundary is the NAS ACL/group membership for `/resources/chapar/cache`.
If that trust model changes, make user scopes read-only and keep publishing
limited to CI/release builders.

## One-Time Migration

`envs/hpcsim/release.sh build` does not automatically migrate legacy cache
contents. Run migration explicitly when retiring an old cache directory for the
selected `HPCSIM_ROOT`:

```bash
OS_NAME=rocky8 envs/hpcsim/release.sh migrate-buildcache
OS_NAME=rocky9 envs/hpcsim/release.sh migrate-buildcache
```

The explicit migration is intentionally conservative:

- It copies from the selected legacy cache path into `/resources/chapar/cache/<os>`.
- It requires the source cache to carry Chapar's current padded install-tree
  layout marker. Unmarked pre-padding caches are not migrated by default because
  they can fail relocation with `CannotGrowString`.
- It never deletes old cache directories.
- It does not overwrite destination files.
- It uses an atomic NFS-safe lock directory at `<cache>.migration.lock`.
- It refreshes the buildcache index after copying so the next install can reuse
  migrated binaries.
- It writes `.legacy-buildcache-migration-complete` in the destination so repeat
  invocations become no-ops unless `--force` is used.

The legacy source path checked by the release helper is:

```text
<hpcsim_root>/<os>/buildcache
```

Set `HPCSIM_ROOT` to the release root being retired before running migration.
Do not copy binary caches built under a different install root into the current
cache unless you have validated that their prefixes are relocatable.

Current hpcsim release builds use `install_tree.padded_length: 256`. If the
destination cache already contains unmarked pre-padding payloads, the release
helper quarantines `blobs`, `v3`, and legacy index payloads under a hidden
`.incompatible-install-tree-padded-256-*` directory before using the cache. This
preserves old files for audit while preventing Spack from selecting binaries that
cannot relocate into the padded store.

After a successful one-time migration and verification build, retire old cache
directories manually so future runs cannot accidentally reuse stale artifacts.

## Admin Setup

Prepare the NAS cache with trusted group ownership and setgid permissions before
enabling broad user autopush:

```bash
mkdir -p /resources/chapar/cache/rocky8 /resources/chapar/cache/rocky9
chgrp -R <trusted-chapar-group> /resources/chapar/cache
chmod -R g+rwX /resources/chapar/cache
find /resources/chapar/cache -type d -exec chmod 2775 {} +
```

Use the group that represents users and CI builders allowed to publish shared
binary artifacts.
