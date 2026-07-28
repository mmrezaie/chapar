# Chapar vlad module path
# Adds the promoted vlad modules for every architecture on this OS through the
# stable <os>/<arch>/modulefiles symlink, so MODULEPATH shows the layout path
# (Environment/OS/architecture/modulefiles) rather than a release-id path.
# Falls back to resolving <arch>/current, then to the legacy <os>/current.
_chapar_vlad_os_root="/resources/chapar/vlad/rocky10"
_chapar_vlad_added="false"
for _chapar_vlad_arch_root in "${_chapar_vlad_os_root}"/linux-*; do
    if [ -d "${_chapar_vlad_arch_root}/modulefiles/" ]; then
        module use "${_chapar_vlad_arch_root}/modulefiles"
        _chapar_vlad_added="true"
    elif [ -L "${_chapar_vlad_arch_root}/current" ]; then
        _chapar_vlad_release="$(readlink -f "${_chapar_vlad_arch_root}/current")"
        for _chapar_vlad_arch_dir in "${_chapar_vlad_release}/modulefiles"/linux-*; do
            if [ -d "${_chapar_vlad_arch_dir}" ]; then
                module use "${_chapar_vlad_arch_dir}"
                _chapar_vlad_added="true"
            fi
        done
    fi
done
if [ "${_chapar_vlad_added}" = "false" ] && [ -L "${_chapar_vlad_os_root}/current" ]; then
    _chapar_vlad_release="$(readlink -f "${_chapar_vlad_os_root}/current")"
    for _chapar_vlad_arch_dir in "${_chapar_vlad_release}/modulefiles"/linux-*; do
        [ -d "${_chapar_vlad_arch_dir}" ] && module use "${_chapar_vlad_arch_dir}"
    done
fi
unset _chapar_vlad_os_root _chapar_vlad_added _chapar_vlad_arch_root
unset _chapar_vlad_release _chapar_vlad_arch_dir
