# Add the promoted vlad release modules to new Rocky login shells.
# Managed by the chapar CI pipeline — manual edits may be overwritten.

if ! type module >/dev/null 2>&1 && [ -r /etc/profile.d/modules.sh ]; then
    . /etc/profile.d/modules.sh
fi

if type module >/dev/null 2>&1; then
    _chapar_vlad_os=""
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}:${VERSION_ID%%.*}" in
            rocky:9|rhel:9|almalinux:9|centos:9) _chapar_vlad_os="rocky9" ;;
            rocky:10|rhel:10|almalinux:10|centos:10) _chapar_vlad_os="rocky10" ;;
        esac
    fi

    if [ -n "$_chapar_vlad_os" ]; then
        _vlad_root="${VLAD_PUBLIC_ROOT:-/resources/chapar/vlad}"
        _module_base="$_vlad_root/$_chapar_vlad_os/current/modulefiles"
        if [ -d "$_module_base" ]; then
            for _arch in "$_module_base"/*; do
                [ -d "$_arch" ] || continue
                case "$(basename "$_arch")" in
                    *-"$_chapar_vlad_os"-*) module use "$_arch" >/dev/null 2>&1 || true ;;
                esac
            done
        fi
    fi
fi

unset _chapar_vlad_os _vlad_root _module_base _arch
