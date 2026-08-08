---
name: chapar-spack-env-change
description: Change Chapar software root specs, classifications, package policy, providers, or variants in the single envs/software catalog. Use for Vlad, HPCSim, or union software-set membership changes.
---

# Chapar software catalog change

`envs/software/spack.yaml` is the sole active root-spec/package-policy source.
Do not recreate per-environment manifests, edit `spack/`, edit locks, or add a
package overlay unless explicitly requested.

Each root has one stable ID, normalized spec, provenance classification, and
software-set membership. Preserve deterministic `vlad`, `hpcsim`, and `all`
composition, including variant-distinct roots. Target facts belong only in
`containers/images/targets.json`; data-center allow/deny policy and paths
belong only in reviewed `datacenters/<id>` contracts.

Test catalog/inventory behavior with the existing offline suites. Then render a
disposable example and resolve every affected allowed tuple using the canonical
flow in `README.md`. Inspect the generated exact `spack.yaml`,
`target-policy.yaml`, `selection.json`, and recorded `selection.sha256`.

Do not concretize, build, install, promote, load modules, or invoke target
validation from an agent session. Those are explicit future platform gates.
Offline contract and selection behavior is verified; target-platform behavior
not validated.
