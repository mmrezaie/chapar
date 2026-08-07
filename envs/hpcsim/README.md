# Retired HPCSim manifest surface

`envs/software/spack.yaml` is the only active Chapar root-spec and package-policy source. This directory retains the release helper, site example, and the tracked historical `spack.lock`; the lock is immutable and is not an active manifest or selection input.

No environment variable selects a software profile. The tuple resolver renders effective manifests and locks into build staging and immutable release directories.
