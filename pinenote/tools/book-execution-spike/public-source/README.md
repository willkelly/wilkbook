# Public Book-execution source gate

This is the fresh-checkout gate for the four current legacy Book-execution
systems. It prepares a read-only finite view from `SOURCE-MAP.tsv`, resolves the
pinned gVisor checkout through the Guix `gvisor-source-inventory` package, runs
one fake-store OCI source unit, loads the current system objects, and computes
and inspects their AArch64 system derivations.

From an absolute, canonical candidate checkout:

```sh
pinenote/tools/book-execution-spike/public-source/run.sh \
  --source-root "$(pwd -P)"
```

The gate uses `channels.scm`, an explicit positive 22-module
`GUILE_LOAD_PATH`, and a separate `-L` directory containing zero Scheme files.
The versioned `run.sh` launcher verifies the preparer against the finite map
before use, then executes mapped helpers only from the authenticated read-only
capsule. It resolves immutable store Python/Guix/Guile bootstrap tools, records
their paths, versions, and hashes, and accepts no tool-path or expected-hash
override. That launcher and `SOURCE-MAP.tsv` are the explicit initial review
boundary.

Every Guix entry point—including each dependency traversal—then crosses the
prepared `guix-isolated.sh` boundary. It starts with `env -i`, a fresh private
mode-0700 `HOME` and XDG tree, an empty `PATH`, cleared Guix package/build
variables, explicit Guile load/compiled/extension paths, and the pinned
`channels.scm` time machine. The bounded BEP-1 regression preseeds the exact
Guile auto-cache key in both default-HOME and caller-XDG caches plus a malicious
compiled module path. Markers must remain absent while isolated commands and
all four real graph queries succeed; default-cache and XDG/compiled-path graph
bytes must match exactly.

Each graph checker requires the exact root system derivation, existing canonical
store paths only, and the exact expected source-built runtime derivation. Its
attestation binds the root and its hash, query argv, pinned Guix version,
bootstrap and launcher identities, both raw graphs and hashes, and checker log
and result. System lowering uses `-d --no-grafts --cores=2 --max-jobs=1`; the
gate does **not** build gVisor, the kernel, a system, or an image, and it never
executes ARM code. The only realized gVisor input is the fixed source origin
requested with `guix build --source`.

The public systems now select `gvisor/source`, except that the diagnostic system
selects the explicit `gvisor/source-diagnostic` patch variant. Their current
runtime behavior is unproven until a separately reviewed QEMU run. Historical
CONTROL/diagnostic v12 results remain evidence for the exact operator-retained
local artifacts only; the old checkers and logs are not rewritten and no target
binaries are copied into Git.

This command is intentionally not the old Book-execution aggregate. Historical
module-view/checker scripts that assert local-v12 artifact identities remain
retained-evidence tools, while broader protocol/session/UI/persistence source
aggregation is owned by `pinenote/tools/book-source-check/` and its independent
review.
