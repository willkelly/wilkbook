# Trusted Book State completion observer contract

## Scope

This private successor adds the smallest trusted polling seam needed to map
typed Book State backend results into the already-accepted reader UI control
contract.  It does not install or join that UI.  The accepted constructor
`make-book-session-host-with-state` remains observer-free.  Trusted code must
opt in with `make-book-session-host-with-state-observer` and may then poll only
`endpoint-take-state-completion!`.

The observer is not a callback, plugin, event bus, or registry.  Every opted-in
endpoint owns exactly one private slot with three possible states:

1. empty;
2. one opaque in-flight reservation; or
3. one immutable typed completion.

An occupied slot rejects another state request with local `backpressure` before
the accepted state FSM or backend can be mutated.  Surface traffic remains
independent and bounded.

## Authority and identity

Only a book may send `state-read` or `state-commit` over its Book Session-owned
socket.  The trusted outer/UI authority may send a bounded `action`, but it may
not call the backend, manufacture an inbound state message, choose a grant, or
select an observer recipient.

Reservation happens under the endpoint mutex before state dispatch.  Result
publication under that same mutex rechecks and records:

- the private endpoint identity;
- copied Book Session ID;
- exact surface generation at dispatch;
- exact state-grant generation;
- operation kind (`read` or `commit`);
- commit operation ID, expected version, and text where applicable; and
- one accepted typed authority response.

The accepted state FSM independently binds the exact pending operation and
backend result.  Read completions accept only `state-value`.  Commit completions
accept only `state-committed`, `state-conflict`, or `state-commit-failed`, with
an exactly matching operation ID.  A committed response must also equal
`expected_state_version + 1` and the operation text's UTF-8 byte count.

Cached idempotent replies are observable, but do not invoke backend I/O again
and do not repeat `state-session-note-commit-ack-sent!`.

## Atomicity, failure, and lifetime

Encoding, bounded response-queue insertion, accepted-model response handling,
and observer publication are one endpoint-mutex transition.  An exception,
impossible response, output pressure, missing/wrong reservation, wrong
operation, stale endpoint/delegate, or stale surface generation publishes
nothing.  The BSD-1 local fail-close transition clears output and the observer,
detaches the exact delegate, and invalidates transport before revocation and
worker cleanup outside the endpoint mutex.

Close, peer EOF, revoke, release, and restart clear the old slot.  Navigation
cannot expose a completion from an earlier surface generation: polling rejects
and clears an already-published stale completion, while an in-flight stale
result fails closed without a wire response or observation.  A replacement
endpoint receives a new private owner, session, grant, worker, and empty slot.

`endpoint-take-state-completion!` performs no backend, transport, UI, or other
callback I/O.  It returns the completion at most once.  Every public string and
typed-response accessor returns a defensive copy; mutation cannot change the
observer's retained record, queued wire bytes, protocol idempotency cache, or
SQLite state.

## UI mapping and non-equivalence of facts

The accepted UI packet's exact mapping remains:

```text
UI submit
  -> trusted host-action!
  -> book-issued state-commit on that book's owned socket
  -> backend typed response
  -> trusted completion poll
  -> matching-generation UI commit-ok or commit-failed
```

Only an observed `state-committed` can authorize `commit-ok`, and trusted UI
code must still correlate its operation text with the UI's pending text.  A
later edit remains a draft and cannot be overwritten by a stale receipt.
`present` is a book presentation fact; UI `applied` is a paint fact.  Neither is
storage evidence, and neither can create an observer completion.

## Commit ambiguity and recovery

A commit may become durable after close, EOF, restart, stale-generation
invalidation, or completion/output backpressure has made its response
unobservable.  Absence of an observation therefore does not prove absence of a
commit.  Recovery is: reopen the exact BookInstance, read its state, then retry
the exact operation ID, expected version, and text.  The backend's durable
idempotency receipt resolves the ambiguity; never synthesize `commit-ok` from
presentation, paint, or current text alone.

## Bounds and execution boundary

The accepted state text bound remains 4,096 UTF-8 bytes and includes U+0000.
The largest framed escaped response reservation remains 24,681 bytes; the
version-1 all-NUL `state-value` fixture is 24,666 bytes.  This is separate from
the accepted ordinary UI codec, which deliberately excludes NUL because it is a
text-widget boundary rather than the durable backend wire.

Backend, transport, and UI I/O remain outside Book Session authority mutexes.
The backend callbacks are still required to be trusted, bounded, and total; no
thread cancellation claim is added.

## Exclusions

No live backend, protocol, adapter, Book Session, delegate, UI, native-v1 root,
kernel, gVisor, image, or central documentation source is changed.  No QEMU,
runsc, AArch64 execution, KOReader execution, image work, hardware, deployment,
staging, commit, push, merge, fetch, or rebase is part of this packet.
