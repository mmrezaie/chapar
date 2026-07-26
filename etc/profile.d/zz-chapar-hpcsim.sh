# Chapar hpcsim module path
# Adds hpcsim modules (and vlad modules for cross-env access)
HPCSIM_CURRENT="/resources/chapar/hpcsim/rocky10/current"
if [ -L "$HPCSIM_CURRENT" ]; then
    RELEASE_DIR="$(readlink -f "$HPCSIM_CURRENT")"
    for arch_dir in "$RELEASE_DIR/modulefiles"/linux-*; do
        [ -d "$arch_dir" ] && module use "$arch_dir"
    done
fi
