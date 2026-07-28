# Chapar vlad module path
# Adds the promoted vlad modules for every architecture on this OS.
# New layout: /resources/chapar/vlad/<os>/<arch>/current; falls back to the
# legacy /resources/chapar/vlad/<os>/current for pre-restructure deployments.
_chapar_vlad_os_root="/resources/chapar/vlad/rocky10"
_chapar_vlad_added="false"
for _chapar_vlad_arch_root in "${_chapar_vlad_os_root}"/linux-*; do
    [ -L "${_chapar_vlad_arch_root}/current" ] || continue
    _chapar_vlad_release="$(readlink -f "${_chapar_vlad_arch_root}/current")"
    for _chapar_vlad_arch_dir in "${_chapar_vlad_release}/modulefiles"/linux-*; do
        if [ -d "${_chapar_vlad_arch_dir}" ]; then
            module use "${_chapar_vlad_arch_dir}"
            _chapar_vlad_added="true"
        fi
    done
done
if [ "${_chapar_vlad_added}" = "false" ] && [ -L "${_chapar_vlad_os_root}/current" ]; then
    _chapar_vlad_release="$(readlink -f "${_chapar_vlad_os_root}/current")"
    for _chapar_vlad_arch_dir in "${_chapar_vlad_release}/modulefiles"/linux-*; do
        [ -d "${_chapar_vlad_arch_dir}" ] && module use "${_chapar_vlad_arch_dir}"
    done
fi
unset _chapar_vlad_os_root _chapar_vlad_added _chapar_vlad_arch_root
unset _chapar_vlad_release _chapar_vlad_arch_dir
