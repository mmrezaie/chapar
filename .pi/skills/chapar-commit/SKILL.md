---
name: chapar-commit
description: Prepare Chapar commits and pushes with the project's commit-splitting and message policy. Use whenever the user asks to commit, push, split commits, or prepare a PR branch.
---

# Chapar Commit Workflow

Use this playbook before any Chapar commit or push.

## Required Inspection

```bash
git status --short
git diff --stat
git diff
git log --oneline -8 --decorate
```

If the branch is not what the user intended, stop and ask or switch only if explicitly requested.

## Split Rules

Create separate commits for separate review contexts:

- docs/comment-only changes
- behavior/config changes
- CI workflow changes
- release tooling changes
- buildcache policy changes
- project-local pi/agent workflow changes

Do not mix documentation/comment-only changes with behavior/config/CI changes unless inseparable. If inseparable, explain why in the commit body.

## Commit Message Style

Use a short subject plus a body that explains:

- root cause or motivation
- why this approach was chosen
- constraints preserved
- validation performed

Avoid messages that only restate the diff.

Example:

```text
Extend Rocky 8 hpcsim concretization timeout

The latest Incus hpcsim run completed on Rocky 9 but Rocky 8 failed after hitting the release helper's three-hour concretization guardrail. Rocky 8 has the heavier constrained solve because ...

Keep the existing Rocky 9 limit ...

Validation: bash -n envs/hpcsim/release.sh; git diff --check ...
```

## Push Policy

- Do not amend or rewrite pushed history unless the user explicitly asks.
- If a bad commit split is discovered after push, prefer a corrective commit over force-pushing `main`.
- Use `[skip ci]` only when intentionally avoiding push-triggered workflows.
- For feature/playbook work, prefer a branch and PR over direct `main` push.

## Final Check

```bash
git status --short
git log --oneline -3
```
