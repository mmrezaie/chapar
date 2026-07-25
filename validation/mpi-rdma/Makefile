MPICXX ?= mpicxx
CPU_EXE ?= mpi_rdma_cpu
GPU_EXE ?= mpi_rdma_cuda

CXXFLAGS ?= -O2 -g -std=c++17 -Wall -Wextra
CUDA_PREFIX ?= $(or $(CUDA_HOME),$(CUDA_ROOT),$(CUDA_PATH),/usr/local/cuda)
CUDA_CPPFLAGS ?= -I$(CUDA_PREFIX)/include
CUDA_LDFLAGS ?= -L$(CUDA_PREFIX)/lib64 -Wl,-rpath,$(CUDA_PREFIX)/lib64 -lcudart

.PHONY: all cpu gpu clean run-openmpi-cpu run-openmpi-gpu run-intelmpi-cpu run-intelmpi-gpu

all: cpu gpu

cpu: $(CPU_EXE)

gpu: $(GPU_EXE)

$(CPU_EXE): mpi_rdma_cpu.cpp
	$(MPICXX) $(CXXFLAGS) $< -o $@

$(GPU_EXE): mpi_rdma_cuda.cpp
	$(MPICXX) $(CXXFLAGS) $(CUDA_CPPFLAGS) $< -o $@ $(CUDA_LDFLAGS)

clean:
	$(RM) mpi_rdma_cpu mpi_rdma_cuda \
		mpi_rdma_cpu.openmpi mpi_rdma_cuda.openmpi \
		mpi_rdma_cpu.intelmpi mpi_rdma_cuda.intelmpi

RUNNER = ./validation/run

run-openmpi-cpu:
	$(RUNNER) openmpi-cpu

run-openmpi-gpu:
	$(RUNNER) openmpi-gpu

run-intelmpi-cpu:
	$(RUNNER) intelmpi-cpu

run-intelmpi-gpu:
	$(RUNNER) intelmpi-gpu
