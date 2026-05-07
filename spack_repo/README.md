# spack_repo/chapar

`spack_repo/chapar` is Chapar's local Spack package overlay. It keeps local package recipes in addition to those provided by Spack.

## Example Packages

| Package | What it does |
| --- | --- |
| `intel-mpi-benchmarks` | Builds Intel MPI Benchmarks, a suite of MPI communication benchmarks for measuring latency, bandwidth, collectives, I/O, RMA, and threading behavior. |
| `ior` | Builds IOR, a parallel file-system benchmark that measures I/O performance through POSIX, MPI-IO, HDF5, and related interfaces. |
| `osu-micro-benchmarks` | Builds the OSU Micro-Benchmarks suite for measuring MPI message-passing performance, including latency, bandwidth, collectives, one-sided operations, and GPU-aware communication. |

## Binary Packages

Binary packages are important for industrial simulation applications where source code is not available, yet reproducible deployment remains essential. Some of these applications rely on external dependencies provided through the `hpcsim` environment.
