# Book Session optional state delegate — adversarial review — 2026-09-06

## Disposition

**Blocked for the real adapter/backend join.** The optional typed-factory shape,
authority separation, one-worker/one-task design, close ordering, and unchanged
ordinary Book Session behavior are sound in the reviewed source. However, the
candidate underestimates the maximum encoded state response. A protocol-valid
4096-byte text value can terminate the sole state worker while leaving its
endpoint active. A later operation is accepted as `queued` but can never run.

This is a core delegate/output-lifecycle bug, independent of SQLite and the
adapter currently under separate review.

No live Book Session, protocol, adapter, backend, guest, UI, or runtime source
was edited. No QEMU, runsc, ARM execution, image or Guix build, hardware,
deployment, staging, commit, or push occurred. Tests used only bounded native
Guile threads and typed host fixtures.

## Frozen review boundary

The private packet was:

```text
/tmp/opencode/book-session-state-integration-v3-source-exact.ltSllU/
packet-manifest.json
9d1faa6eb166dba125c9752693cc5c76fd6d80e79981ca4ce5e0bf1794781624
```

Its evidence identities matched:

```text
code-source-hashes.txt
bdd19fd2af59609298bccd382d7e4e89abcce918ae5e20b10ec78364db769319

evidence-hashes.txt
435b869c5e62b5c47b993f901caddbfa9fedbbe1d3dd04adc1711c362e5f9a5b

host-check.log
104001727a37e0e542b84e4a40e94d363226e4416d1f22de5b6f45009cbc0513

source-old-new.txt
7c4d239a07868aada1367740fccc860a6163daafdb7366ebf4e3ba419854beac
```

All seven source entries matched `code-source-hashes.txt`. Each supplied source
was a regular, single-link, mode-0400 file under the private mode-0700 packet.
The reviewed candidate identities were:

```text
CONTRACT.md                              68811f492520d28b107fcaf05d7a7cb151683116be6f827cd25aee41ec4420dc
book-session.scm                         d60757f38812bd82b03d1e075303036dd0dae740bca4b5f2ba8e5f4b7b7ec813
book-state-session-delegate.scm          eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6
test-book-session-state-integration.scm  a7bc9c2a6571ba5c6725e5980d8daa41d6d8ee0c7d573602e36390e880f4a065
book-session-state-delegate.patch        42fafd8f34d6ff1a64d4c50824e210119e0efd3e2a1b36fb8fa1104d17aac050
test-manifest.scm                        d8bc9e8d542262d2888993859361aa87d7149de1e678f08972aac9a1d33f1d7c
run-host-tests.sh                        073359c1e496fc52565220db245a8d48c76b939f65358d8ed2d0457daf00d109
```

The patch applied to accepted Book Session source
`f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668`
and reproduced candidate `d60757f3…` byte for byte. Its finite core delta is
313 insertions and 64 deletions. The accepted 227-test source remained
`dbd96cbc13fc601edb5d7db5b676cabd2dcf9ad7f832ce85ebdea93b93294aec`.

Protocol V2 and its source-exact read-only accessor delta were treated as a
hash-gated typed dependency, not reopened in this review:

```text
book-state-protocol.scm                  425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257
book-state-operation-id.scm              dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee
Protocol V2 accepted review              10f0b2cf3f8921300ca2644c25d2cabfec2f5cb36dbcdad3d220fbe7128a5e09
```

The accepted backend `7c3a507d…` and review `4cd0629e…` are outside this
candidate's source/test closure. In particular, neither `(book-state)`,
`(sqlite3)`, nor `guile-sqlite3` is imported. The real adapter pair fix remains
under its other reviewer and receives no verdict here.

## Properties established before the blocker

### Narrow authority seam

- `make-book-session-host` remains zero-argument and state-disabled. The
  accepted 227 assertions pass against the patched candidate.
- State is enabled only by one typed `make-book-state-delegate-factory`; there
  is no method registry or raw callback name selected from JSON.
- The trusted factory's open procedure receives only Book Session's fresh,
  private, in-memory endpoint identity. Book revision, instance, namespace,
  SQLite path, SQL, owner, and grant cannot be supplied by a book message.
- The worker receives only accepted typed read/commit operations. Revocation
  receives only the retained typed binding. A later real factory must keep
  namespace selection in its trusted closure and prove that returned bindings
  are bound to the supplied fresh owner.
- All seven `state-*` names route through the accepted typed state decoder.
  Inbound direction permits only read and commit. Wrong-direction messages,
  unknown fields, and book-supplied authority fields reject before callback
  dispatch.

### Mutex and lifetime design

- Factory open and backend binding creation occur without the host or endpoint
  authority mutex held.
- Input is decoded outside the endpoint mutex. Under that mutex, the candidate
  rechecks the endpoint lifetime, advances the typed FSM, and publishes no more
  than one task.
- Each state endpoint creates exactly one worker and one task slot. The typed
  FSM's one-pending-operation rule prevents another storage call while the
  worker has removed the task from that slot.
- `RUN-OPERATION` executes with no host, endpoint, or delegate mutex held.
  Consequently a blocked storage operation does not block surface actions or
  presentations. The focused suite demonstrates presentation while storage is
  cooperatively blocked.
- Completion reacquires the endpoint mutex and checks both the exact endpoint
  identity and exact delegate object before applying the typed backend result.
  Protocol V2 then rechecks operation and grant generation identity. A result
  from an old or detached lifetime cannot select a replacement endpoint.
- Close, EOF, surface revocation, release, and restart invalidate local state,
  clear output, close the pure state FSM, remove any not-yet-taken task, and
  detach the delegate while holding the endpoint mutex. Backend revocation and
  worker join happen only after that mutex is released.
- A task already inside storage races revocation under the eventual backend's
  own mutex. Commit-first may leave a durable receipt but cannot publish an ack
  after close; revoke-first prevents a write. A task still in the one-slot queue
  is removed before revocation and never reaches the callback.
- Worker-initiated close avoids self-join. Repeated close sees the delegate
  already detached and cannot invoke a second revoke/join sequence.

These facts establish ordering, not cancellation of an arbitrary blocked host
call. The actual backend's five-second SQLite busy timeout bounds lock
contention, not every filesystem or kernel I/O failure.

### Startup and bounded scheduling

A state-enabled hello returns the exact existing seven-field `initialize` value
first and one typed `state-ready` second. State operations remain disabled until
the trusted pump owner physically queues that exact ready record. The future
outer-loop join must queue both values in that order; the candidate does not
allow a peer to announce or synthesize a grant.

Dispatch returns only `queued`, `already-pending`, or a typed cached result. It
does not turn storage completion into surface presentation. The task queue is
one slot and the inherited output queue remains eight frames with a byte bound.
If the output queue is already full, the input pump rejects before mutating the
state FSM or publishing a task.

## Independent positive execution

The candidate was loaded from a reviewer-created source-only directory whose
project inputs were copied only after their hashes matched. It did not consume a
repository or user compilation cache. In the pinned Guile 3.0.9 host closure:

```text
accepted Book Session assertions: 227 passed
focused state-delegate assertions: 30 passed
private patch reproduction:        exact
```

The focused suite confirms ordinary-host rejection of state messages,
initialize-before-ready ordering, no work before announcement, typed read and
commit responses, wrong-direction and authority-field rejection, pre-dispatch
output backpressure, surface responsiveness during blocked storage,
single-pending dispatch, close after decode, close during a commit, no late ack,
revocation outside the endpoint mutex, and fresh owner/grant identity on
restart.

Those fixtures return short printable text. They do not cover the wire size of
all text values accepted by Protocol V2 and the backend.

## BSD-1 — a valid escaped value kills the sole worker

The candidate defines:

```scheme
(define max-state-outbound-frame-bytes (+ max-state-text-bytes 1024))
```

With `max-state-text-bytes = 4096`, this reserves 5120 bytes. That treats raw
UTF-8 size as if JSON encoding added only fixed overhead. JSON escaping is not
bounded that way: each control character may become six ASCII bytes.

### Independent counterexample

A reviewer-created typed factory returned a valid present state read result
whose text was `(make-string 4096 #\nul)`. No raw result object, JSON authority
field, adapter, backend, or SQLite database was involved. The accepted state
encoder produced a 24,666-byte framed response. This is below Book Session's
global output-byte bound of 524,320 bytes, but above the candidate's local
5,120-byte reservation.

Observed state after one valid state read:

```text
encoded-response-bytes: 24666
reservation-bytes:       5120
first dispatch:          queued
backend calls:           1
worker exited:           true
endpoint state:          active
outbound frames:         0
delegate stopping:       false
cleanup started:         false
```

`apply-book-state-session-backend-result!` accepted the typed result. During
queueing, `queue-state-response-under-owner!` then threw:

```text
book-session-error: state "bounded state response exceeded reservation"
```

`complete-state-backend-task!` catches only `book-state-protocol-error`, and
`run-delegate-worker` catches exceptions from `RUN-OPERATION` but not exceptions
from its completion procedure. The exception therefore terminated the sole
worker without closing the endpoint or revoking its binding.

A second valid read was then reported as `queued`. After 50 ms, backend calls
remained one and the delegate snapshot contained:

```text
announced:       true
queued_tasks:    1
stopping:        false
cleanup_started: false
```

There was no worker left to consume the task. The process itself returned status
zero after the worker backtrace because an uncaught child-thread exception does
not make the main Guile thread fail. This explains why the existing 30-test gate
can remain green.

This is reachable with the intended persistent text contract: a book can save a
4096-byte value containing controls, receive the small commit receipt, and then
lose its live state channel when that value is read. The problem is neither a
hostile-book isolation claim nor a malformed backend result; all involved typed
values are within accepted bounds.

## Required finite correction

Before this candidate joins the accepted adapter/backend:

1. Derive the state-response reservation from the maximum **encoded framed
   response**, including worst-case JSON escaping and fixed fields—not raw text
   bytes. Every Protocol-V2-valid 4096-byte text value must either fit the
   declared queue bound and be deliverable or be rejected by the protocol before
   storage; it must not become an internal completion exception.
2. Make the completion boundary exception-total. No encoder, queue, invariant,
   or unexpected callback-result exception may terminate the sole worker while
   leaving an endpoint live. An impossible completion must invalidate and detach
   locally, then revoke and reap outside authority mutexes, preserving the
   existing self-close/no-self-join rule.
3. Add a full worker-path regression using 4096 NUL characters and at least one
   quote/backslash-heavy value. Assert the actual encoded size, bounded queue
   accounting, delivered typed response, continued worker service, and clean
   close/revocation.
4. Add completion-time output pressure: dispatch while capacity exists, fill
   the bounded output queue while storage is blocked, release storage, and prove
   deterministic fail-close, one revoke, worker exit, no post-close ack, and no
   stranded task. A committed operation may remain durable and be replayed by
   operation ID; the session must not claim that the write was cancelled.
5. Add an unexpected-completion-exception regression that proves the invariant
   “live state endpoint implies a live service worker” or fails the endpoint
   closed. Do not rely on a child-thread backtrace changing process status.
6. State the trusted callback liveness contract explicitly. `OPEN-BINDING`,
   `RUN-OPERATION`, and `REVOKE-BINDING` must be total/bounded in the supported
   deployment, or the host supervisor must treat an exceeded whole-process
   deadline as fatal. Guile threads and arbitrary kernel I/O are not safely
   cancellable; do not add a request timer that falsely reports cancellation
   while a write may still commit.
7. Preserve and extend the close race controls: queued-before-start, backend
   commit-first, backend revoke-first, double close while cleanup is waiting,
   callback exception, output-pump contention, and fresh-endpoint stale
   completion. Prove one revoke and eventual worker reap whenever the trusted
   callback returns.

Freeze corrected core/delegate/test/patch hashes and request another focused
source-only review. No QEMU, runsc, ARM, image, SQLite, or hardware test is
needed to close BSD-1.

Until then, candidate core `d60757f3…` and delegate `eca58675…` are **not fit for
the real adapter/backend join**. The accepted Book Session source `f5823fa7…`,
Protocol V2, and backend `7c3a507d…` retain their separate accepted statuses.

---

## BSD-1 successor recheck — accepted — 2026-09-06

### Disposition

**BSD-1 is closed for the exact successor pair below.** Candidate core
`f0e2a043…` with unchanged delegate `eca58675…` is fit to enter the separately
reviewed real adapter/backend join. This is acceptance of the source-level
delegate and completion lifecycle, not acceptance of an integration that has
not yet been assembled and tested.

The blocked v3 result above remains valid for `d60757f3…`. It is not relabelled;
the successor changes the core source and both patch identities.

### Frozen successor boundary

```text
pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/
packet-manifest.json
0c446a3a8916a9d3fae0a9f7124da13cc0fa008d6795d598c6833fed4984fa37

code-source-hashes.txt
43ec7444648431030eb51ad75d32b68f943c93e8cf3f6950ba209691fcfedd2c

evidence-hashes.txt
1403fb2773d433b0163769b95da6160c888a205a62666518ba62d82590405178

host-check.log
b3ac8886438ea878a7acb3405763331730e6fc541d186650c2a768be7aad944d

source-old-new.txt
1ba16081e9bf8e18f6411b5770adc436dfaf448634d638903104b58a1845c613
```

All ten source entries matched `code-source-hashes.txt`. The frozen packet files
were regular, single-link, mode-0400 files, except the mode-0500 test launcher.
The reviewed executable-source identities are:

```text
candidate/book-session.scm                  f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301
book-state-session-delegate.scm              eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6
book-session-bsd1-correction.patch           c229c218f48debd36d7209dd1106d22b6e5b9ec34c9f35e979b4ea8682a32d74
book-session-state-delegate.patch            d779ed2c257d9fe0e995011e5a8c83ba9c6945b7eb189648067a29ed7a7d0280
test-book-session-state-integration.scm      4008d9e4491e814b8a33d9a015038eb8684f2c9a0378966839cfd21309055562
CONTRACT.md                                   6d9b0f9323915eebd1390f47227f986cc81567f1af35d2718656187443dfbbf6
```

Independent temporary applications established all three source identities:

- full patch `d779ed2c…` maps accepted Book Session `f5823fa7…` exactly to
  successor `f0e2a043…`;
- reversing that full patch reproduces accepted `f5823fa7…` exactly; and
- focused patch `c229c218…` maps blocked v3 `d60757f3…` exactly to the same
  successor.

The live accepted Book Session source and tests remained unchanged:

```text
book-session.scm         f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668
test-book-session.scm    dbd96cbc13fc601edb5d7db5b676cabd2dcf9ad7f832ce85ebdea93b93294aec
```

The delegate is byte-identical to v3. The finite correction is the 90-insertion,
37-deletion focused core patch plus expanded tests and contract. The complete
accepted-base patch is 366 insertions and 64 deletions. No backend, adapter,
SQLite, or `guile-sqlite3` dependency entered the candidate closure.

### Encoded bound independently checked

The successor replaces the invalid 5,120-byte estimate with:

```text
4        frame prefix
101      largest fixed compact state-value payload at max-safe state_version
24,576   6 * 4,096 bytes of worst-case JSON string escaping
------
24,681   maximum framed worker response
```

The sixfold factor is conservative for every accepted UTF-8 string byte under
the pinned encoder:

- a one-byte C0 control such as NUL becomes six ASCII bytes (`\u0000`), attaining
  the ratio;
- quote and backslash become two bytes;
- safe ASCII remains one byte; and
- an escaped BMP or supplementary scalar consumes no more than six or twelve
  encoded bytes for its multi-byte UTF-8 input, a ratio below six.

`state-value` is the only worker response carrying arbitrary 4,096-byte text.
Its maximum valid form has `present=true` and the 16-digit maximum-safe state
version, and independently encoding it attained exactly 24,681 framed bytes.
The reviewer's original version-1 NUL value remained exactly 24,666 bytes.

The other authority output forms are strictly smaller. The frozen test
enumerates maximum-length grant handle/generation/access for `state-ready`, and
maximum ASCII operation ID, state/current version, text byte count, and longest
accepted failure code for `state-committed`, `state-conflict`, and
`state-commit-failed`. Absent `state-value` is constrained to version zero and
empty text. Inbound `state-read` and `state-commit` are not worker replies.

The 24,681-byte bound includes the four-byte frame header, is below the generic
65,540-byte framed limit, and fits the 524,320-byte eight-frame output bound.
Module initialization asserts those two relationships, while the source-exact
tests attain the exact bound rather than merely sampling a short value.

### Original BSD-1 counterexample now delivers

An independent typed mock returned `(make-string 4096 #\nul)` through the real
successor worker, accepted state codec, output queue, nonblocking output pump,
and frame decoder. The observed queued frame was exactly 24,666 bytes and the
decoded text matched all 4,096 NUL characters.

The result was not rejected or converted to a fail-close. The same worker then
served a second read with a distinct version and text. Normal close attempted
revocation once and reaped that worker:

```text
NUL frame bytes:       24666
first round trip:      complete
second round trip:     complete
backend calls:         2
revocations:           1
worker reaped:         true
```

This directly reverses every observable element of BSD-1: no child-thread
backtrace, no active endpoint with a dead worker, and no stranded second task.

### Exception-total completion and close ordering

Completion now has one local failure transition while holding the endpoint
mutex. After rechecking exact endpoint identity and delegate object, any backend
callback failure, missing completion capacity, malformed/oversized result,
FSM/protocol rejection, encoder failure, queue failure, or response-note
invariant failure:

1. closes the session/surface state and clears output frame/byte accounting;
2. closes the state FSM, stops and clears its one task slot, and detaches the
   exact delegate;
3. marks the transport closed before another input dispatch can publish work;
4. releases the endpoint mutex; then
5. shuts down transport and gives one cleanup owner the revoke/reap sequence.

The inner catch covers result application, encoding, append, and acknowledgement
bookkeeping while local invalidation remains atomic. A final outer containment
path handles unexpected lock/runtime exits by attempting ordinary close. Cleanup
exceptions cannot reactivate the endpoint or escape the sole worker. The
unchanged delegate avoids joining itself when failure cleanup runs on that
worker; after completion returns, its stopping state makes it exit normally.

An independent encoder-failure probe placed two complete state reads on the
transport before the first completion. Injected encoding failure produced:

```text
session state:         closed
transport open:        false
outbound frames/bytes: 0 / 0
backend calls:         1
revocations:           1
next input pump:       closed
worker exited:         true
queued tasks:          0
stopping/cleanup:      true / true
```

Thus the second request neither reached storage nor became stranded, and no
late response survived local close.

A separate double-close probe blocked the one backend callback after dispatch.
The first close invalidated locally, detached, and attempted revocation before
waiting for the worker. A concurrent second close returned without a second
cleanup sequence. Releasing the callback yielded one backend call, one
revocation, zero output frames, and an exited worker.

### Queue pressure and partial output accounting

The inherited queue has eight frame slots and explicit remaining-byte
accounting. The successor's source-exact tests establish:

- seven maximum 65,540-byte frames leave one frame slot and enough bytes for the
  full 24,681-byte schema reservation;
- the worker can consume that eighth slot without crossing the byte bound;
- after 4,096 bytes are sent from the head of an eight-frame queue, byte usage
  falls by exactly 4,096 but the partial head still occupies its frame slot, so
  new state dispatch rejects before task publication; and
- if output fills only after a blocked operation was dispatched, completion
  atomically clears all eight frames and all bytes, closes and detaches, invokes
  revocation once, reaps the worker, and leaves a second unread request
  undispatched.

Close racing an encoder paused inside successful completion waits on the
endpoint mutex rather than deadlocking. Once encoding is released, close clears
the newly queued response and joins the stopping worker, so no acknowledgement
is published after the close transition.

These controls preserve the intended durable-write interpretation: if a real
commit won before local close, its receipt may exist in the accepted backend and
the operation ID may be retried in a fresh session. The delegate emits no false
claim that an in-flight write was cancelled.

### Independent execution

The successor was run from reviewer-created source-only directories after every
project input matched its declared hash. No ambient project compilation cache
was used. Native Guile execution produced:

```text
accepted Book Session assertions: 227 passed
focused successor assertions:      61 passed
full patch forward/inverse:         exact
focused patch forward:              exact
```

The immutable supplied host log separately records zero arity/format compile
warnings for the same source hashes. This recheck did not turn that source-level
warning gate into a product, image, Guix, ARM, or guest build.

### Accepted scope and next join

The pair below is accepted for the next real join:

```text
Book Session successor    f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301
state delegate            eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6
complete patch            d779ed2c257d9fe0e995011e5a8c83ba9c6945b7eb189648067a29ed7a7d0280
```

The real integration must still bind the independently reviewed factory/adapter
and accepted backend at their approved hashes, preserve
initialize-before-state-ready output ordering, and rerun
the joined state/read/commit/retry/close paths. This review does not itself prove
SQLite durability, adapter mapping, guest/outer-loop behavior, sandboxing,
QEMU, ARM, image behavior, or hardware.

The trusted callbacks must remain total and bounded in the supported
deployment. The five-second SQLite busy timeout does not bound arbitrary kernel
I/O; no Guile thread kill or request timer may claim that an unresolved write
was cancelled. Whole-process supervision remains the honest terminal bound.

Any change to the accepted candidate, delegate, full/focused patch, protocol,
codec dependency, or focused-test hashes requires fresh review. No frozen
packet or implementation source was modified during this recheck. No QEMU,
runsc, ARM execution, image/Guix build, hardware, deployment, staging, commit,
or push occurred. Reviewer-created files, threads, sockets, and temporary
directories were removed.
