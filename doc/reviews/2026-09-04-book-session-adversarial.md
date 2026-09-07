# Book Session Python contract adversarial review — 2026-09-04

## Verdict

**Keep the reviewed Python implementation as a sequential, host-only contract
oracle; do not treat it as the accepted production session runtime.** Under the
documented assumption that a trusted caller supplies the correct concrete
connection binding and serializes all calls, I found no peer-wire way to use a
claimed owner, a copied diagnostic label, or even complete knowledge of another
session's handle and request token to present on that other session. The exact
hello/initialize/action/present trace, retry-after-rejection behavior, ordinary
lifecycle invalidation, and sequential bounds behaved as documented.

The selected trusted runtime is now Guile. Three requirements gate that port:

1. the actual inherited endpoint must be inseparably bound to a private,
   host-created identity; the Python socket test does not establish this;
2. Guile must enforce **lexical** JSON integers before `guile-json` normalizes
   decimal/exponent spellings to exact integers; and
3. all state transitions must have one serialized owner (or equivalent atomic
   synchronization). The Python reference exceeds its pending bound and loses
   unique sequences under forced concurrent host callbacks.

The first two are integration prerequisites, not peer exploits in this
deliberately unintegrated Python harness. The third is a real counterexample to
using the Python object concurrently, but still requires trusted-caller
concurrency rather than peer data alone. A fresh independent review must assess
the completed Guile session implementation; no partial Guile port is accepted
or inferred here.

## Threat and scope distinctions

- The adversarial peer controls framed JSON and is assumed to know another
  session's complete opaque handle and request ID. It does not execute in the
  trusted host process.
- `SupervisedConnectionBinding`, `open_session`, host actions, timers,
  navigation, revocation, close, and restart are trusted-side operations. A
  peer cannot invoke the Python methods merely because they are public names in
  this test module.
- Direct mutation of private Python attributes, reflection, or hostile
  monkey-patching inside the trusted process is not a peer attack. One patched
  ID allocator below is used only as a deterministic scheduler/fault injector;
  the resulting concurrency requirement transfers to the Guile design.
- This review makes no sandbox, gVisor, renderer, asynchronous transport,
  durability, display-settled, filesystem, or crash-recovery claim. The
  reference accurately excludes those properties.
- Tests used bounded local Python processes and Unix `socketpair`s only. No
  hardware, external network, VM, Guix operation, package/system build, or
  deployment was used. Temporary probes were removed after execution.

## Exact reviewed snapshot

Repository baseline was
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The new files were untracked, so
the hashes—not the baseline commit alone—identify the review object.

| Reviewed file | SHA-256 |
|---|---|
| `pinenote/tools/book-session/book_session.py` | `042482d071f39d96ba0cb7f74c91c395e7c01ce7685aaf038cc8a88172cd32e3` |
| `pinenote/tools/book-session/test_book_session.py` | `31ce005e7327a99a4522f7c047a1fc7888a60f6d87275e4d78a2e3dc28c25dbe` |
| `pinenote/tools/book-session/README.md` | `e2f14796a7ea718289df45f562e62feff9c4fd499c311cb4b7875d72df225804` |
| `pinenote/tools/book-session/Makefile` | `4518c6d53faa97596b6db5daea3805124dd448ff09b734f37b4c8ba2a498106b` |
| `pinenote/tools/book-protocol/book_protocol.py` | `4e2423e09291d29758a6441d460eee2abfb82f24ed589f477ad62021c95ebe735` |
| `pinenote/tools/book-protocol/book-protocol.scm` (generic framing context only) | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| `pinenote/tools/book-protocol/README.md` | `d75183d9f4574d2a38f9c08e70e2f514dcbab0b114c074ea5633ade45f026613` |
| `doc/wilkbook-self-hosting-book-computer.md` | `aef579f6b1126a9d0803054ee78249e75adfd0c82ac9a00ff3b021fe6ebe8f6e` |
| `doc/book-computer-implementation.md` as initially read | `73bb9289b680207eb61a6c9622808d1def5b16126e036f808abfcb4e76359efb` |
| `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |

`doc/book-computer-implementation.md` changed concurrently to
`f693b059f741dba7a41d1d1add197ad6fb86112378eccdd78b6a7fdfcc9820b8`
after the review snapshot. That later content, and any Guile session port
created after this snapshot, are explicitly outside this verdict.

## Findings, ranked

### 1. High integration prerequisite — authority is the caller-supplied binding, not the socket

**Expected.** The trusted supervisor creates one private execution identity from
one inherited endpoint. Every decoded message from that endpoint is dispatched
through a closure already capturing that identity. No peer field, public
registration message, diagnostic label, or event-loop lookup can choose a
different identity.

**Actual.** `BookSessionHost` correctly keys sessions by Python object identity:
two `SupervisedConnectionBinding("same-label")` objects are distinct, and a
lookalike cannot select either session. With the correct binding, a forged
cross-session presentation was rejected even when request IDs were deliberately
collided and the attacker knew every other field.

But the socket and binding are completely separate inputs to the test caller.
The socketpair fixture decodes bytes, then manually supplies `self.connection`.
If a trusted routing bug supplies B's object for bytes read from A's endpoint,
an exact B response is accepted, as it must be under this API:

```python
target = host.host_action(binding_b, "target", "secret")
peer_a.sendall(encode_frame(present_for(target)))
decoded_from_a = receive_one(host_endpoint_a, decoder_a)
result = host.dispatch_peer(binding_b, decoded_from_a)
print(result.text, host.snapshot(binding_b).pending_requests)
```

Observed:

```text
misrouted 0
```

Dispatching those bytes as A instead rejects them. Thus the identity mechanism
works, but its authority source is not established by this experiment. This is
not a peer-only Python defect: a peer cannot pass the method's first argument or
call `open_session`. It is the most important next integration obligation.

**Guile/integration gate.** The supervisor must create a private binding record
while accepting/donating the endpoint, register it through a trusted-only path,
and capture it in that endpoint's read watcher. Use object identity (`eq?` or an
equivalent private identity), not structural equality, a component string, a
JSON owner claim, an FD number supplied later, or a globally reusable label.
Make registration single-use and prove that close/restart/FD reuse cannot route
old bytes through a successor binding. Add a two-socket test that deliberately
knows both tokens and fails if the dispatcher swaps its captured bindings.

### 2. High Guile port blocker — post-parse exact integers are not lexical JSON integers

**Expected.** `version`, `surface_generation`, `sequence`, and `count` accept
only lexical JSON integer tokens in their safe and field-specific ranges.
Booleans, decimal points, exponents, signed float zero, and rounded aliases must
fail before request lookup or state mutation.

**Actual in the reviewed Python schema.** Over a real socket, each of
`true`, `1.0`, `1e0`, `-0.0`, and `0.99999999999999999` was rejected in
`hello.version`. The same five tokens were rejected independently in each of
the three integer fields of `present` (15 more rejects). The session remained
`awaiting-hello` after the bad hellos, and the pending request survived all bad
presentations before a valid retry succeeded.

**Known generic Guile behavior.** On the exact framing hash above, the already
independently reviewed Guile path parses/re-encodes these spellings as:

```text
1.0 -> 1       0e1000 -> 0       -0.0 -> 0
```

Consequently `(and (integer? value) (exact? value))` after `guile-json` is not
equivalent to Python's `type(value) is int`; it would accept wire aliases that
this schema promises to reject. The generic codec explicitly leaves this
unresolved. No Guile session schema was present in the reviewed snapshot.

**Guile gate.** Preserve token class/path in the existing bounded lexical pass,
or perform an equivalent schema-aware lexical validation before generic parsing
erases it. Pin literal raw frames for every integer field, including all five
aliases above, safe/range boundaries, inappropriate negatives, and future
generations. Assert rejection occurs before pending lookup and without session
mutation. Do not infer safety from Scheme exactness or numerical equality.

### 3. Medium integration requirement — state and bounds require one serialized owner

**Expected.** Pending work never exceeds four, action sequences are unique and
monotonic, and a completed revocation cannot be followed by an action committed
from an earlier check.

**Actual in the Python reference under forced concurrent trusted callbacks.** A
barrier in the host ID-allocation call lets five `host_action` calls all pass the
pending check before any inserts. All five return, the pending count becomes
five, and every returned action carries sequence 5:

```python
barrier = threading.Barrier(MAX_PENDING_REQUESTS + 1)
def token(_):
    name = threading.current_thread().name
    barrier.wait()
    return name

with patch("book_session.secrets.token_urlsafe", side_effect=token):
    # Start and join five threads, each calling host_action on one session.
    ...
print(len(results), host.snapshot(connection).pending_requests,
      sorted(action["sequence"] for action in results))
```

Observed:

```text
returned 5 pending 5 sequences [5, 5, 5, 5, 5]
```

A second deterministic reentrancy probe revoked the session from the same
allocation hook after `_require_active()` but before insertion. The outer call
still returned an action and left `state=revoked, pending_requests=1`; its reply
was correctly rejected because the state was revoked.

The patched allocator is not an attacker primitive and exact built-in schema
types prevented peer-provided equality callbacks. This is therefore not a
peer-only exploit, and the README makes no event-loop claim. It does show that
the bounds are sequential rather than intrinsically concurrent, which matters
once KOReader callbacks, expiry timers, process death, and socket readiness can
interleave.

**Guile/integration gate.** Give every session one serialized transition lane,
or lock the whole validate/allocate/commit transaction. Do not yield or invoke a
callback between state/bound checks and commit. Allocate IDs before mutating the
sequence, then recheck lifecycle if allocation can yield. Exercise simultaneous
action, reply, expiry, navigation, revoke, close, and restart schedules; assert
unique sequences, at most four pending requests, no post-revoke action, and
only one terminal outcome per request.

There is no timer or clock in this reference: `expire_request` is a synchronous
trusted call, and the socket fixtures' one/two-second timeouts are test-harness
deadlock guards, not request deadlines. A real timer must capture the private
binding, session epoch, request ID, generation, and sequence; a stale callback
must become a no-op rather than canceling coincidentally reused successor work.

### 4. Low, fault-assumption clarification — bounded nonce checks do not prevent historical epoch reuse

Current-session collision handling is finite and fail-closed: `_new_opaque`
tries at most eight times. Forced equal request IDs in two live sessions did not
cross authority because connection and surface correlation remained decisive.
After a terminal ID aged out of the eight-entry history, forcing that ID again
also did not accept the old response because the monotonic sequence differed.

There are two lesser observations:

1. Exhausting all eight request-ID attempts raises `StateError` after the
   sequence has incremented. The next successful action jumps from sequence 1
   to 3. This does not violate the README's limited promise that **schema**
   rejects are atomic, but the Guile transaction should avoid this partial
   host-allocation mutation.
2. Restart retains only the immediately previous session's IDs while allocating
   its successor. A deterministic allocator was made to produce epoch 0, a
   different epoch 1, then epoch 0's surface and request tokens again in epoch
   2. Because generation and sequence also reset to 1, `epoch2_action ==
   epoch0_action`, and the exact old presentation was accepted as epoch 2's
   response:

```text
forced two-restart nonce reuse: old exact reply ACCEPTED
```

The second result requires repeated trusted CSPRNG outputs (both the 144-bit
surface token and 144-bit request token for an exact replay) or an allocator
fault. A peer cannot cause `secrets.token_urlsafe` to repeat, and this review
does not claim checkpoint/durability guarantees. It is therefore not a
practical wire break. It does qualify any absolute statement that old grants
can “never” revive: the implementation supplies a negligible-collision
probabilistic guarantee after older epochs leave memory.

**Port gate.** Use a reviewed host CSPRNG, fail closed and atomically on
allocation failure, never reuse a connection-binding object for a successor
endpoint, and include a fresh session epoch in correlation state. Either make
the probabilistic uniqueness assumption explicit or retain/derive enough epoch
identity that deterministic allocator tests cannot reproduce an old complete
request tuple.

### 5. Low contract ambiguity — empty text is rejected while every C0 scalar is accepted

The README explicitly calls the three opaque string fields nonempty, then gives
only maximum sizes for action and presentation text. The shared helper also
requires both text fields to be nonempty. Independently, every escaped C0 scalar
U+0000 through U+001F was accepted as a one-character presentation, including
NUL and ESC. This is valid scalar/JSON behavior and not an authority or path
injection—the schema has no markup, resource, filename, or host path—but the
future renderer/logging contract needs an explicit decision.

Observed:

```text
all 32 C0 text values accepted
empty presentation rejected with SchemaError
```

The exact UTF-8 byte limits worked: 512 emoji action scalars (2,048 bytes) and
1,024 emoji presentation scalars (4,096 bytes) passed; one extra action emoji
failed without creating pending work. Unknown field names containing escaped
NUL were rejected.

**Port/reader gate.** Specify whether empty text is legal. Specify whether C0
characters are literal surface data, normalized, or rejected, and make the
Guile and reader tests agree. If controls remain legal, the renderer must not
interpret them as markup/control protocol, and diagnostics must escape them.

## Independent positive and negative evidence

The supplied command used ambient Python 3.11.14 without a Guix build:

```sh
make -C pinenote/tools/book-session python-check
```

All **16** supplied `unittest` methods passed in 0.003 seconds. That confirms the
recorded method count, not the future Guile runtime.

Across the supplied suite and an additional bounded matrix, real socketpairs
were used where bytes/framing mattered and direct calls for trusted lifecycle
transitions. They established:

- the initialize message has exactly its seven documented fields and one
  host-generated surface; the ordinary Python grant envelope, surface grant,
  result, and snapshot values are frozen;
- equal diagnostic names do not compare equal or select another binding;
- a complete cross-session handle/request forgery fails on the correct source
  binding, including when request IDs are deliberately equal across sessions;
- self-asserted `owner`/`component`, missing/extra/path/markup fields, a hidden
  control-bearing field name, and peer `action`/`cancel` messages are rejected;
- schema/authority errors do not poison framing or consume pending work, while a
  duplicate JSON key is a framing error that poisons its decoder and requires a
  new stream;
- malformed correlation (action, handle, generation, sequence), a successful
  duplicate, cancel, expiry, navigation, revoke, close, and pre-hello restart
  all reject late responses; corrected retry succeeds only while still pending;
- a stale expiry callback naming a retired navigation request does not cancel a
  current request;
- sequential pending count stops at four; terminal retention contains exactly
  the newest eight request identities/reasons, while older identities become
  unknown rather than valid; no presentation text history is stored by the
  host;
- the registry stops at eight sessions, closed sessions still occupy their slot
  as documented, and explicit release permits a replacement; and
- present fields using exact built-in string/integer types do not invoke
  attacker-defined Python equality callbacks.

These results support carrying the schema, authority-correlation, retry,
bounded-history, and lifecycle semantics into Guile. Python frozen dataclasses,
`eq=False`, GIL behavior, and monkey-patched module details do not transfer as
implementation mechanisms. In particular, immutable authority in Guile must
live in private trusted registry state; merely returning a mutable JSON alist
with an opaque string is not a grant.

## Next integration gate

Before connecting the Guile session core to a sandbox or reader:

1. finish the Guile port, freeze exact hashes, and obtain a new independent
   source plus executable review rather than applying this Python verdict;
2. prove trusted endpoint-to-binding creation and identity dispatch with two
   real inherited sockets, deliberate label/token equality, swapped-routing
   fault injection, EOF/FD reuse, and restart;
3. enforce Guile lexical integers on raw wire vectors before any state lookup;
4. serialize all action/reply/timer/navigation/revoke/close/restart transitions
   and pin the concurrency counterexamples above;
5. reproduce the exact schema, immutable trusted grants, four/eight/eight
   bounds, atomic retry, consumed-request errors, and lifecycle matrix in Guile;
6. decide text empty/control semantics and add the future literal renderer as a
   separate untrusted-input boundary; and
7. only then add the nonblocking owner, deadlines, backpressure, descriptor
   teardown, and aggregate rate/work limits already excluded by both reference
   layers.

No hardware session is justified by this gate.

---

## Fresh independent Guile authority re-review — 2026-09-04

### Verdict

**The completed Guile implementation closes the Python review's lexical,
ordinary identity, atomic-allocation, and serialized-transition obligations for
its host-only reference scope. It is not yet safe to integrate by calling its
blocking endpoint API from the supervisor.** I found no raw-message bypass of
the four current lexical-integer fields, no way for peer JSON to choose an
endpoint identity, and no pending/history/registry bound failure while the
transition API was allowed to run.

Two new concrete findings gate integration:

1. an untrusted peer can stall `endpoint-read-and-dispatch!` while that function
   owns the endpoint transition mutex, preventing host cancel, expiry,
   navigation, revoke, or close; if restart/release waits for that endpoint, it
   also holds the host-wide registry mutex and blocks unrelated registration;
2. endpoint exclusivity and restart freshness compare Guile port objects with
   `eq?`, not underlying socket ownership. The same port object can be
   registered in a second host, a duplicated descriptor can be registered as a
   second endpoint in one host, and a dup of the old socket is accepted as a
   restart's “fresh” port, allowing the same peer connection to initialize the
   successor.

Finding 1 is directly peer-triggerable if this blocking fixture is integrated.
Finding 2 requires a trusted scheduler/supervisor ownership mistake; peer bytes
cannot create or register a Guile port. Neither finding undermines the utility
of the current bounded reference tests, and this review does not demand the
full asynchronous production transport now. They do mean that this exact
blocking API and its port-object uniqueness check cannot serve as the eventual
lifetime/ownership enforcement boundary.

This is a fresh review of Guile rather than an inference from the Python oracle.
No hostile `@@` reflection, private-record construction, or private-state
mutation is in the peer threat model. The private random-source parameter was
used only for bounded trusted fault injection.

### Exact Guile review snapshot

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-session/book-session.scm` | `bf5c5768e1995dae810edb23152b050a5de738ec9ec3601a40fd94caa8b2c3ba` |
| `pinenote/tools/book-session/test-book-session.scm` | `8495cf53a0d1ad307c3a4f029afc812d62f15a2dc3a7b5e280c23c33c60877de` |
| `pinenote/tools/book-session/README.md` | `9f1a3f8edf8261a8c98094a3fd836db9f3eaa6b48a9e65800ca703b069673ef5` |
| `pinenote/tools/book-session/Makefile` | `4b3bbdb31f7c3bd0b5373c9d6f2947db16fe8a7e570394b5a1cc37de20ea4c48` |
| Unchanged Python oracle `book_session.py` | `042482d071f39d96ba0cb7f74c91c395e7c01ce7685aaf038cc8a88172cd32e3` |
| Unchanged Python oracle tests `test_book_session.py` | `31ce005e7327a99a4522f7c047a1fc7888a60f6d87275e4d78a2e3dc28c25dbe` |
| Accepted generic Python codec `book_protocol.py` | `4e2423e09291d29758a6441d460eee2abfb82f24ed589f477ad62021c95ebe735` |
| Accepted generic Guile codec `book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| Accepted Guile blocking codec adapter `book-protocol/blocking-io.scm` | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| Generic codec `README.md` | `d75183d9f4574d2a38f9c08e70e2f514dcbab0b114c074ea5633ade45f026613` |
| `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |
| This report before this Guile section | `ff7808f64dbd676916c0aa88c814a9acb55cbd1e8af07d9bc2d051029c987d3e` |

The generic codec hashes exactly match their accepted reviews; they were not
modified by this session increment. The pinned shell resolved Guile 3.0.11,
Python 3.12.12, and `guile-gcrypt` 0.5.0. No partial or later Guile authority
file is covered by these hashes.

### Disposition of the five transferable Python findings

| Original finding | Guile disposition |
|---|---|
| 1. Authority source must be the actual endpoint | **Partially closed.** Peer dispatch accepts only a private `peer-message`, `endpoint-read-and-dispatch!` has no caller-supplied binding argument, and each pending request records an `eq?` binding identity. Correctly exclusive endpoints isolate all known tokens. Actual socket ownership is still not exclusive across port aliases/hosts; finding 2 below remains. |
| 2. Lexical integers must survive `guile-json` normalization | **Closed for the four version-1 fields on this hash.** Raw token evidence rejects decimal/exponent aliases before state dispatch, including escaped/reordered keys. Any new integer field reopens this obligation. |
| 3. Transitions must serialize and allocation must be atomic | **Closed for nonblocking core transitions.** Five simultaneous actions become four unique sequences plus one rejection; reply/expiry has one winner; cooperative same-thread reentry returns `busy`; entropy/collision errors leave state and the lock clean. Holding the same lock across blocking I/O creates the separate high finding below. |
| 4. Historical nonce reuse and allocation fault assumptions | **Accepted as explicitly documented, not made deterministic.** Libgcrypt strong randomness supplies 18-byte tokens, current IDs get eight bounded collision attempts, and request/restart allocation failure is atomic. Historical replay after an entire old tuple repeats remains a stated negligible-CSPRNG-collision assumption. |
| 5. Empty/C0 text semantics | **Closed as a version-1 decision.** Empty text is rejected; all valid C0 scalars are literal data; the README requires a future renderer not to treat them as control protocol and requires escaped diagnostics. Renderer behavior itself remains unimplemented. |

### 1. High integration blocker — blocking peer I/O owns the authority transition mutex

`endpoint-read-and-dispatch!` enters `with-endpoint-owner` before calling
`read-peer-message`. `read-exactly` then waits indefinitely for a four-byte
header or the declared payload. The endpoint mutex therefore covers not only
the atomic dispatch transition but an unbounded wait controlled by the peer.

**Expected for integrated lifetime enforcement.** A peer that sends no header,
sends a partial header/payload, or stops reading output cannot prevent trusted
cancel, expiry, revoke, close, or whole-domain shutdown. No global host lock is
held while waiting for that peer.

**Actual.** An independent socket fixture initialized an endpoint, started one
thread in `endpoint-read-and-dispatch!` with no further peer bytes, then started
another in `close-session!`. After 200 ms neither had returned. Closing the peer
port externally made the read observe EOF; only then did both calls complete:

```text
stalled peer read prevents close transition from completing: PASS
EOF releases lock and both blocked operations terminate: PASS
```

The same experiment then started `restart-session!`. Restart acquired the host
mutex and waited for the read-held endpoint mutex. A registration on an
unrelated fresh socket could no longer acquire the host mutex:

```text
read result       = pending
restart result    = pending
registration      = pending
```

After externally closing the stalled peer, all three threads drained. Source
lock ordering agrees with this observation: restart/release take host then
endpoint, while the blocking read already owns endpoint. There is no cyclic
deadlock once the peer closes, but a malicious peer need not close.

`endpoint-write-message!` similarly holds the transition mutex through
`put-bytevector` and `force-output`; a future generic or repeated-output path
can have the same issue when a peer stops reading.

**Threat distinction.** The stall itself is peer-controlled. Calling this
documented blocking fixture from a supervisor transition loop is the trusted
integration choice that would make it an exploit. The README accurately says
the function is only a compact blocking inherited-FD fixture, so this is not a
false claim that a completed nonblocking owner exists.

**Required integration shape.** Keep exactly one reader owner, but perform
read/framing work without holding the state-transition mutex. Acquire the mutex
only to atomically recheck endpoint identity/state and dispatch a fully decoded
private message. Close/revoke must invalidate the epoch before a late read can
commit. The supervisor also needs an out-of-band way to interrupt/close the
transport and terminate the execution domain; it cannot depend on
`close-session!` waiting behind that transport. Put blocking output behind a
bounded queue/writer rather than under the transition lock. Tests must cover a
silent peer, every partial-header/payload boundary, a peer that never reads,
concurrent close/restart, and no stale dispatch after unblocking.

### 2. Medium authority/API defect — port-object `eq?` does not establish exclusive socket ownership

`host-has-port?` compares only `(eq? port stored-port)` and searches only one
`<book-session-host>`'s endpoint list. This correctly rejects registering the
same Guile port object twice in one host. It does not identify the actual socket
connection or establish process-wide transfer of its ownership.

Three bounded independent cases reproduced the distinction:

1. The exact same open port object registered successfully in two separately
   created host registries.
2. `fdopen(dup(fileno(port)))` registered successfully as a second endpoint in
   the same host. Both port objects refer to the same socket endpoint.
3. A dup of an old endpoint's socket was accepted by `restart-session!` as the
   fresh replacement port. Closing the old port left the duplicate open, and
   the same pre-restart peer sent `hello` through the same connection and
   activated the replacement session.

Observed:

```text
same port object / second host       accepted
dup alias / same host                accepted
dup alias as restart fresh port      accepted
same old peer's successor hello      accepted
```

This does not let an untrusted peer manufacture a host descriptor or call the
registration procedures. It is a trusted supervisor error, but it defeats the
API's intended single-use/fresh-connection authority property and permits one
physical stream to be assigned two session identities. The existing test that
forces reuse of the old **numeric FD by a newly created socket** still passes
and is valuable: dispatch captures the port object and never reconstructs
identity from the integer. Numeric reuse and duplicated aliases are different
threats.

**Required integration shape.** Transfer one actual socket endpoint into one
supervisor-owned connection object exactly once. Do not expose a reusable raw
port registration path to unrelated trusted components, and do not accept an
arbitrary non-`eq?` port as proof of a fresh restart connection. A process-wide
ownership registry may cheaply reject the same port and known FD aliases, but
the stronger rule belongs at descriptor creation/donation: make no duplicate,
close every unused copy, and mint the session endpoint in the same operation.
Restart should consume a newly accepted/donated connection, not a caller's
claim that a port is fresh. Add same-port/different-host, `dup`, inherited-copy,
and restart-alias negative tests.

### Timer and I/O lifecycle prerequisites, not current-core defects

`expire-request!` remains a synchronous owner event. There is no timer, clock,
deadline, or callback scheduler, as the README says. The completed tests prove
that a callback retaining the **old endpoint object** cannot cross restart or
numeric FD reuse. They do not implement the proposed check over endpoint epoch,
request ID, generation, and sequence: the current expiry procedure accepts only
endpoint plus request ID. Before adding real timers, use an opaque pending lease
or extend the transition so all captured correlation fields are checked
atomically. Otherwise a faulty RNG plus terminal-history eviction could let a
very late timer cancel a coincidentally reused request ID.

Clean EOF and generic framing errors close authority and retire pending work.
Arbitrary local I/O exceptions and peer/output backpressure are not a proven
lifecycle path. The integrated owner must turn every terminal transport/process
outcome into one idempotent close transition and then reap the execution domain.
This review does not require those asynchronous mechanisms in the current
reference, but they remain blockers to treating it as lifetime enforcement.

### Independent evidence and non-findings

The exact pinned command, bounded by an outer 240-second watchdog, passed:

```text
125 Guile SRFI-64 assertions
16 unchanged Python unittest oracle methods
```

The forked supplied test exited normally. A post-run process-table check found
no Guile, Python, Guix, timeout, or make process associated with the Book
Session tests.

Together, the supplied suite and independent bounded socket/thread/fork probes
established:

- `version`, `surface_generation`, `sequence`, and `count` reject `true`,
  `1.0`, `1e0`, `-0.0`, and `0.99999999999999999` before mutation;
- escaped names for all four integer fields retain the right raw-token
  evidence; reordering does not matter; key-looking fragments inside escaped
  strings do not move the scanner; nested array/object values are schema
  rejects; and direct/escaped duplicate keys remain generic framing errors that
  close the endpoint;
- owner/unknown fields, wrong correlation, consumed replies, stale/future
  generations, cancel, synchronous expiry, navigation, revoke, close, restart,
  EOF, and framing failure have the documented state outcomes and do not leak
  the mutex after errors;
- two distinct captured sockets reject each other's complete presentations even
  when every token and diagnostic label is known;
- an uncaught same-thread reentrant revoke propagates `busy`, leaves the outer
  action uncommitted, releases the mutex, and permits the next ordinary action;
- entropy failure and all eight forced current-request collision attempts leave
  sequence/pending unchanged; the next distinct allocation uses the next
  sequence without a gap;
- forced restart allocation collision leaves the old endpoint active and usable
  and leaves the proposed new port open/unpublished;
- the terminal list retains exactly the newest eight completed request
  identities: replays of those eight report `completed`, while the four older
  identities are unknown rather than valid;
- eight closed endpoints retain exactly eight host registry slots until one is
  explicitly released; one release admits exactly one replacement; restart
  replaces rather than grows the host entry; and
- an independent `primitive-fork` fixture closed unused socket ends, completed
  an inherited-descriptor hello/initialize exchange under a five-second alarm,
  reaped the exact child with exit status 0, and left no residual process.

One temporary aggregate reviewer script executed and printed 28 successful
checks, then exited nonzero because an unexecuted trailing fork form in that
temporary script was missing a closing parenthesis. No child or temporary file
remained. The fork/history/restart-allocation portion was corrected and rerun as
a separate green script; no implementation or repository test was changed.
All required dependencies were already available to the pinned shell; no system
image build, VM, deployment, or hardware operation was performed.

No peer-wire counterexample was found for the current lexical evidence pass,
private `eq?` binding identity, immutable grant accessors, atomic schema retry,
ordinary mutex serialization, CSPRNG allocation ordering, generation
invalidation, or the stated sequential memory bounds. This is not evidence for
sandbox isolation, durability, rendering, aggregate rate/work limits, or the
future nonblocking supervisor.

### Next integration gate

1. Do not integrate `endpoint-read-and-dispatch!` or
   `endpoint-write-message!` as currently locked blocking operations. Add the
   nonblocking/supervised I/O owner and prove host close/revoke/termination wins
   against stalled input and output.
2. Make actual endpoint donation exclusive and restart connection freshness a
   supervisor fact, then reject the three port-alias reproductions above.
3. Add a timer lease/correlation API before automatic expiry; prove old callback,
   navigation, restart, request-ID collision, and terminal-eviction cases.
4. Retain the current raw lexical corpus, two-socket all-token tests,
   allocation/reentrancy races, exact 4/8/8 bounds, numerical-FD-reuse test, and
   fork cleanup as gates around the new owner.
5. Obtain a fresh independent integration review over exact supervisor/session
   hashes. The current Guile core need not wait for hardware, a renderer, or
   persistence work.

No hardware session is justified by these findings.

---

## Focused Guile transport and ownership re-review — 2026-09-04

### Verdict

**The new factory/nonblocking transport closes both integration defects from the
preceding Guile review for the module's supported public API, but this exact hash
still must not be integrated: a peer can make one input-pump call commit a valid
frame and then throw on a later bad frame, irretrievably hiding the already
committed result from the supervisor.** In particular, a valid `present`
followed by a schema-invalid frame left the request completed while the pump
returned only an exception; the next pump had no `<presented-text>` value to
recover. The same schedule can activate `hello` without delivering its
`initialize` value.

This is a new high integration blocker in batched result delivery, not an
authority escalation: the bad peer does not acquire another endpoint's grant or
make an invalid presentation commit. It can, however, make an accepted result
disappear and leave host and peer protocol progress irreconcilable. Fix that
before connecting the pump to a supervisor.

Subject to that finding, the focused transport claims held. Silent and partial
input no longer owns an authority or host mutex; a fully decoded message paused
outside the lock cannot commit after revoke; raw-port registration and
caller-selected restart ports are absent; restart creates a distinct connection
and shuts down old aliases; input/output work, buffers, and queues have the
stated per-call bounds; a close/write/readiness race did not cross numeric FD
reuse; both socketpair ends were actually close-on-exec; and disconnected output
became caught `EPIPE` rather than process-terminating `SIGPIPE`.

This review used the supported public API as the security boundary. Private
read-only socket access and the two documented no-op test hooks were used only
to observe an FD and force decoded/send scheduling points. No private record was
constructed or mutated, no private socket was registered, and no conclusion
depends on hostile `@@` access being available to a peer.

### Exact focused-review snapshot

Repository baseline remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The reviewed files remained
untracked, so the hashes identify the object under review:

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-session/book-session.scm` | `dca01ab93c44f024c6cdf8828f91a2a8165b758ea4c90f80d3c35b1db0b6cea0` |
| `pinenote/tools/book-session/test-book-session.scm` | `af93cdb7512aaaa562fbdb047f4be2a3c481d00c6984e9dd3dbf473dbad729df` |
| `pinenote/tools/book-session/README.md` | `b83cf7b5b88f08d0fe9a7821d84e8d45bba878c99fa8798db79298ce9eeed7ce` |
| `pinenote/tools/book-session/Makefile` | `4b3bbdb31f7c3bd0b5373c9d6f2947db16fe8a7e570394b5a1cc37de20ea4c48` |
| Unchanged Python oracle `book_session.py` | `042482d071f39d96ba0cb7f74c91c395e7c01ce7685aaf038cc8a88172cd32e3` |
| Unchanged Python oracle tests `test_book_session.py` | `31ce005e7327a99a4522f7c047a1fc7888a60f6d87275e4d78a2e3dc28c25dbe` |
| Accepted generic Python codec `book_protocol.py` | `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735` |
| Accepted generic Guile codec `book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| Accepted Guile blocking adapter `book-protocol/blocking-io.scm` | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| Generic codec `README.md` | `d75183d9f4574d2a38f9c08e70e2f514dcbab0b114c074ea5633ade45f026613` |
| `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |
| This report before this focused section | `84f251e17b3b597528b982680fd3ef960a2c4cfc53d80aac9c46fa119b3777b6` |

The generic codecs and unchanged Python oracle were not re-reviewed. The old
lexical mutation corpus was intentionally not rerun; the supplied baseline
retained it, while independent work targeted only the changed transport,
ownership, lifetime, and batching surfaces.

### Closed and open disposition

| Earlier obligation or finding | Focused disposition |
|---|---|
| Python finding 1: endpoint must be the authority source | **Closed for this module's public API.** `open-session-endpoint!` creates socket, private identity, session, and mutex together. Dispatch has no binding/FD argument. The future process supervisor still must donate only the intended peer end and close unused process-local copies; that supervisor does not exist here. |
| Python finding 2: lexical Guile integers | **Remains closed on this hash.** No relevant lexical/schema code changed and the 212-assertion supplied suite retained the raw cases. This focused pass did not infer that result from Python or rerun the old mutation matrix. |
| Python finding 3: serialized transitions and atomic allocation | **Remains closed for individual transitions.** The new I/O owners are separate, short claims; decoded commit reacquires the endpoint transition mutex and rechecks lifetime. The newly open batching defect concerns delivery of multiple committed transition results, not lock exclusion within one transition. |
| Python finding 4: historical nonce reuse | **Unchanged accepted assumption.** Historical full-tuple reuse remains negligible-CSPRNG-collision reasoning, not deterministic replay prevention. |
| Python finding 5: empty/C0 text | **Unchanged version-1 decision.** Empty text is rejected and C0 scalars are literal data. No renderer property was reviewed. |
| Prior Guile finding 1: blocking I/O under the transition/host mutex | **Closed.** Nonblocking receive/send/select occur outside authority and host mutexes. Partial input, paused decode, paused send, restart, close, and unrelated registration all made bounded progress in the focused schedules. |
| Prior Guile finding 2: same-port/cross-host, `dup`, and restart-alias registration | **Closed for the exported API.** There is no raw-port registration or authority-FD accessor, and open/restart accept no donor port. Restart factory creation plus `shutdown(SHUT_RDWR)` severs old peer aliases. A future process handoff is still outside this module and must not intentionally donate the peer end twice. |
| Timer lease/correlation before automatic expiry | **Open integration prerequisite.** `expire-request!` is still synchronous; no timer API atomically validates endpoint epoch, request ID, generation, and sequence. |
| Batched input result delivery | **New high blocker.** A later rejected frame can erase the return path for an earlier committed frame in the same pump call. |

### New high blocker — a later bad frame hides an earlier committed result

`endpoint-pump-input!` loops over up to four frames. For each complete payload
it removes the payload from the input buffer, decodes it, commits under
`dispatch-if-current!`, and accumulates the returned value only in the loop's
local `values` list. That list becomes an `endpoint-pump-result` only when the
call returns normally. A later `book-session-error` escapes the call directly;
a later `book-protocol-error` closes the endpoint and then escapes. Neither path
returns the accumulated values.

An independent real-socket reproduction initialized a session, created one
pending action, and wrote two frames in one operation: a valid presentation,
then a complete `present` whose lexical `count` was `1.0`. One pump read both.
The first frame committed and the second raised `book-session-error`:

```text
pump outcome                 book-session-error
session state                active
pending requests             0
retained terminal requests   1
next pump                    would-block, frames 0, values ()
```

The `<presented-text>` result from the first frame was never returned and could
not be requested again because its request was already terminal. A separate
case sent valid `hello` followed by a schema-invalid `hello`; it threw after
moving the session to `active`, and the committed `initialize` value was likewise
unrecoverable. A valid presentation followed by a generic zero-length frame
also committed the presentation, then closed and threw without returning it.

Ordering the frames the other way does not create this particular loss: a
schema-invalid frame followed by valid `hello` raised before mutation, retained
the valid follower in the bounded buffer, and the next pump returned
`initialize`. This confirms that the issue is partial commit plus exception
reporting, not stream poisoning by an ordinary schema reject.

**Required fix.** Every committed dispatch result must be observable exactly
once even when a later frame in the same input batch fails. Viable shapes include
returning after each committed frame, or returning a structured partial-success
result that carries both all committed values and the later error. Merely
catching and suppressing the later error would be insufficient. Specify the
same rule for terminal framing errors, and pin at least valid-hello/bad-follower,
valid-present/bad-follower, bad-first/valid-follower, and
valid-present/terminal-malformed-follower orderings.

### Closed transport findings and bounded behavior

Focused independent probes established the following on the exact hash:

- A two-byte partial frame made the input pump return immediately with
  `would-block`, two bytes read, and no dispatch. Restart then completed, an
  unrelated endpoint registered on the same host, and the old peer observed
  EOF. The previous peer-controlled endpoint/host mutex stall did not recur.
- A presentation paused after complete decode but before commit lost a race to
  `revoke-surface!`: the pump returned `stale`, zero committed frames, no values,
  and no post-revoke pending/result state. This directly checks the required
  lifetime recheck for a fully decoded waiting message.
- The public interface has no `register-session-endpoint!`, authority descriptor
  accessor, or donor-port parameter; both open and restart have required arity
  two. A duplicate of the returned old **peer** port observed shutdown across
  restart, while only the new factory peer could initialize the successor.
  Consequently the former same-port/cross-host and broker-`dup` registrations
  are not representable through the supported API. This does not claim that an
  unimplemented supervisor cannot mishandle pass-FD donation.
- A send paused outside locks raced with readiness polling, close, and creation
  of a fresh endpoint that reused the exact old numeric FD. The old endpoint
  stayed closed, readiness returned no old events, the late writer did not touch
  the fresh stream, and that stream yielded only its own queued message.
- Input completed exactly four frames in one call and left a fifth buffered for
  the next call. Output completed exactly four small frames, deferred the fifth,
  then drained it in FIFO order on the second call. There was no frame-count
  off-by-one at either boundary.
- Eight exact maximum-size outbound frames occupied exactly 524,320 bytes; a
  ninth was rejected as backpressure. Separately, eight approximately 60 KiB
  frames were segmented over bounded 4,096-byte pumps, completely drained to a
  concurrent reader, and decoded in exact FIFO order. No call exceeded four
  completed frames or 4,096 output bytes.
- A declared input length of 65,537 was rejected from its four-byte prefix and
  closed the endpoint without accumulating its body. A legal approximately
  60 KiB frame carrying an extraneous large `hello.text` was read only in
  at-most-4,096-byte calls and then rejected by the exact schema. The framing
  payload limit remains 65,536 bytes, the retained input buffer is finite, and
  accepted presentation text remains limited to 4,096 UTF-8 bytes. These are
  per-frame/per-call bounds, not aggregate rate or CPU scheduling guarantees.
- Both authority and peer descriptors reported `FD_CLOEXEC`. A real `/bin/sh`
  exec had neither original socket object (the check compared `/proc/self/fd`
  symlink targets as well as flags). This proves factory close-on-exec, not the
  policy or cleanup of a future intentional pass-FD donation.
- In a forked subprocess whose last peer copies were closed, queued output raised
  a catchable `system-error`/`EPIPE`, left that subprocess's endpoint closed,
  and exited 0 rather than dying from `SIGPIPE`. The parent reaped that exact
  child under an alarm watchdog.

The output queue bounds trusted host messages encoded through the generic codec;
it does not turn the queue API into a peer entry point. No raw peer message can
enqueue output directly.

### Test accounting and scope

One fresh independent invocation of the exact pinned baseline, under an outer
240-second watchdog, passed:

```text
212 Guile SRFI-64 assertions
16 unchanged Python unittest oracle methods
```

The implementer's separately reported reruns are not counted as independent
evidence here. Seven green temporary probe programs added exactly **29 focused
assertions** across batching order, partial input/restart/global-lock progress,
decoded/revoke lifetime, readiness/write/close/numeric-FD reuse, input/output
off-by-one boundaries, exact and segmented queue flushing, public API/old-peer
aliases, input memory bounds, real exec/CLOEXEC, and fork/EPIPE/SIGPIPE cleanup.
Every blocking/thread/fork probe had an external watchdog or internal alarm.

Two initial aggregate reviewer scripts exited nonzero after their substantive
checks because of reviewer-harness cleanup/composition mistakes: one supplied
the wrong arity to a trailing `call-with-values`, and one redundantly tried to
release an old endpoint after restart had already replaced its registry entry.
All affected assertions were rerun in the seven green programs counted above.
Neither failure was an implementation failure; neither left a child or file.

A final process-table and temporary-directory check found no matching Guile,
Python, Guix, make, shell, timeout, or reviewer process and no review directory.
Only this review document was edited. No implementation file, hardware,
deployment, VM, kernel/system build, or external network investigation was used.

No result here proves sandbox/process isolation, intentional descriptor-donation
policy, process reaping by a future supervisor, rendering, display settlement,
durability, persistence, aggregate fairness/rate control, or asynchronous
production transport behavior.

### Next integration gate

1. Fix and independently re-review batched result delivery so every committed
   value remains observable exactly once when any later frame in the same pump
   is rejected or terminally malformed.
2. Add the future timer lease API and atomically validate endpoint epoch,
   request ID, generation, and sequence before automatic expiry commits.
3. When a real supervisor exists, review its intentional pass-FD operation,
   closure of every unused parent/child copy, process termination/reaping, and
   mapping from pump outcomes to queued output. Factory `CLOEXEC` alone is not
   that integration proof.
4. Retain the new paused-decode, partial/restart/global-lock,
   poll/write/close/FD-reuse, malformed-ordering, exact pump-edge, queue-flush,
   exec, and subprocess cleanup cases as regression gates.

No hardware session is justified by this finding.

---

## Final focused batch-result delivery recheck — 2026-09-04

### Verdict

**Accept the Book Session authority and pump contract at the exact hashes below
for the scoped, untimed first supervised `hello` → host action → `present`
interaction.** The prior high batch-result blocker is closed. I found no
remaining defect in the changed one-commit input path or buffered-readiness
contract.

Every accepted input transition now returns its value before the pump examines
a trailing frame. A complete buffered follower—including a terminally invalid
four-byte header—remains visible as `input` readiness when the socket itself has
no unread bytes. The next pump handles that follower independently. Results are
neither hidden by a later error nor returned a second time, and close between
pumps invalidates buffered later work without changing the already returned
value.

This is deliberately a **scoped session-module acceptance**, not acceptance of
a production lifecycle or of an as-yet-unwritten supervisor. A timer lease is
required if and when automatic expiry is added; its absence does not block this
untimed first interaction. Intentional pass-FD donation, closure of inherited
parent/child copies, sandbox launch, process termination, and reaping remain a
separate review of the integrated supervisor.

### Exact accepted snapshot

Repository baseline remained
`50572d7796abdb0928969f4db8836fc5e30aeb58`. The reviewed Book Session files
were still untracked, so these hashes—not the baseline commit alone—identify the
accepted object:

| File | SHA-256 |
|---|---|
| `pinenote/tools/book-session/book-session.scm` | `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668` |
| `pinenote/tools/book-session/test-book-session.scm` | `dbd96cbc13fc601edb5d7db5b676cabd2dcf9ad7f832ce85ebdea93b93294aec` |
| `pinenote/tools/book-session/README.md` | `0574ab84bbc24eea49d9831f5ccdfa58c36dc90a1f812e8cc3cfd0ea71f2ba18` |
| `pinenote/tools/book-session/Makefile` | `4b3bbdb31f7c3bd0b5373c9d6f2947db16fe8a7e570394b5a1cc37de20ea4c48` |
| Unchanged Python oracle `book_session.py` | `042482d071f39d96ba0cb7f74c91c395e7c01ce7685aaf038cc8a88172cd32e3` |
| Unchanged Python oracle tests `test_book_session.py` | `31ce005e7327a99a4522f7c047a1fc7888a60f6d87275e4d78a2e3dc28c25dbe` |
| Accepted generic Python codec `book_protocol.py` | `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735` |
| Accepted generic Guile codec `book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| Accepted Guile blocking adapter `book-protocol/blocking-io.scm` | `543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd` |
| `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |
| This report before this final section | `076af84b15e44ad74faee2690b52be404df3322d444ab4893c93c366b995b983` |

The generic codecs, Python oracle, lexical-integer corpus, authority-isolation
matrix, allocation races, and previously closed transport/FD cases were not
freshly re-reviewed. They were exercised once through the accepted snapshot's
regression suite. Independent work was restricted to the changed result and
readiness behavior.

### Disposition of the final gate

| Gate | Final disposition |
|---|---|
| Later bad frame hides an earlier committed result | **Closed.** An input pump returns immediately after one committed transition. The follower remains buffered and is processed by a later pump. |
| Buffered follower is invisible after kernel readahead | **Closed.** Readiness checks the bounded internal buffer for a complete frame or an already-invalid header before relying on zero-timeout socket readiness. |
| Successful values can be repeated or replaced | **Closed.** Success/success returns one distinct request result per call in order; a third pump returns no value. Equal presentation text does not collapse request identity or sequence. |
| Close before the next buffered transition | **Closed.** The first returned value remains usable; close retires the still-pending follower and later input returns `closed` with no value. |
| Earlier blocking-I/O mutex and raw-port alias findings | **Remain closed on the regression snapshot.** No relevant regression appeared; their full independent reproductions were not repeated in this narrowly scoped pass. |
| Automatic timer correlation | **Required only when automatic timers are added.** It is not a blocker for an untimed first supervised action interaction. |
| Supervisor process/descriptor handoff | **Separate integrated-review gate.** This module still does not claim process launch, exclusive intentional donation, inherited-FD cleanup, sandboxing, termination, or reaping. |

### Source-path assessment

`endpoint-pump-input!` still reads at most 4,096 bytes, but
`max-input-frames-per-pump` is now one. Once `dispatch-if-current!` reports a
commit, the function immediately constructs a `committed` pump result containing
that one value. It cannot enter the loop again and encounter a trailing schema,
authority, or framing failure before returning the accepted value.

Any readahead after the first frame stays in `endpoint-input-buffer`.
`buffered-input-ready?` recognizes either a complete length-delimited frame or a
four-byte zero/oversized terminal header. `endpoint-ready-events` reports
`input` directly for that buffered work and omits the socket from its read
`select` set, so an empty kernel receive queue cannot suppress the next unit of
work. The ordinary endpoint-identity/lifetime recheck still occurs after the
readiness snapshot.

The output path was not converted to single-frame operation. It retains its
4,096-byte and four-completed-frame limits, which is safe because output pumping
does not accumulate authority-transition return values that a later frame can
erase.

### Independent ordering reproductions

One bounded local Guile probe used real factory-created socketpairs and checked
all requested orderings:

1. **Valid `hello` / bad schema.** The first pump read both frames, returned one
   `committed` `initialize`, and made the session active. Two consecutive
   readiness queries both reported buffered `input` without consuming it. The
   second pump raised the schema error; a third returned `would-block` with no
   repeated initialize.
2. **Valid `present` / bad schema.** The valid result returned first and moved
   the request from pending to terminal. The bad `count:1.0` follower remained
   ready, failed only on the next pump, and did not erase or repeat the accepted
   `<presented-text>`.
3. **Bad first / valid follower.** The first schema error left the session
   `awaiting-hello`; readiness exposed the buffered valid frame. The next pump
   committed exactly one initialize and the following pump returned no value.
4. **Valid `present` / terminal zero-length header.** The first pump's byte count
   equaled the complete two-frame write, proving the four-byte invalid follower
   had been consumed from the kernel into the private buffer. Readiness still
   reported `input`. The next pump raised `book-protocol-error` and closed the
   endpoint; the prior result remained readable and no later pump redelivered
   it.
5. **Success / success exact-once.** Two presentations deliberately carried the
   same text. Consecutive pumps returned the two distinct request IDs and
   sequences 1 then 2; pending became zero, terminal history became two, and a
   third pump returned `would-block` with no value. Equal result text did not
   cause a spurious repeat or replacement.
6. **Close before next call.** Two valid presentations were fully read ahead.
   The first result returned while the second request remained pending and
   ready. `close-session!` before the second pump retired that request; later
   input returned `closed`, while the already returned first value remained
   intact.
7. **Unchanged output boundary.** Five queued small messages completed as four
   then one across two pumps and decoded in exact FIFO order without duplicates.

In each valid-first readahead case, the first pump's byte count equaled the exact
combined write length. Thus the subsequent `input` readiness came from the
internal buffer rather than unread peer bytes. Repeated readiness checks and all
next-pump calls returned within the external watchdog; no buffered-readiness
deadlock was observed.

### Test accounting and scope

One fresh independent run of the accepted snapshot's pinned regression command,
under a 240-second outer watchdog, passed exactly:

```text
227 Guile SRFI-64 assertions
16 unchanged Python unittest oracle methods
```

The implementer's claimed five repeats are not counted as independent evidence.
The focused ordering probe passed exactly **25 additional assertions** under a
180-second outer watchdog. No probe failed or required correction in this pass.

A final process-table and temporary-directory check found no matching Guile,
Python, Guix, make, shell, timeout, or reviewer process and no temporary probe
directory. Only this review document was edited. No implementation edit,
hardware action, deployment, VM, kernel/system build, or external-network
investigation was performed.

This acceptance proves no sandbox, renderer, display-settled acknowledgement,
durability, persistence, automatic deadline, crash recovery, process lifecycle,
or asynchronous production scheduler property. It is sufficient to proceed
from the session-module gate to a separately reviewed untimed supervisor
integration; it is not a claim that the resulting demo is a full production
lifecycle.

No hardware session is justified by this recheck.
