---
name: chapar-macos-ci-triage
description: Triage Chapar native macOS self-hosted hpcsim CI failures, runner registration, Homebrew bootstrap, macOS buildcache paths, and macOS workflow changes. Use for .github/workflows/macos-spack-build.yml, ci/bootstrap-macos.sh, ci/register-macos-runner.sh, docs/ci-macos.md, or macOS-specific hpcsim build failures.
---

# Chapar macOS CI Triage

Use this playbook for native macOS self-hosted GitHub Actions builds of hpcsim.
Linux Incus failures use `chapar-incus-ci-triage` instead.

## First Principles

- macOS artifacts must be built on a native macOS runner. Do not use Docker,
  Colima, or Linux containers for macOS Spack artifacts.
- The workflow target is `.github/workflows/macos-spack-build.yml` and currently
  builds `envs/hpcsim`.
- The runner uses labels `self-hosted`, `chapar`, `macos`, and `arm64` unless the
  workflow input intentionally changes the common label.
- The workflow uses a dedicated Spack checkout at
  `~/.local/opt/spack-chapar-macos` and must not mutate a user's normal Spack
  checkout.
- User-local default roots are intentional because the macOS runner may not mount
  the NAS.

## Key Files

```text
.github/workflows/macos-spack-build.yml
ci/bootstrap-macos.sh
ci/register-macos-runner.sh
ci/container-build.sh
ci/prepare-hpcsim-root.sh
docs/ci-macos.md
envs/hpcsim/release.sh
```

## Common Failure Classes

- Runner scheduling: missing self-hosted labels, offline launchd service, or wrong
  architecture.
- Bootstrap: missing Xcode command line tools, Homebrew, GCC/GFortran 15, ccache,
  GNU build tools, Python, or environment modules.
- Resource path validation: unsafe `hpcsim_root` or `buildcache_root`, unwritable
  release/cache directories, or missing user-local defaults.
- Spack setup: dedicated Spack checkout update failure or bad `spack_ref`.
- Concretization/build: use `chapar-spack-solve-debug` and preserve macOS package
  policy.
- Buildcache/release-helper: use `chapar-buildcache` or `chapar-release-helper`
  when the failure involves cache publication, staging, promotion, or modules.

## macOS Policy Notes

- Homebrew GCC/GFortran are expected externals on macOS.
- Thunderbolt Bridge is treated as IP networking; macOS MPI policy uses OFI TCP
  providers, not Linux RDMA verbs.
- Keep macOS cache/release roots distinct from Rocky roots.
- Use unsafe root overrides only for controlled local tests.

## Required Inspection

```bash
git status --short
gh run list --workflow macos-spack-build.yml --limit 10
gh run view <run-id> --json jobs,conclusion,displayTitle,headSha,headBranch,event
```

For local runner debugging, inspect `docs/ci-macos.md` before changing bootstrap
or registration behavior.

## Validation

```bash
bash -n ci/bootstrap-macos.sh
bash -n ci/register-macos-runner.sh
bash -n ci/container-build.sh
bash -n ci/prepare-hpcsim-root.sh
bash -n envs/hpcsim/release.sh
git diff --check
```

Do not run bootstrap or build commands that install packages or publish releases
unless the user explicitly asks.
