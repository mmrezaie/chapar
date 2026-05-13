# Copyright Spack Project Developers. See COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

import os

from spack.package import *


class ChaparBinaryOnlyExample(Package):
    """Tiny binary-only application example.

    Use this pattern for commercial simulation applications such as Abaqus,
    STAR-CCM+, or LS-DYNA when Spack cannot download source. The vendor installer
    is run outside Spack, then Spack copies or registers that install tree so
    modules, dependencies, and release metadata remain reproducible.
    """

    homepage = "https://example.com/chapar-binary-only-example"
    manual_download = True
    has_code = False

    version("2024.1")

    # Before running `spack install`, point this variable at an extracted or
    # already-installed vendor application tree that contains bin/solver.
    vendor_root_env = "CHAPAR_BINARY_ONLY_EXAMPLE_ROOT"

    def install(self, spec, prefix):
        vendor_root = os.environ.get(self.vendor_root_env)
        if not vendor_root:
            raise InstallError(
                "Set {0} to the vendor install tree before installing. "
                "Example: export {0}=/opt/vendor/abaqus/2024".format(self.vendor_root_env)
            )
        if not os.path.isdir(vendor_root):
            raise InstallError("{0} does not exist: {1}".format(self.vendor_root_env, vendor_root))

        install_tree(vendor_root, prefix)

    def setup_run_environment(self, env):
        env.prepend_path("PATH", self.prefix.bin)
        env.set("CHAPAR_BINARY_ONLY_EXAMPLE_ROOT", self.prefix)

        # Real packages often set product-specific license variables here, or in
        # modules.yaml if the value differs by site.
        # env.set("ABAQUSLM_LICENSE_FILE", "27000@licenses.example.com")
