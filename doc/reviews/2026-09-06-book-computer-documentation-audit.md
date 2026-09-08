# Book Computer documentation coverage and consistency audit — 2026-09-06

## Disposition

**The appropriate bootstrap architecture, protocols, state machines,
capabilities, and evidence boundaries are now documented, but the product is not
fully specified or implemented.** Before this pass, most facts existed somewhere
in architecture prose, chronological implementation notes, tool README/contracts,
source, or appended review dispositions. The main defect was fragmentation and
status drift, not absence of technical work.

This pass adds one consolidated current reference and updates the five owned
author-facing documents. It does not edit frozen contracts, source, immutable
evidence, hardware truth, shipping docs, or other reviewers' records. Exact
corrections recommended for stale frozen prose are recorded below rather than
applied.

## Scope and authority

Audited author-facing documents:

- `doc/wilkbook-self-hosting-book-computer.md`;
- `doc/book-computer-implementation.md`;
- `doc/book-computer-demo.md`;
- `doc/book-computer-reader-spike.md`; and
- `doc/book-computer-execution-spike.md`.

Consolidation added:

- `doc/book-computer-protocols.md`.

Read-only evidence included the exact Book Protocol, Book Session, Book State,
typed state protocol/adapter, optional delegate, native-integration, reader,
interaction, QEMU-volume contracts/sources and the final dispositions in their
adversarial reviews. `doc/status.md` was used only to keep hardware
claims subordinate to the repository's hardware source of truth.

Evidence precedence used by the audit:

1. exact executable source plus its final independent review disposition,
   whether accepted or blocked;
2. a frozen contract for the snapshot it identifies;
3. current candidate source/packet, labelled candidate or active rather than
   accepted or reviewed;
4. chronological implementation prose, interpreted at its date; and
5. broad architecture direction, which must not silently promote itself to an
   implementation claim.

## What was already documented well

The repository already had unusually strong primary documentation for:

1. **Architecture and trust split.** Guile owns trusted authority, storage, OCI,
   and supervision; Lua owns KOReader widgets/presentation; Guile and Python are
   book languages; Python host code is an oracle only.
2. **Wire framing.** Four-byte unsigned big-endian lengths, 1..65,536-byte UTF-8
   JSON objects, depth 16, duplicate/Unicode policy, safe-number behavior,
   lexical-integer obligations, noncanonical encoding, and separate diagnostics.
3. **Ordinary Book Session.** Exact `hello`/`initialize`/`action`/`present`
   shapes, endpoint-owned identity, request correlation, bounded queues/pumps,
   navigation/revocation/close/restart, and the absence of automatic timers.
4. **Persistent state.** Seven exact messages, the single-pending FSM, absent
   versus present-empty state, CAS, durable idempotency receipts, conflict and
   failure semantics, exact operation-ID grammar, schema validation, and quotas.
5. **Failure preservation.** The framing iterator defect, blocking/raw-port
   session predecessors, batch-result loss, backend BS-1 trigger,
   adapter wrong-binding close, delegate BSD-1 response bound, gVisor EFBIG
   attribution, and QEMU-volume blocked snapshot remain recorded with their
   original outcomes.
6. **Reader boundaries.** The KOReader action/widget/polling/paint seams, private
   lowercase-hex transport, descriptor/process ownership, and offscreen versus
   physical-glass distinction were already detailed.
7. **QEMU/runtime boundaries.** Exact USER_NS test kernel, gVisor package/helper
   identity, OCI policy, no-network/no-share graph, cleanup, and fixed-workload
   limitations were extensively recorded.
8. **Acknowledgement concepts.** Storage commit, protocol receipt, presentation,
   paint, and optical settlement were repeatedly distinguished, although not in
   one place.

The audit therefore did not invent a new architecture or another implementation
plan. It extracted the stable cross-cutting contract and preserved the detailed
records as evidence.

## Coverage and consistency gaps found

### 1. No current “start here” or status vocabulary

The architecture opened as wholly proposed, the implementation note was a long
append-only chronology, and the successful demo had no central link back to
protocol/state definitions. A reader could not tell whether “accepted” meant a
design decision, exact source review, QEMU result, shipping state, or hardware
truth.

**Correction:** the architecture now has a reading map and status definitions;
the implementation note has a current snapshot before its chronology; and the
consolidated reference has one explicit status legend.

### 2. Illustrative protocol vocabulary looked current

The old architecture section listed `hello`, `initialize`, `call`, `reply`,
`event`, `cancel`, checkpoint, suspend, and shutdown together. In reality, the
accepted ordinary session is the exact finite
`hello`/`initialize`/`action`/`present` schema (plus host-generated `cancel`),
and state is a separate seven-message schema. Generic `call`/`reply`/`event` and
lifecycle messages do not exist.

**Correction:** architecture section 7.6 now names the accepted messages and
labels the earlier generic vocabulary future. Reference sections 3 through 5
give the exact framing, ordinary session, and state tables/FSMs.

### 3. Identity and capability terms were distributed across layers

Endpoint object identity, diagnostic labels, book/revision/instance identity,
wire handles, backend grants, generations, and namespaces were all documented,
but not contrasted centrally. This made it too easy to say “the handle is the
capability” or imply a peer JSON book identity selects storage.

**Correction:** reference sections 1 and 2 separate endpoint identity,
capability binding, book identity, diagnostics, and every channel. They record
that a wire handle must match endpoint-retained authority and that no accepted
state message contains a namespace or path.

### 4. Ordinary session and state concurrency could be conflated

The ordinary Book Session permits four pending presentation requests. The state
model deliberately permits one staged/backend operation and omits a read ID only
under that condition. No prior author-facing page placed those facts together.

**Correction:** reference sections 4.2 and 5 make the non-composition rule
explicit and scope the no-read-ID decision to the current single-pending model.

### 5. Acknowledgement ownership was incomplete at the outer API

Individual contracts correctly said that `state-committed`, book `present`,
private UI `applied`, and optical settlement differ. The missing fact was who can
honestly issue private UI `commit-ok`. The native v1 outer only observes a book
presentation; it cannot independently observe the typed worker receipt.

**Correction:** the full chain and non-implications are centralized in reference
section 7. The native candidate and reader-spike docs now state that a book
presentation is not receipt authority. A separately
scoped completion-observer candidate is active under
`pinenote/tools/book-state-integration/completion-observer/`; it is not
pre-accepted and does not mutate the frozen native v1 packet.

### 6. Generation/version categories were not centralized

The docs use Guix generation, environment revision, `BookRevision`, endpoint
identity, surface generation, action sequence, state-grant generation, state
version, private UI generation, protocol version, and storage schema version.
Their individual definitions existed, but readers had no direct warning that
equal integer values carry no authority across categories.

**Correction:** reference section 9 gives an owner, advance/invalidation rule,
and explicit non-equivalence for each category. The architecture links to it at
section 7.9.1.

### 7. Evidence stopped at different seams without one matrix

The accepted reader seam, trusted-native interaction, ARM64 compatibility,
Book Session FD donation, real KOReader QEMU demonstration, state UI fixture,
native SQLite join, QEMU-volume helper, and future hardware proof were each
recorded in different documents. “Reader integration,” “persistence,” and
“QEMU” could therefore overstate a result by one or more seams.

**Correction:** reference section 10 records each capability as accepted,
blocked, candidate/active, historical, or unimplemented and states its exact
evidence boundary.

### 8. Native persistence and persistent-note UI progress were newer than the prose

The implementation note said the real native join was still being completed.
The frozen candidate packet now reports:

```text
review packet  02bd736c7dd6954837ab1053b2d91692d60a723a4ede5fb80499ce2d06bac777
manifest       42053ee2907648aac4334b75bf26cc19c63f11984128705963aeae43bcdd9ffe
host log       23392544b6a1339b3548a19247ad1d74eec63fb7fb8c975cc1e0f96b97a2724d
```

Independent source-only execution passed 13 factory assertions and six fresh
authority phases / twelve fresh Guile-or-Python book processes across save,
restart/reopen, CAS, acknowledged receipt replay, isolation, and 4,096-NUL
reopen/second commit. Deleted-database recovery failed as required and a swapped
namespace was caught. Review document SHA-256 is
`16469cd08f246743caa4b0e3524cba3080cd75603fc84512f7f7a678f0998877`.

The final disposition is nevertheless **blocked as an exact-source executable
evidence packet**:

- NI-1: the runner does not authenticate every executed source, including the
  Python codec and live blocking-I/O source; it also permits caller-selected
  source paths and expected identities. An unlisted Python codec executed while
  the normal suite stayed green.
- NI-2: both first-phase books consumed and presented the receipt before replay.
  V1 therefore proves acknowledged receipt replay, not one continuous
  drop-before-ack/restart/retry scenario. The accepted backend's separate real
  lost-ack process-crash coverage remains valid. A separate close/commit race
  suppressed a late acknowledgement after close but never retried that
  operation, so it does not close NI-2.

**Correction:** author-facing docs call v1 a **blocked exact-source gate with an
independently passing functional join**, not accepted native integration and not
merely an unreviewed candidate. They explicitly exclude KOReader, QEMU, runsc,
ARM, image, and hardware and retain the missing typed completion observer. NI-1
and NI-2 successor work under `pinenote/tools/book-state-integration/` remains
separate from the completion-observer candidate.

The persistent-note UI review independently accepted the exact
`pinenote/tools/book-state-reader/` packet at the offline native-UI fixture gate:

```text
SHA256SUMS manifest  a77c989accef03d2a4698a6483b0d8968b8712dacbb097f69eaf4b5095f7d9ab
review document      56a23f3acc1b2010a89ea8f00134687a0d07f290572f218477361cf0b6222301
```

The provided gate and independent 29-control, 38-stream, 32-UI, and 14-cleanup
checks passed. The accepted evidence is one in-memory Guile authority process,
one real packaged KOReader process, five UI generations, inherited offscreen
paint, and finite generation/cleanup behavior. It is **not** fresh-process or
SQLite durability, the native state join, QEMU/runsc/ARM, an operator run,
physical rendering, or release behavior. The review preserves the distinctions
between `commit-ok`, later `present`, and inherited paint, including a stale
commit arriving after newer edits.

**Correction:** the reference, architecture, implementation snapshot, and reader
spike now call this an **accepted offline native-UI fixture**, while continuing
to call the typed receipt observer and durable reader join unimplemented or
active candidates. Acceptance of the UI half is not transitive to storage.

### 9. The QEMU state-volume design changed at the ownership boundary

The design review's file-node example names the mutable campaign pathname
(`doc/reviews/2026-09-06-book-state-qemu-seam-design.md:92,105-109`). The blocked
helper review proved that this was not bound to the retained inode
(`doc/reviews/2026-09-06-book-state-qemu-volume-adversarial.md:149-179`). Current
candidate source instead carries a scoped inherited descriptor and generates
`/proc/self/fd/N` (`pinenote/tools/book-state-qemu/CONTRACT.md:47-101`).

**Correction:** owned docs mark the pathname proposal historical and the
descriptor-bound implementation an active corrected candidate. They do not call
it accepted until a successor review appends a disposition.

### 10. Hardware availability could be mistaken for acceptance

Read-only SSH established that os2 is reachable and has real `/data`, but its
running 7.1.8 kernel has `CONFIG_USER_NS` disabled. That observation neither
authorizes deployment/reboot nor proves Book Computer behavior.

**Correction:** architecture and reference now state that a separately reviewed
USER_NS-enabled generation and attended hardware session are prerequisites, and
that no current display/input/power/suspend/durability/user-experience claim
follows from availability.

## Exact proposed corrections to frozen or non-owned records

These files were deliberately not edited. The following text changes should be
made only through their owning/freeze process, without deleting the original
failed dispositions.

### A. Accepted ordinary Book Session README status

File: `pinenote/tools/book-session/README.md`.

1. Replace lines 81-83:

   > There is no known unresolved lexical-integer hole in the four current
   > fields; the exact Guile source was independently accepted for the scoped,
   > untimed ordinary session. Any new integer field reopens this obligation.

2. Replace lines 249-252 with:

   > Source `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668`
   > is independently accepted for the scoped untimed ordinary Book Session.
   > External supervisor, sandbox, reader, and persistence joins retain their
   > own review and evidence boundaries; this module alone proves none of them.

This corrects stale “awaits fresh review” wording without broadening module
acceptance.

### B. Accepted typed state protocol status

File: `pinenote/tools/book-state-protocol/CONTRACT.md`.

Replace lines 3-5 with:

> Status: independently accepted version-1 typed protocol model. Current source
> SHA-256 is `425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257`;
> the accepted backend adapter is `349c960b…`, and the optional state-enabled
> Book Session successor/delegate is independently accepted as a separate
> source candidate. The live ordinary Book Session source is unchanged. The
> frozen native v1 integration is blocked at its exact-source executable gate;
> no durable
> KOReader, QEMU, runsc, ARM, or hardware join is accepted here.

Rename `## Backend adapter` at line 94 to `## Accepted backend adapter mapping`
and change “The next trusted adapter should map” at lines 96-114 to present tense
for accepted adapter source `349c960b…`, while retaining the rule that no Book
Session mutex spans backend I/O. Rename the line-168 recheck heading to a
historical note rather than presenting it as a pending gate.

### C. Accepted BSD-1 successor status

File:
`pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/CONTRACT.md`.

Replace the title/status at lines 1-6 with:

> # Optional Book State delegate — accepted BSD-1 successor source
>
> Status: independently accepted host-only source pair for the next real join:
> core `f0e2a043…`, delegate `eca58675…`, full patch `d779ed2c…`. The accepted
> ordinary Book Session source remains unchanged at `f5823fa7…`; this optional
> successor is not installed over it. Source acceptance includes typed mock
> storage and completion lifecycle, not the native SQLite integration, reader,
> QEMU, sandbox, or hardware.

At lines 25-26, replace “eventual real factory may” with “the independently
exercised but source-gate-blocked native v1 factory does,” followed by the v1
evidence boundary. Do not rewrite or remove the BSD-1 failed predecessor in its
adversarial review.

### D. Blocked native state integration v1

File: `pinenote/tools/book-state-integration/CONTRACT.md`.

The current lines 3-8 accurately freeze v1 as a candidate, and lines 112-156
accurately define the missing receipt observer. Append—do not retroactively
replace—a disposition naming packet `02bd736c…`, manifest `42053ee2…`, host log
`23392544…`, and review
`16469cd08f246743caa4b0e3524cba3080cd75603fc84512f7f7a678f0998877`.
It must state both sides of the result: the independently assembled functional
join passed, while NI-1 blocks exact-source executable evidence and NI-2 reduces
“lost-ack retry” to acknowledged receipt replay. Keep the completion observer in
a new separate packet; do not imply v1 had reader UI or outer receipt
observation. The NI-1/NI-2 successor must receive its own identity and review.

### E. Historical QEMU pathname design

File: `doc/reviews/2026-09-06-book-state-qemu-seam-design.md`.

If this frozen design receives an appendix, use:

> **Historical transport detail:** the two-boot/shared-disk evidence design
> remains the intended campaign, but the pathname file-node at lines 92 and
> 105-109 is superseded for the current candidate by an opaque scoped descriptor
> handed to QEMU as `/proc/self/fd/N`. This change responds to the independently
> reproduced inode/path replacement defect. It is a candidate until separately
> re-reviewed and does not itself establish QEMU writer exclusion or semantic
> persistence.

Do not alter the original proposal or pretend it used the descriptor design.

### F. Blocked QEMU-volume review

File: `doc/reviews/2026-09-06-book-state-qemu-volume-adversarial.md`.

Do not change its lines 3-26 or the 56-check result: they correctly reject exact
sources `2e396ab8…` and `d426cdc7…`. A successor review should append a new
hash-bound disposition for the descriptor handoff, synchronized process-local
registry, strict modes, structural JSON graph parser, quarantine cleanup threat
model, and all former counterexamples. It must still reserve actual guardian
join and QEMU image-lock behavior for integration.

### G. Accepted interaction README status

File: `pinenote/tools/book-interaction/README.md`.

Its final lines 265-268 say the integrated fixture requires fresh review. Add a
short appendix pointing to the final accepted authority and reader dispositions
and the accepted QEMU demonstration, while preserving the distinction between:

- the original trusted-native fixture;
- the private UI channel;
- the fixed sandboxed QEMU join; and
- the unimplemented durable-state reader join.

Do not call the private channel Book Protocol or a production control plane.

## Remaining product/documentation issues

The consolidated reference intentionally leaves these open rather than
inventing contracts:

1. the completion-observer candidate's exact trusted API, event drain, capacity,
   close/restart, and cached-response behavior;
2. a native state integration successor that seals the executable source closure
   (NI-1), performs a real drop-before-ack/restart/retry scenario (NI-2), and
   receives its own independent disposition;
3. final independent disposition for the corrected descriptor-bound QEMU-volume
   helper;
4. the exact joined two-boot runner/system and its QEMU lock/guardian evidence;
5. automatic timer leases, aggregate connection scheduling/rate limits, and
   resource-pressure behavior;
6. general manifest-selected books, resources, structured/custom surfaces,
   document anchors, workspaces, and object capabilities;
7. `BookRevision` construction, schema migration, activation, rollback,
   provenance, and export;
8. controlled environment provisioning and retention/eviction;
9. hostile-book isolation qualification beyond the fixed workloads; and
10. PineNote startup, latency, memory, display/input, suspend, idle-power,
    durability, and on-glass usability.

These are implementation/design gaps, not omissions to fill with speculative
wire fields. Each should acquire a finite contract and evidence boundary when it
becomes the next implementation slice.

## Files edited by this audit

- `doc/wilkbook-self-hosting-book-computer.md`
- `doc/book-computer-implementation.md`
- `doc/book-computer-demo.md`
- `doc/book-computer-reader-spike.md`
- `doc/book-computer-execution-spike.md`
- `doc/book-computer-protocols.md` (new)
- `doc/reviews/2026-09-06-book-computer-documentation-audit.md` (new)

No code, contract, frozen packet, checksum file, artifact, hardware-status file,
shipping doc, or other review record was edited.
