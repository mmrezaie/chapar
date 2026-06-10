---
name: chapar-spack-env-change
description: Add, remove, or reorganize packages/root specs in any Chapar Spack environment under envs. Use when changing hpcsim spack.yaml definitions, packages, providers, variants, or OS-specific package policy for hpcsim or future environments.
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
- For hpcsim Python roots, keep `+tkinter` on explicit root specs or root specs
  that truly need a Tk-enabled Python dependency. Do not add package-wide
  `python+tkinter`; package policy should only constrain allowed Python minor
  versions.

## Identify the Environment First

Before editing, identify the target environment and use a shell variable in
commands and notes:

```bash
ENV_PATH=envs/hpcsim        # or envs/<future-env>
```

If the user did not name an environment, inspect `envs/` and ask before making a
behavior change.

## Expected Layout

The current `hpcsim` environment is intentionally single-file for human review:

```text
envs/hpcsim/spack.yaml  # root specs, package policy, and module policy
```

Do not recreate `common/`, `linux/`, `rocky9/`, or `rocky10/` hpcsim package
policy directories unless the user explicitly asks for that split.

For a future environment with real cross-platform differences, prefer the
smallest readable layout. Start with one `spack.yaml`; add included config files
only when a single file becomes less readable.

Example multi-file layout for a future environment:

```text
envs/<env>/spack.yaml                 # environment entry point
envs/<env>/spack.yaml                 # environment entry point
envs/<env>/packages.yaml              # package policy, if too long for spack.yaml
```

A future environment may not need every scope. Add only the scopes required by
real cross-platform differences.

## Where Changes Belong

Root specs:

- hpcsim root specs go in `envs/hpcsim/spack.yaml` under `definitions:`.
- Use `when:` conditionals only where a spec is truly OS-specific.

Package policy:

- hpcsim package requirements go in `envs/hpcsim/spack.yaml` under `packages:`.
- Use OS-specific `when:` clauses only where needed.
- System/user external policy belongs under `etc/system/` and `etc/user/`, not in
  an environment, unless it is truly environment-specific.
- hpcsim `python:` package policy should use allowed minor-version constraints,
  such as `one_of: ['python@3.10:3.10', 'python@3.11:3.11',
  'python@3.12:3.12']`, and should not force `+tkinter` globally.

## Editing Procedure

1. Identify the target environment and whether the package is cross-platform,
   Linux-only, or OS-specific.
2. Add/remove the root spec in the environment's `definitions:` section.
3. Add package requirements only when needed for real platform/toolchain
   constraints.
4. Keep root specs and package sections alphabetically sorted when practical.
5. Avoid source-level package overrides in `spack_repo/` unless explicitly asked.
6. If creating a new environment, keep it readable and do not accidentally inherit
   hpcsim-only policy.

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

If local validation is not on Rocky 9 or Rocky 10, state that full validation
requires the Incus workflow, sbatch wrapper, or Rocky runner.

## Commit Split Guidance

Keep package/config behavior changes separate from documentation-only changes
unless they are inseparable. Use `chapar-commit` before committing.
