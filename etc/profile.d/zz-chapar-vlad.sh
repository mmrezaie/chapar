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

    _chapar_hpcsim_site_config="${CHAPAR_SITE_CONFIG:-}"
    if [ -z "${_chapar_hpcsim_site_config}" ] && [ -n "${CHAPAR_ROOT:-}" ]; then
        _chapar_hpcsim_site_config="${CHAPAR_ROOT}/envs/hpcsim/hpcsim-site.env"
    fi
    if [ -r "${_chapar_hpcsim_site_config}" ]; then
        . "${_chapar_hpcsim_site_config}"
    fi
    : "${CHAPAR_INSTALL_MODE:=home}"
    _chapar_hpcsim_home="${CHAPAR_HOME_ROOT:-${HOME}/.spack/chapar}/envs/hpcsim"
    case "${CHAPAR_INSTALL_MODE}" in
        public) _chapar_hpcsim_default="${HPCSIM_PUBLIC_ROOT:-}" ;;
        *) _chapar_hpcsim_default="${_chapar_hpcsim_home}" ;;
    esac
    _chapar_hpcsim_root="${HPCSIM_ROOT:-${_chapar_hpcsim_default}}"
    _chapar_hpcsim_current="${_chapar_hpcsim_root}/${_chapar_vlad_os}/current"
    if [ -n "${_chapar_vlad_os}" ] && [ -n "${_chapar_hpcsim_root}" ] && { [ -L "${_chapar_hpcsim_current}" ] || [ -d "${_chapar_hpcsim_current}" ]; }; then
        _chapar_hpcsim_release="$(cd -P "${_chapar_hpcsim_current}" 2>/dev/null && pwd || true)"
        _chapar_hpcsim_module_root="${_chapar_hpcsim_release}/modulefiles"
        if [ -n "${_chapar_hpcsim_release}" ] && [ -d "${_chapar_hpcsim_module_root}" ]; then
            for _chapar_hpcsim_arch in "${_chapar_hpcsim_module_root}"/*; do
                [ -d "${_chapar_hpcsim_arch}" ] || continue
                case "$(basename "${_chapar_hpcsim_arch}")" in
                    *-*-*) module use "${_chapar_hpcsim_arch}" >/dev/null 2>&1 || true ;;
                esac
            done
        fi
    fi
fi

unset _chapar_vlad_os _vlad_root _module_base _arch
unset _chapar_hpcsim_site_config _chapar_hpcsim_home _chapar_hpcsim_default
unset _chapar_hpcsim_root _chapar_hpcsim_current _chapar_hpcsim_release
unset _chapar_hpcsim_module_root _chapar_hpcsim_arch
