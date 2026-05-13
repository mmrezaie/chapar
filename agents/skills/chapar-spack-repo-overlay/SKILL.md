---
name: chapar-spack-repo-overlay
description: Modify or review Chapar local Spack package overlay recipes and patches under spack_repo/chapar. Use only when the user explicitly asks for local package recipe or patch work, package overlay debugging, or changes to existing overlay packages such as ior, osu-micro-benchmarks, or intel-mpi-benchmarks.
---

# Chapar Spack Repo Overlay

Use this playbook for local Spack package overlay work under `spack_repo/chapar`.
Most environment/package policy changes belong under `envs/` or `etc/`; use this
skill only when a local recipe or patch is actually required.

## Guardrails

- Never edit the `spack/` submodule.
- Do not add or override recipes in `spack_repo/` unless the user explicitly asks
  or an existing overlay package needs a targeted fix.
- Prefer environment constraints in `envs/<env>` or persistent scope policy in
  `etc/` when the problem is dependency selection rather than source behavior.
- Keep patches narrow, platform/version-scoped, and documented with the upstream
  failure they address.
- Do not vendor large source payloads or generated build artifacts.
- Do not edit generated lock files or `.spack-env/` directories.

## Existing Overlay Packages

```text
spack_repo/chapar/packages/intel_mpi_benchmarks/
spack_repo/chapar/packages/ior/
spack_repo/chapar/packages/osu_micro_benchmarks/
```

Current overlay patches mainly cover Darwin/macOS portability and package build
race fixes. Preserve platform guards such as `platform=darwin` unless a failure
is proven cross-platform.

## Recipe Change Guidance

- Keep package class names and directory names aligned with Spack naming rules.
- Use existing Spack package APIs and style from nearby recipes.
- Add version checks, variants, conflicts, and dependencies at the narrowest
  correct scope.
- When adding a patch, include a short comment explaining the concrete build
  failure and condition it applies to.
- Avoid pinning dependency minor or patch versions unless the user explicitly
  asks and the reason is documented.
- For CUDA/GDR transport-related overlay work, also use
  `chapar-cuda-gdr-transport`.

## Validation

```bash
python3 -m py_compile spack_repo/chapar/packages/<package>/package.py
source ./etc/init.sh
spack -e envs/hpcsim spec <package>
git diff --check -- spack_repo/chapar
```

If the overlay change is platform-specific and local validation is on a different
platform, state which CI or runner is needed for full validation.
