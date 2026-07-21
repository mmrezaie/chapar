.PHONY: all node-smoke ib-pairwise mpi-collective hpc-challenge io profiling \
        gpu-stress transport frameworks analyze

all:
	sbatch slurm/node-smoke.sbatch || true
	sbatch slurm/ib-pairwise.sbatch || true
	sbatch slurm/mpi-collective.sbatch || true
	sbatch slurm/hpc-challenge.sbatch || true
	sbatch slurm/io.sbatch || true
	sbatch slurm/profiling.sbatch || true
	sbatch slurm/gpu-stress.sbatch || true
	sbatch slurm/transport.sbatch || true
	sbatch slurm/frameworks.sbatch || true

node-smoke:
	sbatch slurm/node-smoke.sbatch

ib-pairwise:
	sbatch slurm/ib-pairwise.sbatch

mpi-collective:
	sbatch slurm/mpi-collective.sbatch

hpc-challenge:
	sbatch slurm/hpc-challenge.sbatch

io:
	sbatch slurm/io.sbatch

profiling:
	sbatch slurm/profiling.sbatch

gpu-stress:
	sbatch slurm/gpu-stress.sbatch

transport:
	sbatch slurm/transport.sbatch

frameworks:
	sbatch slurm/frameworks.sbatch

analyze:
	python3 analyze/outliers.py --suite $(SUITE)
