# Foobar Worktrees

Use this directory for local Git worktrees that should live inside the project
checkout without appearing as repository changes.

The preferred helper creates worktrees under `foobar/`:

```bash
make worktree my-idea
```

Everything under `foobar/` is ignored except this README and the local
`.gitignore` file.

Equivalent manual example:

```bash
git worktree add foobar/my-idea -b idea/my-idea
```

Be careful with `git clean -fdx` from the main checkout. Ignored worktree
directories under `foobar/` can be deleted by that command.
