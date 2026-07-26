# Chapar vlad module path
# Adds vlad modules (and hpcsim modules for cross-env access)
VLAD_CURRENT="/resources/chapar/vlad/rocky10/current"
if [ -L "$VLAD_CURRENT" ]; then
    RELEASE_DIR="$(readlink -f "$VLAD_CURRENT")"
    for arch_dir in "$RELEASE_DIR/modulefiles"/linux-*; do
        [ -d "$arch_dir" ] && module use "$arch_dir"
    done
fi
