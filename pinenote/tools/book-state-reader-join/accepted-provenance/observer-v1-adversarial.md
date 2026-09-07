# Book State completion observer adversarial review — 2026-09-06

## Disposition

**Accept the frozen completion-observer candidate
`0342e87c665626b01c5318d125d7f96a152e16ebe25cc310499ca92698002c8f`
as the private trusted-observer prerequisite for the actual reader UI join.** I
found no path by which presentation, paint, a caller-supplied state object, a
different endpoint, an obsolete lifetime, queue pressure, or callback failure
can manufacture an observable commit receipt.

This is deliberately narrow acceptance. It establishes that trusted join code
can poll one endpoint-owned typed result after the accepted state model has
accepted a backend result and queued its Book Protocol response. It does **not**
accept the later UI join, the provisional native-v1 execution packet, process
restart or power-loss durability, QEMU/runsc/AArch64 behavior, KOReader runtime
behavior, an image, hostile-book isolation, output import, production resource
policy, or release integration.

The actual join must still preserve the correlation rules in [UI-join
requirements](#ui-join-requirements). In particular, the observer's Book
Session surface generation and state-grant generation are not the reader's UI
generation. Only join-owned mapping of all three lifetimes, the operation ID,
the captured pending draft, and the reader's edit epoch may produce
`commit-ok`.

## Frozen boundary and identities

I reviewed the read-only packet at:

```text
pinenote/tools/book-state-integration/completion-observer/build/artifacts/book-state-completion-observer-sources-20260906-v1/
```

The principal identities are:

| Input or record | SHA-256 |
|---|---|
| packet `SHA256SUMS` | `e45002e153ce6ae94cd2ddfff2c1a3a9551ce0a0b9046c6cee9c7a08bea50d36` |
| packet `SOURCE-IDENTITIES.sha256` | `dfbd19cbfc3f988992d1042f4f8e3faf30ca8feb15e1638e3073ec1a6a80da9b` |
| review packet | `f5303c0ea430c8dfb23ad769ddf7084cf494367d9da55d4080b29ff7e2cb8a51` |
| successful bounded host log | `247895fe7cfe6d8202d03e9498a0c097460f3c3963b68133f4a44dea004d8a76` |
| accepted BSD-1 base | `f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301` |
| candidate Book Session | `0342e87c665626b01c5318d125d7f96a152e16ebe25cc310499ca92698002c8f` |
| exact base-to-candidate patch | `bf93bafc254eafa5ed05b3fad7b86b442f9cc88f6a9254aaf3b2b6cc53726f49` |
| unchanged accepted delegate | `eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6` |
| accepted backend | `7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9` |
| accepted protocol plus pairing predicate | `425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257` |
| accepted corrected adapter | `349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769` |
| accepted operation-ID schema | `dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee` |
| accepted Book Protocol codec | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| accepted blocking codec | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| accepted reader packet `SHA256SUMS` | `a77c989accef03d2a4698a6483b0d8968b8712dacbb097f69eaf4b5095f7d9ab` |
| accepted reader adversarial review | `56a23f3acc1b2010a89ea8f00134687a0d07f290572f218477361cf0b6222301` |

The last hash resolves the ambiguous earlier transcription of the reader review
identity. I recomputed it from the frozen copy rather than relying on the prior
conversation summary.

The source snapshot was taken while repository HEAD was the packet's declared
base `50572d7796abdb0928969f4db8836fc5e30aeb58`. During this review the parent
worktree advanced concurrently to `549dded816e5f73d2c11557ffcd3130a018b82a8`.
I did not perform that update. The observer packet, reader identities, and
review evidence above remained byte-identical, so the source verdict stays
bound to the explicit hashes rather than to the moving worktree.

The packet's candidate was reproduced byte-for-byte by applying its patch to
the accepted base, and the inverse patch reproduced the accepted base. The
independent round-trip record is `bf992c8f…`. I did not reopen the accepted
Backend V2, Protocol V2, adapter, or BSD-1 behavior outside the observer's
explicit joins.

The packet owner reported an initial runner attempt that stopped in preflight
without executing tests. I do not count that attempt. The separately frozen
successful log above is the packet evidence used here. Likewise, my first
direct replay used ambient Guile 3.0.11 and stopped before tests because its
SRFI-64 does not export `test-log-to-file`; it is excluded. All reported direct
replays used the already-realized Guix 3.0.9 output referenced by the successful
profile derivation.

## Independent method and results

Before execution I copied the packet and only its declared immutable inputs to
a reviewer-owned read-only tree. Its source-freeze manifest is:

```text
e734891679178a11b12421719789564e202cc65cf38897beb027fd9a8ab910f4  source-freeze-manifest.json
```

The retained evidence is under:

```text
/tmp/opencode/book-state-completion-observer-independent-review-20260906
```

Its 54-entry evidence manifest is:

```text
90362b51099718e710c2a4c42bf6d07f173b4136d980d5d6db536f18e5e68bb1  EVIDENCE.sha256
```

Key independently generated records are:

| Record | SHA-256 |
|---|---|
| `patch-roundtrip.txt` | `bf992c8f946a79fdf43774fdaecaab4fd8ea2180cd9b114354b3a9f1f1ec0695` |
| `provided-focused.log` | `1fedd3bb498bbba25fa0b17bed2ba90ab43c95d7343f54c142f2051475f32830` |
| `provided-real.log` | `408e79917bfdaafc0fc2dd33225bac3a72695ec60d4303057342726cd5484702` |
| `independent-counterexamples.scm` | `cf8eb49f3319bfd6df229dd514afb0aac34d6b0fec1bc4c62499f9717b8c7059` |
| `independent-counterexamples.log` | `2655c847717745c47f6efc619fa06755c58b2f086c6a742d8dad25f142fe9920` |
| `load-trace-relevant.txt` | `7425b7d1a6d66963efa67025361f4f49b70b25107d63c7935fe148c5135e2b79` |
| `verify-frozen-load.py` | `6db5560df5eb1c3c1ba5e1281b1b59478629df68a4efc7ba9afdc2a688e1c64b` |
| `verify-frozen-load.log` | `6a2b36cb54b53f1f2da527cd86b5afd305e822c5e8f72e1f2d4050576754d3ad` |
| `RUNTIME-IDENTITIES.txt` | `8dab132c9ffc4a1080ea30e9be83ab51bdfd2e1a83c5a186596b165edb1c3c74` |

### Authenticated packet evidence

The frozen successful log records zero compile warnings and these exact
results:

- accepted Book Session regression: **227/227**;
- accepted BSD-1 delegate integration: **61/61**;
- focused completion observer: **37/37**;
- accepted adapter/backend/SQLite plus one native Guile book: **37/37**;
- exact forward and inverse patch reproduction;
- 4,096-NUL state-value delivery at 24,666 framed bytes within the 24,681-byte
  reservation; and
- a native-book load view without `guile-sqlite3`.

I authenticated but did not rerun the first two accepted suites. I directly
replayed both observer-specific suites, without compilation, from the read-only
snapshot using exact already-realized Guix outputs. They independently passed
**37/37** and **37/37**.

### Independent counterexamples

`independent-counterexamples.scm`
(`cf8eb49f3319bfd6df229dd514afb0aac34d6b0fec1bc4c62499f9717b8c7059`)
is separate from the packet tests. Its bounded run passed **53/53** checks; log
`2655c847…`. It exercised:

- Book Protocol peer `state-read` through Book Session, the accepted delegate,
  adapter, and real SQLite backend—not a direct outer backend call;
- absent state versus persisted present-empty state across endpoint reopen;
- a typed commit completion while its wire frame was queued but had not been
  sent, followed by separate Book-side receipt delivery;
- a second drain returning empty;
- exact cached retry observation with no second backend call;
- changed payload under a reused operation ID failing before backend mutation;
- two real endpoints reading the same version, one winning, and the stale one
  observing only typed conflict while a fresh wire read recovered the winner;
- a non-closing typed commit failure remaining distinct from committed success;
- a forged early `present`, a typed result passed to the public output method,
  and a state-looking alist all failing to create a completion;
- two overlapping endpoint slots, with neither endpoint able to drain the
  other's result;
- mutation of returned session ID, operation ID, text, and response strings,
  without changing the retained completion, queued bytes, cache, or SQLite;
- a backend blocked while surface frames filled the bounded output queue,
  followed by fail-close, zero published completion, zero retained frames, one
  revocation, and a joined worker;
- an unexpected backend callback exception with the same no-result/no-worker
  cleanup;
- dynamic checks that backend execution and revocation observed neither the
  endpoint mutex nor the delegate mutex as owned;
- EOF and restart clearing a published completion and queued response, with the
  old worker cleanup complete before replacement publication; and
- observer construction failure leaving no registered endpoint.

### Source-exact load proof

A no-build `strace -ff` replay of the real packet suite recorded both process
execs and every opened source. A no-argument checker with hardcoded expected
hashes (`verify-frozen-load.py`, `6db5560d…`) passed:

```text
PASS hardcoded hashes: 22
PASS authenticated exhaustive source-freeze manifest: 16 packet, 15 external, 2 adjacent
PASS packet inner manifest entries: 15
PASS required frozen loaded sources: 11
PASS successful execs: 2 exact Guile, 0 Python
PASS no mutable repository source opened
```

The parent loaded the frozen candidate, delegate, Book Protocol codec and
blocking I/O, state protocol and operation-ID module, adapter, backend, and SQL
schema. The native book loaded the frozen book fixture and the same frozen Book
Protocol codec/blocking I/O through its restricted load path. Both traced
fixture execs used
`/gnu/store/65c3bwbhv8qq747h0bpx8mlmy8rjn660-guile-3.0.9/bin/guile`.
No Python process or module participated in the traced Guile-only packet suite.
The separate reviewer-side Python manifest checker only read evidence and never
entered the protocol path. This packet's lack of a Python book does not repair
or accept native-v1's separate NI1/NI2 Python evidence gaps.

No package, image, kernel, QEMU, runsc, ARM, KOReader, mount, network, device,
or hardware action occurred. No implementation, frozen packet, reader UI,
native-v1 root, or concurrent integration file was edited.

## Authority and API findings

### Opt-in pull API only

The accepted `make-book-session-host-with-state` constructor remains
observer-free. The delta adds one explicit opt-in constructor and one polling
operation: `make-book-session-host-with-state-observer` and
`endpoint-take-state-completion!` (`candidate/book-session.scm:319-340,
983-1019`). There is no callback registry, raw endpoint-binding constructor,
observer recipient selector, or public completion publisher.

The caller must already possess the exact trusted `session-endpoint` object.
The endpoint's unexported identity object remains in the reservation and
completion and is rechecked by record identity during drain. The peer receives
only its connected socket. No JSON member can name the observer slot, owner,
backend grant, namespace, path, book identity, or recipient.

The public completion is a typed record, not decoded JSON
(`candidate/book-session.scm:164-217`). It exposes copied Book Session ID,
surface generation, state-grant generation, closed operation kind, copied
operation ID, expected version, copied commit text, and a reconstructed copy of
one accepted typed response. The endpoint identity has no public accessor.

Wire operation ID and text are correlation data, not authority. They reach the
record only after the accepted state FSM has matched the endpoint-retained
binding and backend result. The opaque backend owner/grant and namespace stay
captured outside the wire. Read completion has no operation ID; that remains
sound only under the accepted synchronous, connection-local, single-pending
read rule, which this one-task delegate and one-slot observer preserve.

### Receipt publication point is precise

For a state request, the endpoint mutex first checks worst-case output capacity
and installs one opaque slot reservation before dispatching the accepted state
FSM (`candidate/book-session.scm:843-871,1082-1107`). The delegate's sole worker
runs backend I/O without its mutex or the Book Session mutex
(`book-state-session-delegate.scm:197-229`).

After the backend returns, one endpoint-mutex transition:

1. rechecks exact endpoint and delegate identity;
2. applies the typed backend result to the accepted state model;
3. encodes and appends the response to the bounded output queue;
4. notes the fresh response as queued in the accepted delegate FSM; and
5. replaces the exact reservation with an immutable typed completion
   (`candidate/book-session.scm:941-1048,1454-1506`).

Therefore a commit completion means an accepted typed storage result and queued
protocol reply. It does **not** mean that the reply frame has been partially or
fully sent. The independent run observed a completion while one outbound frame
was queued and the peer was not readable. Socket send remains a later output-
pump event. Presentation and paint are still later, independent facts.

Only a valid `state-committed` response can accompany a successful commit
completion. Exact operation ID, resulting version `expected + 1`, and UTF-8
byte count are rechecked before publication. `state-conflict` and
`state-commit-failed` remain distinct typed responses. Terminal
`storage-failure` closes the accepted state model and consequently fails the
endpoint closed without publishing; the later UI join must treat that as
unknown/failure and recover, never as Saved.

An exact same-session cached retry creates a new completion for the exact retry
but does not repeat backend I/O or commit-ack bookkeeping. A changed payload
under the same operation ID closes before mutation. This gives the actual join
an honest lost-ack retry path without allowing cache replay to write new state.

### Boundedness and pressure

Each opted-in endpoint stores exactly one of: empty, one opaque reservation, or
one typed completion. A nonempty slot rejects another state request with local
backpressure before delegate dispatch. It cannot overwrite an undrained result
or grow into an event queue. Surface traffic remains independently bounded.

The 24,681-byte output calculation safely covers the accepted 4,096-byte text
even when every byte expands to six JSON bytes. One nuance is worth pinning:
the pre-dispatch output check does not withhold queue entries from later surface
traffic. Such traffic can consume capacity while backend work is in flight.
Completion therefore rechecks capacity. The independent gated test exhausted
all eight output entries after dispatch; the worker then atomically closed the
endpoint, cleared both queue and slot, revoked once, and exited. This is an
allowed bounded ambiguity requiring reopen/read/exact retry, not a successful
completion and not unbounded growth.

Encoding, accepted-model transition, output append, commit-ack bookkeeping, and
publication are covered by exception-total local invalidation. A failure after
a backend commit may leave durable state but cannot leave an observable receipt
on the obsolete endpoint. Cleanup performs transport shutdown and backend
revocation after releasing the endpoint mutex. Independent dynamic probes also
confirmed backend execution and revocation did not run under endpoint/delegate
authority mutexes.

### Lifetime and copy isolation

Close, EOF, revoke, release, and restart clear the endpoint's queue and slot and
detach the exact delegate under the endpoint mutex; transport shutdown,
revocation, and worker joining follow outside it
(`candidate/book-session.scm:1703-1774,1799-1889`). A published completion that
becomes stale after navigation is discarded on poll. An in-flight completion
whose reserved surface generation becomes stale fails the endpoint closed. No
old result can cross into a replacement endpoint or newer surface lifetime.

Every public string accessor returns a copy, and
`book-state-completion-response` reconstructs a fresh typed response. The
independent mutation probes and the packet's 4,096-NUL probe confirm that caller
mutation cannot alter the retained completion, queued frame, protocol cache, or
stored text.

## UI-join requirements

This API is sufficient for the actual UI join, but does not itself perform or
prove that join. The trusted coordinator must retain a join-owned pending record
that includes at least:

- exact endpoint object and Book Session ID;
- exact Book Session surface generation;
- exact state-grant generation;
- independently tracked reader UI generation;
- commit operation ID;
- expected state version and exact submitted draft; and
- the reader's post-submit edit epoch/state.

On drain, all endpoint/session/surface/grant facts must still match that record.
For commit success, the response must be `state-committed`, its operation ID
must match the retained operation, and the observer's text must equal the exact
captured pending draft. Only then may the coordinator send `commit-ok` for the
separately mapped current UI generation. Comparing only current widget text is
insufficient: an edit away and back is still a newer edit epoch, so the accepted
reader FSM must update its committed baseline but remain dirty.

A conflict must map only to the reader's closed `conflict` failure, and a
non-closing commit failure only to its matching closed failure code. Endpoint
closure or lost observation while a save is pending must preserve the draft and
enter recovery/failure; it must never synthesize `commit-ok`. Exact retry may
recover a cached receipt without a second write.

For reads, `present? = #f`, version zero, and empty text maps to `load-absent`.
`present? = #t` maps to `load-value`, including present-empty text. The
independent real-backend test proved those two empty renderings remain distinct
across a commit and endpoint reopen.

The coordinator must continue to treat these as separate milestones:

1. backend durability/typed receipt;
2. observer publication after reply queue insertion;
3. Book Protocol frame transmission;
4. reader `commit-ok` acceptance;
5. separate book presentation; and
6. topmost inherited KOReader paint observation.

Neither `presented-text` nor paint can enter the observer publication path. The
independent forged-presentation test produced a surface record, zero backend
calls, and no completion.

## Remaining boundary

The next acceptance point is the frozen real SQLite/Book Session/adapter/reader
join. It must prove typed save, close, reopen, load, lost-ack retry,
stale/changed-payload no-write, pending-edit behavior, and process recovery with
the correlation rules above. This review does not turn the reader's five UI
generations into five process restarts or SQLite recovery, and it does not make
the provisional native-v1, outer QEMU, gVisor, AArch64, durability, hardware, or
release gates pass.
