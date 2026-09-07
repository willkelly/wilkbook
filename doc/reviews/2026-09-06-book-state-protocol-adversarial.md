# Persistent-text Book State protocol adversarial review — 2026-09-06

## Disposition

**Do not integrate frozen protocol implementation
`358f8a724f9c7dacf3b8c1c3e01ad9db4f34fda2755c7682a6a277522ecb6194`
yet.** The seven version-1 wire shapes, endpoint authority projection, finite
state-machine shape, deliberate omission of a read ID, and separation of durable
save acknowledgement from presentation/paint are accepted. Two related
backend-result consistency defects have concrete reproductions, and the already
known operation-ID grammar mismatch must be aligned with the now-frozen backend
contract before the join.

This is a narrow result, not a rejection of JSON, the seven-message design, or
the finite FSM. A focused correction and recheck is sufficient; no new wire
field, generic RPC method, second codec, read ID, async framework, or UI rewrite
is indicated.

## Scope and identities

The code-only input packet was mode-private at
`/tmp/opencode/book-state-protocol-v1-code-only.ucqLHk`. Its requested manifest
matched:

```text
7768784b32a5636aa7752578dc6e91dfe6ba8f8ecdc0a25dee39b2c9cae47bf9  packet-manifest.json
```

The machine-frozen inputs matched the packet:

| Input | SHA-256 |
|---|---|
| `pinenote/tools/book-state-protocol/book-state-protocol.scm` | `358f8a724f9c7dacf3b8c1c3e01ad9db4f34fda2755c7682a6a277522ecb6194` |
| `pinenote/tools/book-state-protocol/test-book-state-protocol.scm` | `b968e7c4057a7a51e03f928968e9e799e143f37ae8b67f8f0172f217c7818705` |
| `pinenote/tools/book-state-protocol/Makefile` | `0d4a9dc27d6201bb65ed3a99e932f708c1dc85cb18807338006d1613e6ed7eb4` |
| accepted `pinenote/tools/book-protocol/book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| accepted `pinenote/tools/book-session/book-session.scm` | `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668` |

The reviewed prose candidate, intentionally outside the packet's machine-code
freeze, was pinned for this review as:

```text
d5cedeb8d836991f7f7c9043f56c13488a366ef5970374029f8be2c00e85bd3a  pinenote/tools/book-state-protocol/CONTRACT.md
```

At the user's supplemental direction, I read only the separately frozen backend
review packet and published contract for typed-API/grammar cross-mapping. I did
not inspect its implementation or duplicate its durability audit:

```text
b873e5fe0039e9ce9d01383bb83b76c202517607390b47418fbd8b6d558ff946  pinenote/tools/book-state/build/book-state-backend-review-packet-v1.txt
c25622ef491cedc919be4ea1ffede666cea83241dd0b9066c03f769e5f96b677  pinenote/tools/book-state/CONTRACT.md
```

The packet reports 71 backend host assertions plus one process-death/restart
scenario under SQLite `DELETE`/`synchronous=FULL`. Those results belong to the
separate backend reviewer. This protocol review makes no independent backend,
SQLite, physical-power-loss, or filesystem durability finding.

## Findings

### 1. Blocking: a typed read can roll back or rewrite the known snapshot

`apply-read-result!` verifies exact pending-operation `eq?` identity and the
generic absent/value shape, but it does not compare the result with the
session's already-known snapshot. It then unconditionally calls
`set-current-snapshot!` before returning `state-value`
(`book-state-protocol.scm:918-934`).

Two source-exact counterexamples succeeded without error:

```text
READ-ROLLBACK error=#f snapshot=(clean #t 4 "old" #f #f #f)
READ-SAME-VERSION-DIFFERENT-TEXT error=#f snapshot=(clean #t 5 "changed" #f #f #f)
```

In the first, the session had already observed present version 5/text `"new"`;
an exact pending read operation carrying a well-shaped but fabricated version
4/text `"old"` result replaced it and emitted a value. In the second, version 5
was retained but its text changed from `"known"` to `"changed"`. Both results
are impossible under the backend's monotonic CAS contract. Exact operation
identity prevents a completion for the wrong read, but does not establish that
the returned snapshot is consistent.

Required focused correction, before any mutation or response construction:

1. reject and close if a read result version is below
   `state-session-current-version`;
2. at the same version, require identical `present`, version, and text fields;
3. permit a higher well-shaped version, and permit the identical current
   snapshot; and
4. preserve the existing `resume-dirty?` behavior only after those checks pass.

The failure path must not install any part of the fabricated snapshot. Tests
should cover lower version, same-version/different text, absent-after-known-
present, and both `clean` and conflict-refresh `edit-dirty` reads.

### 2. Blocking: impossible stale-version metadata becomes a wire conflict

The stale-CAS branch checks only that `current-state-version` is present, then
records it and returns `state-conflict` (`book-state-protocol.scm:968-987`). It
does not check the backend's two relevant invariants:

- `current-state-version` cannot be below the snapshot already known by this
  session; and
- a `stale-version` result cannot have a current version equal to the pending
  operation's expected version, because that CAS comparison was not stale.

Both impossible results were accepted:

```text
STALE-EQUAL-EXPECTED error=#f response-conflict=#t snapshot=(edit-dirty #t 5 "known" "draft" 5 #f)
STALE-BELOW-KNOWN error=#f current-version=5 conflict-version=4 phase=edit-dirty
```

The focused fix should fail-close before clearing/replacing pending state or
publishing a conflict unless:

```text
current-state-version >= session's known current version
current-state-version != operation's expected state version
```

Do **not** require `current-state-version > expected-state-version`: a peer may
submit an expected version ahead of the store, for which a lower current version
is a legitimate conflict so long as it has not regressed below the session's
known snapshot.

### 3. Integration condition: enforce the backend's exact operation-ID grammar

The frozen backend contract exports `book-state-operation-id?` and
`book-state-max-operation-id-bytes`, with grammar exactly:

```text
[A-Za-z0-9_-]{1,128}
```

The protocol currently applies only nonempty/128-byte UTF-8 bounds. A direct
cross-map probe confirmed that it accepts a dot, colon, space, Unicode, and NUL,
all of which the backend contract rejects:

```text
PROTOCOL-OPERATION-ID "dot.id" accepted=#t
PROTOCOL-OPERATION-ID "colon:id" accepted=#t
PROTOCOL-OPERATION-ID "white space" accepted=#t
PROTOCOL-OPERATION-ID "é" accepted=#t
PROTOCOL-OPERATION-ID "\x00" accepted=#t
```

Before the join, every protocol constructor/decoder carrying `operation_id`
(`state-commit`, `state-committed`, `state-conflict`, and
`state-commit-failed`) must enforce the same closed ASCII predicate. Prefer the
backend's exported predicate at the integration boundary, or pin an exactly
equivalent protocol checker with cross-tests against that predicate. Do not add
a field or broaden the backend grammar. Include positive 1/128-byte boundary
tests and negative 0/129-byte, dot, colon, whitespace, control, and Unicode
tests.

This is the known finite alignment item. It does not invalidate the seven wire
shapes or require their redesign.

## Accepted finite decisions

### Seven exact version-1 messages and JSON framing

The model defines exactly the requested message types:

```text
state-ready  state-read  state-value  state-commit
state-committed  state-conflict  state-commit-failed
```

All use the accepted Book Protocol frame/JSON codec. The additional source pass
records lexical shape for top-level scalar numbers; it is not a second JSON
parser or alternate transport. Direction, exact fields, duplicate/unknown/
missing members, lexical integers, booleans, absent versus present empty text,
and UTF-8 byte bounds are explicit. There is no generic `method`, arbitrary key,
book/instance/namespace/path field, or generic RPC dispatcher.

An independent Python-driven oracle checked 59 source-exact cases: all 24 field
permutations of `state-read`, escaped required keys and values, all seven message
types, literal and escaped-equivalent duplicate/unknown keys, missing fields,
wrong directions, decimal/exponent integer aliases, type errors, bounds,
malformed JSON, invalid UTF-8, and a generic-RPC-shaped object. All outcomes
matched the finite oracle.

### Endpoint authority and backend operation identity

Owner object, opaque backend grant, generation, and access are retained in one
trusted endpoint binding. Only handle/generation/access are announced; received
handle and generation merely have to match that binding. They cannot select a
namespace or manufacture authority. Typed read/commit operations copy the exact
trusted owner and grant from the binding.

Backend results must carry the exact `eq?` pending Scheme operation. The model
correctly rejected a result for another session without mutating the pending
read. A close/EOF clears pending identity; a late exact completion was rejected
and could not revive the session. The future adapter must additionally compare
the backend receipt's independent operation ID, expected version, result
version, and text-byte count before constructing the protocol receipt, exactly
as both contracts require.

Malformed typed commit receipts are already handled correctly: wrong result
version or UTF-8 byte count closed the session while preserving its known
snapshot. The blockers above are missing analogous semantic checks for reads and
conflicts, not a failure of exact operation-record identity.

### No read ID is needed in this finite model

The deliberate omission is accepted. Exactly one backend operation is pending,
the read result must name the exact connection-local Scheme operation by `eq?`,
and a second read/commit cannot replace it. `state-value` is the only read reply
shape, while commit replies carry operation IDs. EOF/revocation invalidates the
pending record, and reopening requires a fresh endpoint binding/grant. There is
therefore no response ambiguity for this synchronous one-endpoint design.

This conclusion is scoped to the current model. It would need reconsideration
if later work introduced concurrent reads, a queue, detached completion,
cross-connection continuation, or multiple state delegates. None should be
added to this join.

### Retry, conflict, and acknowledgement semantics

The tested model preserves absent state versus committed empty text. Exact
cached success and conflict retries returned the same response-record identity.
An exact old durable receipt did not roll a newer local snapshot backward, and
changed payload under a reused operation ID closed locally or relied on the
durable backend's `operation-conflict` check for older IDs. Draft text survives
ordinary conflict/quota handling and is not a mirror of UI keystrokes.

`state-committed` means only that a typed durable receipt was accepted. It does
not claim that a presentation was queued, KOReader received it, or inherited
`paintTo` observed it. Keeping storage acknowledgement, protocol response,
presentation, and paint as separate facts is accepted and directly addresses
the save-latency/UI concern without changing serialization.

### Minimal integration seam

The proposed seam is acceptable in shape after the three items above are fixed:

1. one optional state delegate is attached to the existing Guile endpoint only
   after accepted `hello`;
2. the endpoint supplies owner/grant authority out of band and routes only the
   two book-to-authority state request types;
3. model transitions remain serialized, but synchronous backend I/O occurs with
   the Book Session transition mutex unlocked;
4. after the backend call, the caller reacquires transition ownership and
   applies only the exact typed result; and
5. close/EOF first makes the local model reject late completion, then invokes
   owner-checked backend revocation outside the Book Session mutex.

The backend mutex determines commit-versus-revocation ordering. If a commit
linearizes first but the endpoint closes before its result can be applied, the
write may be durable without a wire acknowledgement; the durable operation ID
receipt is precisely what makes a later fresh-session retry recoverable. If
revocation linearizes first, the backend rejects the operation. This does not
justify holding the Book Session mutex across SQLite I/O.

This approves the seam contract, not an implementation. Accepted Book Session,
Book Protocol, UI/private-control, guest, outer runner, and QEMU graph sources
were not edited or integration-reviewed here.

## Independent execution evidence

The supplied code-only host command was rerun independently and passed 76
SRFI-64 assertions with zero compile warnings. Additional review tests produced:

- **59/59** independent wire-schema oracle outcomes;
- **3,136/3,136** deterministic generated legal-FSM checks;
- exact cached receipt and conflict identity;
- rejection of a wrong-operation result without pending-state mutation;
- rejection of late completion after EOF;
- fail-closed wrong-version/wrong-byte-count commit receipts; and
- the four blocking semantic counterexamples quoted above.

The private evidence root is:

```text
/tmp/opencode/book-state-protocol-independent-review-20260906
```

Key hashes:

```text
058d3d9f6fd8d98eac8f4d8a9641bb77c6872b867b018cfe2cc83c6f268e1f0e  independent-review-manifest.json
be766e2035b3d108f19ef4604c2ddb4a0be48c7fef023e7734209179aeff63bd  independent-host-check.log
b9affedd25061483ebf69f99ea4a12e0fb268e7848aa2df25b1d6028345571c3  wire-oracle.log
b9883762c88ca3d0088df62efa8127d0d052e6b9131ec3b4177c3194f4d3a5a9  sequence-oracle.log
df72d722385a0082da95fab92ae1256e87f2b2c4a68bd2fe66830be983709be1  adversarial-model.log
9c47da5ab392877fae6ec6805f88642e07ea2ca79f448da7ae4fe2419fc75b56  operation-id-crossmap.log
```

No protocol/backend implementation, accepted core/UI/guest/outer source, or
QEMU disk work was modified. No backend implementation/test, QEMU, runsc, ARM,
image/package/Bazel build, hardware, mount, network, staging, commit, or push was
performed.

## Focused recheck gate

A corrected candidate needs only a finite delta review proving:

1. lower and same-version/inconsistent read results fail closed before snapshot
   mutation or `state-value` construction;
2. stale conflicts below the known version or equal to expected fail closed,
   while the valid `known <= current != expected` cases still work;
3. all four operation-ID-bearing messages enforce exactly
   `[A-Za-z0-9_-]{1,128}` and cross-match the backend predicate; and
4. the existing 76 assertions, wire oracle, generated FSM walks, cached replay,
   wrong-operation, late-completion, and malformed-receipt checks remain green.

After that focused source acceptance, the parent may freeze a joined candidate.
Actual save/reopen/recovery claims still require the typed protocol to be joined
to the reviewed backend and exercised through the real guest/QEMU path; this
host-only model is not such evidence.

## Focused V2 correction recheck — 2026-09-06

### Disposition

**Accept the corrected protocol code as the fixed typed-model input to a later
storage-adapter/join review.** No blocker remains in the finite correction for
the three findings above. This is candidate V2 in review history; its seven wire
messages deliberately remain `protocol_version: 1`.

This acceptance does not include the separately prepared backend adapter, the
backend's pending BS1 schema-hardening review, accepted Book Session changes, or
an actual storage/QEMU join. It proves no SQLite durability, save/reopen path,
guest transport, recovery, presentation, or paint behavior.

### Frozen inputs

The mode-private packet
`/tmp/opencode/book-state-protocol-v2-code-only.kZnkPM` authenticated at:

```text
4410ad29c116c8f5e4199203c4d3da520805c3156c8298e36407d609321d4b64  packet-manifest.json
```

The accepted code-specific inputs are:

| Input | SHA-256 |
|---|---|
| `book-state-operation-id.scm` | `dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee` |
| `book-state-protocol.scm` | `3e5567cad0f5c43f54a0b2abb6916dcbd3c1c7dbd922a6fb8642eb3d4c84e3cc` |
| `test-book-state-protocol.scm` | `d8ea11fc99dcd59a5904cdc1ed74b41309842a8c654640a7c043ba59bd0a1635` |
| `Makefile` | `e35b4155f4036abef93260e02c4f68792279e3a4a86a9238fb0975311b65a970` |
| unchanged accepted `book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |
| unchanged accepted `book-session.scm` | `f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668` |

The corrected prose contract was outside the packet's machine freeze but was
read and pinned for this focused review at:

```text
7a8f691a659689c78cb76c01e93d8f41408a6f9af90190f8c9f646b16598c900  pinenote/tools/book-state-protocol/CONTRACT.md
```

The V1 findings above remain historical evidence. This section supersedes only
their blocked disposition for protocol source
`358f8a724f9c7dacf3b8c1c3e01ad9db4f34fda2755c7682a6a277522ecb6194`;
it does not rewrite that source's observed behavior.

### Finding 1 resolved: read results preserve the monotonic snapshot

`read-result-consistent?` now permits only a higher version or the exact same
`present`/version/text snapshot. `apply-read-result!` checks it after exact
pending-operation validation and before constructing `state-value`, replacing
the known snapshot, or clearing successful pending state. An impossible result
closes with `inconsistent-backend-read`; the close clears pending/draft
authority and revokes the endpoint binding while leaving known presence,
version, and text unchanged.

I replayed the exact V1 adversarial script, SHA-256
`99d3d6f2a4481e355516ea917b9b02637dc0d3a3c23ce09c82db23d4e56d4583`.
Its former successful mutations now report:

```text
READ-ROLLBACK error=backend snapshot=(closing #t 5 "new" #f #f inconsistent-backend-read)
READ-SAME-VERSION-DIFFERENT-TEXT error=backend snapshot=(closing #t 5 "known" #f #f inconsistent-backend-read)
```

An additional independent failure-state audit used the private pending accessor
only as a test oracle. It confirmed for both cases that the binding is revoked,
pending and draft are false, and version/text remain exactly 5/`"known"`.

The focused positive checks also accepted:

- an identical same-version read;
- a higher fresh read;
- transition from absent version 0 to present version 1 with empty text; and
- the existing distinction between present empty and absent state.

### Finding 2 resolved: impossible stale metadata cannot become conflict

The stale branch now constructs `state-conflict` only when both reviewed
predicates hold:

```text
current-state-version >= session's known current version
current-state-version != operation's expected state version
```

Both former counterexamples now close before conflict construction:

```text
STALE-EQUAL-EXPECTED error=backend response-conflict=#f snapshot=(closing #t 5 "known" #f #f invalid-backend-rejection)
STALE-BELOW-KNOWN error=backend current-version=5 conflict-version=#f phase=closing
```

The independent failure-state audit additionally confirmed no returned response,
no recorded conflict version, cleared pending/draft, revoked binding, and an
unchanged known snapshot. The important valid edge cases remain accepted:
current 6 versus expected 5, and current 5 below peer-supplied future expected
7. The correction therefore does not accidentally impose the rejected
`current > expected` rule.

### Finding 3 resolved: exact closed operation-ID grammar

The new SQLite-free `(book-state-operation-id)` module implements exactly
`[A-Za-z0-9_-]{1,128}`. It uses explicit ASCII code-point ranges; because every
accepted character is one UTF-8 byte, its character and byte bounds coincide.
It has no import or dependency on `(book-state)`, SQLite, or backend schema code.

`book-state-protocol.scm` uses this one predicate in all four operation-ID
constructors, so both programmatic construction and decoded wire messages for
`state-commit`, `state-committed`, `state-conflict`, and `state-commit-failed`
share the same rejection point. The compatibility maximum aliases the
predicate module's 128-byte constant.

The independent finite grammar oracle covered all 128 one-byte ASCII values,
the 1- and 128-byte positive boundaries, and empty/129-byte, dot, colon,
whitespace, newline, tab, NUL, and Unicode negatives. It exercised all four
constructors and raw decoder examples for all four message types. The domain
matches the immutable backend contract's independently exported predicate;
backend implementation behavior was not used as the oracle.

### Focused independent evidence

I intentionally did not rerun the prior 59-case general wire inventory or the
3,136-case generated FSM inventory. The authenticated packet reports those, plus
147 SRFI-64 assertions, all green. The independent delta recheck instead ran:

- both focused modules through Guile arity/format warning compilation: zero
  warnings;
- the exact four prior counterexamples: four fail-closed outcomes;
- 12 explicit fail-state assertions covering preserved baseline, revoked
  binding, cleared pending/draft, and no impossible conflict; and
- 202 operation-ID boundary and valid read/conflict checks: zero failures.

Previously accepted properties also remained visible in the exact replay:
wrong-operation results do not replace pending identity, late EOF completion
cannot revive a session, malformed receipts fail closed, and cached receipt and
conflict responses retain identity.

The private evidence root is:

```text
/tmp/opencode/book-state-protocol-v2-independent-recheck-20260906
```

Key hashes:

```text
20d1b23d9a96a83b4cdac80d566fed5d5736dbe60568c69a7e2504ad2be40fad  independent-recheck-manifest.json
98a7761e3ca58b8bbd7979ffd3855c3cfaa1c5eb3c4f371d3f074df686000ff6  v1-counterexample-replay.log
a9b479afcebc5b5e18c4b642a05ea1ef99ed575756af5da560cc0bb57dbc2632  failure-state-audit.log
33e5a2c41d2f63e3c24b4dfc078a9844efe3852d4471f023e0879e72d08314e0  focused-v2-boundaries.log
```

### Remaining boundary

The deliberate no-read-ID decision remains accepted only for this synchronous,
single-pending, connection-local model; V2 does not broaden it or add reopen
semantics. The next valid gate is independent review of the actual typed backend
adapter after its backend source/BS1 contract is accepted. Only then may a
storage join claim that protocol results originate in the real backend. Actual
save/reopen and process-recovery evidence must then cross that adapter and,
later, the real guest/QEMU path rather than stopping at this model.

The separate adapter-preparation packet was not inspected or accepted. No
backend/SQLite test, QEMU, runsc, ARM, image/package/Bazel build, hardware,
mount, network, accepted core/UI/guest/outer edit, implementation edit, staging,
commit, or push occurred in this recheck. Two source-only Guile warning
compilations and the focused host model probes wrote only to the private
evidence root.
