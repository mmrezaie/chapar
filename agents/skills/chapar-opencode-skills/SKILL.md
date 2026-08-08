---
name: chapar-opencode-skills
description: Maintain Chapar OpenCode configuration, shared harness skill wiring, AGENTS.md, agents/README.md, and focused project skills.
---

# Chapar harness skills

`agents/skills` is the single skill source. OpenCode/Codex use
`opencode.json`; Claude imports `AGENTS.md` through `CLAUDE.md` and discovers
the same directory through `.claude/skills`. Keep permissions narrow and never
reintroduce legacy Pi paths.

All software-related skills must route through `envs/software/spack.yaml`,
reviewed `datacenters/<id>` snapshots, and resolver-produced
`selection.json`/recorded `selection.sha256`. They must distinguish offline evidence
from deferred platform gates, preserve immutable legacy roots, retain public
container IDs and internal `vlad-image` compatibility, and link to the single
runnable offline sequence in `README.md` rather than duplicating it.

Use `skill-creator` for substantive skill edits. Validate frontmatter, shared
wiring, stale active authority, human-only attribution, and `git diff --check`.
