#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${script_dir}/../../.." && pwd)"
wrapper="${root}/envs/hpcsim/release.sh"
before="$(git -C "${root}" status --porcelain=v1 --untracked-files=all)"

if rg -F 'envs/hpcsim/spack.lock' "${wrapper}" >/dev/null; then
    echo "legacy wrapper retains concrete checkout lock authority" >&2
    exit 1
fi
if rg -F '${ENV_PATH}/spack.lock' "${wrapper}" >/dev/null; then
    echo "legacy wrapper retains generic checkout lock authority" >&2
    exit 1
fi

set +e
output="$("${wrapper}" build retired-release 2>&1)"
exit_code=$?
set -e

if [ "${exit_code}" -ne 2 ]; then
    echo "legacy wrapper exit code was ${exit_code}, expected 2" >&2
    exit 1
fi
case "${output}" in
    *"retired"*"envs/software/release.sh"*"explicit selection"*) ;;
    *)
        echo "legacy wrapper did not provide migration guidance: ${output}" >&2
        exit 1
        ;;
esac

after="$(git -C "${root}" status --porcelain=v1 --untracked-files=all)"
if [ "${before}" != "${after}" ]; then
    echo "legacy wrapper mutated the worktree" >&2
    exit 1
fi

printf 'hpcsim legacy release retirement test passed\n'
