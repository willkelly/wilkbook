# KOReader + Book State persistent-note join

This is the runnable v2 native join between the accepted KOReader editable-note
widget and the accepted Book State/SQLite stack. A trusted Guile authority owns
the two private connected channels; fixed Guile and Python books issue their own
reads and commits through completion-observer v1. See `CONTRACT.md` for the
authority and exact success chain.

## One bounded command

From the repository root:

```sh
make -C pinenote/tools/book-state-reader-join check
```

The command accepts no path or expected-value arguments. It requires the exact
already-realized KOReader output:

```text
/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
```

It authenticates the frozen v2 join snapshot and all three prerequisite packets
before compilation or project execution, copies them into a private read-only
closure, enters the channel-pinned Guix shell, uses private Scheme/Python/Lua
caches, and runs the real KOReader offscreen. It also proves the join-local
state-text candidate is the exact reviewable patch over accepted observer
`0342e87c…`, then reruns the accepted 227/61/37 tests. The whole command has a
180-second
deadline. It performs no network substitution, QEMU, runsc, ARM, image, mount,
kernel, hardware, device, staging, or VCS operation.

Every attempt gets a new `build/runs/<timestamp>-<pid>[-N]/` directory. Failed
logs are retained rather than overwritten. A successful run contains:

- `host.log` and compile/module-origin/source-mutation logs;
- `suite/joined-evidence.json`, the concise cross-process evidence;
- 22 per-lifecycle authority, fixed-book, KOReader, and JSON result logs;
- the retained SQLite database used only by the trusted Guile authorities and
  inspected by the external oracle after process exit.

The success output reports Guile and Python versions 1 → 2 → 3, exact
multilingual painted/recovered text, fresh operation IDs, actual empty and exact
4 KiB UI Saves, one-row same-operation retry, and fresh Guile/book/KOReader
process IDs. Process start times and endpoint/surface/grant identities are
retained in each lifecycle `result.json`.

## Review boundary

`build/artifacts/book-state-reader-join-sources-20260906-v1/` and every v1
log/packet remain immutable rejected predecessors. The successor review boundary
is `build/artifacts/book-state-reader-join-sources-20260906-v2/`, the separately
hashed evidence packet, `build/book-state-reader-join-host-check-v2.log`, and
`build/book-state-reader-join-review-packet-v2.txt`. This packet requests the
original reviewer's independent recheck; it does not declare itself accepted or
alter the accepted status of any prerequisite.
