SPACK_INIT := ./etc/init.sh
CANARY_ENV := skipper-canary
PROD_ENV := skipper
SECTIONS := toolchain devtools python mpi libs gpu benchmarks profiling

.PHONY: help
help:
	@printf '%s\n' \
	  'Chapar section build targets:' \
	  '  make canary              Build all canary sections, then full canary' \
	  '  make prod                Build all production sections, then full prod' \
	  '  make canary-sections     Build only canary section environments' \
	  '  make prod-sections       Build only production section environments' \
	  '  make canary-full         Build full canary integration environment' \
	  '  make prod-full           Build full production integration environment' \
	  '  make canary-<section>    Build one canary section' \
	  '  make prod-<section>      Build one production section' \
	  '  make check               Validate all skipper environment configs' \
	  '  make clean-locks         Remove generated section/full lockfiles' \
	  '' \
	  'Sections:' \
	  '  $(SECTIONS)'

.PHONY: canary prod canary-sections prod-sections canary-full prod-full check clean-locks
.PHONY: $(addprefix canary-,$(SECTIONS)) $(addprefix prod-,$(SECTIONS))

define CANARY_SECTION_TARGET
canary-$(1):
	bash -lc 'source $$(SPACK_INIT) && spack -e ./envs/$$(CANARY_ENV)-$(1) concretize -f && spack -e ./envs/$$(CANARY_ENV)-$(1) install'
endef

define PROD_SECTION_TARGET
prod-$(1):
	bash -lc 'source $$(SPACK_INIT) && spack -e ./envs/$$(PROD_ENV)-$(1) concretize -f && spack -e ./envs/$$(PROD_ENV)-$(1) install'
endef

$(foreach section,$(SECTIONS),$(eval $(call CANARY_SECTION_TARGET,$(section))))
$(foreach section,$(SECTIONS),$(eval $(call PROD_SECTION_TARGET,$(section))))

canary:
	$(MAKE) canary-sections
	$(MAKE) canary-full

prod:
	$(MAKE) prod-sections
	$(MAKE) prod-full

canary-sections:
	@for section in $(SECTIONS); do \
	  $(MAKE) canary-$$section; \
	done

prod-sections:
	@for section in $(SECTIONS); do \
	  $(MAKE) prod-$$section; \
	done

canary-full:
	bash -lc 'source $(SPACK_INIT) && spack -e ./envs/$(CANARY_ENV) concretize -f && spack -e ./envs/$(CANARY_ENV) install'

prod-full:
	bash -lc 'source $(SPACK_INIT) && spack -e ./envs/$(PROD_ENV) concretize -f && spack -e ./envs/$(PROD_ENV) install'

check:
	bash -lc 'source $(SPACK_INIT) && for env in envs/skipper*; do [ -f "$$env/spack.yaml" ] || continue; spack -e "./$$env" config get config >/dev/null && spack -e "./$$env" config get packages >/dev/null && spack -e "./$$env" config get modules >/dev/null || exit 1; done'

clean-locks:
	rm -f envs/skipper*/spack.lock
