---
name: chapar-hpcsim-package-change
description: Add, remove, or reorganize packages/root specs in Chapar's envs/hpcsim environment. Use when changing hpcsim definitions.yaml, packages.yaml, providers, variants, or OS-specific package policy.
---

# Chapar hpcsim Package Change

Use this playbook when editing hpcsim root specs or package policy.

## Rules

- Do not edit `spack/`.
- Do not edit generated lock/cache files.
- Keep one hpcsim environment entry point: `envs/hpcsim/spack.yaml`.
- Do not split by release tier unless the user explicitly asks.
- Do not pin dependency minor/patch versions unless explicitly requested.
- Preserve latest-major compiler/MPI/LLVM policy.
- Preserve CUDA/GDR transport support on Linux.

## Where Changes Belong

Root specs:

```text
envs/hpcsim/common/definitions.yaml   # cross-platform
envs/hpcsim/linux/definitions.yaml    # all Linux
envs/hpcsim/rocky8/definitions.yaml   # Rocky 8 only
envs/hpcsim/rocky9/definitions.yaml   # Rocky 9 only
envs/hpcsim/macos/definitions.yaml    # macOS only
```

Package policy:

```text
envs/hpcsim/common/packages.yaml
envs/hpcsim/linux/packages.yaml
envs/hpcsim/rocky8/packages.yaml
envs/hpcsim/rocky9/packages.yaml
envs/hpcsim/macos/packages.yaml
```

System/user external policy belongs under `etc/system/` and `etc/user/`, not in the hpcsim environment unless it is environment-specific.

## Editing Procedure

1. Identify whether the package is cross-platform, Linux-only, or OS-specific.
2. Add/remove the root spec in the narrowest correct `definitions.yaml` group.
3. Add package requirements only when needed for real platform/toolchain constraints.
4. Keep root specs and package sections alphabetically sorted when practical.
5. Avoid source-level package overrides in `spack_repo/` unless explicitly asked.

## Validation

```bash
source ./etc/init.sh
spack -e envs/hpcsim concretize -f
```

For package-specific debugging:

```bash
spack -e envs/hpcsim spec <pkg>
spack -e envs/hpcsim config blame packages
```

If the change is Linux-only but local validation is macOS, state that full Rocky validation requires the Incus workflow or Rocky runner.

## Commit Split Guidance

Keep package/config behavior changes separate from documentation-only changes unless they are inseparable. Use `chapar-commit` before committing.
