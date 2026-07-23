# Add the promoted vlad release modules to new Rocky login shells.
if ! type module >/dev/null 2>&1 && [ -r /etc/profile.d/modules.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/modules.sh
fi

if type module >/dev/null 2>&1; then
    _chapar_vlad_os=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}:${VERSION_ID%%.*}" in
            rocky:9|rhel:9|almalinux:9|centos:9) _chapar_vlad_os="rocky9" ;;
            rocky:10|rhel:10|almalinux:10|centos:10) _chapar_vlad_os="rocky10" ;;
        esac
    fi

    _chapar_site_config="${CHAPAR_SITE_CONFIG:-}"
    if [ -z "${_chapar_site_config}" ] && [ -n "${CHAPAR_ROOT:-}" ]; then
        _chapar_site_config="${CHAPAR_ROOT}/envs/vlad/vlad-site.env"
    fi
    if [ -r "${_chapar_site_config}" ]; then
        # shellcheck disable=SC1090
        . "${_chapar_site_config}"
    fi

    : "${CHAPAR_MODULE_ROOT:=/resources/chapar/vlad/modulefiles}"
    _chapar_home_root="${CHAPAR_HOME_ROOT:-${HOME}/.spack/chapar}"
    _chapar_vlad_root="${VLAD_PUBLIC_ROOT:-${VLAD_HOME_ROOT:-${_chapar_home_root}/envs/vlad}}"
    _chapar_shared_module_added="false"

    if [ -n "${_chapar_vlad_os}" ] && [ -n "${CHAPAR_MODULE_ROOT:-}" ] && [ -d "${CHAPAR_MODULE_ROOT}" ]; then
        for _chapar_vlad_module_dir in "${CHAPAR_MODULE_ROOT}"/*; do
            [ -d "${_chapar_vlad_module_dir}" ] || continue
            case "$(basename "${_chapar_vlad_module_dir}")" in
                *-"${_chapar_vlad_os}"-*)
                    module use "${_chapar_vlad_module_dir}" >/dev/null 2>&1 || true
                    _chapar_shared_module_added="true"
                    ;;
            esac
        done
    fi

    _chapar_vlad_current="${_chapar_vlad_root}/${_chapar_vlad_os}/current/modulefiles"
    if [ "${_chapar_shared_module_added}" != "true" ] && [ -n "${_chapar_vlad_os}" ] && [ -n "${_chapar_vlad_root}" ] && [ -d "${_chapar_vlad_current}" ]; then
        for _chapar_vlad_module_dir in "${_chapar_vlad_current}"/*; do
            [ -d "${_chapar_vlad_module_dir}" ] || continue
            case "$(basename "${_chapar_vlad_module_dir}")" in
                *-"${_chapar_vlad_os}"-*)
                    module use "${_chapar_vlad_module_dir}" >/dev/null 2>&1 || true
                    ;;
            esac
        done
    fi
fi

unset _chapar_vlad_os _chapar_site_config _chapar_home_root _chapar_vlad_root
unset _chapar_vlad_current _chapar_vlad_module_dir
unset _chapar_shared_module_added
