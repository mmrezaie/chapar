# AGENTS.md — Chapar

## Rules

- NEVER modify `spack/` submodule. All local policy lives in `etc/` and `envs/`.
- Do not add or override package recipes in `spack_repo/` unless the user explicitly asks to add a package there.
- NEVER edit generated/lock files (`.spack-env/`, lockfiles, caches).
- DO NOT pin dependency minor/patch versions on concretization. Use major version only (`gcc@15` not `gcc@15.2.0`).
- **GCC:** hpcsim targets Rocky 9 and Rocky 10 and uses one Spack-built GCC 15 compiler stack for the whole environment. Use the OS GCC only to bootstrap GCC 15.
- **Python/Tk:** hpcsim may expose multiple Python minor-version roots. Keep `+tkinter` only on explicit Python root specs, or on root specs that truly need a Tk-enabled Python dependency. Package-wide `python:` policy should constrain allowed minor versions only; do not add package-wide `+tkinter`.
- **Intel compiler:** Always use the latest available version.
- **MPI:** Always use the latest available version. Prefer Open MPI.
- **GPUDirect:** hpcsim Linux transport layers must keep CUDA/GDR-capable builds. Keep UCX, Open MPI, and libfabric CUDA-aware with GDRCopy where supported; do not disable CUDA/GDR transport support to work around downstream build failures.
- **Rocky builders:** Do not install or rely on OS CUDA Toolkit, OS Intel oneAPI compiler/MPI, or GitHub CLI RPMs for hpcsim builds. CUDA, Intel MPI, and any future Intel compiler dependency must come from Spack unless the user explicitly changes this policy.
- **LLVM:** Always use the latest available major version. For LLVM 15+, do not add `+cuda`; Spack marks that variant obsolete. Use NVPTX targets/offload variants as needed, and prefer latest LLVM over downgrading only to satisfy LLVM `+cuda`.
- **Build cache:** Prefer binary caching (`spack mirror`) over building from source.
- **Commits:** Before pushing commits, split changes by purpose and future review context. Do not mix documentation/comment-only changes with behavior, config, or CI changes unless they are inseparable; if inseparable, explain why in the commit body.
- **Commit messages:** Explain the root cause, why the approach was chosen, important constraints preserved, and validation performed. Avoid messages that only restate the diff. Use `[skip ci]` only when intentionally avoiding push-triggered workflows.
- **hpcsim buildcache migration:** Do not make hpcsim release builds auto-import legacy buildcaches. Use an explicit one-time migration only for caches marked with the current padded install-tree layout, then retire stale cache directories after validation.
- **Rocky builder cleanup:** After Rocky 9/Rocky 10 container validation, leave only files and directories needed by the current Chapar codebase; remove stale staging, run, and legacy-cache artifacts that can confuse later debugging.
- Config scope hierarchy: `defaults > system > site > user > spack > environment > command line`.
- OS-specific overrides use `include.yaml` with `when:` conditionals.

## Key Paths

| Path | Purpose |
|------|---------|
| `etc/system/` | Machine-level configs (providers, mirrors, build settings) |
| `etc/system/base/` | Cross-platform: concretizer, config, mirrors, packages, repos |
| `etc/system/{rocky9,rocky10,linux}/` | OS-specific external packages |
| `etc/user/` | Per-user configs (install_tree, build_stage, modules) |
| `etc/user/base/` | Cross-platform user settings |
| `envs/hpcsim/spack.yaml` | Canonical hpcsim environment entry point |
| `envs/hpcsim/release.sh` | hpcsim release, module, and buildcache helper |
| `envs/hpcsim/hpcsim-site.env.example` | Template for local site roots, shared buildcache, shared ccache, and group policy |
| `etc/init.sh` | Shell initializer (source to bind to this checkout) |
| `etc/link-scopes.sh` | Symlink configs into `/etc/spack` / `~/.spack` |

## Workflows

**Add a package:** Edit `envs/hpcsim/spack.yaml`. Keep root specs in the `definitions:` section and package requirements in the `packages:` section. Add OS-specific tuning with `when: os=rocky9` or `when: os=rocky10` only where required by real platform differences. Run `spack -e envs/hpcsim concretize -f` on a Rocky builder to verify.

**Add an OS:** Create `etc/system/{os}/packages.yaml` (externals: compiler, glibc, system libs). Register in `etc/system/include.yaml` and `etc/user/include.yaml`.

**Release:** Copy `envs/hpcsim/hpcsim-site.env.example` to ignored `envs/hpcsim/hpcsim-site.env`, fill the local roots/cache/group policy, then run `envs/hpcsim/release.sh` or the Rocky 9/Rocky 10 sbatch wrappers. Release builds into a staging tree, refresh root-only modules, and promote via atomic symlink swap.

**Deploy config:** Run `etc/link-scopes.sh` or source `etc/init.sh`.

## Project Skills

Chapar keeps project-local agent skill playbooks under `agents/skills/`. When a task
matches one of these areas, load the matching skill if the runtime exposes it;
otherwise read the skill's `SKILL.md` before changing files.

| Task | Skill |
|------|-------|
| Spack environment package/root spec or package policy changes under `envs/<name>` | `agents/skills/chapar-spack-env-change/SKILL.md` |
| Spack concretization failures, solver timeouts, provider conflicts, or config layering debug | `agents/skills/chapar-spack-solve-debug/SKILL.md` |
| Persistent Spack scope changes under `etc/system` or `etc/user` | `agents/skills/chapar-config-scope-change/SKILL.md` |
| Commits, pushes, branch prep, or PR prep | `agents/skills/chapar-commit/SKILL.md` |
| hpcsim release helper changes in `envs/hpcsim/release.sh` | `agents/skills/chapar-release-helper/SKILL.md` |
| Buildcache layout, migration, quarantine, index refresh, or publication | `agents/skills/chapar-buildcache/SKILL.md` |
| Live CI/CD progress inspection via mounted artifact roots, logs, stores, releases, modulefiles, or caches | `agents/skills/chapar-ci-artifact-watch/SKILL.md` |
| CUDA/GDR transport work involving UCX, Open MPI, libfabric, GDRCopy, NCCL, or NVSHMEM | `agents/skills/chapar-cuda-gdr-transport/SKILL.md` |
| Incus-backed GitHub Actions or Rocky runner CI triage | `agents/skills/chapar-incus-ci-triage/SKILL.md` |
| CVE checker agent, security scan config, Nemotron summaries, or issue workflow changes | `agents/skills/chapar-cve-checker/SKILL.md` |
| Local Spack package overlay recipe or patch changes under `spack_repo/chapar_plus` | `agents/skills/chapar-spack-repo-overlay/SKILL.md` |
| OpenCode config, agent skill layout, skill migration, or project skill policy changes | `agents/skills/chapar-opencode-skills/SKILL.md` |
| Creating or improving `agents/skills` | `agents/skills/skill-creator/SKILL.md` |
| Visual diff help when VS Code CLI is available | `agents/skills/vscode/SKILL.md` |
| External web search when Brave Search credentials are configured | `agents/skills/brave-search/SKILL.md` |

`AGENTS.md` is baseline repository guidance, not a skill. Use it together with
the matching skill playbook when both apply.

## Commit Workflow

When asked to commit or push:

- Inspect `git status`, `git diff`, and recent `git log` before staging.
- Identify separate change contexts before committing, such as docs-only, behavior/config, CI, release tooling, and policy.
- Create separate commits for separate contexts even if the changes came from one user request.
- Prefer a short subject plus a body that records why the change exists and what risk it reduces.
- Do not amend or rewrite pushed history unless the user explicitly asks.
- If a bad commit split is discovered after push, prefer leaving it or creating corrective commits over force-pushing `main`.

## Commands

| Action | Command |
|--------|---------|
| Concretization check | `spack -e envs/hpcsim concretize -f` |
| Inspect package DAG | `spack spec <pkg>` |
| Check config layering | `spack config blame <scope>` |
| Build & promote | `envs/hpcsim/release.sh` |

## Conventions

- YAML: 2-space indent
- Package specs alphabetically sorted
- External packages: `externally_managed: true` + `buildable: False`
- Targets per-platform (e.g., `target: [x86_64_v4]` for Rocky)
- Virtual providers in priority order (`mpi: [openmpi, mpich]`)
