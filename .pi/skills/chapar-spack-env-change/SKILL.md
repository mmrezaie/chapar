---
name: chapar-spack-env-change
description: Add, remove, or reorganize packages/root specs in any Chapar Spack environment under envs/<name>. Use when changing definitions.yaml, packages.yaml, providers, variants, or OS-specific package policy for hpcsim or future environments.
---

# Chapar Spack Environment Change

Use this playbook when editing root specs or package policy for any Chapar Spack
environment under `envs/<env-name>`. Today the main environment is `hpcsim`, but
Chapar is expected to grow more environments; do not hard-code hpcsim unless the
task is specifically about hpcsim.

## Rules

- Do not edit `spack/`.
- Do not edit generated lock/cache files or `.spack-env/` directories.
- Keep each environment with one clear entry point: `envs/<env-name>/spack.yaml`.
- Do not split an environment by release tier unless the user explicitly asks.
- Do not pin dependency minor/patch versions unless explicitly requested.
- Preserve Chapar's latest-major compiler/MPI/LLVM policy unless an environment
  has an explicit documented exception.
- Preserve CUDA/GDR transport support for Linux environments that require GPU
  transports, especially hpcsim.

## Identify the Environment First

Before editing, identify the target environment and use a shell variable in
commands and notes:

```bash
ENV_PATH=envs/hpcsim        # or envs/<future-env>
```

If the user did not name an environment, inspect `envs/` and ask before making a
behavior change.

## Expected Layout

For an environment with OS-specific policy, prefer this layout:

```text
envs/<env>/spack.yaml                 # environment entry point
envs/<env>/common/definitions.yaml    # cross-platform root specs
envs/<env>/common/packages.yaml       # cross-platform package policy
envs/<env>/linux/definitions.yaml     # all Linux root specs
envs/<env>/linux/packages.yaml        # all Linux package policy
envs/<env>/rocky8/definitions.yaml    # Rocky 8 only
envs/<env>/rocky8/packages.yaml
envs/<env>/rocky9/definitions.yaml    # Rocky 9 only
envs/<env>/rocky9/packages.yaml
envs/<env>/macos/definitions.yaml     # macOS only
envs/<env>/macos/packages.yaml
```

A future environment may not need every scope. Add only the scopes required by
real cross-platform differences.

## Where Changes Belong

Root specs:

- Cross-platform specs go in `envs/<env>/common/definitions.yaml`.
- Linux-only specs go in `envs/<env>/linux/definitions.yaml`.
- OS-only specs go in `envs/<env>/{rocky8,rocky9,macos}/definitions.yaml`.

Package policy:

- Put requirements in the matching `packages.yaml` at the narrowest scope.
- Use OS-specific `when:` clauses only where needed.
- System/user external policy belongs under `etc/system/` and `etc/user/`, not in
  an environment, unless it is truly environment-specific.

## Editing Procedure

1. Identify the target environment and whether the package is cross-platform,
   Linux-only, or OS-specific.
2. Add/remove the root spec in the narrowest correct `definitions.yaml` group.
3. Add package requirements only when needed for real platform/toolchain
   constraints.
4. Keep root specs and package sections alphabetically sorted when practical.
5. Avoid source-level package overrides in `spack_repo/` unless explicitly asked.
6. If creating a new environment, ensure `spack.yaml` includes the right scopes
   with `when:` conditionals and does not accidentally inherit hpcsim-only policy.

## Validation

```bash
source ./etc/init.sh
spack -e "${ENV_PATH}" concretize -f
```

For package-specific debugging:

```bash
spack -e "${ENV_PATH}" spec <pkg>
spack -e "${ENV_PATH}" config blame packages
```

If the change is Linux-only but local validation is macOS, state that full Rocky
validation requires the Incus workflow or Rocky runner.

## Commit Split Guidance

Keep package/config behavior changes separate from documentation-only changes
unless they are inseparable. Use `chapar-commit` before committing.
