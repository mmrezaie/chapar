# spack_repo/chapar

`spack_repo/chapar` is reserved for Chapar's local Spack package overlay. Prefer builtin Spack recipes and add local package recipes only when Chapar needs a targeted source-level override.

## Package Overrides

No Chapar-specific package overrides are currently registered. The hpcsim environment uses builtin Spack recipes for benchmark packages unless a future build failure requires a narrow local patch.

## Binary Packages

Binary packages are important for industrial simulation applications where source code is not available, yet reproducible deployment remains essential. Some of these applications rely on external dependencies provided through the `hpcsim` environment.
