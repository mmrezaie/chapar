# AGENTS.md — Chapar

## Rules

- NEVER modify `spack/` submodule. All local policy lives in `etc/` and `envs/`.
- Do not add or override package recipes in `spack_repo/` unless the user explicitly asks to add a package there.
- NEVER edit generated/lock files (`.spack-env/`, lockfiles, caches).
- DO NOT pin dependency minor/patch versions on concretization. Use major version only (`gcc@15` not `gcc@15.2.0`).
- **GCC:** Use the system compiler for the target OS by default (e.g., Rocky 9 → GCC 11.x). For packages that cannot build with the system compiler, use a Spack-provided GCC — always the latest available version.
- **Intel compiler:** Always use the latest available version.
- **MPI:** Always use the latest available version. Prefer Open MPI.
- **LLVM:** Always use the latest available major version. For LLVM 15+, do not add `+cuda`; Spack marks that variant obsolete. Use NVPTX targets/offload variants as needed, and prefer latest LLVM over downgrading only to satisfy LLVM `+cuda`.
- **Build cache:** Prefer binary caching (`spack mirror`) over building from source.
- Config scope hierarchy: `defaults > system > site > user > spack > environment > command line`.
- OS-specific overrides use `include.yaml` with `when:` conditionals.

## Key Paths

| Path | Purpose |
|------|---------|
| `etc/system/` | Machine-level configs (providers, mirrors, build settings) |
| `etc/system/base/` | Cross-platform: concretizer, config, mirrors, packages, repos |
| `etc/system/{rocky8,rocky9,macos,linux,darwin}/` | OS-specific external packages |
| `etc/user/` | Per-user configs (install_tree, build_stage, modules) |
| `etc/user/base/` | Cross-platform user settings |
| `envs/skipper/spack.yaml` | Canonical environment spec |
| `envs/skipper/{rocky8,rocky9}/packages.yaml` | Per-OS target tuning |
| `etc/init.sh` | Shell initializer (source to bind to this checkout) |
| `etc/link-scopes.sh` | Symlink configs into `/etc/spack` / `~/.spack` |

## Workflows

**Add a package:** Add spec to `envs/skipper/spack.yaml` (alphabetically). Add OS-specific tuning to `envs/skipper/{os}/packages.yaml` if needed. Run `spack concretize -f` to verify.

**Add an OS:** Create `etc/system/{os}/packages.yaml` (externals: compiler, glibc, system libs). Register in `etc/system/include.yaml` and `etc/user/include.yaml`. Optionally add `envs/skipper/{os}/`.

**Release:** Run `envs/skipper/release.sh` — builds into isolated root, runs test hints, promotes via atomic symlink swap.

**Deploy config:** Run `etc/link-scopes.sh` or source `etc/init.sh`.

## Commands

| Action | Command |
|--------|---------|
| Concretization check | `spack concretize -f` |
| Inspect package DAG | `spack spec <pkg>` |
| Check config layering | `spack config blame <scope>` |
| Build & promote | `envs/skipper/release.sh` |

## Conventions

- YAML: 2-space indent
- Package specs alphabetically sorted
- External packages: `externally_managed: true` + `buildable: False`
- Targets per-platform (e.g., `target: [x86_64_v4]` for Rocky)
- Virtual providers in priority order (`mpi: [openmpi, mpich]`)
