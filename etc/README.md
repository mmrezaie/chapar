# Chapar configuration scopes

`etc/system/` and `etc/user/` contain persistent Spack scope policy. They do
not own software selection, target facts, data-center paths, or publication
policy.

Authority order remains `defaults > system > site > user > spack > environment
> command line`, but the active software catalog is
`envs/software/spack.yaml`. The resolver combines it with the target registry,
container registry, and reviewed `datacenters/<id>` target contract. It emits
an effective `spack.yaml`, `target-policy.yaml`, `selection.json`, and
`selection.sha256`; consumers use only that exact set.

`etc/init.sh` binds repository scopes. It must not turn ambient variables or a
local site file into selection authority. `etc/chapar-selection.sh` verifies a
selection/contract pair and renders temporary release scopes.

The contract path classes are durable writable, ordered read-only, and
temporary. Mutable paths are tuple-namespaced and cannot overlap immutable
legacy shadow/canary roots `/resources/chapar/vlad` or
`/resources/chapar/hpcsim`. No migration or retirement is authorized.

For the complete disposable render/resolver/plan flow, use the single sequence
in `README.md`. Platform config-blame, concretization, build, promotion, module,
and shared-filesystem checks are deferred to an approved Ubuntu 24.04 target
session. Offline contract and selection behavior is verified; target-platform
behavior not validated.
