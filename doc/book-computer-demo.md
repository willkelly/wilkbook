# Book computer demonstration: sandbox results in real KOReader

Status: demonstrated in one AArch64 QEMU run on 2026-09-06. The runtime itself
completed, but the original launcher and harvest correctly remain failed because
a host checker expected an un-timestamped Linux power-down line. The functional
demonstration, narrowly corrected checker, and immutable-evidence offline replay
are independently accepted. The original failed status remains unchanged.

Context: [architecture](wilkbook-self-hosting-book-computer.md) ·
[protocol/state reference](book-computer-protocols.md) ·
[chronological implementation record](book-computer-implementation.md).

## Later milestone: durable native note editor

The separate native KOReader/book/session/SQLite join is now independently
accepted at its v2 snapshot. Run its bounded SDL-offscreen demonstration with:

```sh
make -C pinenote/tools/book-state-reader-join check
```

Both Guile and Python books support save → restart all three processes → load
→ save again, advancing versions 1 → 2 → 3 with distinct operation IDs. Real
UI Clear → Save survives restart as present-empty state; a full 4096-byte UI
save/reopen and exact-operation retry also pass. Storage acknowledgement comes
from the trusted typed completion observer, separately from book presentation
and inherited KOReader paint.

Independent replay passed in 38 seconds: 22 lifecycles, 66 unique authority,
book, and KOReader process identities, all reaped; nine SQLite namespaces,
13 receipts, integrity OK and no foreign-key violations. The v1 restart-ID
collision and mutable-helper loading defects remain recorded as failed
predecessors. Review:
[`2026-09-06-book-state-reader-join-adversarial.md`](reviews/2026-09-06-book-state-reader-join-adversarial.md),
SHA-256 `15b0e535180540ef852a3f21895c56edbba7e32959cfc104120d4fe285c39aa5`.
Source manifest:
`6fcbb5b7b8766f5cbc8802ad84c4b28d500c5941b0f2dc6f871d4ec8976c82e0`.

This is a trusted-native persistence demonstration. The sandboxed QEMU result
below remains its own earlier, transient four-result demonstration; joining
durability into that sandboxed path and proving two-boot recovery are next.

## What ran in the sandboxed demonstration

This was the first complete execution path from the fixed sandboxed books to a
real packaged KOReader widget:

1. The pinned native KOReader v2026.03 opened one real editable `InputDialog`
   through the registered selection action. It ran with SDL's offscreen backend.
2. The coordinator donated one connected host-side QEMU chardev socket to
   KOReader as FD 3; QEMU exposed the other side at the named guest
   virtio-serial port. The trusted AArch64 guest authority's UI descriptor
   remained `FD_CLOEXEC` and never entered a book sandbox.
3. The guest authority generated a fresh nonce for each action and ran the two
   fixed Guile actions followed by the two fixed Python actions under the
   unpatched `release-20260831.0` gVisor `runsc`, using exactly
   `run --pass-fd=3:3`. Each book received only its own Book Session Unix socket
   at FD 3.
4. The authority validated each committed presentation and relayed its text to
   KOReader. KOReader put the value in the same topmost `InputDialog` and called
   its packaged inherited `InputDialog:paintTo` implementation before returning
   the `applied` acknowledgement.
5. After four acknowledgements, the guest delivered `finish`, KOReader returned
   `done`, removed the action and private source, closed the dialog and FD, and
   exposed UI EOF. The guest then proved both runsc/cgroup/runtime-state cleanup
   paths and powered down. The native coordinator reaped both direct children
   and reported zero children; the outer run root was removed.

There are two deliberately different protocols in this path:

- Each sandboxed book uses accepted Book Protocol JSON framing and only the
  ordinary `hello` → `initialize` → `action` → `present` session over its own
  Unix socket at FD 3.
- KOReader uses the private lowercase-hex line channel over a different FD 3 in
  a different process. Its `input-update`/`submit`/`present`/`applied` lifecycle
  is not Book Protocol and is not a public book API.

Neither channel carries a framebuffer, screenshot, page image, raster command,
host path, launcher control, or expected result. The trusted authority relays
only the one accepted plain-text presentation after Book Session has matched its
request, action, surface, generation, sequence, and endpoint identity.

No host expected-result oracle supplied these values:

```text
GUILE[28]:ADA|NONCE=G-HJIZTUEJEO9GZJIF
GUILE[31]:ÉLAN Λ|NONCE=G-PXZEN3PVTJC9CTZI
PYTHON[30]:oycWqNaQevLuRssg-p=ecnon|ecarG
PYTHON[27]:JJclqSAZ8ME8O3Pk-p=ecnon|京東
```

The first two are the fixed Guile book's runtime length and uppercase result.
The second two are the fixed Python book's runtime length and reversed result.
All four include different guest-generated 16-character nonce suffixes. In
`reader.log`, each value has one
`BOOK_INTERACTION_UI_AUDIT: paintTo-topmost-exact:` observation immediately
followed by its matching `present-painted-exact:` acknowledgement.

“Four results” means four actions computed by two fixed reviewed fixture books;
it does not mean four arbitrary installed books or user-selected programs. The
nonce and independent result relations prevent a host expected-value fixture
from supplying these exact values, but do not turn the fixed workload into a
general protocol implementation.

## Evidence and the host-checker disposition

The immutable evidence directory is:

```text
pinenote/tools/book-execution-spike/build/artifacts/reader-interaction-real-qemu-20260906-v6-harvest/
```

It is mode `0500`; each retained file is mode `0400`, single-linked, and was
stable across the harvester's reads. The six runtime logs are all retained:

| File | Bytes | SHA-256 | What it records |
|---|---:|---|---|
| `console.log` | 25,849 | `6b67e290e473533446ee02582475b34c4021abd7629ef0f1922c47ef44605d56` | Guest provenance, Guile/Python Systrap PASS, cgroup teardown, UI EOF, overall PASS, and kernel power-down |
| `reader.log` | 10,419 | `e85264b8d9726ab83503d700e65b619d9f0c34d718f803e78231b5b6b465c8c2` | Real KOReader action, dialog, wait, `paintTo`, presentation, and cleanup observations |
| `coordinator.stdout` | 72 | `d389cf6c983eb071374ad49a863285a3d5817e001d918c988511f512aad4f8a4` | Exact child-zero and reader-lifecycle PASS line |
| `coordinator.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | Empty |
| `qemu.stdout` | 61 | `fe1bf85f980f1eccc0ccd094cfab2cac34881adc00554f939c209118f187298c` | Exact QEMU exec-descriptor hygiene line |
| `qemu.stderr` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | Empty |

`HARVEST.txt` remains truthfully sealed as `harvest-status=failed` and
`launcher-status=1`; it also records `writer-completion=true`, natural launcher
pipe EOF, zero adopted children observed or unreaped, all six stable logs, and
`run-root-removed=true`. Its SHA-256 is
`cc13872224a622d9e6fb2ededf3212cf7c7c58871f3d9f4d9c6a82ba22a6f77d`.
The original wrapper is preserved at
`/tmp/opencode/wilkbook-reader-demo-v6-wrapper.PTQ1Xq.log`, SHA-256
`c72c6de4a016539247ef271ebf545decc6f57ed0dbec6abdd47c64c340c1e6fe`.

The sole outer failure was this exact final console line:

```text
[   30.381268] reboot: Power down
```

The frozen checker expected exactly the bare `reboot: Power down`. The corrected
host-only checker admits either that exact bare line or one exact canonical
Linux printk timestamp followed by that exact payload. It still requires one
line, preserves final ordering and cardinality, and rejects malformed
timestamps, arbitrary prefixes, suffixes, duplicates, missing lines, and early
power-down. It does not normalize any other marker.

The fixed post-run replay is retained in
`pinenote/tools/book-execution-spike/build/reader-interaction-v6-offline-semantic-replay-v1.log`.
It reports `READER-INTERACTION-V6-OFFLINE-SEMANTIC-REPLAY=PASS` after checking
the immutable hashes, failed-harvest disposition, all six logs, exact native
lifecycle and value relationships, corrected guest chain, and empty production
run base. This separate offline verdict does not rewrite the original status.
No QEMU rerun is needed for the host checker defect.

Final independent acceptance is recorded in
`doc/reviews/2026-09-06-book-interaction-qemu-image-adversarial.md`, SHA-256
`64bb3cb11a1125147b708bc0883b33e924e1d84da80ea08edd0fd6778d120ed2`.
It closes both the shutdown-checker and fixed-evidence offline gates for this
demonstration. The accepted checker SHA-256 is
`de1129e263a0be22b90086f93de2476880a3f61480383696f6bfedd857bea607`.

## What this does not establish

- This is real KOReader widget execution, but **offscreen**, not a PineNote
  display or input session. There is no physical-glass claim and no PNG or
  screenshot oracle.
- The selection action was invoked by the trusted fixture, not by simulated
  touch or a real highlight-menu interaction.
- The two books and four actions are fixed demonstrations. This is not yet a
  general Workbench, arbitrary-book interface, or hostile-book qualification.
- Results are transient UI presentations. There is no durable state, reopen,
  recovery, export, cancellation, or long-running resource-pressure result.
- `present` means the fixed book produced a matching Book Session result;
  `applied` means the inherited topmost widget paint returned. Neither is a
  durable-state receipt or an optical-settlement acknowledgement.
- Nothing here changes a shipping flavor or establishes e-ink quality, latency,
  input, suspend, power, or hardware acceptance.

The concrete next product slice is therefore not “prove that computed text can
reach KOReader”—that now happened. It is to turn the fixed fixture into a
reviewed Workbench interaction with broker-owned durable state while preserving
the demonstrated authority, descriptor, cleanup, and presentation boundaries.
