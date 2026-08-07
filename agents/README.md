# Chapar project skills

`agents/skills/` is the single project-skill source for OpenCode, Codex/omo,
and Claude Code. `AGENTS.md` supplies baseline rules; focused skills supply
workflow detail.

All software workflows now start from `envs/software/spack.yaml`, a reviewed
`datacenters/<id>` snapshot, and resolver-produced `selection.json` plus
`selection.sha256`. Skills must not restore old environment/profile/site-file
authority or copy the canonical runnable flow from `README.md`.

Harness wiring is intentionally shared:

- OpenCode and Codex/omo read `skills.paths: ["agents/skills"]` from
  `opencode.json`.
- `CLAUDE.md` imports `AGENTS.md` and `.claude/skills` is a directory symlink
  to `agents/skills`.

Keep the public `nvidia-vlad` and `ubuntu-hpcsim` IDs. Keep `vlad-image` only
where historical internal runtime paths, units, and variables require it.
Validate edited skills with the local `skill-creator` validator and preserve
the human-only attribution policy.
