# Chapar Agent Resources

This directory contains project-local agent resources that are safe to version
with Chapar. OpenCode loads project skills from `agents/skills`.

- `skills/chapar-*`: Chapar-specific operational playbooks for CI triage,
  Spack solving, Spack environment package/spec changes, hpcsim release tooling,
  buildcache policy, CUDA/GDR transport policy, config scopes, CVE scanning,
  local Spack overlays, OpenCode skill/config maintenance, and commit workflow.
- `skills/chapar-spack-env-change` and `skills/chapar-spack-solve-debug` are
  environment-generic: use them for `envs/hpcsim` today and for future
  `envs/<name>` environments.
- `skills/chapar-release-helper` is intentionally hpcsim-specific because the
  current release helper is `envs/hpcsim/release.sh`.
- `skills/chapar-macos-ci-triage` covers native macOS self-hosted runner and CI
  failures; Linux Incus CI remains covered by `skills/chapar-incus-ci-triage`.
- `skills/chapar-cve-checker` covers the security scanner workflow and its
  restricted trust boundary.
- `skills/chapar-spack-repo-overlay` covers local Spack package recipes and
  patches under `spack_repo/chapar`.
- `skills/chapar-opencode-skills` covers OpenCode config, skill path migration,
  and agent playbook maintenance.
- `skills/brave-search`, `skills/vscode`: Generic skills copied from
  [`badlogic/pi-skills`](https://github.com/badlogic/pi-skills).
- `skills/skill-creator`: Generic skill copied from
  [`anthropics/skills`](https://github.com/anthropics/skills).
