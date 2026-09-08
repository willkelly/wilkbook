# Book computer protocol and state reference

**Status:** current reference for accepted bootstrap contracts, blocked gates,
and explicitly labelled candidates, as observed 2026-09-06. It is not a shipping
specification, hardware-acceptance record, or replacement for the exact source
and frozen review packets.

This page answers the cross-cutting questions that were previously scattered:
which process is trusted, which channel carries which messages, who owns an
identity, what each state machine can do, what an acknowledgement means, and
which generations must never be conflated.

## Start here

| Question | Document |
|---|---|
| Product model, trust architecture, and self-hosting goal | [Toward a Self-Hosting Book Computer](wilkbook-self-hosting-book-computer.md) |
| Protocols, state machines, bounds, and current evidence | **This page** |
| Chronological implementation and failed-predecessor record | [Offline implementation lane](book-computer-implementation.md) |
| Accepted fixed-book QEMU/KOReader result | [Book computer demonstration](book-computer-demo.md) |
| Pinned KOReader seams and private reader boundary | [KOReader integration spike](book-computer-reader-spike.md) |
| gVisor/OCI/QEMU investigation and counterexamples | [Execution spike](book-computer-execution-spike.md) |
| Physical-device truth | [`status.md`](status.md) |

The exact executable contracts remain in `pinenote/tools/book-*/`. Review
reports under `doc/reviews/` preserve the failed inputs and identify accepted or
blocked source hashes. When this page and an exact reviewed source disagree, the
source and its final independent review disposition win.

### Status words used here

- **Accepted** — independently reviewed for the stated, narrow evidence
  boundary at an exact source identity. It does not mean shipped.
- **Candidate** — implemented and possibly locally exercised, but not covered
  by a final independent acceptance disposition.
- **Blocked** — final independent review found a gate that prevents acceptance
  at the claimed boundary. The same review may still preserve narrower observed
  behavior; that does not make the blocked packet accepted.
- **Active** — a mutable candidate or review in progress. Its observed behavior
  is not frozen by this page.
- **Historical** — a dated result or failed predecessor retained as evidence;
  later work may supersede its conclusion without rewriting it.
- **Unimplemented** — architecture or required integration work for which no
  current executable join exists.

## 1. Trust, processes, and identity

### 1.1 Role split

| Participant | Role | Trust status |
|---|---|---|
| Guile authority | Endpoint creation, capability binding, protocol/FSM transitions, SQLite state, OCI construction, supervision | Trusted host |
| KOReader Lua bridge | Widget lifetime, input callback, bounded private channel, final presentation/paint observation | Trusted presentation host |
| Guile or Python book | Book-defined computation behind one donated Book Session endpoint | Sandboxed in the accepted QEMU demo; trusted-native only in host fixtures |
| Python test code | Independent codec, lifecycle, and SQLite oracle | Test-only; never the production broker or supervisor |
| gVisor Sentry/Gofer and host kernel | Execution containment below the broker boundary | Part of the security boundary, not a capability authority |

Guix supplies immutable software closures. It does not grant a book access to a
document, state namespace, surface, network, or host path. gVisor contains book
execution; it does not decide whether a requested book operation is authorized.

### 1.2 Four things that must remain distinct

1. **Endpoint identity** is a fresh private Guile object created with the
   authority side of a socketpair. It never crosses JSON. This is the caller
   identity used by Book Session.
2. **Capability binding** is trusted endpoint-retained state: owner object,
   target/grant record, handle, generation, access, and lifetime. A wire handle
   is only a correlation value checked against that binding.
3. **Book identity** (`BookRevision`, `BookInstance`, component, or namespace)
   is selected by trusted host construction. The accepted state protocol has no
   book, revision, instance, namespace, database, SQL, or path selector.
4. **Diagnostic identity** (labels, PIDs, FD numbers, process names) helps
   observe or reap work. It is not authority. Numeric FD reuse and a copied
   label do not recreate an endpoint.

Possessing another endpoint's complete handle and request tuple is insufficient:
ordinary presentation also has to arrive through the exact endpoint binding.
Similarly, a state handle copied to another endpoint does not select the first
endpoint's retained backend grant.

## 2. Channel map

| Boundary | Encoding and carriage | Current purpose | Status |
|---|---|---|---|
| Book ↔ Guile authority | 4-byte big-endian length + UTF-8 JSON object over a dedicated Unix stream | Ordinary session and typed persistent state | Accepted codecs and ordinary session; optional state-enabled successor accepted as source, not installed in the live core |
| Guile authority ↔ KOReader Lua, original interaction | `kind|generation|lowercase-hex-UTF8\n` over one private full-duplex FD | Fixed dialog input, lifecycle, and result painting | Accepted private fixture channel; not Book Protocol |
| Guile authority ↔ KOReader Lua, persistent-note successor | Same framing family, different closed vocabulary | Load/edit/save/failure/saved UI FSM | Accepted offline native-UI fixture with an in-memory authority; not Book Protocol or durable storage evidence |
| Host KOReader ↔ AArch64 authority in the accepted demo | Private FD 3 on KOReader side, QEMU socket chardev, named virtio-serial port | Carries the private UI channel through QEMU | Accepted for the fixed four-result demonstration |
| Authority ↔ sandboxed fixed book in the accepted demo | One Book Session Unix socket donated as guest FD 3 with `run --pass-fd=3:3` | `hello`/`initialize`/`action`/`present` | Accepted for the fixed Guile and Python books |
| Child stdout/stderr | Separate bounded files or captures | Diagnostics only | Never protocol, identity, result, or receipt authority |
| QEMU console | Bounded assertion/evidence channel | Boot, cleanup, and fixed test verdicts | Never a general book or reader protocol |

Neither accepted channel carries framebuffer bytes, page images, arbitrary
raster commands, host paths, SQLite, or launcher control. The accepted
presentation payload is one bounded plain-text value. Rich structured surfaces,
custom display lists, resources, workspace operations, and a general object RPC
remain unimplemented.

## 3. Book Protocol framing

The accepted Guile and Python codecs define each frame as:

```text
4-byte unsigned big-endian payload length
exactly LENGTH bytes of one UTF-8 JSON object
```

| Property | Rule |
|---|---|
| Payload size | 1 through 65,536 bytes; length counts bytes, not characters |
| Top level | JSON object only |
| Container depth | At most 16, including the top-level object |
| Object keys | Strings; duplicates rejected at every depth after escape decoding |
| Unicode | Strict UTF-8 and Unicode scalar values; valid escaped surrogate pairs accepted, lone/reversed surrogates rejected |
| Integers | Generic codec accepts only the interoperable safe range `-(2^53-1)..2^53-1`; identity-bearing schemas additionally require lexical integer tokens |
| Fractions | Finite binary64 values only; not valid for identifiers, generations, sequences, counts, or exact amounts |
| Exponents | Decimal exponent magnitude at most 1,000; nonzero binary64 overflow/underflow rejected |
| Error lifetime | Framing/UTF-8/JSON/value-policy errors poison that decoder/stream; no resynchronization |
| Encoding | Compact but deliberately noncanonical JSON |

Opaque IDs and handles are strings. `1`, `1.0`, `1e0`, booleans, signed float
zero, and rounded numeric aliases are not interchangeable in an exact-integer
schema. Raw frame bytes are not a signing form, idempotency key, capability, or
revision identity. Parsing latency and aggregate per-connection CPU/rate limits
have not been measured or implemented by the codec.

JSON is the retained encoding decision. There is no wire-format replacement in
progress. The architecture is modeled through exact messages and transitions,
not through a permissive JSON-RPC method namespace.

Accepted codec source identities are:

- Guile: `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44`;
- Python: `4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735`.

## 4. Ordinary Book Session version 1

### 4.1 Exact wire messages

Every object has exactly the listed fields. Unknown, missing, duplicate, and
wrong-direction fields reject. The peer cannot send `owner`, `component`, or a
capability selector.

| Type | Direction | Exact fields after `type` | Meaning |
|---|---|---|---|
| `hello` | book → authority | `version` | Starts a fresh endpoint; `version` is lexical integer `1` |
| `initialize` | authority → book | `version`, `grant_count`, `surface_handle`, `surface_generation`, `max_pending_requests`, `max_present_text_bytes` | Announces one surface grant and fixed bounds |
| `action` | authority → book | `request_id`, `action_id`, `surface_handle`, `surface_generation`, `sequence`, `text` | Delivers a trusted host action to the book |
| `present` | book → authority | `request_id`, `action_id`, `surface_handle`, `surface_generation`, `sequence`, `count`, `text` | Returns exactly one plain-text presentation for a pending action |
| `cancel` | authority → book | `request_id` | Synchronously retires one pending request |

`initialize` fixes `version=1`, `grant_count=1`, `surface_generation=1`,
`max_pending_requests=4`, and `max_present_text_bytes=4096`. `present.count` is
lexical integer `1`. Action input is at most 2,048 UTF-8 bytes; presentation
text is nonempty and at most 4,096 UTF-8 bytes. Valid C0 scalars are literal
text at this boundary, not markup or private control messages.

### 4.2 Session and request transitions

```text
factory creates fresh endpoint
    awaiting-hello
        -- matching hello/version 1 --> active + initialize

active
    -- host-action! -------------> pending request + action
    -- exact present ------------> request completed + presented-text
    -- cancel-request! ----------> request cancelled + cancel
    -- expire-request! ----------> request expired (synchronous host event)
    -- navigate! ----------------> all pending navigation-retired;
                                    surface generation increments
    -- revoke-surface! ----------> revoked; transport shut down
    -- close/EOF/terminal I/O ---> closed; transport shut down

restart-session!
    creates a new socketpair/endpoint in awaiting-hello,
    invalidates and shuts down the old endpoint before publishing replacement
```

A `present` matches request ID, action ID, surface handle, surface generation,
sequence, and the exact private endpoint-binding identity. A stale, future,
cancelled, expired, navigated, revoked, closed, completed, or unknown result
cannot become a presentation. Navigation does not create a new book revision or
state version; it only invalidates the prior surface layout lifetime.

The accepted core permits four simultaneous pending surface actions and retains
only the newest eight terminal request reasons. By contrast, the state protocol
below permits only one staged or backend operation. Do not infer state
pipelining from the ordinary presentation bound.

Input and output I/O occur outside the authority transition mutex. Each pump
handles at most 4,096 bytes; input commits at most one transition, and output
completes at most four frames. The output queue holds at most eight frames and
524,320 bytes. `expire-request!` is synchronous; there is no automatic timer,
deadline scheduler, or accepted timer-lease API.

### 4.3 Accepted versus optional core

- Accepted ordinary live source: `book-session.scm` SHA-256
  `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668`.
- Accepted optional state-enabled successor core: SHA-256
  `f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301`.
- Accepted state delegate: SHA-256
  `eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6`.

The successor core/delegate pair is independently accepted source, not a
replacement already installed at `pinenote/tools/book-session/book-session.scm`
and not a shipping daemon.

## 5. Persistent Book State protocol version 1

### 5.1 Exact wire messages

The accepted typed model uses the unchanged Book Protocol frame. Every message
has lexical integer `protocol_version=1`.

Accepted source identities are:

- typed state protocol:
  `425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257`;
- backend adapter:
  `349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769`.

| Type | Direction | Exact fields after `type` | Meaning |
|---|---|---|---|
| `state-ready` | authority → book | `protocol_version`, `grant_handle`, `grant_generation`, `access` | Announces the endpoint's `read-only` or `read-write` grant |
| `state-read` | book → authority | `protocol_version`, `grant_handle`, `grant_generation` | Requests the one value |
| `state-value` | authority → book | `protocol_version`, `present`, `state_version`, `text` | Returns the current snapshot |
| `state-commit` | book → authority | `protocol_version`, `grant_handle`, `grant_generation`, `operation_id`, `expected_state_version`, `text` | Requests one compare-and-swap commit |
| `state-committed` | authority → book | `protocol_version`, `operation_id`, `state_version`, `text_bytes` | Returns a typed durable receipt, including exact retry |
| `state-conflict` | authority → book | `protocol_version`, `operation_id`, `current_state_version` | Reports a stale new operation; no write occurred |
| `state-commit-failed` | authority → book | `protocol_version`, `operation_id`, `code` | Reports `receipt-quota-exhausted`, `read-only`, or `storage-failure` |

There is no read ID because this finite connection-local model allows exactly
one pending operation and applies only the exact in-memory typed operation
record returned to the worker. Adding concurrency, detached completion, or
cross-connection continuation would reopen that decision.

`grant_handle` is nonempty and at most 128 UTF-8 bytes. `operation_id` is
exactly `[A-Za-z0-9_-]{1,128}`. Text may be empty and is at most 4,096 UTF-8
bytes. Absent state is exactly `present=false`, version `0`, text `""`;
present-empty state is `present=true`, version at least `1`, text `""`.

### 5.2 Typed state FSM

| Current phase | Event | Next phase | Output/effect |
|---|---|---|---|
| `ready`, `clean`, or `edit-dirty` | matching `state-read` | `read-pending` | one typed backend read; dirty draft retained when applicable |
| `clean` or `edit-dirty` | new matching `state-commit` | `edit-dirty` | stage copied draft; no backend call yet |
| `edit-dirty` with staged commit | trusted dispatch | `commit-pending` | one typed backend commit |
| `read-pending` | exact consistent absent/value result | `clean`, or `edit-dirty` after conflict refresh | `state-value` |
| `commit-pending` | exact valid receipt | `commit-ack` | `state-committed` |
| `commit-ack` | acknowledgement queued/sent | `clean` | no presentation implied |
| `commit-pending` | valid `stale-version` | `edit-dirty` | `state-conflict`; draft retained |
| `commit-pending` | receipt quota/read-only | `edit-dirty` | `state-commit-failed`; draft retained |
| `commit-pending` | storage failure | `closing` | final `state-commit-failed` may be queued |
| any nonclosing phase | EOF, close, revocation, identity/result inconsistency | `closing` | pending/draft cleared as specified; binding revoked |

Reads cannot lower a known version or change presence/text at the same version.
A stale conflict is valid only when current version is at least the known
version and differs from the operation's expected version. An exact old receipt
does not roll a newer local snapshot backward. Reusing an operation ID with
changed expected version or text closes the binding and writes nothing.

### 5.3 Session/delegate ordering

For a state-enabled endpoint:

1. the ordinary `hello` transition queues `initialize`;
2. the trusted owner then queues `state-ready`;
3. no state operation is accepted before that announcement;
4. one delegate worker owns one task slot;
5. typed FSM transitions occur under the endpoint mutex, but backend I/O does
   not;
6. completion rechecks endpoint, delegate, operation, binding, and generation;
7. close first invalidates/detaches locally, then revokes the backend grant and
   joins the worker outside the endpoint mutex.

The accepted successor reserves 24,681 bytes for the worst valid framed worker
response: 4-byte frame prefix + 101 fixed JSON bytes + sixfold escaping of a
4,096-byte state value. A valid 4,096-NUL value produces a 24,666-byte frame.
Any completion/encoding/queue exception fail-closes the endpoint rather than
leaving an active endpoint with a dead worker. This corrects the historical
5,120-byte BSD-1 predecessor; that predecessor's failure remains valid evidence.

## 6. SQLite state semantics and quotas

The accepted backend owns one optional plain-text value per trusted
`BookInstance` namespace. The host chooses the root, book revision, and instance
identity and retains the namespace/grant records. A sandbox sees no database
path or SQLite handle. Accepted backend source identity is
`7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9`.

### 6.1 Commit and retry rules

Within one `BEGIN IMMEDIATE` transaction, existing-operation lookup precedes
CAS and quota checks:

1. exact same operation ID + expected version + text returns its original
   persisted receipt, even after restart or later commits;
2. same operation ID with changed expected version or text returns
   `operation-conflict` and writes nothing;
3. a new operation with a stale expected version returns `stale-version` and
   writes nothing;
4. a new matching operation writes value and receipt atomically, increments the
   version by one, and returns only after SQLite `COMMIT` succeeds.

The backend uses SQLite rollback journal `DELETE` mode,
`synchronous=FULL`, and bound SQL values. It validates the exact schema-1
manifest at open and at the start of every write transaction. No migration or
repair exists. Process death before commit leaves no acknowledged write; death
after commit but before acknowledgement is recovered by exact operation retry.
This is host-filesystem process-crash evidence, not physical power-loss,
ext4/device-cache, QEMU, or PineNote durability.

### 6.2 Fixed schema-1 quotas

| Resource | Limit |
|---|---:|
| Text per value | 4,096 UTF-8 bytes |
| Operation ID | 128 ASCII bytes in the closed grammar |
| Trusted revision / instance identity | 256 bytes each |
| Namespaces per database | 32 |
| Simultaneous live grants per worker | 32 |
| Grant generation | 1..1,000,000 |
| Durable receipts per namespace | 64, never evicted |
| SQLite page size / maximum pages | 4,096 bytes / 4,096 pages (16 MiB) |
| Concurrent backend operations | 1, under the backend mutex |

Because receipts are never evicted, schema 1 admits at most 64 new commits per
namespace. At capacity, exact retries still work and stale CAS still reports
stale; a new current-version operation fails `receipt-quota-exhausted` until a
future explicit migration/archive design exists.

## 7. Save, presentation, and paint acknowledgements

These are distinct facts and must not be collapsed into a single “saved” or
“done” event:

```text
private UI submit
  -> trusted host-action!
  -> fixed book receives action
  -> book sends state-commit
  -> typed adapter/backend returns durable receipt
  -> book receives state-committed
  -> book may separately send present
  -> authority may send private UI present
  -> inherited InputDialog:paintTo is observed
  -> Lua sends applied
```

| Observation | What it means | What it does not mean |
|---|---|---|
| Backend `<book-state-receipt>` | SQLite commit completed or exact persisted receipt was recovered | Book received it; UI painted it |
| Book receives `state-committed` | Typed storage receipt entered the book protocol path | Book presented; KOReader painted |
| Book `present` / host `<presented-text>` | Book supplied one matching presentation result | Authority independently observed a typed receipt |
| Private `present` / Lua `applied` | Exact topmost widget text passed inherited `paintTo` | Storage committed; panel optically settled |
| Driver/display completion (future) | A separately defined publication/quiescence fact | Authoring storage commit |

The blocked native v1 integration packet deliberately preserves the book in the
middle of the commit chain. Its outer trusted API does **not** expose the typed
worker completion. Therefore the later durable reader join still lacks the
trusted receipt observer needed to issue private UI `commit-ok` honestly. A
separately scoped private successor is now independently accepted under
`pinenote/tools/book-state-integration/completion-observer/`, at core source
`0342e87c665626b01c5318d125d7f96a152e16ebe25cc310499ca92698002c8f`.
Its seam is a bounded trusted-only event containing the exact typed commit operation and
exact typed committed/conflict/failed response, published only after that
response enters the output queue and cleared on close/restart. No such event
belongs on either wire. That observer is separate from NI-1/NI-2 remediation and
does not change the frozen native v1 packet or pre-accept an eventual join.
Independent review passes 53 focused checks and both 37-assertion observer
suites; review SHA-256
`e4f1ae002ba07268c825ddc24b02477ba259a16226ca5a1e42344a6fdd0286a5`.

## 8. Private KOReader channels

Both private channels use one line:

```text
kind|canonical-generation|lowercase-hex-of-UTF8\n
```

Generation is `1..1,000,000`; value is at most 4,096 UTF-8 bytes; line is at
most 8,224 bytes excluding LF; queues and nonblocking pumps are bounded. These
channels are trusted fixture protocols, not public SDKs, JSON, or general
production control planes.

### 8.1 Accepted original interaction vocabulary

```text
authority -> Lua:
  input-update input-navigation input-close present stale-navigation
  closed finish

Lua -> authority:
  ready submit tick applied done
```

It supports the accepted transient fixed-book demonstration. It has no storage
operation ID, state version, receipt, namespace, path, or arbitrary method.

### 8.2 Accepted persistent-note native-UI vocabulary

```text
authority -> Lua:
  open load-absent load-value edit save commit-ok commit-failed present
  navigate close finish

Lua -> authority:
  channel-ready ready status submit applied ignored navigated closed done
```

`status` is one of `loaded-absent`, `loaded-value`, `dirty`, `pending`, `saved`,
or `failed`. Only `commit-ok` can produce `saved`; `load-*`, `present`, and
`applied` cannot. The exact packet sealed by
`pinenote/tools/book-state-reader/SHA256SUMS` (manifest SHA-256
`a77c989accef03d2a4698a6483b0d8968b8712dacbb097f69eaf4b5095f7d9ab`)
is independently accepted at the offline native-UI fixture gate. Its in-memory
Guile oracle and real packaged KOReader process exercise five UI generations,
failure, late-message rejection, and reopen. They do not prove fresh processes,
SQLite durability, the native Book Session/backend join, or the missing trusted
receipt observer. The fixture rejects U+0000 because the ordinary text widget
does not claim NUL rendering, even though the backend and Book Protocol can
store/carry NUL.

## 9. Generation and version taxonomy

| Name | Owner and purpose | Invalidated/advanced by | Not the same as |
|---|---|---|---|
| OS generation | Guix System trusted-host rollback unit | system registration/promotion | Book or state revision |
| Environment revision | Immutable Guix closure/software identity | controlled provisioning | Live sandbox/session |
| `BookRevision` | Immutable authored/installed publication | workspace seal/activation (unimplemented) | `BookInstance` state |
| Endpoint/session identity | Private connection lifetime | open/restart/close | Wire label, PID, or FD number |
| Surface generation | Layout/presentation lifetime | navigation/reflow/rotation policy; accepted core proves navigation | State version or UI generation |
| Action sequence | Monotonic ordering inside one session | each `host-action!` | State version |
| State grant generation | Short-lived backend capability lifetime | trusted grant issuance/revocation | State content version |
| State version | CAS version of one namespace value | successful new commit | Protocol version |
| Private UI generation | One dialog/interaction lifetime | `open`; invalidated by navigate/close | Surface generation |
| Protocol version | Wire schema selector (`1` here) | future explicit schema evolution | Storage schema |
| Storage schema version | SQLite application schema (`1` here) | future explicit migration only | State version or software revision |

No current accepted implementation activates or rolls back `BookRevision`s.
Guix system generations, state versions, UI generations, and surface generations
must not be presented as evidence for that future lifecycle.

## 10. Evidence and implementation matrix

Publication checkpoint: the accepted native editor and public source checks
are included. Guest persistence and the unfinished two-boot runner are local
follow-up experiments; their source paths mentioned in historical records are
not part of this publication roster. BSG-3's source-view replay is closed.
BSG-4 establishes that the 45-path language closure contains SQLite components,
contrary to earlier SQLite-absence claims. This does not grant access to the
authority's persistent database; library availability and storage authority
are different facts.

| Capability | Current status | Evidence boundary / gap |
|---|---|---|
| JSON framing, cross-language value policy | **Accepted** | Host codec/source tests; no aggregate rate/latency claim |
| Ordinary endpoint-owned Book Session | **Accepted** | Untimed host/session source; no automatic timer or daemon |
| SQLite CAS, receipts, quotas, process restart | **Accepted** | Host filesystem; no physical-power-loss claim |
| Seven-message typed state FSM | **Accepted** | Host typed model only |
| Typed backend adapter | **Accepted** | Real accepted backend join at exact hashes |
| Optional state worker/session successor | **Accepted optional source** | Source-level lifecycle and 24,681-byte bound; not installed in live core |
| Pinned KOReader widget/action/paint seams | **Accepted** | Desktop/SDL offscreen fixture; no glass |
| Original transient Guile/Python native interaction | **Accepted** | Trusted-native known books, not sandbox isolation |
| ARM64 gVisor/Systrap fixed-language execution | **Accepted** | Networkless QEMU/TCG compatibility under USER_NS test kernel |
| Book Session FD donation to fixed ARM books | **Accepted** | Guile and Python fixed actions plus cleanup in QEMU |
| Fixed sandbox result reaches real KOReader | **Accepted** | Four nonce-bearing results; offscreen QEMU demonstration; original launcher/harvest remain nonzero/failed |
| Persistent-note KOReader UI | **Accepted offline native-UI fixture** | Exact packet manifest `a77c989a…`; one Guile and one real packaged KOReader process, five UI generations, in-memory authority, inherited offscreen paint, generation/cleanup semantics; no SQLite, process restart, QEMU/runsc/ARM, operator run, physical render, or durable join. Review `book-state-reader-adversarial.md` SHA-256 `56a23f3acc1b2010a89ea8f00134687a0d07f290572f218477361cf0b6222301` |
| Fresh-process native backend/session join v1 | **Blocked exact-source executable gate; independent functional join passed** | Independent source-only run passed 13 factory assertions and six fresh-authority/twelve fresh-book processes for SQLite save/reopen/CAS/acknowledged receipt replay/isolation/4,096-NUL paths. NI-1 leaves executable source closure unsealed; NI-2 proves acknowledged replay, not drop-before-ack/restart/retry. A separate close/commit race suppressed a late acknowledgement but never retried that operation. Review SHA-256 `16469cd08f246743caa4b0e3524cba3080cd75603fc84512f7f7a678f0998877`; no accepted native join or KOReader/QEMU/runsc/ARM/hardware result |
| Descriptor-bound QEMU state-volume helper | **Accepted v3 host unit for conditional integration** | Independent v3 recheck closes the original and subsequent fork, open-file-description identity, and JSON grammar findings; 29/29 focused checks pass. `KCMP_FILE` must be supported and permitted; unsupported or denied comparison fails closed. Actual QEMU FD inheritance, locking, guardian joining, and semantic persistence remain separate obligations. Review: `2026-09-06-book-state-qemu-volume-adversarial.md`, final SHA-256 `e8dd85f44e9df080ecb37ad59df969e9e06da56d3178bcc4a59d2eacbeaa2383` |
| Fresh-process native backend/session join v2 | **Accepted trusted-native persistence** | Exact 29-file roster / 25-source executable closure, source and environment mutation rejection, actual dropped acknowledgement followed by fresh-process exact retry with unchanged version/receipt count, and 4096-NUL persistence paths. Review SHA-256 `928885be26b58469c9012848260035428ac2eb1494f47bc9a90f940df4777c51`. Supersedes v1's acceptance blockers without changing v1's evidence; no KOReader, QEMU, sandbox, or hardware claim |
| Paused-QEMU state-disk/guardian join | **Accepted host runtime seam** | Real post-exec OFD identity, image-lock contention, normal/TERM/SIGKILL cleanup, foreign-root preservation, and reopening after reap. Exact checker successor accepted against both unchanged evidence sets. Review SHA-256 `0c23c2e61165759586779548b0f39fca217d51627e9f6db9d0c1315f5cbc0b68`; the guest stayed paused, so this establishes no guest execution or semantic persistence |
| Two-boot QEMU durability with same state disk | **Runner v1 rejected for real use; v2 correction active** | Per-boot `360/5` binding and fail-stop sequencing pass source review, but pre-authentication code loading/mutable helper paths, self-asserted bundle authority, acceptance of extra `FAIL:` records and production `module-set!` wiring block launch. Guest-v4 metadata and an exact reviewed image binding are also needed. Review SHA-256 `0a825f5ed151c6f03b97c41a227919e9a28891a35056af963d680f3a5b101560`; no runtime result |
| Trusted completion observer for reader `commit-ok` | **Accepted private source prerequisite** | Core `0342e87c…` publishes bounded typed storage outcomes; 53 independent checks and 37+37 observer assertions pass. The actual reader join must connect these outcomes to its pending UI save; acceptance of this API alone proves no durable KOReader interaction |
| Native durable KOReader/book/session join v1 | **Historical blocked predecessor; v2 accepted below** | First save and fresh-process load pass, but a second save after restart reuses `note_s1_q1` and conflicts. A helper is checked then sourced from a mutable path. UI clear-and-save is also missing; storage-only empty recovery does not prove it. Review SHA-256 `cf31edc06b2c057f3c2c6bfd280940559255301eb76934bf0f603abb06a39d6e` |
| Native durable KOReader/book/session join v2 | **Accepted SDL-offscreen persistent-note editor** | Restart-safe saves in both languages advance 1 → 2 → 3; real UI clear/save, present-empty recovery, 4096-byte save/reopen and same-operation retry pass. 22 fresh lifecycles / 66 reaped process identities. Review SHA-256 `15b0e535180540ef852a3f21895c56edbba7e32959cfc104120d4fe285c39aa5`; supersedes v1 blockers without altering their evidence |
| Persistent state inside sandboxed book/KOReader join | **Guest source-view blocker BSG-3; no image/boot proof** | FD-3 exclusivity and external timeout containment findings are closed. Cooperative guest budget is 300 seconds; actual runner binding to 360-second outer termination plus 5-second TERM grace remains pending. Frozen v3 omits required Guix modules and cannot replay its system derivation; complete hash-bound source-view correction is active. New runtime selects reusable `gvisor/source`, not historical CONTROL |
| Public fresh-checkout persistence checks | **Accepted v2 public source/native lane** | Early startup isolation blocks both independently reproduced `guild.go` cache poisons. Candidate, capsule, aggregate, explicit retained replay and ungrafted KOReader provenance verified. Review SHA-256 `f43d955e8a866654288049e61e462821074dd412ff875ec3ca6c9ea1a802a1b0`; original blocked predecessor preserved |
| Public legacy-system dependency graphs | **Accepted v4 source/package integration; BEP-1 closed** | Every Guix entry point uses the isolated launcher; independent recheck reproduces all four real graphs byte-for-byte and rejects original fabricated graphs. Review SHA-256 `5b675a8917b5eb6abb7a7cbda244d86c2d55d745d1edf1a63ec1585eda43d357`. Runtime behavior remains a separate gate |
| Workspaces, immutable BookRevision activation/rollback/export | **Unimplemented** | Architecture only |
| General hostile-book isolation/resource qualification | **Unimplemented** | Fixed books and selected cleanup paths only |
| PineNote Book Computer behavior | **Unimplemented / not accepted** | Device is reachable, but current os2 kernel has `CONFIG_USER_NS=n`; a new reviewed generation is required |

Physical-device availability is only a prerequisite observation. It does not
authorize a write or reboot and does not establish Book Computer display,
input, latency, power, suspend, durability, or user-experience acceptance.

## 11. Immediate integration obligations

The smallest coherent next joins are:

1. use the accepted native v2 source closure and actual
   drop-before-ack/restart/retry evidence as the storage/session baseline;
2. reuse the accepted native reader-join v2, including its trusted completion
   observer and restart-safe/empty-save policy, in guest integration;
3. reuse the accepted descriptor-bound state-volume helper and paused-QEMU
   process/guardian integration in the boot campaign;
4. construct a successor two-boot QEMU runner/system that reuses the accepted
   reader graph and process guardian, proves real QEMU image locking and fresh
   guest identities, and recovers version/text only from the shared state disk;
5. only then prepare a new USER_NS-enabled device generation and seek attended
   hardware acceptance.

Automatic timer leases, aggregate protocol scheduling, resource-pressure
qualification, general book manifests, workspaces/revisions, and physical
power-loss durability remain separate later gates. None should be inferred from
the narrow persistent-text slice.
