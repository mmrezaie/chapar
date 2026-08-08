# Chapar project skills

`.agents/skills/` is the one skill directory. Codex and OpenCode discover it
themselves, and Claude Code reaches the same files through the `.claude/skills`
symlink. Nothing declares a skill path in configuration, so there is no wiring
to keep in step. `AGENTS.md` holds the baseline rules and the harness table;
focused skills hold workflow detail.

Adding a skill means creating `.agents/skills/<name>/SKILL.md` and adding a row
to the Project Skills table in `AGENTS.md`. That is the whole procedure.

## Conventions

All software workflows start from `envs/software/spack.yaml`, a reviewed
`datacenters/<id>` snapshot, and resolver-produced `selection.json` plus
`selection.sha256`. Skills must not restore old environment, profile, or
site-file authority, and must not copy the canonical runnable flow out of
`README.md` — link to it instead.

Keep the public `nvidia-vlad` and `ubuntu-hpcsim` IDs. Keep `vlad-image` only
where historical internal runtime paths, units, and variables require it.

Validate edited skills with the local `skill-creator` validator and preserve the
human-only attribution policy.
