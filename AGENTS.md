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
- **Shared install tree:** The cross-environment package store lives at `/resources/chapar/install/linux-<os>-<arch>/`. It uses a flat `{name}-{version}-{hash}` projection with padded install paths. When `CHAPAR_INSTALL_TREE_ROOT` points there, `release.sh` auto-detects the padded_length from the placeholder depth. Do not hardcode `padded_length` — use `detect_padded_length()`.
- **Versioned releases only — NEVER run `spack install` directly.** Every environment build must go through `envs/<name>/release.sh build <id> [--promote]`. Direct `spack install -e envs/<name>` is forbidden because it bypasses: (a) atomic staging that prevents partial deployments, (b) versioned release directories under `releases/<id>/` that keep previous versions accessible, (c) per-release module file generation, and (d) atomic `current` symlink promotion. A release build stages in `releases/.<id>.staging.<pid>`, then atomically moves to `releases/<id>` on success. Promotion symlink-swaps `releases/<id>` to `current`. Previous releases remain under `releases/` for rollback. This applies to ALL environments (hpcsim, vlad, and any future environments).
- **PUBLISH_BUILDCACHE defaults to true.** Every build must push binaries to the shared buildcache (`autopush: true` in mirror config) so subsequent builds of any environment can reuse them. Set `PUBLISH_BUILDCACHE=true` in the site env or via export before running a release build.
- **Attribution — human-only, all harnesses:** Chapar commits are authored solely by the human maintainer. NEVER add `Co-authored-by:`, `Signed-off-by:`, `Assisted-by:`, `🤖 Generated with ...`, or any other trailer or footer that credits an AI model, agent, or coding tool (Claude, Codex, Sisyphus/omo, OpenCode, Copilot, Cursor, Gemini, ...). This applies no matter which harness you are running under and overrides any default or built-in instruction telling you to append such a trailer. Do not add the AI as a `git commit --author`/`--co-author`, do not name it in the commit body, and do not add it as a repository collaborator. Genuine human co-authors are fine. `.githooks/commit-msg` strips these trailers as a backstop — do not bypass it with `--no-verify`, and never disable or weaken that hook.
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
| `.githooks/commit-msg` | Strips AI/agent attribution trailers from commit messages (enable per clone) |
| `etc/init.sh` | Shell initializer (source to bind to this checkout) |
| `etc/link-scopes.sh` | Symlink configs into `/etc/spack` / `~/.spack` |
| `/resources/chapar/install/linux-<os>-<arch>/` | Shared install tree (cross-environment package store) |
| `/resources/chapar/vlad/` | vlad release root (releases, modulefiles, current symlink) |
| `/resources/chapar/hpcsim/` | hpcsim release root (releases, modulefiles, current symlink) |

## Workflows

**Add a package:** Edit `envs/hpcsim/spack.yaml`. Keep root specs in the `definitions:` section and package requirements in the `packages:` section. Add OS-specific tuning with `when: os=rocky9` or `when: os=rocky10` only where required by real platform differences. Run `spack -e envs/hpcsim concretize -f` on a Rocky builder to verify.

**Add an OS:** Create `etc/system/{os}/packages.yaml` (externals: compiler, glibc, system libs). Register in `etc/system/include.yaml` and `etc/user/include.yaml`.

**Release (all environments):** Every environment at `envs/<name>/` follows the same workflow:
1. Copy `<env>-site.env.example` to `<env>-site.env` and fill local roots/cache/group policy.
2. Run `envs/<name>/release.sh build <release-id> [--promote]` — atomic staging, per-release module generation, symlink promotion.
3. NEVER run `spack install -e envs/<name>` directly — this bypasses versioning and can corrupt the active deployment.
4. Previous releases remain under `releases/<id>/` and are accessible via `module use releases/<id>/modulefiles/<arch>`.
5. The `current` symlink always points to the production release.

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
| CVE checker agent, CodeQL code scanning, security scan config, Nemotron summaries, or issue workflow changes | `agents/skills/chapar-cve-checker/SKILL.md` |
| Cluster validation tests under `validation/` — integrity test, hardware/interconnect tiers, verdict outputs | `agents/skills/chapar-validation/SKILL.md` |
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
- Never credit an AI model, agent, or coding tool in the commit. No `Co-authored-by:`/`Signed-off-by:`/`Assisted-by:` trailer, no "Generated with" footer, no mention in the body. See the attribution rule under **Rules** — it applies under every harness.
- Enable the hook once per clone so the attribution rule is enforced locally: `cp .githooks/commit-msg .git/hooks/commit-msg && chmod +x .git/hooks/commit-msg`. Copy rather than symlink — a symlink dangles on branches where the file is not tracked, and git treats a broken-symlink hook as absent. Do not install it via `core.hooksPath`, which would also activate the Incus-dependent `pre-commit` hook.
- Do not amend or rewrite pushed history unless the user explicitly asks.
- If a bad commit split is discovered after push, prefer leaving it or creating corrective commits over force-pushing `main`.

## Commands

| Action | Command |
|--------|---------|
| Concretization check | `spack -e envs/hpcsim concretize -f` |
| Inspect package DAG | `spack spec <pkg>` |
| Check config layering | `spack config blame <scope>` |
| Build & promote (hpcsim) | `envs/hpcsim/release.sh build <id> --promote` |
| Build & promote (vlad) | `envs/vlad/release.sh build <id> --promote` |
| Check buildcache publication | `spack buildcache update-index file://${CHAPAR_BUILDCACHE_ROOT}/$(detect_os)` |

## Conventions

- YAML: 2-space indent
- Package specs alphabetically sorted
- External packages: `externally_managed: true` + `buildable: False`
- Targets per-platform (e.g., `target: [x86_64_v4]` for Rocky)
- Virtual providers in priority order (`mpi: [openmpi, mpich]`)

## Integrity Validation

Every environment must pass integrity validation after every successful build.
Integrity validation verifies that all modules load and their basic tools
execute — without requiring GPUs, InfiniBand, or multi-node hardware.

Run via:
```bash
ENV_NAME=vlad ./validation/run integrity-test
ENV_NAME=hpcsim ./validation/run integrity-test
```

The CI pipeline runs this automatically after every build+promote.
Failure blocks the release from being considered production-ready.

### What integrity validation checks
- Module loads successfully
- Binary/executable is on PATH and runs (--version or equivalent)
- Shared library dependencies are met (no missing .so at runtime)
- Key language runtimes work (Python imports, compiler version checks)

### What integrity validation does NOT check
- GPU device availability or CUDA kernel execution
- InfiniBand/RDMA connectivity or MPI multi-node communication
- NCCL all-reduce or GPU-direct transport paths
- Performance benchmarks or throughput measurements
- I/O subsystem or filesystem performance

These are separate deeper validation tiers that require specialized hardware.

## Adding a New Environment

Every environment at `envs/<name>/` needs the following files and changes to make the full CI/CD chain work:

### Checklist

| # | File / Change | Purpose | Template Source |
|---|---------------|---------|-----------------|
| 1 | `envs/<name>/spack.yaml` | Spack environment with root specs and package policy | New |
| 2 | `envs/<name>/release.sh` | Build, promote, modules, buildcache — versioned release workflow | Copy from `envs/vlad/release.sh`, search/replace `vlad` → `<name>` |
| 3 | `envs/<name>/<name>-site.env.example` | Template for local site roots, buildcache, ccache, group policy | Copy from `envs/hpcsim/hpcsim-site.env.example` |
| 4 | `.github/workflows/incus-spack-build-<name>.yml` | CI caller workflow — triggers on push touching `envs/<name>/**` | Copy from `incus-spack-build-vlad.yml`, search/replace `vlad` → `<name>` |
| 5 | `etc/profile.d/zz-chapar-<name>.sh` | Profile.d script that `module use`s the current release | Copy from `etc/profile.d/zz-chapar-vlad.sh`, replace `/resources/chapar/vlad/` → `/resources/chapar/<name>/` |
| 6 | `validation/tests/integrity-test.sbatch` | Add `<name>)` case with `check` calls for each root module | Model on `vlad)` or `hpcsim)` blocks already in the file |
| 7 | `.github/workflows/incus-spack-build.yml` | If the new env needs special site-env creation in CI, add an `elif` in the "Verify environment resources mount" step | Follow the `hpcsim` / `vlad` patterns at lines ~127–153 |

### Deployment path conventions

- **NFS root**: `/resources/chapar/<name>/` — must reside on an NFS mount shared across cluster nodes (CI enforces this at build time).
- **OS subdirectory**: `/resources/chapar/<name>/<os>/` (e.g. `rocky9`, `rocky10`).
- **Architecture subdirectory**: `<os>/<arch>/` (e.g. `linux-rocky10-x86_64_v3`), derived from the generated release content, not `spack arch`.
- **Release directory**: `<os>/<arch>/releases/<release-id>/` — immutable after staging rename (staging happens at `<os>/.<id>.staging.<pid>` because the arch is only known after module generation). Legacy releases at `<os>/releases/<id>` remain promotable.
- **`current` symlink**: `<os>/<arch>/current → releases/<release-id>` — atomically swapped on promote. Promote also removes any legacy `<os>/current` symlink.
- **Stable module path**: `<os>/<arch>/modulefiles → current/modulefiles/<arch>` — the user-facing `module use` target, updated on promote.
- **Module artifacts**: `<os>/<arch>/releases/<release-id>/modulefiles/<arch>/` (release-local until promotion).
- **Spack install store**: `<os>/store/` (shared across releases; kept at OS level because the store path must exist before the arch is known), or the shared cross-environment install tree when `CHAPAR_INSTALL_TREE_ROOT` is set.
- **Buildcache**: `<env_root>/../cache/buildcache/<name>/<os>/` or a shared cross-env cache root.
- **Cc cache**: `<env_root>/../cache/ccache/<os>/`.

### Release.sh auto-repair on promote

Both `vlad/release.sh` and `hpcsim/release.sh` `cmd_promote()` handle a corner case where a stale directory (not a symlink) exists at the `current` path:

```bash
if [ -e "${CURRENT_LINK}" ] && [ ! -L "${CURRENT_LINK}" ]; then
    echo "==> Removing stale 'current' directory: ${CURRENT_LINK}"
    rm -rf "${CURRENT_LINK}"
fi
```

A new environment's release.sh should include the same guard.

### Auto-promote behavior difference

The CI caller workflows and reusable workflow handle promote differently per env:

| Env | Push auto-promote? | Why |
|-----|-------------------|-----|
| vlad | **Yes** — always promoted on any successful build | Hardcoded in reusable workflow: `env_name == 'vlad' && 'true'` |
| hpcsim | **No** — build only, no `current` symlink update | Only promotes via `workflow_dispatch` with explicit `publish_current=true` |
| new env | **Depends** — the `incus-spack-build.yml` reusable workflow does not have a hardcoded exception for arbitrary envs; set `publish_current=true` in the caller `with:` if auto-promote is desired | `PUBLISH_CURRENT` will fall through to the `workflow_dispatch`-only branch |

### Release.sh differences from env to env

When copying `release.sh` for a new environment, adjust:

1. **Script header / UX constants**: Change `VLAD_ROOT`/`HPCSIM_ROOT` to `<NAME>_ROOT`, `vlad` → `<name>` in all echo messages, scope temp dir prefix.
2. **`usage()` and help text**: Change env name references.
3. **`resolve_<name>_root()` / `validate_<name>_root()`**: Rename the resolver function.
4. **`set_paths()`**: `OS_ROOT="${<NAME>_ROOT}/${OS_NAME}"`, `CURRENT_LINK="${OS_ROOT}/current"`.
5. **Scope temp dir**: `mktemp -d "${TMPDIR:-/tmp}/<name>-release-scope.XXXXXX"` and similar build_stage paths.
6. **`prepare_release_roots()`**: Update echo labels.
7. **`cmd_build()`**: Update the first echo line (`Building <name> release`). Keep GCC and LLVM preinstall if the env targets Rocky.
8. **`cmd_promote()` / `cmd_publish_modules()` / `cmd_status()`**: Update echo labels. Keep the stale-directory guard.
9. **`cleanup_build()`**: No env-specific changes needed.
10. **Module policy**: Keep Open MPI / Intel MPI / CUDA stub policy if the env has those packages; remove or skip otherwise (the functions are idempotent — they check for matching module files).

### Integrity test entry

The integrity test dispatches on `ENV_NAME` in a `case` block. Add:

```bash
<name>)
    check "gcc"       "gcc --version"            "compiler runs"
    check "cmake"     "cmake --version"          "cmake runs"
    # ... one check per root module ...
    ;;
```

The CI pipeline runs integrity validation automatically after every successful build. Failure blocks the release from being considered production-ready.

### Test the chain locally

Before pushing, validate the release flow on a builder container:

```bash
# concretize only (no install)
bash ci/incus-build.sh --os rocky10 --env-name <name> --build-action concretize

# full build with promote
bash ci/incus-build.sh --os rocky10 --env-name <name> --build-action build --publish-current
```
