# Chapar pi resources

This directory contains project-local pi resources that are safe to version with
Chapar.

- `skills/chapar-*`: Chapar-specific operational playbooks for CI triage,
  Spack solving, Spack environment package/spec changes, hpcsim release tooling,
  buildcache policy, CUDA/GDR transport policy, config scopes, and commit
  workflow.
- `skills/chapar-spack-env-change` and `skills/chapar-spack-solve-debug` are
  environment-generic: use them for `envs/hpcsim` today and for future
  `envs/<name>` environments.
- `skills/chapar-release-helper` is intentionally hpcsim-specific because the
  current release helper is `envs/hpcsim/release.sh`.
- `skills/brave-search`, `skills/vscode`: Generic skills copied from
  [`badlogic/pi-skills`](https://github.com/badlogic/pi-skills).
- `skills/skill-creator`: Generic skill copied from
  [`anthropics/skills`](https://github.com/anthropics/skills).

Keep personal or machine-local pi files out of git, especially
`settings.json`, `sandbox.json`, `git/`, and `npm/`.
