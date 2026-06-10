---
name: chapar-spack-solve-debug
description: Debug Chapar Spack concretization problems, solver timeouts, provider conflicts, and config layering for any environment under envs. Use for spack environment concretize commands, solver errors, or package constraint changes.
---

# Chapar Spack Solve Debug

Use this playbook for concretization failures, long solver runs, provider
conflicts, or package constraint edits in any Chapar environment under
`envs/<env-name>`. Do not assume `hpcsim` unless the user or failing workflow is
specifically about hpcsim.

## Guardrails

- Never edit the `spack/` submodule.
- Never edit generated files/directories: `.spack-env/`, lockfiles, caches.
- Do not pin dependency minor/patch versions on concretization. Use major
  versions only unless the user explicitly asks.
- Prefer latest available major versions for GCC, Intel compiler, MPI, LLVM, and
  CUDA policy already documented for the target environment.
- Preserve CUDA/GDR support for environments that require GPU transports,
  especially hpcsim.
- Put shared policy in shared scopes; OS-specific policy in OS-specific scopes.

## Identify the Target Environment

Set `ENV_PATH` before running commands:

```bash
ENV_PATH=envs/hpcsim        # or envs/<future-env>
```

If the user did not name an environment, inspect `envs/` and ask before changing
behavior. When reading CI logs, derive `ENV_PATH` from the workflow or build
script rather than assuming hpcsim.

## Load Chapar Environment

```bash
source ./etc/init.sh
spack --version
spack config scopes -p
spack arch
```

Confirm the selected OS scope is present through `etc/*/include.yaml` and the
target environment's `spack.yaml` includes.

## Inspect Effective Config

```bash
spack -e "${ENV_PATH}" config blame packages
spack -e "${ENV_PATH}" config blame concretizer
spack -e "${ENV_PATH}" config blame config
```

For a specific package/provider:

```bash
spack -e "${ENV_PATH}" spec <pkg>
spack -e "${ENV_PATH}" spec <pkg> %gcc@15
```

## Scope Placement Rules

For hpcsim, root specs and package requirements belong in
`envs/hpcsim/spack.yaml`. Use `when:` conditionals only for real Rocky 9/Rocky 10
differences. Future environments may use included scopes, but inspect their own
layout before moving policy.

## Concretization Checks

Primary check:

```bash
spack -e "${ENV_PATH}" concretize -f
```

If solving stalls, narrow the problem:

```bash
spack -e "${ENV_PATH}" spec <root-spec>
spack -e "${ENV_PATH}" spec <root-spec> ^<suspected-dependency>
```

For release-helper or CI context, include any generated command-line scope shown
in the logs. Do not manually create permanent config for release-only roots; the
release/build helper should generate that scope.

## Common Failure Patterns

- C/C++/Fortran provider conflict: inspect `c`, `cxx`, and `fortran` virtual
  package requirements in the relevant scope.
- Compiler provider conflict: hpcsim should use the Spack-built GCC 15 stack for
  Rocky 9 and Rocky 10, with the OS GCC used only to bootstrap GCC 15.
- CUDA-aware MPI stack: use `chapar-cuda-gdr-transport`; do not disable `+cuda`,
  GDRCopy, UCX, Open MPI, or libfabric capability to pass a build.
- Python root conflicts: if hpcsim has multiple Python minor-version roots, keep
  `+tkinter` on explicit Python roots only. A package-wide `python+tkinter`
  requirement can make otherwise valid `python@3.10`, `python@3.11`, or
  `python@3.12` roots unsatisfiable.
- Visualization or frontend packages pulling Node/C++ requirements: constrain
  compiler provider, not source package patch levels unless requested.

## Validation Before Finishing

Run the narrowest meaningful validation and report exactly what was run:

```bash
spack -e "${ENV_PATH}" concretize -f
git diff --check
```

If the work touched `envs/hpcsim/release.sh`, also run:

```bash
bash -n envs/hpcsim/release.sh
```
