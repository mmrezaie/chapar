MPICXX ?= mpicxx

CXXFLAGS ?= -O2 -g -std=c++17 -Wall -Wextra
CUDA_PREFIX ?= $(or $(CUDA_HOME),$(CUDA_ROOT),$(CUDA_PATH),/usr/local/cuda)
CUDA_CPPFLAGS ?= -I$(CUDA_PREFIX)/include
CUDA_LDFLAGS ?= -L$(CUDA_PREFIX)/lib64 -Wl,-rpath,$(CUDA_PREFIX)/lib64 -lcudart

.PHONY: all cpu gpu clean

all: cpu gpu

cpu: mpi_rdma_cpu

gpu: mpi_rdma_cuda

mpi_rdma_cpu: mpi_rdma_cpu.cpp
	$(MPICXX) $(CXXFLAGS) $< -o $@

mpi_rdma_cuda: mpi_rdma_cuda.cpp
	$(MPICXX) $(CXXFLAGS) $(CUDA_CPPFLAGS) $< -o $@ $(CUDA_LDFLAGS)

clean:
	$(RM) mpi_rdma_cpu mpi_rdma_cuda
