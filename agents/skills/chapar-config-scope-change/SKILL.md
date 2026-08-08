---
name: chapar-config-scope-change
description: Modify Chapar Spack configuration scopes under etc/system, etc/user, include.yaml, externals, mirrors, providers, modules, or install-tree settings. Use for config layering and OS-specific scope changes.
---

# Chapar Config Scope Change

Use this playbook when editing persistent Spack scopes under `etc/`.

## Scope Hierarchy

Chapar follows normal Spack precedence:

```text
defaults > system > site > user > spack > environment > command line
```

Chapar uses:

```text
etc/system/base/                 # shared machine/site policy
etc/system/{rocky9,rocky10}      # OS-specific system externals/policy
etc/user/base/                   # shared user policy
etc/user/{rocky9,rocky10}        # OS-specific user paths/modules/cache
envs/hpcsim/                     # environment-level hpcsim roots/policy
```

OS routing is controlled by:

```text
etc/system/include.yaml
etc/user/include.yaml
envs/hpcsim/spack.yaml
```

## Rules

- Model only expected externals: OS/bootstrap compilers, glibc on Rocky, unavoidable platform runtime pieces, ccache where enabled.
- Do not model ordinary link-time libraries (OpenSSL, zlib, libpng, curl, OpenBLAS, HDF5, NetCDF) as OS externals unless explicitly justified with matching dev metadata.
- CUDA should be built by Spack for hpcsim GPU packages, not modeled as a host external.
- Do not add OS Intel oneAPI compiler/MPI RPMs or GitHub CLI RPMs to hpcsim
  Rocky builder bootstrap policy. Use Spack for Intel MPI and any future Intel
  compiler dependency unless the user explicitly changes that policy.
- OS-specific overrides use `include.yaml` with `when:` conditionals.
- Keep paths per-platform; do not mix Rocky 9/Rocky 10 stores or caches.
- Site-specific release, buildcache, ccache, group, and public root paths belong
  in ignored `envs/hpcsim/hpcsim-site.env`, not tracked YAML.

## Inspection

```bash
source ./etc/init.sh
spack config scopes -p
spack arch
spack config blame packages
spack config blame config
spack config blame mirrors
spack config blame modules
```

## Editing Procedure

1. Decide if the change is system, user, or environment policy.
2. Decide if it is shared or OS-specific.
3. Edit the narrowest appropriate YAML file.
4. Preserve existing YAML style: 2-space indentation, sorted sections where practical.
5. Validate with config blame and hpcsim concretization when relevant.

## Validation

```bash
source ./etc/init.sh
spack config scopes -p
spack config blame packages
spack -e envs/hpcsim concretize -f
git diff --check
```
