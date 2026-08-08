---
name: chapar-ci-artifact-watch
description: Inspect live Chapar CI/CD artifacts and progress when an operator supplies an approved selection, tuple, artifact root, and run identity.
---

# Chapar CI artifact watch

There is no active repository contract and no GitHub Actions workflow. Do not
invent a live root or treat immutable legacy shadow/canary paths
`/resources/chapar/vlad` and `/resources/chapar/hpcsim` as current desired
state.

For an explicitly supplied deployment, first verify the exact
`selection.json`, digest, target contract, data-center/software-set/target,
release ID, and run ID. Follow only selection-declared release, module,
buildcache, container, receipt, evidence, and temporary roots. Distinguish
process/timestamp churn from advancing immutable artifacts and receipts.

Watching is read-only. Do not submit, retry, promote, publish, clean, migrate,
or repair without new authorization. Report selection/receipt digest mismatch
as a blocker. Offline fixture behavior does not prove target progress; target-
platform behavior must be observed directly and remains unvalidated otherwise.
