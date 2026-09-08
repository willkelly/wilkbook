# Optional Book State delegate — BSD-1 successor candidate

Status: private host-only source candidate correcting BSD-1 from the blocked v3
packet. The accepted Book Session source remains unchanged at `f5823fa7...`;
`candidate/book-session.scm` and `book-session-state-delegate.patch` are the
proposed delta. This is typed mock-storage evidence, not the real SQLite join.

## Exact interface

There is one optional typed facility, not a callback registry:

```scheme
(make-book-state-delegate-factory OPEN-BINDING RUN-OPERATION REVOKE-BINDING)
(make-book-session-host-with-state FACTORY)
```

`OPEN-BINDING` receives only the fresh opaque endpoint identity created by Book
Session and must return one `<state-endpoint-binding>`. Its trusted closure owns
namespace/store selection. `RUN-OPERATION` receives only an accepted typed read
or commit operation. `REVOKE-BINDING` receives only the retained binding. No
book-supplied namespace, owner, path, SQL, socket, language, or component value
can enter these calls. The ordinary zero-argument `make-book-session-host`
retains its exact behavior and does not accept state messages.

The eventual real factory may close over accepted Book State and the accepted
adapter. Neither is imported by this candidate or its tests.

## Wire and initialization

The accepted surface `hello -> initialize` envelope is unchanged. A
state-enabled hello produces two ordered pump values:

1. the exact existing seven-field `initialize` alist;
2. one typed `state-ready` record for this endpoint's retained grant.

The trusted pump owner must queue both in that order with
`endpoint-queue-message!`. State operations are inactive until the exact typed
`state-ready` has been queued. This two-value hello is the first unavoidable
outer-loop integration difference: existing one-value loops remain unchanged
for ordinary hosts, while a future state-aware loop must queue both values.

After initialization, an accepted `state-read` or `state-commit` pump returns
one bounded `<state-delegate-dispatch-result>` (`queued`, `already-pending`, or
`cached`). It is an authority scheduling fact, not a presentation. A future
state-aware outer loop must recognize it rather than pass it to presentation
handling. State wire replies are queued by the endpoint-owned delegate. Surface
actions and `<presented-text>` results are unchanged.

All seven state type names route only through the accepted typed state decoder.
Inbound direction admits only `state-read` and `state-commit`; unknown fields,
wrong-direction state types, and book-supplied authority fields are rejected
before storage dispatch.

## Worker and bounds

Each state-enabled endpoint owns one worker and one task slot. The accepted FSM
permits one pending state operation, so no second queue is needed. A pump:

1. decodes outside the endpoint mutex;
2. under the endpoint mutex, validates current endpoint/hello/grant, advances
   the pure FSM, and publishes at most one task;
3. returns without waiting for storage;
4. the worker runs storage with no host, endpoint, or delegate mutex held;
5. the worker reacquires the endpoint mutex, checks exact endpoint and delegate
   identity, lets Protocol V2 recheck exact operation/generation identity, and
   queues at most one bounded typed response.

Thus the backend's documented SQLite busy wait (up to five seconds) can block
only this endpoint's state worker, not the Book Session pump or simultaneous
surface presentation. No worker pool, generic async method system, or unbounded
queue is introduced.

One worker response reserves 24,681 bytes within the accepted eight-frame/byte
output bounds. This is derived rather than estimated: the four-byte frame
header, 101 fixed compact-JSON bytes for a present `state-value` at the maximum
safe state version, and `6 * max-state-text-bytes` for the codec's worst C0
escape (`\u0000`). It is below both the 65,540-byte maximum framed codec value
and the 524,320-byte whole output queue. Static tests attain the bound, cover
every other typed output shape, and exercise seven maximum frames plus one
state response and an eight-frame queue with a partially sent head.

If capacity existed at dispatch but another producer fills the queue before
completion, the completion atomically closes, clears, and detaches the exact
endpoint lifetime while holding its mutex. Backend callback errors, malformed
or oversized results, encoder failures, queue failures, and local invariant
failures take the same path. Transport shutdown and the one revoke/reap happen
after releasing the authority mutex. No completion exception can leave an
active endpoint whose sole worker has exited.

## Close and replacement

Close, EOF, surface revocation, release, and restart all serialize local state
invalidation under the endpoint mutex. They clear pending output and detach the
exact delegate before any backend call. With no Book Session mutex held, cleanup
then revokes that delegate's retained grant and joins its worker. Backend mutex
ordering decides whether an operation already inside storage wins; a queued or
late operation cannot publish an acknowledgement after local close.

Restart creates a new endpoint identity and invokes the trusted binding factory
again outside authority locks. The old handle/generation cannot select the new
delegate.

## Trusted callback liveness boundary

`OPEN-BINDING`, `RUN-OPERATION`, and `REVOKE-BINDING` are trusted deployment
callbacks and must be total and bounded. They may perform the already accepted
backend's bounded synchronous I/O; no Book Session mutex is held around that
I/O. Guile threads cannot safely preempt arbitrary filesystem or kernel I/O, so
this candidate adds no request timer and never reports a blocked write as
cancelled. A supervisor may treat an exceeded whole-process deadline as fatal,
but cannot infer that a commit did not occur. Whenever a callback returns or
throws, focused tests establish local fail-close, one attempted revocation, and
worker termination. This does not claim cancellation while a callback remains
blocked.

## Evidence boundary

Focused host tests use typed mock bindings/results only. They retain the 30 v3
assertions and add the exact 4096-NUL counterexample, quote-heavy round trip,
worst-shape and exact/partial queue-capacity guards, completion pressure with a
second unread request, malformed/oversized/callback/encoder/cleanup failures,
and close during completion. They prove worker and mutex behavior, bounded
single-pending dispatch, state grammar routing, read/commit response transport,
close-before-dispatch, close-during-commit, simultaneous surface presentation,
and fresh restart grants. They do **not** claim SQLite durability, adapter
acceptance, save/reopen, QEMU, sandbox, image, or hardware integration.
