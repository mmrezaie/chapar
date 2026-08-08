# Proposed CI design

This is a proposal. The repository intentionally has no `.github/workflows/`
files, and adding one requires explicit agreement.

## Inputs and authority

A future workflow must accept the full identity tuple and invocation:
data-center ID, software-set ID, target ID, release ID, run ID, absolute
`selection.json`, and its exact digest. It must load the matching reviewed
`datacenters/<id>/targets/<target>/contract.json`. Partition, constraint,
account, QoS, paths, publication flags, and selected containers come only from
that verified contract/selection pair.

The selection is resolved from `envs/software/spack.yaml`,
`containers/images/targets.json`, `containers/images/containers.json`, and the
data-center snapshot. CI must reject ambient environment/profile/path overrides
and must never use direct Spack installation as its delivery surface.

## Proposed stages

1. Validate registries, schemas, source lock, data-center snapshot, and
   selection digest.
2. Plan the exact release tuple and destinations with no side effects.
3. On an explicitly approved target runner, concretize and build through
   `envs/software/release.sh` using the selection-local effective manifest.
4. Run selection-aware integrity validation and preserve machine-readable
   verdicts.
5. If globally source-unblocked and contract-enabled, plan/build the selected
   `nvidia-vlad` or `ubuntu-hpcsim` image and bind receipts to release-local
   bytes/digests.
6. Publish only artifacts whose selection, validation receipt, role custody,
   and contract permission all match.

The global `containers/images/sources-lock.json` remains `blocked`; image build
and publication cannot proceed. Historical internal `vlad-image` runtime names
remain compatible and do not define a third public container.

## Deferred gates

No workflow, runner registration, Slurm job, release build, validation job,
image import, or publication is claimed here. Target-platform gates include
Ubuntu 24.04 runner identity, mounts/atomic rename, Spack concretization,
buildcache reuse, Slurm placement, hardware validation, Enroot behavior, and
per-platform descriptor/source approval. Offline contract and selection
behavior is verified; target-platform behavior not validated.

Use the single disposable operator sequence in `README.md` for offline review;
do not copy it into a future workflow without approval.
