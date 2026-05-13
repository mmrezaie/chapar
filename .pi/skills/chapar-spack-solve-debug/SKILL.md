---
name: chapar-spack-solve-debug
description: Debug Chapar Spack concretization problems, solver timeouts, provider conflicts, and config layering for envs/hpcsim. Use for `spack -e envs/hpcsim concretize`, solver errors, or package constraint changes.
---

# Chapar Spack Solve Debug

Use this playbook for hpcsim concretization failures, long solver runs, provider conflicts, or package constraint edits.

## Guardrails

- Never edit the `spack/` submodule.
- Never edit generated files/directories: `.spack-env/`, lockfiles, caches.
- Do not pin dependency minor/patch versions on concretization. Use major versions only unless the user explicitly asks.
- Prefer latest available major versions for GCC, Intel compiler, MPI, LLVM, and CUDA policy already in Chapar.
- Preserve CUDA/GDR support for hpcsim Linux transports.
- Put shared policy in shared scopes; OS-specific policy in OS-specific scopes.

## Load Chapar Environment

```bash
source ./etc/init.sh
spack --version
spack config scopes -p
spack arch
```

Confirm the selected OS scope is present through `include.yaml` and `envs/hpcsim/spack.yaml` includes.

## Inspect Effective Config

```bash
spack -e envs/hpcsim config blame packages
spack -e envs/hpcsim config blame concretizer
spack -e envs/hpcsim config blame config
```

For a specific package/provider:

```bash
spack -e envs/hpcsim spec <pkg>
spack -e envs/hpcsim spec <pkg> %gcc@15
```

## Scope Placement Rules

Root specs:

- Cross-platform hpcsim specs: `envs/hpcsim/common/definitions.yaml`
- Linux-only specs: `envs/hpcsim/linux/definitions.yaml`
- Rocky 8-only specs: `envs/hpcsim/rocky8/definitions.yaml`
- Rocky 9-only specs: `envs/hpcsim/rocky9/definitions.yaml`
- macOS-only specs: `envs/hpcsim/macos/definitions.yaml`

Package requirements:

- Matching `packages.yaml` in the same scope level.
- Use OS-specific `when:` clauses for OS-only constraints.
- Keep specs/package sections sorted where existing files are sorted.

## Concretization Checks

Primary check:

```bash
spack -e envs/hpcsim concretize -f
```

If solving stalls, narrow the problem:

```bash
spack -e envs/hpcsim spec <root-spec>
spack -e envs/hpcsim spec <root-spec> ^<suspected-dependency>
```

For CI-like release-helper context, include the generated command-line scope if debugging inside a run log. Do not manually create permanent config for release-only roots; `envs/hpcsim/release.sh` generates that scope.

## Common Failure Patterns

- C/C++/Fortran provider conflict: inspect `c`, `cxx`, and `fortran` virtual package requirements in the OS scope.
- Old system compiler on Rocky 8: prefer `%gcc@15` constraints in Rocky 8 scope for packages that need a newer compiler.
- CUDA-aware MPI stack: use `chapar-cuda-gdr-transport`; do not disable `+cuda`, GDRCopy, UCX, Open MPI, or libfabric capability to pass a build.
- Visualization or frontend packages pulling Node/C++ requirements: constrain compiler provider, not source package patch levels unless requested.

## Validation Before Finishing

Run the narrowest meaningful validation and report exactly what was run:

```bash
bash -n envs/hpcsim/release.sh
spack -e envs/hpcsim concretize -f
git diff --check
```
