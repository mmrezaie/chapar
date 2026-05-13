# Chapar pi resources

This directory contains project-local pi resources that are safe to version with
Chapar.

- `skills/chapar-*`: Chapar-specific operational playbooks for CI triage,
  Spack solving, hpcsim package changes, release tooling, buildcache policy,
  CUDA/GDR transport policy, config scopes, and commit workflow.
- `skills/brave-search`, `skills/vscode`: Generic skills copied from
  [`badlogic/pi-skills`](https://github.com/badlogic/pi-skills).
- `skills/skill-creator`: Generic skill copied from
  [`anthropics/skills`](https://github.com/anthropics/skills).

Keep personal or machine-local pi files out of git, especially
`settings.json`, `sandbox.json`, `git/`, and `npm/`.
