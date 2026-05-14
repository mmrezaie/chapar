SPACK_INIT := ./etc/init.sh
ENV := hpcsim
RELEASE_ID ?=
SPACK_INSTALL_ARGS ?=
WORKTREE_ROOT ?= foobar
WORKTREE_START ?= HEAD

.PHONY: help build release promote module-use check clean-locks FORCE

help:
	@printf '%s\n' \
	  'Chapar hpcsim targets:' \
	  '  make build              Concretize and install envs/hpcsim with active scopes' \
	  '  make release            Build a staged hpcsim release under /resources/share/hpcsim/<os>' \
	  '  make promote            Promote RELEASE_ID for the current OS' \
	  '  make module-use         Print module use command for RELEASE_ID or current' \
	  '  make check              Validate the hpcsim environment config' \
	  '  make clean-locks        Remove generated hpcsim lockfile' \
	  '  make worktree-<name>    Create $(WORKTREE_ROOT)/<name> on branch <name>' \
	  '' \
	  'Variables:' \
	  '  RELEASE_ID=$(RELEASE_ID) (blank means generated for release/current for module-use)' \
	  '  SPACK_INSTALL_ARGS=$(SPACK_INSTALL_ARGS)' \
	  '  WORKTREE_ROOT=$(WORKTREE_ROOT)' \
	  '  WORKTREE_START=$(WORKTREE_START) (used when creating a new branch)'

build:
	bash -lc 'source $(SPACK_INIT) && spack -e ./envs/$(ENV) concretize -f && spack -e ./envs/$(ENV) install $(SPACK_INSTALL_ARGS) && spack -e ./envs/$(ENV) module tcl refresh -y'

release:
	bash -lc 'source $(SPACK_INIT) && release_id="$(RELEASE_ID)" && : "$${release_id:=$$(date -u +%Y%m%d%H%M%S)}" && SPACK_INSTALL_ARGS="$(SPACK_INSTALL_ARGS)" bash ./envs/$(ENV)/release.sh build "$${release_id}"'

promote:
	bash -lc 'source $(SPACK_INIT) && test -n "$(RELEASE_ID)" && bash ./envs/$(ENV)/release.sh promote "$(RELEASE_ID)"'

module-use:
	bash -lc 'source $(SPACK_INIT) && release_id="$(RELEASE_ID)" && if [ -n "$${release_id}" ]; then bash ./envs/$(ENV)/release.sh module-use "$${release_id}"; else bash ./envs/$(ENV)/release.sh module-use; fi'

check:
	bash -lc 'source $(SPACK_INIT) && spack -e ./envs/$(ENV) config get config >/dev/null && spack -e ./envs/$(ENV) config get packages >/dev/null && spack -e ./envs/$(ENV) config get modules >/dev/null'

clean-locks:
	rm -f envs/$(ENV)/spack.lock

worktree-%: FORCE
	@name="$*"; \
	path="$(WORKTREE_ROOT)/$$name"; \
	mkdir -p "$$(dirname "$$path")"; \
	if git show-ref --verify --quiet "refs/heads/$$name"; then \
		git worktree add "$$path" "$$name"; \
	else \
		git worktree add -b "$$name" "$$path" "$(WORKTREE_START)"; \
	fi

FORCE:
