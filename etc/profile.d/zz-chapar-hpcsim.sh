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

    _chapar_site_config="${CHAPAR_SITE_CONFIG:-}"
    if [ -z "${_chapar_site_config}" ] && [ -n "${CHAPAR_ROOT:-}" ]; then
        _chapar_site_config="${CHAPAR_ROOT}/envs/hpcsim/hpcsim-site.env"
    fi
    if [ -r "${_chapar_site_config}" ]; then
        # shellcheck disable=SC1090
        . "${_chapar_site_config}"
    fi

    : "${CHAPAR_INSTALL_MODE:=home}"
    _chapar_home_root="${CHAPAR_HOME_ROOT:-${HOME}/.spack/chapar}"
    _chapar_hpcsim_home_root="${HPCSIM_HOME_ROOT:-${_chapar_home_root}/envs/hpcsim}"
    case "${CHAPAR_INSTALL_MODE}" in
        public) _chapar_hpcsim_default_root="${HPCSIM_PUBLIC_ROOT:-}" ;;
        *) _chapar_hpcsim_default_root="${_chapar_hpcsim_home_root}" ;;
    esac
    _chapar_hpcsim_root="${CHAPAR_HPCSIM_ROOT:-${HPCSIM_ROOT:-${_chapar_hpcsim_default_root}}}"
    _chapar_shared_module_added="false"

    if [ -n "${_chapar_hpcsim_os}" ] && [ -n "${CHAPAR_MODULE_ROOT:-}" ] && [ -d "${CHAPAR_MODULE_ROOT}" ]; then
        for _chapar_hpcsim_module_dir in "${CHAPAR_MODULE_ROOT}"/*; do
            [ -d "${_chapar_hpcsim_module_dir}" ] || continue
            case "$(basename "${_chapar_hpcsim_module_dir}")" in
                *-"${_chapar_hpcsim_os}"-*)
                    module use "${_chapar_hpcsim_module_dir}" >/dev/null 2>&1 || true
                    _chapar_shared_module_added="true"
                    ;;
            esac
        done
    fi

    _chapar_hpcsim_current="${_chapar_hpcsim_root}/${_chapar_hpcsim_os}/current"
    if [ "${_chapar_shared_module_added}" != "true" ] && [ -n "${_chapar_hpcsim_os}" ] && [ -n "${_chapar_hpcsim_root}" ] && { [ -L "${_chapar_hpcsim_current}" ] || [ -d "${_chapar_hpcsim_current}" ]; }; then
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

unset _chapar_hpcsim_os _chapar_site_config _chapar_home_root _chapar_hpcsim_home_root
unset _chapar_hpcsim_default_root _chapar_hpcsim_root _chapar_hpcsim_current
unset _chapar_hpcsim_release _chapar_hpcsim_module_root _chapar_hpcsim_module_dir
unset _chapar_shared_module_added
