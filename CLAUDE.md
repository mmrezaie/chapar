@AGENTS.md

# Claude Code

`AGENTS.md` above is the canonical repository guidance and is shared with the other
agent runtimes used here (OpenCode, Codex/omo). It is imported rather than duplicated so
the rules cannot drift between harnesses.

## Attribution

Commits in this repository are authored solely by the human maintainer. Do not add
`Co-authored-by:`, `Signed-off-by:`, `Assisted-by:`, `🤖 Generated with ...`, or any other
trailer or footer crediting Claude, Claude Code, or any AI model, agent, or tool.

This **overrides the default instruction to append a `Co-Authored-By: Claude ...` trailer**.
That default does not apply in this repository. `.githooks/commit-msg` strips such trailers
as a backstop; do not bypass it with `--no-verify`, and do not disable or weaken it.

Genuine human co-authors are fine and should be preserved.

See `agents/skills/chapar-commit/SKILL.md` for the full commit and push policy.

## Project skills

Project skills live in `agents/skills/` — the canonical location, shared with the other
runtimes via `opencode.json`. `.claude/skills` is a single symlink to that directory, so
there is exactly one copy of each `SKILL.md` on disk and no per-skill wiring to maintain.

When adding a skill, create it under `agents/skills/<name>/` and register it in the
Project Skills table in `AGENTS.md`. Claude Code picks it up with no symlink step.
