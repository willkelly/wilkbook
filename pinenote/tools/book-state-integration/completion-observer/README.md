# Book State completion observer — private source successor

This directory freezes an opt-in, finite, typed Book Session completion
observer.  It is the prerequisite needed for a later trusted UI join to issue
`commit-ok` from a backend receipt rather than from book presentation or paint.
Nothing here is installed or live.

Read `CONTRACT.md` first.  The source delta is:

- `base/book-session-v4.scm` — accepted, unchanged BSD-1 base;
- `candidate/book-session.scm` — observer-enabled private successor;
- `book-session-completion-observer.patch` — exact base-to-candidate delta;
- `book-state-session-delegate.scm` — accepted delegate, byte-identical;
- `test-completion-observer.scm` — focused finite-slot/model/race tests;
- `test-real-completion-observer.scm` — accepted adapter/backend/SQLite and
  native-book process test;
- `observer-book.scm` — native book fixture using only its donated socket;
- `test-manifest.scm` and `run-host-tests.sh` — pinned, bounded offline gate.

The gate authenticates the immutable native-v1 snapshot's accepted component
copies rather than mutable native-v1 root files.  Native-v1's own execution
packet remains **provisional** because its independent review found NI1/NI2
evidence gaps; this observer does not repair or re-accept that packet.

Run only from the repository base:

```sh
pinenote/tools/book-state-integration/completion-observer/run-host-tests.sh
```

The runner disables substitutes, uses the repository's pinned Guix time
machine, limits jobs/cores, applies per-suite timeouts, compiles with arity and
format warnings enabled, reproduces and reverses the exact patch, and executes
from an empty directory.  It performs no QEMU, runsc, ARM, KOReader, image,
network fetch, hardware, deployment, staging, or VCS operation.

The frozen review boundary is the read-only artifact directory under
`build/artifacts/`; `SHA256SUMS` inside that directory is its packet manifest.
The host execution log and review digest are adjacent under `build/` and are not
included recursively in their own hashes.
