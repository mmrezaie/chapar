#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' 'envs/hpcsim/release.sh is retired and performs no release action.' >&2
printf '%s\n' 'Use the future envs/software/release.sh explicit selection flow after Todo 6 lands.' >&2
printf '%s\n' 'Required selection identity: datacenter, software_set, target, release_id, and run_id.' >&2
exit 2
