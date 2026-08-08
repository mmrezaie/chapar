---
name: chapar-opencode-skills
description: Maintain Chapar OpenCode configuration, agent skill layout, project skill migration, permission rules, AGENTS.md, and agents/skills playbooks. Use when changing opencode.json, creating or moving project skills, updating skill trigger policy, or removing legacy Pi skill references.
---

# Chapar OpenCode Skills

Use this playbook when editing OpenCode-facing agent configuration or the
project-local skill catalog under `agents/skills`.

## Scope

Key files:

```text
opencode.json
AGENTS.md
agents/README.md
agents/skills/*/SKILL.md
```

Use `skill-creator` too when creating or substantially rewriting a skill.

## Invariants

- OpenCode project skills live under `agents/skills`.
- Do not reintroduce legacy Pi skill paths or project state.
- Keep `AGENTS.md` as baseline repository guidance; keep detailed workflow logic
  in focused skills.
- Keep `opencode.json` permissions narrow and task-oriented. Do not add broad
  write, shell, token, or secret access just to make a workflow convenient.
- Do not allow edits to `spack/`, `.spack-env/`, lockfiles, or `.git/`.
- Skill descriptions should be trigger-oriented and specific enough for OpenCode
  to select the right playbook without over-triggering unrelated tasks.

## Editing Procedure

1. Identify whether the change is config, skill content, skill layout, or docs.
2. For new skills, create `agents/skills/<name>/SKILL.md` with kebab-case `name`
   and a description that states when to use it.
3. Update `AGENTS.md` when the skill covers a repository workflow that agents
   must consult before changing files.
4. Update `agents/README.md` when the catalog structure or major skill set
   changes.
5. Update `opencode.json` only for paths and commands the skills actually need.
6. Keep behavior/config changes separate from documentation-only changes when
   committing.

## Validation

```bash
python3 agents/skills/skill-creator/scripts/quick_validate.py agents/skills/<skill-name>
git diff --check
```

Search for stale paths before finishing:

```bash
rg 'legacy Pi|pi/skills' AGENTS.md agents opencode.json .gitignore
```

If historical Pi references remain only in external upstream links, call that out
explicitly.
