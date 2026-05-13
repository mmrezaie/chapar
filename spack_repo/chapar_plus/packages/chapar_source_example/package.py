# Copyright Spack Project Developers. See COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack_repo.builtin.build_systems.cmake import CMakePackage

from spack.package import *


class ChaparSourceExample(CMakePackage):
    """Tiny source-available application example.

    Use this pattern when the application source is available as a tarball or
    from an internal Git server. Replace the homepage, url, version checksum,
    and CMake flags with the real vendor or in-house solver details.
    """

    homepage = "https://example.com/chapar-source-example"
    url = "https://downloads.example.com/chapar-source-example-1.0.tar.gz"
    manual_download = True

    # Replace this placeholder with the checksum for the real source release.
    version("1.0", sha256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")

    variant("mpi", default=True, description="Build the MPI-enabled solver")
    variant("cuda", default=False, description="Build optional NVIDIA GPU kernels")

    depends_on("c", type="build")
    depends_on("cxx", type="build")
    depends_on("cmake@3:", type="build")
    depends_on("mpi", when="+mpi")
    depends_on("cuda", when="+cuda")

    def cmake_args(self):
        return [
            self.define_from_variant("CHAPAR_ENABLE_MPI", "mpi"),
            self.define_from_variant("CHAPAR_ENABLE_CUDA", "cuda"),
        ]

    def setup_run_environment(self, env):
        env.prepend_path("PATH", self.prefix.bin)
        env.set("CHAPAR_SOURCE_EXAMPLE_ROOT", self.prefix)
