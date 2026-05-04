# Add the promoted hpcsim release modules to new Rocky login shells.
if ! type module >/dev/null 2>&1 && [ -r /etc/profile.d/modules.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/modules.sh
fi

if type module >/dev/null 2>&1; then
    _chapar_hpcsim_os=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}:${VERSION_ID%%.*}" in
            rocky:8|rhel:8|almalinux:8|centos:8) _chapar_hpcsim_os="rocky8" ;;
            rocky:9|rhel:9|almalinux:9|centos:9|fedora:*) _chapar_hpcsim_os="rocky9" ;;
        esac
    fi

    _chapar_hpcsim_current="/resources/share/hpcsim/${_chapar_hpcsim_os}/current"
    _chapar_hpcsim_module_root="${_chapar_hpcsim_current}/modulefiles"
    if [ -n "${_chapar_hpcsim_os}" ] && { [ -L "${_chapar_hpcsim_current}" ] || [ -d "${_chapar_hpcsim_current}" ]; } && [ -d "${_chapar_hpcsim_module_root}" ]; then
        for _chapar_hpcsim_module_dir in "${_chapar_hpcsim_module_root}"/*; do
            [ -d "${_chapar_hpcsim_module_dir}" ] || continue
            case "$(basename "${_chapar_hpcsim_module_dir}")" in
                *-*-*) module use "${_chapar_hpcsim_module_dir}" >/dev/null 2>&1 || true ;;
            esac
        done
    fi
fi

unset _chapar_hpcsim_os _chapar_hpcsim_current _chapar_hpcsim_module_root _chapar_hpcsim_module_dir
