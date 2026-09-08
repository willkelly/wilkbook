# Book Session state delegate BSD-1 successor — review packet

## Disposition requested

**Ready for another focused source-only review.** This private successor closes
BSD-1 from `doc/reviews/2026-09-06-book-session-state-delegate-adversarial.md`.
It is not installed in live Book Session source and is not a backend/adapter
join. The accepted Book Session, protocol, backend, adapter, guest, outer loop,
UI, package, system, and image sources remain outside this candidate.

The blocked input packet was authenticated as:

```text
/tmp/opencode/book-session-state-integration-v3-source-exact.ltSllU/
9d1faa6eb166dba125c9752693cc5c76fd6d80e79981ca4ce5e0bf1794781624  packet-manifest.json
5b01ce1e47b9efeac9c0f823da7015b32b22cf769818ec6d9076c078c5cf5e13  adversarial review
```

The exact blocked core is preserved at `base/book-session-v3.scm`; the corrected
private source is `candidate/book-session.scm`. The delegate module itself is
byte-identical to v3. `book-session-bsd1-correction.patch` is the focused v3 to
v4 delta. `book-session-state-delegate.patch` is the complete future-integration
delta from accepted Book Session source. Neither patch has been applied to live
source.

## BSD-1 correction

### Encoded frame bound

The old 5,120-byte estimate treated raw UTF-8 text as encoded JSON. The new
24,681-byte bound is:

```text
4       frame prefix
101     fixed compact JSON for the largest state-value metadata
24576   6 * 4096, attained by 4096 NUL bytes encoded as \u0000
-----
24681
```

The reviewer's version-1 counterexample remains exactly 24,666 framed bytes;
the extra 15 bytes in the bound are the maximum-safe `state_version`. The bound
is below the generic codec's 65,536-byte payload/65,540-byte framed limit and the
eight-frame queue's 524,320-byte limit. It cannot permanently reject all valid
requests. Tests attain the bound, enumerate every other typed authority output
shape, deliver 4096 NUL and quote-heavy values through the real worker/codec,
fill seven maximum codec frames before a valid response, and prove that a
partially sent eighth frame still occupies its slot.

### Exception-total completion

Completion now rechecks the exact endpoint identity and delegate object under
the endpoint mutex. Backend callback failure, missing completion capacity,
malformed/oversized result, protocol/FSM rejection, encoder exception, queue
exception, and response-note invariant failure all use one local failure
transition under that same mutex:

1. close the surface/session state;
2. clear all queued output and byte accounting;
3. close the state FSM, stop/clear its one task slot, and detach the exact
   delegate; and
4. mark transport closed before any subsequent input can publish work.

After releasing the endpoint mutex, completion shuts down the transport and
owns the one revoke/reap sequence. A worker-initiated failure does not join
itself; the now-stopping worker returns from completion, observes no task, and
exits. Cleanup exceptions are contained after local invalidation. Tests inspect
the retained worker object rather than relying on a child-thread backtrace or
process status.

Completion-time pressure is tested by dispatching a blocked read, placing a
second read on the socket without pumping it, filling all eight output slots,
and releasing storage. The endpoint closes with zero output bytes/frames, one
backend call, no second task, one revoke, and an exited worker. A repeated close
does not revoke twice. Close racing an encoder paused inside completion waits for
the endpoint mutex, then clears the just-queued response and joins without a
late acknowledgement or deadlock.

## Owner and lifetime claims

- `OPEN-BINDING` still receives only Book Session's fresh opaque endpoint owner,
  outside host and endpoint mutexes.
- `RUN-OPERATION` still receives only one accepted typed operation and runs with
  no host, endpoint, or delegate mutex held.
- Completion applies a result only to the exact endpoint identity, exact
  delegate object, exact pending operation, and exact grant generation.
- Local failure invalidation and detachment precede trusted revocation and are
  atomic against another endpoint input dispatch.
- `REVOKE-BINDING` receives only the delegate's retained typed binding, outside
  the endpoint mutex. One cleanup owner attempts it once.
- Restart continues to construct a fresh endpoint/owner/grant. A stale
  completion cannot select a replacement endpoint.
- The one worker and one task slot remain unchanged. No pool, timer, custom
  codec, cancellation report, or generic callback framework was added.

The three trusted callbacks must be total and bounded in the supported
deployment. If arbitrary filesystem/kernel I/O never returns, Guile cannot
safely cancel that operation; a supervisor may fail the whole process after an
external deadline but cannot claim a write was cancelled. Tests prove eventual
reap only when the trusted callback returns or throws.

## Exact host evidence

`run-host-tests.sh` uses the pinned Guix time machine with substitutes disabled,
reproduces both patches, reverses the full patch to the accepted source, compiles
all modules with arity/format warnings enabled, and runs from an empty directory
with a private compilation cache.

```text
accepted Book Session assertions: 227 passed
focused delegate assertions:       61 passed (30 retained + 31 added)
compile warnings:                   0
full patch reproduction:            exact
full patch inverse:                 exact accepted source
focused v3 -> v4 patch:             exact
backend/SQLite imports:             none
```

The logged gate is `host-check.log`. `code-source-hashes.txt`,
`source-old-new.txt`, `evidence-hashes.txt`, and `packet-manifest.json` freeze the
review boundary.

## Excluded claims

No SQLite/backend behavior, adapter acceptance, durable save/reopen, guest or
outer-loop integration, QEMU, runsc, ARM, image/Guix build, hardware,
deployment, staging, commit, or push was performed or is claimed. Accepted
backend `7c3a507d…`, protocol/accessor `425ccc46…`, and adapter `349c960b…` retain
their independent statuses. The parent session must join the separately
accepted backend/adapter only after this source receives independent review.
