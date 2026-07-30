# NHC Integration Guidance

NHC is a site-operated node-health service. Chapar's validation suites produce
unprivileged batch evidence; they do not install, configure, invoke, or manage
NHC. A site may correlate the two evidence sources, but neither substitutes for
the other.

## Ownership and Release Policy

The cluster administrator owns the NHC package, configuration, service account,
Slurm health-check settings, prologs, and node-drain policy. Chapar CI never
deploys NHC configuration or changes a site Slurm control plane.

Use a versioned NHC release approved by the site. Record the release version,
source or package digest, build provenance, configuration revision, approver,
and rollout date in the administrator's change record. Do not track a moving
development branch or consume an unpinned source checkout.

Keep NHC configuration in an administrator-owned versioned repository or
package. Review changes before promotion, retain the prior known-good revision,
and make rollback a pointer change to that revision rather than an ad hoc edit
on compute nodes.

## Controlled Rollout

1. Build or obtain the approved, pinned NHC release through the site's normal
   operating-system package or configuration-management process.
2. Validate the candidate configuration on non-production nodes using the
   site's maintenance workflow. Confirm that each check has an owner, a
   documented remediation path, and an intended drain or alert policy.
3. Promote the immutable package and configuration revision to a small canary
   node set. Observe scheduled health checks and Slurm behavior before widening
   the rollout.
4. Roll out by explicit administrator approval. Retain the previous versioned
   package and configuration revision for rollback.

Slurm `HealthCheckProgram`, health-check intervals, prologs, node-state changes,
and remediation actions are site policy. They are not prescribed or modified by
this repository.

## Boundary With Batch Validation

`validation/tests/node-admission.sbatch` is intentionally limited to
batch-visible, unprivileged evidence: CPU/GPU/NIC inventory, NVIDIA
uncorrected ECC counters, PCIe link state, and reported NVLink/NVSwitch status.
Live batch jobs record Xid history as unavailable; they do not read kernel logs.
Missing optional diagnostics produce a `WARN` rather than an implicit privileged
probe.

Keep DCGM host-engine operation, raw kernel logs and Xid history, NVMe SMART,
firmware interrogation, and other privileged host diagnostics in the
administrator-managed NHC or prolog path. NHC may publish a sanitized,
access-controlled health result for correlation with batch evidence, but batch
jobs must not access host-engine control interfaces or privileged diagnostics.

The batch suite defaults to manual, non-authoritative result provenance. A
runner must explicitly assign `VALIDATION_RESULT_MODE=runner`,
`VALIDATION_RUN_ID`, and `VALIDATION_RUN_ISSUED_AT` before its evidence can be
considered runner-authoritative. Suite evidence never grants scheduler authority
or directly drains a node.

## Correlation and Fixtures

The admission suite accepts only deterministic local fixtures:

```bash
bash validation/tests/node-admission.sbatch --fixture healthy
bash validation/tests/node-admission.sbatch --fixture ecc-fault
bash validation/tests/node-admission.sbatch --fixture inventory-mismatch
bash validation/tests/node-admission.sbatch --fixture missing-optional-diagnostic
bash validation/tests/test-node-admission-fixtures.sh
```

The healthy fixture passes. ECC and inventory fixtures fail under the default
threshold policy. The missing optional diagnostic fixture warns and exits zero.
Fixtures do not represent a site inventory or GPU allocation.
