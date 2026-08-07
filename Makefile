DATACENTER ?=
SOFTWARE_SET ?=
TARGET ?=
RELEASE_ID ?=
RUN_ID ?=
SELECTION ?=
SELECTION_DIGEST ?=
DRY_RUN ?= false
WORKTREE_ROOT ?= foobar
WORKTREE_START ?= HEAD
MAKE_TARGETS := help build submit clean-locks git-ssh-setup worktree
WORKTREE_BRANCH_GOALS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
WORKTREE_BRANCH ?= $(or $(BRANCH),$(firstword $(WORKTREE_BRANCH_GOALS)))

.PHONY: help build submit clean-locks git-ssh-setup worktree FORCE

ifeq ($(firstword $(MAKECMDGOALS)),worktree)
ifeq ($(BRANCH),)
ifneq ($(WORKTREE_BRANCH),)
ifneq ($(filter $(WORKTREE_BRANCH),$(MAKE_TARGETS)),)
$(error branch name "$(WORKTREE_BRANCH)" conflicts with a Make target; use make worktree BRANCH=$(WORKTREE_BRANCH))
endif
.PHONY: $(WORKTREE_BRANCH)
$(WORKTREE_BRANCH):
	@:
endif
endif
endif

ifneq ($(filter build submit,$(MAKECMDGOALS)),)
ifeq ($(strip $(DATACENTER)),)
$(error DATACENTER is required)
endif
ifeq ($(strip $(SOFTWARE_SET)),)
$(error SOFTWARE_SET is required)
endif
ifeq ($(strip $(TARGET)),)
$(error TARGET is required)
endif
ifeq ($(strip $(RELEASE_ID)),)
$(error RELEASE_ID is required)
endif
ifeq ($(strip $(RUN_ID)),)
$(error RUN_ID is required)
endif
ifeq ($(strip $(SELECTION)),)
$(error SELECTION is required)
endif
ifeq ($(strip $(SELECTION_DIGEST)),)
$(error SELECTION_DIGEST is required)
endif
endif

help:
	@printf '%s\n' \
	  'Chapar software build targets:' \
	  '  make submit            Submit one resolved software tuple' \
	  '  make build             Alias for submit' \
	  '  make clean-locks        Always refuses to remove tracked locks' \
	  '  make git-ssh-setup      Configure repo-local SSH for GitHub pushes' \
	  '  make worktree <name>    Create $(WORKTREE_ROOT)/<name> on branch <name>' \
	  '' \
	  'Resolved invocation variables required by build/submit:' \
	  '  DATACENTER SOFTWARE_SET TARGET RELEASE_ID RUN_ID SELECTION SELECTION_DIGEST' \
	  '  DRY_RUN=true verifies a plan without submitting it'

build: submit

submit:
	bash ./ci/submit-env-build.sh --datacenter "$(DATACENTER)" --software-set "$(SOFTWARE_SET)" --target "$(TARGET)" --release-id "$(RELEASE_ID)" --run-id "$(RUN_ID)" --selection "$(SELECTION)" --selection-digest "$(SELECTION_DIGEST)" $(if $(filter true,$(DRY_RUN)),--dry-run)

clean-locks:
	@printf '%s\n' 'error: clean-locks cannot remove tracked release locks' >&2; exit 2

git-ssh-setup:
	bash ./etc/setup-git-ssh.sh

worktree:
	@if [ -z "$(WORKTREE_BRANCH)" ]; then \
		printf 'error: usage: make worktree <branch-name>\n' >&2; \
		exit 2; \
	fi; \
	if [ "$(words $(WORKTREE_BRANCH_GOALS))" -gt 1 ] && [ -z "$(BRANCH)" ]; then \
		printf 'error: provide exactly one branch name\n' >&2; \
		exit 2; \
	fi; \
	name="$(WORKTREE_BRANCH)"; \
	path="$(WORKTREE_ROOT)/$$name"; \
	mkdir -p "$$(dirname "$$path")"; \
	if git show-ref --verify --quiet "refs/heads/$$name"; then \
		git worktree add "$$path" "$$name"; \
	else \
		git worktree add -b "$$name" "$$path" "$(WORKTREE_START)"; \
	fi

FORCE:
