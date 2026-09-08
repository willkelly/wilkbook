# Experimental Book Session contract

This directory is a host-only reference for the first Book Protocol message
schema: one supervised endpoint performs `hello`, receives one surface and one
host action, and returns one bounded plain-text presentation.

**Guile is the trusted authority implementation.** `book-session.scm` owns
endpoint identity, session state, capabilities, and transitions. Python is not
a production path: `book_session.py` and `test_book_session.py` remain unchanged
as the independently reviewed sequential contract oracle and language
comparison. A future Python book program is an untrusted peer of the Guile
authority, not an alternative broker.

This remains executable design evidence, not a generic framework or production
daemon. It has no reader, sandbox, persistent state, or shipping integration.

## Exact version 1 trace

The only peer-originated messages are `hello` and `present`. Unknown or missing
fields are errors, including self-asserted `owner` or `component` fields.
Ellipses below stand only for Guile-host-generated opaque strings.

```text
peer -> Guile  {"type":"hello","version":1}

Guile -> peer  {"type":"initialize","version":1,"grant_count":1,
                "surface_handle":"surface_...","surface_generation":1,
                "max_pending_requests":4,"max_present_text_bytes":4096}

trusted host-action!("submit-name", "Ada")
Guile -> peer  {"type":"action","request_id":"request_...",
                "action_id":"submit-name","surface_handle":"surface_...",
                "surface_generation":1,"sequence":1,"text":"Ada"}

peer -> Guile  {"type":"present","request_id":"request_...",
                "action_id":"submit-name","surface_handle":"surface_...",
                "surface_generation":1,"sequence":1,"count":1,
                "text":"Hello, Ada"}
Guile result   <presented-text value="Hello, Ada" ...>
```

`count` is exactly 1 because this experiment accepts one text item, not an
extensible command list. `text` is literal scalar data: the schema has no
markup, resource, filename, or host-path field. Version 1 preserves the Python
oracle's text decision: text must be nonempty, and valid JSON C0 scalars are
accepted literally. A future renderer must not interpret those scalars as
markup or control protocol, and diagnostics must escape them.

`action_id`, `request_id`, and `surface_handle` are nonempty strings of at most
96 UTF-8 bytes. Action input is at most 2,048 UTF-8 bytes and presented output
is at most 4,096 UTF-8 bytes.

## Raw lexical integer evidence

The accepted generic Guile framing codec intentionally defines generic numbers
by mathematical value. `guile-json` 4.7.3 can therefore normalize `1.0`, `1e0`,
`-0.0`, and `0.99999999999999999` to exact Scheme integers. Testing only
`(integer? value)` after decoding would violate this session schema.

The session read path resolves this without changing generic framing semantics:

1. `decode-payload` performs the reviewed frame payload, UTF-8, JSON grammar,
   duplicate-key, depth, and generic numeric validation.
2. The session checks the exact shallow message shape and permits only scalar
   values.
3. A bounded metadata pass follows the already-decoded `#:ordered #t` member
   order and records whether each numeric value's original token contained a
   decimal point or exponent. It does not validate JSON grammar or decode a
   second value. Escaped and reordered field names use the corresponding
   decoded key, so `"\u0076ersion":1.0` cannot bypass the check.
4. Only a private evidence record reaches state dispatch. There is no public
   `dispatch(binding, decoded-json)` entry point.

`version`, `surface_generation`, `sequence`, and `count` must have lexical JSON
integer tokens, exact Scheme integer values, JSON-safe magnitudes, and their
smaller field ranges. Raw socket tests reject booleans, decimals, exponents,
signed float zero, rounded aliases, negatives, unsafe/range boundaries, and
future generations before request lookup or mutation. A corrected frame on the
same valid framed stream can retry.

There is no **known** unresolved lexical-integer hole in the four current fields,
but that conclusion awaits the fresh Guile authority review. Any new integer
field must be added to both the exact schema and raw-evidence check in the same
change. The generic framing codec itself remains unchanged and does not claim
schema-aware lexical metadata.

## Endpoint-owned authority

`open-session-endpoint!` is the only creation path. The host factory creates a
`SOCK_CLOEXEC` Unix socketpair, makes its private end nonblocking, and mints the
private binding, `eq?` identity, session, and transition mutex in the same
operation. It returns the endpoint and the peer end to pass explicitly to a
sandbox. There is no public raw-port registration or internal-socket accessor.

The host socket and its numeric FD remain private. `endpoint-ready-events`
performs a zero-timeout readiness query without exposing either; callers retain
the endpoint object and then invoke its pumps. `endpoint-pump-input!` reads only
the captured nonblocking socket, and a completely decoded private message
acquires the transition mutex to recheck binding identity and lifetime before
dispatch. Two-socket tests use identical labels and reveal every token; A's
response on B's socket cannot reach A. Pending requests also retain their
private binding identity.

The input and output pumps handle `EAGAIN` and return a pump-result record. Each
call reads or writes at most 4,096 bytes. An input pump returns immediately after
its first committed authority transition; an output pump may complete up to four
frames. Separate short input/output owner flags reject concurrent same-direction
pumps without holding a mutex across `recv`, `send`, decoding hooks, or caller
work. Outbound frames enter an explicit eight-frame/524,320-byte queue before a
bounded output pump sends them. A peer that never reads reaches `would-block`;
it cannot turn a host transition into a blocking write. Linux `MSG_NOSIGNAL` is
used so disconnect becomes caught `EPIPE`, not process-terminating `SIGPIPE`.

The one-commit input rule makes every accepted `initialize` or
`<presented-text>` value observable exactly once before a later frame can fail.
Complete trailing data retained in the internal buffer is reported as input
readiness even when the kernel socket is empty. Its next pump independently
returns a schema/authority error, closes on a terminal framing error, or commits
the next valid transition. Errors are not suppressed and prior values are not
redelivered.

Close, revoke, clean EOF, framing failure, and terminal local I/O failure retire
authority idempotently. Close/revoke first invalidate state under the transition
mutex, then `shutdown(SHUT_RDWR)` and close outside it. Thus a silent or partial
peer cannot delay invalidation, and a decoded frame paused before commit becomes
`stale`. Shutdown also reaches accidental duplicated or inherited copies of the
old broker-side descriptor.

`restart-session!` accepts only the old endpoint and a diagnostic name. It
creates a new socketpair itself; callers cannot nominate a same port, `dup`, or
old-connection alias. New allocation completes before mutation, old authority
is invalidated before replacement publication, and the successor awaits
`hello`. Tests cover factory allocation failure, unrelated registration during
a paused decode, duplicated/inherited old descriptors, delayed callbacks, and
safe reuse of the old numeric FD by a genuinely new factory connection.

The pump is the initial supervisor-facing I/O owner, not an event framework.
The current bounded scheduler can probe readiness and call the pumps while
retaining the endpoint. A later event-loop adapter must stay inside this
ownership boundary rather than export/reconstruct the host FD. This module
intentionally does not add Fibers or define supervisor/process-reaping policy.

### Pinned Guile style references

The small ownership conventions were checked against sources resolved by this
repository's `channels.scm`: GNU Shepherd 1.0.9 and Guix 1.5.0-5.e343ff0 at
commit `e343ff040092cd3428f7d35423add6fdb2939f53`.

- Shepherd's daemon creates nonblocking/CLOEXEC sockets in
  `modules/shepherd/endpoints.scm` and waits through readiness operations in
  `modules/shepherd.scm`; `herd` in `modules/shepherd/scripts/herd.scm` is the
  separate blocking control client, not a daemon I/O model for this module.
- Guix's `guix/inferior.scm` creates a CLOEXEC socketpair and closes the unused
  end in each process. `guix/serialization.scm` uses `dynamic-wind` for
  unconditional port cleanup.

This implementation follows those explicit-record, owned-endpoint, and cleanup
patterns only. It neither imports Fibers nor infers security from precedent.

## Serialized transitions and allocation

Every endpoint has one mutex-protected transition lane. The lock covers the
whole validate/allocate/commit operation for peer replies, host actions,
synchronous expiry, navigation, revocation, close, and restart. Calls from
other threads serialize; same-thread cooperative reentry is rejected rather
than deadlocking. No user/peer equality callbacks run because decoded schema
values have built-in Guile types. Private test hooks pause CSPRNG allocation,
complete decoding, or a send attempt to reproduce hostile trusted schedules;
each runs either as the accepted reentrancy probe or with no mutex held.

Request IDs are allocated before the sequence or pending set changes. Tests
force entropy failure and show sequence 0/pending 0 remain unchanged, force a
same-thread revocation during allocation and receive `busy`, serialize five
simultaneous actions to four unique sequences plus one rejection, race reply
against synchronous expiry to exactly one terminal outcome, and serialize an
action against revocation without post-revoke pending work.

`expire-request!` is a synchronous owner event only. There is no timer, clock,
deadline, or cancellation scheduler. A future timer must capture the endpoint
identity/session epoch, request ID, generation, and sequence; this code makes no
claim about that unimplemented callback.

## Identifiers and explicit bounds

Guile generates 18-byte (144-bit) URL-safe tokens with `guile-gcrypt`'s
libgcrypt strong random source. It does not derive authority from environment
variables, labels, process IDs, clocks, or FD numbers. Current live and bounded
terminal IDs are checked for collision, with at most eight allocation attempts.

Historical uniqueness after old endpoints leave memory relies on negligible
CSPRNG collision probability. If a faulty random provider repeated an entire
old surface/request tuple in a later epoch, the wire cannot distinguish that
historical replay. This is a documented fault assumption, not a practical peer
break and not a reason to retain unbounded history. Endpoint identity and close
still prevent ordinary delayed callbacks or FD reuse from crossing epochs.

| State or work | Bound |
|---|---:|
| Registered endpoints | 8, until explicit release/restart |
| Live handles per active session | 1 |
| Pending requests per session | 4 |
| Retained terminal request reasons | 8, oldest evicted |
| Peer members inspected per message | 8 |
| Surface generation and action sequence | 1–1,000,000 |
| Presentation items | exactly 1 |
| Opaque ID/handle | 96 UTF-8 bytes |
| Action text / presentation text | 2,048 / 4,096 UTF-8 bytes |
| Input/output bytes per pump | 4,096 each |
| Committed input transitions per pump | 1 |
| Completed output frames per pump | 4 |
| Outbound queue | 8 frames / 524,320 bytes |

Exact shallow schemas keep session-layer work bounded after the framing codec's
64 KiB bound. The host stores no presentation history or text. Its only
completed-request memory is the eight-entry terminal list; older requests stay
unknown and rejected rather than becoming valid.

These bounds provide local per-call and queue backpressure, not aggregate
connection CPU/rate/deadline control. This reference also has no supervisor
process, sandbox, durable state, filesystem access, rendering adapter, crash
recovery, or automatic activation. A `<presented-text>` result is not a
display-settled or durable-write acknowledgement.

## Check

```sh
make -C pinenote/tools/book-session check
```

`check` uses the repository `channels.scm` pin with Guile, `guile-json`,
`guile-gcrypt`, and Python. It runs the Guile authority tests first, then the 16
unchanged Python oracle methods through `PYTHONPATH=../book-protocol`.
`guile-check` runs only authority tests; `python-check` and
`python-oracle-check` retain the reviewed ambient comparison command.

The recorded 2026-09-04 pinned run passed 227 Guile SRFI-64 assertions and all
16 unchanged Python `unittest` oracle methods.

The Guile SRFI-64 suite uses factory-created Unix socketpairs for all peer
dispatch. It exercises every partial header/payload boundary, silent input,
never-read output, `EAGAIN`, bounded pumps/queueing, disconnected output,
concurrent direction owners, close/restart during paused I/O work, and no stale
commit. Valid/error, error/valid, valid/terminal, success/success, and
close-between-pumps orderings pin exact-once result delivery. Fork tests cover
the complete inherited-peer strict trace and prove restart shutdown defeats a
retained inherited broker-side descriptor. Their ten-second alarm is a test
deadlock guard, not a protocol deadline.

The changed Guile authority requires another fresh independent review before
integrated use. No result here proves supervisor isolation/reaping, persistent
storage, KOReader integration, aggregate scheduling policy, or production
security.
