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
            rocky:9|rhel:9|almalinux:9|centos:9) _chapar_hpcsim_os="rocky9" ;;
            rocky:10|rhel:10|almalinux:10|centos:10) _chapar_hpcsim_os="rocky10" ;;
        esac
    fi

    _chapar_home_root="${CHAPAR_HOME_ROOT:-${HOME}/.spack/chapar}"
    _chapar_hpcsim_root="${CHAPAR_HPCSIM_ROOT:-${HPCSIM_ROOT:-${_chapar_home_root}/envs/hpcsim}}"
    _chapar_hpcsim_current="${_chapar_hpcsim_root}/${_chapar_hpcsim_os}/current"
    if [ -n "${_chapar_hpcsim_os}" ] && { [ -L "${_chapar_hpcsim_current}" ] || [ -d "${_chapar_hpcsim_current}" ]; }; then
        _chapar_hpcsim_release="$(cd -P "${_chapar_hpcsim_current}" 2>/dev/null && pwd || true)"
        _chapar_hpcsim_module_root="${_chapar_hpcsim_release}/modulefiles"
        if [ -n "${_chapar_hpcsim_release}" ] && [ -d "${_chapar_hpcsim_module_root}" ]; then
            for _chapar_hpcsim_module_dir in "${_chapar_hpcsim_module_root}"/*; do
                [ -d "${_chapar_hpcsim_module_dir}" ] || continue
                case "$(basename "${_chapar_hpcsim_module_dir}")" in
                    *-*-*) module use "${_chapar_hpcsim_module_dir}" >/dev/null 2>&1 || true ;;
                esac
            done
        fi
    fi
fi

unset _chapar_hpcsim_os _chapar_home_root _chapar_hpcsim_root _chapar_hpcsim_current _chapar_hpcsim_release
unset _chapar_hpcsim_module_root _chapar_hpcsim_module_dir
