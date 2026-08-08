---
name: chapar-vlad-image
description: Modify or debug selected Chapar Pyxis image planning, source custody, registries, preflight, release receipts, or vlad-image runner provisioning. Use for containers/images and related CI scripts.
---

# Chapar image pipeline

Load target/container/source registries rather than creating duplicated base or
target dictionaries. Public IDs remain `nvidia-vlad` and `ubuntu-hpcsim`;
historical internal `vlad-image` paths, units, and variables remain compatible
but do not define a third container.

An image consumes a selection-bound immutable release and verifies data center,
software set, target, release/run identity, contract/registry/selection
digests, effective manifest, target policy, metadata, and release-local lock.
Preserve build-time absolute prefixes, link/run closure, one module destination,
base payload checks, descriptor digests, and role custody.

`containers/images/sources-lock.json` is globally `blocked`; every image build
must stop before candidate/final writes. A resolved individual category never
overrides the global block. Use only plan/fixture tests and the canonical
offline flow in `README.md`; never import/export an image from an agent session.

Target-platform gates include source approval, preflight on each architecture,
Enroot, base glibc/module availability, CPU/GB300 features, Slurm/Pyxis/PMIx,
runtime validation, and publisher custody. Offline contract and selection
behavior is verified; target-platform behavior not validated.
