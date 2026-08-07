# Selection-aware validation architecture

Validation consumes resolver output, not an environment name or architecture
directory scan. `validation/selection.py` verifies `selection.json`, its exact
digest, and the target contract, then derives:

- canonical data-center/software-set/target identity;
- release/run result namespace;
- one exact module tree;
- exact selected root inventory and root-specific checks;
- contract partition, constraint, account, and QoS.

Mixed paths, unknown targets, missing roots, digest mismatch, or contract drift
fail before submission or module loading. Integrity remains hardware-free:
module availability, basic executable/version behavior, shared-library
resolution, and language-runtime checks. Hardware/interconnect tiers preserve
exit 77 as SKIP and existing PASS/WARN/FAIL/SKIP JSON and Prometheus formats.

The canonical disposable flow is in `README.md`. Its dry run exercises plan
rendering only; it does not submit Slurm, load a module, or touch target paths.
`/resources/chapar/vlad` and `/resources/chapar/hpcsim` remain immutable legacy
shadow/canary roots and are never validation discovery inputs.

Future platform approval is required for Slurm placement and every integrity,
GPU, RDMA, MPI, NCCL, I/O, topology, or performance execution. Offline contract
and selection behavior is verified; target-platform behavior not validated.
