# shellcheck shell=sh
# load_env_from_config: read YAML env config, map symbolic names to modules, load them
#
# Usage:
#   load_env_from_config <config_file>
#   load_env_from_config <config_file> --needs openmpi cuda ...
#
# When --needs is given, only the listed symbolic module names are loaded.
# Otherwise every entry in module_map is loaded.

load_env_from_config() {
    set -euo pipefail

    local config_file="$1"
    local needs_only=false
    local needs=()
    shift

    if [ "${1:-}" = "--needs" ]; then
        needs_only=true
        shift
        needs=("$@")
    fi

    [ "${PURGE_MODULES:-yes}" = "yes" ] && module purge 2>/dev/null || true

    # Build Python list literal from bash array for safe interpolation
    local py_needs="[]"
    if [ "${#needs[@]}" -gt 0 ]; then
        py_needs="["
        local sep=""
        for n in "${needs[@]}"; do
            py_needs+="${sep}'${n}'"
            sep=", "
        done
        py_needs+="]"
    fi

    python3 -c "
import yaml, sys
with open('${config_file}') as f:
    cfg = yaml.safe_load(f)
module_map = cfg.get('module_map', {}) or {}
needs = ${py_needs} if ${needs_only} else list(module_map.keys())
for need in needs:
    if need in module_map:
        print(f'module load {module_map[need]}')
    else:
        print(f'# WARNING: no module mapping for need: {need}', file=sys.stderr)
" | while read -r cmd; do
    case "${cmd}" in
        module\ load\ *) eval "${cmd}" ;;
        \#*) echo "${cmd}" >&2 ;;
    esac
done
}
