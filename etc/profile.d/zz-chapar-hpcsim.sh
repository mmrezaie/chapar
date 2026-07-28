# Chapar hpcsim module path
# Adds the promoted hpcsim modules for every architecture on this OS.
# New layout: /resources/chapar/hpcsim/<os>/<arch>/current; falls back to the
# legacy /resources/chapar/hpcsim/<os>/current for pre-restructure deployments.
_chapar_hpcsim_os_root="/resources/chapar/hpcsim/rocky10"
_chapar_hpcsim_added="false"
for _chapar_hpcsim_arch_root in "${_chapar_hpcsim_os_root}"/linux-*; do
    [ -L "${_chapar_hpcsim_arch_root}/current" ] || continue
    _chapar_hpcsim_release="$(readlink -f "${_chapar_hpcsim_arch_root}/current")"
    for _chapar_hpcsim_arch_dir in "${_chapar_hpcsim_release}/modulefiles"/linux-*; do
        if [ -d "${_chapar_hpcsim_arch_dir}" ]; then
            module use "${_chapar_hpcsim_arch_dir}"
            _chapar_hpcsim_added="true"
        fi
    done
done
if [ "${_chapar_hpcsim_added}" = "false" ] && [ -L "${_chapar_hpcsim_os_root}/current" ]; then
    _chapar_hpcsim_release="$(readlink -f "${_chapar_hpcsim_os_root}/current")"
    for _chapar_hpcsim_arch_dir in "${_chapar_hpcsim_release}/modulefiles"/linux-*; do
        [ -d "${_chapar_hpcsim_arch_dir}" ] && module use "${_chapar_hpcsim_arch_dir}"
    done
fi
unset _chapar_hpcsim_os_root _chapar_hpcsim_added _chapar_hpcsim_arch_root
unset _chapar_hpcsim_release _chapar_hpcsim_arch_dir
