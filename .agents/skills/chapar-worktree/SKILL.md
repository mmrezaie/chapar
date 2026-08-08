---
name: chapar-worktree
description: Manage Chapar Git worktrees and branch checkout conflicts. Use whenever a user asks to create, move, inspect, remove, open, switch to, or clean up a worktree or a branch cannot be selected because it is checked out elsewhere. Keep every linked local worktree under the repository's foobar/ directory.
---

# Chapar Git Worktrees

Use this playbook for any linked-worktree or branch-checkout task in Chapar.

## Layout policy

The primary checkout is the repository root. Every linked local worktree belongs
under `foobar/<worktree-name>/`. This keeps temporary branch checkouts isolated,
ignored by the primary worktree, and visible in one predictable place. Do not
create sibling checkouts elsewhere in the workspace.

`foobar/README.md` documents the layout. The directory ignores every worktree
entry while retaining its README and `.gitignore` as the visible contract.

## Inspect before changing Git state

Run these commands before an add, move, remove, or branch switch:

```bash
git status --short --branch
git worktree list --porcelain
```

For a linked worktree that may be moved or removed, also inspect it directly:

```bash
git -C <worktree-path> status --short --branch
git -C <worktree-path> diff --stat
git -C <worktree-path> diff --staged --stat
```

Preserve unrelated dirty work. Do not remove or relocate a dirty worktree
without the user's explicit direction.

## Create and relocate

For a new idea branch, prefer the repository helper:

```bash
make worktree <name>
```

It creates the linked checkout below `foobar/`. When an existing clean
worktree must be relocated, first confirm that `foobar/<worktree-name>` does
not exist, then use Git rather than a filesystem move:

```bash
git worktree move <old-path> foobar/<worktree-name>
```

After either operation, confirm the registered path and branch with
`git worktree list --porcelain` and check the target worktree's status.

## Branch selection

Git prevents the same branch from being checked out in both the primary root
and a linked worktree. If a branch selector disables a branch, locate it with
`git worktree list --porcelain` and use that worktree under `foobar/`.

If the user specifically wants the primary checkout to switch to that branch,
explain that the linked worktree must first be removed. Only run
`git worktree remove` after explicit approval and a clean-status check; moving
a worktree into `foobar/` does not free its branch for the primary checkout.

## Final report

State the primary branch, every affected `foobar/` path, each worktree's
branch and cleanliness, and any branch-selection limitation that remains.
