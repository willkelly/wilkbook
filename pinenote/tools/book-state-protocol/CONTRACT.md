# Persistent text protocol contract — version 1

Status: focused v2 correction candidate after the 2026-09-06 adversarial
review. It is not joined to Book Session, the durable backend, a guest, or
KOReader.

## Boundary

This protocol projects the existing `(book-state)` API onto the accepted Book
Protocol JSON frames. It stores one optional plain UTF-8 text value for the
trusted endpoint's `BookInstance`. It is not a generic JSON-RPC or key/value
protocol.

The trusted Guile authority creates an endpoint binding containing the exact
owner object, opaque backend grant record, grant handle, generation, and access.
Only the handle and generation cross the wire. A received handle is matched
against that one endpoint-retained binding; it does not select a namespace or
confer authority by itself. No message contains a book/revision/instance ID,
namespace, storage schema, database or filesystem path, SQL, host socket, or
arbitrary key.

All messages use the unchanged `(book-protocol)` four-byte length plus UTF-8
JSON-object frame. `encode-state-message` calls `encode-frame` and
`decode-state-frame` calls `decode-frame`; this module has no second binary or
JSON decoder. A post-decode scalar-token walk only preserves the accepted
Book Session rule that exact fields use lexical JSON integers, rejecting aliases
such as `1.0`, `1e0`, and booleans.

## Exact messages

Every object has exactly the listed fields. Unknown, missing, and duplicate
fields fail before state mutation. `protocol_version` is the lexical integer 1.
All other version/count fields are nonnegative lexical safe integers.

| Type | Direction | Exact fields after `type` | Meaning |
|---|---|---|---|
| `state-ready` | authority → book | `protocol_version`, `grant_handle`, `grant_generation`, `access` | Announces this endpoint's `read-only` or `read-write` short-lived grant. |
| `state-read` | book → authority | `protocol_version`, `grant_handle`, `grant_generation` | Reads the one value. There is no read ID because exactly one operation may be pending and backend reads are synchronous. |
| `state-value` | authority → book | `protocol_version`, `present`, `state_version`, `text` | Returns the current snapshot. |
| `state-commit` | book → authority | `protocol_version`, `grant_handle`, `grant_generation`, `operation_id`, `expected_state_version`, `text` | Requests one backend CAS commit. |
| `state-committed` | authority → book | `protocol_version`, `operation_id`, `state_version`, `text_bytes` | Returns a durable backend receipt, including an exact retry's original receipt. |
| `state-conflict` | authority → book | `protocol_version`, `operation_id`, `current_state_version` | A new operation had a stale expected version; no write occurred. |
| `state-commit-failed` | authority → book | `protocol_version`, `operation_id`, `code` | Bounded recoverable/final storage failure. Codes are `receipt-quota-exhausted`, `read-only`, or `storage-failure`. |

`grant_handle` is nonempty and at most 128 UTF-8 bytes. `operation_id` matches
exactly `[A-Za-z0-9_-]{1,128}`. The SQLite-free
`(book-state-operation-id)` module exports that wire/client predicate; focused
trusted-host tests compare it exhaustively with the backend's independently
exported predicate. `text` may be empty and is at most 4096 UTF-8 bytes.

Absent state is exactly `present=false, state_version=0, text=""`. Present
empty text is `present=true, state_version>=1, text=""`; it is not absence.

## Authority state machine

The Scheme model has exactly these phases:

| Current phase | Event | Next phase | Result |
|---|---|---|---|
| `ready` | matching `state-read` | `read-pending` | one typed backend read operation |
| `clean` | matching `state-read` | `read-pending` | one typed backend read operation |
| `edit-dirty` | matching `state-read` | `read-pending` | one read; submitted draft is retained |
| `clean` or `edit-dirty` | new matching `state-commit` | `edit-dirty` | stage the submitted draft; no backend call yet |
| `edit-dirty` with staged commit | dispatch | `commit-pending` | one typed backend commit operation |
| `read-pending` | exact operation's absent/value result | `clean`, or `edit-dirty` when refreshing a conflict | `state-value` |
| `commit-pending` | exact durable receipt | `commit-ack` | `state-committed` |
| `commit-ack` | acknowledgement queued/sent | `clean` | no storage or presentation event |
| `commit-pending` | `stale-version` | `edit-dirty` | `state-conflict`; draft retained, no overwrite |
| `commit-pending` | receipt quota or read-only rejection | `edit-dirty` | `state-commit-failed`; draft retained |
| `commit-pending` | storage failure | `closing` | final `state-commit-failed` may be queued |
| any nonclosing phase | close, EOF, or revocation | `closing` | pending operation invalidated; binding locally revoked |

There is at most one staged or backend operation. `read-pending` and
`commit-pending` reject all additional operations. A backend result must carry
the exact `eq?` operation record emitted by this model. A completion after EOF,
revocation, close, or replacement is rejected and cannot mutate state.

A read result may advance the known version or repeat the exact known snapshot.
It cannot lower the known version or change presence/text at the same version.
An impossible result closes the binding, clears pending/draft state, and leaves
the known snapshot untouched. A stale rejection becomes `state-conflict` only
when its current version is at least the known version and differs from the
operation's expected version. Current may legitimately be below a peer-supplied
future expected version.

The model contains no worker, queue, mutex, or I/O. Its eventual Guile caller
must serialize model transitions as part of the one endpoint authority while
leaving the accepted Book Session mutex unlocked during synchronous storage I/O.

`edit-dirty` records only a submitted persistence draft needed for CAS retry,
conflict, and quota handling. It does not mirror keystrokes, dialog focus,
presentation, paint, navigation, or other KOReader UI state.

## Backend adapter

The next trusted adapter should map the typed operations directly, without a
new port or broker:

```text
<state-read-operation>
  -> read-book-state STORE OWNER BACKEND-GRANT GRANT-GENERATION

<state-commit-operation>
  -> commit-book-state! STORE OWNER BACKEND-GRANT GRANT-GENERATION
                        OPERATION-ID EXPECTED-STATE-VERSION TEXT
```

The operation carries OWNER and BACKEND-GRANT from the endpoint binding, never
from JSON. Map `<book-state-absent>`/`<book-state-value>` to
`make-state-read-result`, `<book-state-receipt>` to
`make-state-commit-receipt`, and `<book-state-rejection>` to
`make-state-backend-rejection`. The adapter must verify the receipt's operation
ID, expected version, resulting version, and text byte count against the exact
pending operation before applying it.

Do not hold the accepted Book Session transition mutex across either synchronous
backend call. The backend rechecks owner, grant identity, generation, access,
and revocation under its own mutex. On close/EOF, the authority must invoke the
backend's owner-checked revocation; this model's local `closing` transition is
not a substitute for durable-backend grant revocation.

An exact retry of a successfully committed operation, with the same operation
ID, expected version, and text, returns the backend's persisted original receipt
even after restart or later commits. The model returns an immediately cached
receipt when available and never rolls a newer local snapshot backward when an
old receipt is replayed. Exact retries of rejected operations reproduce their
cached conflict/failure while the session survives. The same operation ID with
changed expected version or text is a protocol/backend identity violation:
close the grant and write nothing.

## Save acknowledgement is not paint acknowledgement

`state-committed` can be constructed by the authority model only after applying
a typed backend receipt. It says that storage committed (or returned the exact
persisted receipt); it does not say that KOReader displayed anything.

A later adapter may separately turn that receipt into a Book Session
presentation and then wait for the private Lua `applied` paint event. Those are
three distinct facts:

1. backend durable receipt;
2. book/authority protocol `state-committed` and optional presentation; and
3. inherited `paintTo` observation followed by Lua `applied`.

No type in this protocol aliases those facts.

## Error policy

| Error/event | Wire outcome | Model outcome | Storage outcome |
|---|---|---|---|
| Unknown/duplicate/missing field, wrong direction, nonlexical integer, invalid bound | none | current phase unchanged | backend not called |
| Wire handle or generation differs from endpoint binding | none | `closing`, local binding revoked | adapter must revoke retained backend grant |
| Another operation while one is staged/pending | none | current pending phase unchanged | no second backend call |
| New commit has stale expected version | `state-conflict` with current version | `edit-dirty`, draft retained | no write |
| Same operation ID and exact payload after success | original `state-committed` receipt | `commit-ack`; a newer local snapshot is not rolled back | no repeated write |
| Same operation ID with changed expected version or text | none | `closing` | `operation-conflict`, no write |
| Receipt quota exhausted | `state-commit-failed` | `edit-dirty`, draft retained | no write |
| Read-only commit | `state-commit-failed` if reached through backend; model normally rejects before dispatch | clean/dirty state retained | no write |
| Storage failure | final `state-commit-failed` when a commit was pending | `closing` | transaction rolled back or no acknowledgement |
| Owner/grant/generation/revocation failure, impossible post-schema validation failure, invalid receipt | none | `closing` | no accepted write/ack |
| EOF/revocation/close followed by a late wire message or backend result | none | remains `closing` | result cannot mutate model |

A read may refresh the baseline after stale conflict while retaining the
submitted draft; a reconciled commit needs a new operation ID. A closed or
revoked binding cannot be reused. Reopen requires a newly issued backend grant
and endpoint binding; the durable namespace remains a trusted host choice.

## Focused v2 recheck before touching accepted cores

The seven message shapes, omitted read ID, endpoint authority, finite FSM, join
seam, and separation of storage/presentation/paint were accepted. The focused
v2 source recheck is limited to monotonic read completion, consistent stale
metadata, and the closed operation-ID grammar.

No accepted codec, Book Session, UI/private-control source, guest adapter,
outer runner, graph checker, package, or system source should change before
those points are reviewed.
