# Chapar data-center contract template

This is the one-time generator for non-secret Chapar data-center policy. It
creates `datacenters/<id>/datacenter.json` and one
`datacenters/<id>/targets/<target>/contract.json` for every target supplied in
the context. The generated contracts are configuration inputs, not mutable
deployment state.

Start by copying `examples/example-context.yaml` outside the repository and
replace every example-only value with reviewed site values. Every durable
writable root, ordered read-only input, and temporary root is mandatory for
each target. Do not add credentials, tokens, passwords, private keys, current
symlinks, receipts, release state, or other mutable data.

Run the isolated renderer from the repository root:

```bash
uv run tools/chapar_datacenter_template.py render /path/to/context.yaml \
  --output-root "$PWD"
```

The renderer validates the context against the current target and container
registries, invokes the real noninteractive Cookiecutter CLI, validates the
strict output schemas, and records template, context, tool, dependency, schema,
and registry digests. It refuses an existing data-center directory; regeneration
is intentionally not an overwrite operation. To review a changed context,
render into a fresh disposable root and compare the complete generated tree
before replacing committed policy through an ordinary reviewed Git change.

Validate an already generated tree without changing it:

```bash
uv run tools/chapar_datacenter_template.py validate-tree \
  datacenters/<id>
```

Only `status: example` is accepted by this generator today. The committed
example is disposable test input and does not describe an active site.
