# Native Book State integration contract

Status: **corrected frozen host-only integration candidate (v2)**.  It is pinned to the
independently accepted BSD1 successor pair (`f0e2a043…` + `eca58675…`) and the
separately accepted backend, protocol, and adapter.  Its source/evidence packet
is prepared for review; this status does not pre-accept the new integration.
Nothing here changes an accepted backend, protocol, adapter, Book Session live
source, guest, or reader.

## Reusable trusted interface

The module `(book-state-integration)` exports only:

```scheme
(open-native-book-state-runtime TRUSTED-ROOT) => RUNTIME
(open-native-book-instance-host! RUNTIME TRUSTED-REVISION TRUSTED-INSTANCE
                                 [ACCESS]) => INSTANCE-HOST
(native-book-instance-session-host INSTANCE-HOST) => BOOK-SESSION-HOST
(close-native-book-state-runtime! RUNTIME) => closed | already-closed
```

`ACCESS` is `read-write` by default and may be `read-only`.  The runtime owns
one accepted `(book-state)` store.  Opening an instance resolves its durable
namespace once, before any endpoint exists.  Its private factory captures the
store, namespace, and access and is exactly:

```scheme
(make-book-state-delegate-factory OPEN-BINDING RUN-OPERATION REVOKE-BINDING)
(make-book-session-host-with-state FACTORY)
```

For each endpoint, `OPEN-BINDING` receives only Book Session's fresh opaque
owner, issues a new accepted backend grant, and constructs the accepted typed
endpoint binding.  `RUN-OPERATION` passes only a typed accepted operation to
`run-state-backend-operation`.  `REVOKE-BINDING` revokes only the retained exact
binding.  There is no namespace lookup, path selection, SQL, language choice,
or component registry on the wire.

The module intentionally exports no store, namespace, grant, database path, or
factory accessor.  A trusted caller must release or close all Book Session
endpoints before closing the runtime.  Backend close is the final fail-closed
grant revocation.

## Native proof flow

The local proof supervisor hard-codes one stable trusted instance per fixture
language.  It creates endpoints through the accepted socketpair factory and
launches actual native Guile and Python fixture-book processes.  The books get
only one connected Book Protocol socket as standard input; stdout and stderr
are bounded diagnostic logs and never carry protocol traffic.  The native
launcher is test evidence, not a second production API and not a sandbox.

For each fresh endpoint:

1. the book sends `hello`;
2. the authority queues the existing seven-field `initialize`, then the typed
   `state-ready`, in that order;
3. the book sends `state-read` and waits for `state-value`;
4. trusted `host-action!` sends the fixed `load-display` action, and the book
   separately presents the loaded text;
5. trusted `host-action!` sends the fixed `edit-save` action;
6. the book commits with an ASCII operation ID and the loaded CAS version,
   waits for `state-committed`, and separately presents receipt text; and
7. the authority distinguishes delegate scheduling results from
   `<presented-text>`, drains worker-queued output, closes the endpoint, revokes
   the grant, and reaps the exact recorded child.

The restart test uses distinct Guile authority processes.  Only the first
process receives the generated Unicode fixture values, and it delivers them by
`host-action!`.  Later authority and book processes receive no expected value
in argv or environment.  Their displayed text can therefore originate only in
the reopened backend's `state-value`; a Python test oracle compares it outside
the authority.

A test-client retry mode retains only the operation identity and reconstructs
the exact retry text from `state-value`.  It checks the original receipt both
before and after a later CAS advances the namespace, then rereads to prove that
the old receipt did not overwrite or roll back the newer state.  This is
positive **acknowledged persisted-receipt replay**, not loss evidence.

A separate one-book test proves actual lost acknowledgement.  Its test-only
factory wrapper calls the real accepted `run-state-backend-operation` first,
then stops at a deterministic baton before returning the typed result to the
delegate worker.  While that callback is paused, another thread closes the
endpoint using accepted Book Session close order.  The book must reach EOF
without parsing `state-committed`, its process group must be gone, the endpoint
must have zero outbound frames, and an independent read-only SQLite connection
must see the exact value and one receipt.  Only then does the oracle release the
callback so close can join the worker.  A fresh Guile authority and fresh book
load the durable text, submit the same operation ID and original expected
version, receive the original version-1 receipt, and prove that value, version,
and receipt count did not change.  Recovery text is never passed to the retry
authority.  A positive counterexample which consumes `state-committed` and then
claims loss is executed and must be rejected by the loss oracle.

## Lock and process rules

- Book Session's endpoint mutex is never held by this module around backend
  work.  The delegate worker invokes the accepted synchronous adapter exactly
  as designed.
- Close first invalidates and detaches the endpoint under Book Session's mutex;
  backend revocation and worker join occur after that mutex is released.
- The lost-ack baton is after the real adapter return and outside every Book
  Session/delegate/backend lock.  Close runs asynchronously, all waits have
  finite deadlines, and the exact worker and child are joined/reaped.
- Each native child is created by Guile `spawn`, which inherits only selected
  stdio descriptors.  The accepted socketpair peer is `FD_CLOEXEC` in the
  authority; `spawn` duplicates it to the child's protocol FD 0.  Fixture books
  assert that FD 0 is a connected Unix stream, is not close-on-exec after
  donation, has no duplicate socket alias, and that no unrelated non-CLOEXEC
  descriptor survived.
- Every child enters its own process group and stops before protocol work.  The
  supervisor records PID plus Linux start time before `SIGCONT`, verifies that
  identity before signalling, bounds logs, reaps status, and removes its
  process record on every exit path.

## Evidence boundary

The default host suite includes the 4,096-byte NUL state round trip through the
real worker and reopened SQLite store.  That case is not skipped or marked
expected-failure.  The accepted successor reserves the derived 24,681-byte
worst case and fail-closes worker-completion exceptions.  Its independent review
closed BSD1 at SHA-256 `4a3e650c…`; the known-bad 5,120-byte v3 candidate is not
rerun or relabelled.

Passing evidence will establish native process restart, not gVisor, QEMU,
AArch64 execution, KOReader, paint acknowledgement, image construction, or
physical-power-loss durability.  The accepted 45-path sandbox language closure
remains unchanged and contains no newly added SQLite authority path.

Before compilation or any native fixture execution, the outer gate authenticates
the fixed v2 snapshot path, `PACKET-ROSTER.txt`, `SOURCE-IDENTITIES.sha256`, and
`MANIFEST.sha256`.  The source manifest includes every consumed project Scheme
and Python module, schema, fixture, authority, test oracle, factory test, source
gate, origin checker, test manifest, and inner runner.  In particular it binds
`book_protocol.py` and `(book-protocol blocking-io)`.  Accepted backend,
protocol, adapter, Book Session, and delegate hashes are hard-coded in the
source verifier; no expected hash or source directory is caller-selectable.
Review documents are provenance only and are not machine-gate inputs.

The pinned Guix shell clears Python and Guile injection variables.  Python
fixtures run with `-I -S` through an exact-path loader that checks and reports
the accepted codec identity.  Scheme project modules are compiled from the
snapshot into a private cache and their runtime compiled origins are checked.
This authenticates the native host execution; it does not turn that execution
into the accepted sandbox.  The separate 45-path sandbox closure remains
unchanged.

## Required private receipt observer for the later reader join

This native proof deliberately preserves the actual book execution chain:

```text
trusted host-action! -> fixed book -> inbound state-commit -> backend/adapter
-> outbound state-committed -> fixed book -> separate present
```

The fixture books validate the exact typed `state-committed` fields before they
send `present`, and the test-only SQLite oracle independently verifies durable
receipt rows.  The outer authority's resulting `<presented-text>` is still only
a **book presentation claim**.  It is not an authority-observed typed storage
receipt, and this integration does not reinterpret it as one.

The accepted Book Session interface currently hides asynchronous worker
completion from the trusted pump owner.  Initial input yields only a
`<state-delegate-dispatch-result>` such as `queued`; later
`endpoint-pump-output!` reports byte/frame progress, not the typed response that
the worker applied and queued.  Therefore a future join to
`../book-state-reader/` cannot honestly issue private UI `commit-ok` from the
current outer API.

That join needs one separately reviewed, trusted-only completion seam.  The
minimal shape is a bounded per-endpoint completion event containing both:

- the exact accepted typed commit operation (including operation ID, expected
  version, and text); and
- the exact typed `state-committed`, `state-conflict`, or
  `state-commit-failed` response.

Book Session should publish that event under its endpoint mutex only after the
typed response has successfully entered the bounded output queue.  It must bind
the exact endpoint identity, delegate, operation, and grant generation; cover
both worker completions and cached responses; permit at most the existing one
pending commit event; clear atomically on close/restart; and never publish after
a completion fail-close.  A trusted non-I/O drain operation can then return the
event to the outer loop.  No event is added to the book or private UI wire.

For the reader, one pending UI generation/draft must be matched against the
event's exact commit text before `state-committed` maps to private `commit-ok`;
conflict/failure maps to `commit-failed`.  The route remains UI `submit` →
trusted `host-action!` → the book's owned socket → backend.  The outer must not
call the backend directly, impersonate an inbound `state-commit`, or use the
later `present`/`applied` paint path as receipt evidence.
