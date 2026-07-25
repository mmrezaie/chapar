.PHONY: all node-smoke ib-pairwise mpi-collective hpc-challenge io profiling \
        gpu-stress transport frameworks analyze

VLAD_ENV ?= validation/config/vlad.yaml
RUNNER = python3 validation/run.py

all:
	$(RUNNER) --all --env $(VLAD_ENV)

node-smoke:
	$(RUNNER) --suite node-smoke --env $(VLAD_ENV)

ib-pairwise:
	$(RUNNER) --suite ib-pairwise --env $(VLAD_ENV)

mpi-collective:
	$(RUNNER) --suite mpi-collective --env $(VLAD_ENV)

hpc-challenge:
	$(RUNNER) --suite hpc-challenge --env $(VLAD_ENV)

io:
	$(RUNNER) --suite io --env $(VLAD_ENV)

profiling:
	$(RUNNER) --suite profiling --env $(VLAD_ENV)

gpu-stress:
	$(RUNNER) --suite gpu-stress --env $(VLAD_ENV)

transport:
	$(RUNNER) --suite transport --env $(VLAD_ENV)

frameworks:
	$(RUNNER) --suite frameworks --env $(VLAD_ENV)

analyze:
	python3 validation/vlad/analyze/outliers.py --suite $(SUITE)
