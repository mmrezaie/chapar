---
name: chapar-spack-solve-debug
description: Debug Chapar Spack concretization problems, solver timeouts, provider conflicts, and config layering for any envs/<name> environment. Use for `spack -e envs/<env> concretize`, solver errors, or package constraint changes.
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

For environments that use Chapar's include-scope layout, place files as follows:

- Cross-platform specs: `envs/<env>/common/definitions.yaml`
- Linux-only specs: `envs/<env>/linux/definitions.yaml`
- Rocky 8-only specs: `envs/<env>/rocky8/definitions.yaml`
- Rocky 9-only specs: `envs/<env>/rocky9/definitions.yaml`
- macOS-only specs: `envs/<env>/macos/definitions.yaml`

Package requirements belong in the matching `packages.yaml` in the same scope
level. Future environments may not need every scope; add only the scopes required
by real platform differences.

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
- Old system compiler on Rocky 8: prefer `%gcc@15` constraints in Rocky 8 scope
  for packages that need a newer compiler.
- CUDA-aware MPI stack: use `chapar-cuda-gdr-transport`; do not disable `+cuda`,
  GDRCopy, UCX, Open MPI, or libfabric capability to pass a build.
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
