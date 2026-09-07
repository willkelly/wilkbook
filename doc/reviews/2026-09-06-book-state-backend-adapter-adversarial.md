# Book State backend adapter adversarial review — 2026-09-06

## Disposition

**Do not accept frozen adapter source
`6c9206ad8ab4fe15a3954f3e92a3fcf9ded9bee07a53f1fb9dabbc420f01f08e`
for the storage join yet.** Its operation dispatch and typed-result mapping are
fit in the reviewed paths, but its combined close/revoke helper does not prove
that the supplied session and binding belong together. A source-exact two-
endpoint counterexample made the helper return successful `revoked`, close
session A, revoke endpoint B, leave A's grant active, and permit A's captured
commit to reach durable storage after the helper had returned.

This finding is independent of the old backend's BS1 schema issue and remains
applicable to the newly accepted backend because the relevant public grant/
revoke API is unchanged. The correction can remain narrow. Final adapter
acceptance also requires rebinding and rerunning the corrected adapter against
the accepted backend V2 immutable snapshot; the old-backend preparation run is
not final join evidence.

## Scope and identities

The adapter preparation packet was mode-private at
`/tmp/opencode/book-state-backend-adapter-prep-v1.oKogKp` and authenticated at:

```text
96a84b4bbab817423dcda0d3b919f15ea337ae0d50f7d7efeb5169d56194386b  packet-manifest.json
```

The reviewed frozen inputs were:

| Input | SHA-256 |
|---|---|
| `book-state-backend-adapter.scm` | `6c9206ad8ab4fe15a3954f3e92a3fcf9ded9bee07a53f1fb9dabbc420f01f08e` |
| `test-book-state-backend-adapter.scm` | `53e58e6db91369a41b88e48adfeb1e32593d0f11006f4077f60e6144e5c89342` |
| `backend-adapter-test-manifest.scm` | `35ffb9555d91c280e7a1ffa01eb6aae3cc8c4b598e27ca78fa683fd7f5aba354` |
| `run-book-state-backend-adapter-tests.sh` | `8dd1f7e39c812cf71e71f3f2acbcbc1cbc3335f7d4107bed9f02a871e6337c2c` |
| accepted `book-state-operation-id.scm` | `dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee` |
| accepted Protocol V2 `book-state-protocol.scm` | `3e5567cad0f5c43f54a0b2abb6916dcbd3c1c7dbd922a6fb8642eb3d4c84e3cc` |
| accepted `book-protocol.scm` | `91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44` |

The preparation test used immutable old backend source
`eeb572ef8c97873fd7d2b3295ac20552bcc72bf2916d8c1bdca8004ba5fbd3d4`.
That run is useful only for adapter control flow and public-API mapping. It does
not accept that backend, repeat its crash audit, or erase its known BS1 issue.

During this review the backend's separate reviewer accepted the corrected
backend source. I authenticated, but did not re-audit, these supplied identities:

```text
7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9  pinenote/tools/book-state/book-state.scm
6520e5ed592cbec37be4605544b7606387d8032335a474ce596a485c022f5426  immutable V2 MANIFEST.sha256
d4bc141b24020cf4df8316835a9d4aa1c7eb3c0c0d906ebd1143fee9e996a2f3  book-state-backend-review-packet-v2.txt
4cd0629b72c56e37ded959483d14c53e448565cac41b116910d51ebce0ee7b46  backend adversarial review
```

The backend acceptance, including its 92 assertions/crash/two-handle/trigger
evidence, belongs to that independent review. This document neither repeats nor
extends its durability or schema claims.

## Blocking finding: close can revoke a different endpoint's binding

`close-state-session-and-revoke!` accepts `STORE`, `SESSION`, and `BINDING` as
three independent arguments (`book-state-backend-adapter.scm:149-155`). It first
closes `SESSION`, then calls `revoke-state-backend-binding!` with `BINDING`.
Neither it nor `assert-binding-agrees-with-grant!` checks that `BINDING` is the
exact binding retained by `SESSION`.

The latter check proves only that the supplied binding's handle, generation, and
access match its own retained backend grant (`lines 121-135`). That is useful,
but cannot establish the missing session-to-binding relation.

### Source-exact counterexample

I opened two trusted namespaces and created valid endpoint contexts A and B. A
loaded its absent value and staged one exact commit operation. I then called:

```scheme
(close-state-session-and-revoke! store session-a binding-b
                                 'mismatched-binding)
```

The observed result was:

```text
MISMATCHED-CLOSE close-result=revoked session-a=closing grant-a=active grant-b=revoked backend-result=1 stored="wrote-after-wrong-close" late-apply=state
```

Thus the helper:

1. returned successful `revoked`;
2. closed A's local model;
3. revoked unrelated endpoint B's backend grant;
4. left A's backend grant active; and
5. allowed A's already-emitted operation to commit after the helper returned.

Protocol V2 correctly rejected the late backend receipt, so no forged storage
acknowledgement was emitted. That does not undo the durable write or repair the
wrong grant revocation. The test uses only trusted typed values; no JSON field,
namespace ID, path, SQL, or sandbox capability is involved.

### Required correction

Before any local close or backend revocation, the adapter must establish by
record identity—not handle-string equality—that the revocation binding is the
exact binding retained by the supplied session. Prefer an API that derives the
binding from one adapter/session context rather than accepting two independently
pairable public arguments. If both arguments remain, a mismatch must fail before
closing either session or revoking either grant.

The corrected matched path should preserve the intended order:

1. stop endpoint input and close the exact local model so no late result can be
   accepted;
2. without the Book Session mutex, invoke owner-checked backend revocation for
   that exact retained binding; and
3. treat only the backend contract's successful revocation outcomes as helper
   success; surface a typed rejection explicitly rather than allowing callers to
   mistake an unrevoked grant for completion.

Required regression tests should include:

- valid session A plus valid binding B: fail before either endpoint changes;
- a malformed binding/grant metadata relation: no partial local close followed
  by silent missing revocation;
- a matched close followed by an operation that reaches the backend only after
  the helper returns: rejection and no write; and
- the existing matched commit-first case: a commit that already linearized may
  remain durable, but its result cannot be applied after local close.

The last two cases are deliberately distinct. Backend mutex ordering permits a
commit already ahead of revocation to win; it must not permit a never-started
operation to write after a supposedly successful matched revoke has returned.

## Accepted adapter control-flow findings

### Authority remains out of band

The adapter accepts only typed protocol operations. It never accepts JSON,
handle strings, owner identifiers, namespaces, SQLite paths, SQL, sockets, or a
raw registry. Reads call the backend with the exact owner object, opaque grant
record, and grant generation embedded by the accepted Protocol V2 model. Commits
add only the operation ID, expected version, and copied text from that typed
operation.

Those operation records are produced from the endpoint-retained binding after
wire handle/generation validation. Their constructors are not public. A
review-only private-constructor probe supplied a wrong owner with a real grant;
the backend returned typed `owner-mismatch` and the namespace remained absent.
This confirms that even a forged internal operation does not bypass the
backend's owner/grant validation before mutation. It does not make private
constructors or grants sandbox-visible.

Two namespaces remain selected by trusted `open-book-instance!` calls outside
the adapter. The operation carries the opaque grant that fixes its namespace;
there is no peer namespace selector to confuse A and B. The blocker above is a
trusted lifecycle API pairing error, not a wire authority escalation.

### Typed result mapping is narrow

Backend absent/value records map to exact typed read results; backend rejections
map to typed model rejections. `store-failed` is normalized to the finite
terminal `storage-failure` code rather than exposing backend worker state on the
wire. Unknown result types throw adapter errors.

Before creating a protocol commit receipt, the adapter checks all independently
available receipt facts against the exact typed operation:

- operation ID;
- expected state version;
- resulting version equals expected plus one; and
- UTF-8 text byte count.

Independent private-record probes confirmed that the exact tuple passes and
that changing any one of those four facts fails the agreement predicate. The
adapter then retains the exact pending operation record in the typed result;
Protocol V2 separately rejects wrong-operation and post-close completions.

The old real-backend functional run also exercised exact restart retry after a
lost acknowledgement and a stale/changed-payload no-write path. An old receipt
can map back to its original result version, while Protocol V2 keeps a newer
loaded local snapshot from rolling backward. Storage receipt, wire
`state-committed`, presentation, and paint remain separate facts.

### Operation-ID alignment and failure boundary

Each commit compares the SQLite-free wire predicate with the backend predicate
for that actual operation ID before any backend call, and compares all three
128-byte limits. The independently rerun test covered 16,384 ASCII pairs, all
4,096 allowed-character pairs, exact length boundaries, and Unicode/control
counterexamples. Protocol V2 already rejects invalid IDs before it can emit a
commit operation.

`book-state-operation-id-contract-aligned?` itself compares the three limits;
global grammar agreement remains source/hash-and-test evidence, while every
actual commit also compares both predicates for its concrete ID. It should not
be treated as a dynamic proof about arbitrary future predicate replacements.

No adapter source opens a database, evaluates SQL, handles a path, or catches
raw SQLite exceptions. Those responsibilities remain behind the typed backend
API. The adapter maps finite typed failures; it does not claim to repair or
reinterpret backend durability.

### Correct matched close/commit ordering

For a correctly paired session and binding, local-close-before-backend-revoke is
the right order: late protocol application is disabled before the potentially
blocking backend mutex call. Revocation-first backend linearization rejects the
operation. Commit-first linearization may persist, but its late result cannot
revive the model or produce an acknowledgement. The real-backend test covered
both sequential sides and confirmed the resulting stored values.

No Book Session delegate exists in this frozen unit, so the source cannot yet
prove that a future caller releases the Book Session mutex around backend I/O.
That remains a mandatory integration review condition, not a reason to move
mutex or I/O into this adapter.

## Independent host evidence

The packet's exact no-substitute adapter gate was rerun independently
against the immutable old backend snapshot. It passed **33 real-backend
assertions**, including save/close/reopen/load, restart retry, stale and changed
payload no-write, predicate alignment, and the two matched ordering cases. All
private SQLite roots were cleaned.

The additional adversarial program passed **12 review assertions** while
demonstrating the mismatch above and confirming wrong-owner no-write, all four
receipt comparisons, finite failure normalization, and post-close result
rejection.

The private evidence root is:

```text
/tmp/opencode/book-state-backend-adapter-independent-review-20260906
```

Its manifest and principal raw evidence hashes are:

```text
db51c068c700d635471bbf90f10347e6e7c7952aff561058d4c7ddebef89d7e3  independent-review-manifest.json
8f46ea7c06eef2264d889ba25f8938bff8838f95bc69b41086ae3fdd3eddf9c0  adapter-host-check.log
45235cb6775d0a5afac0f3e61609c4120ed3c1d8abf7362f9f1e0e2d9919a0cf  adapter-adversarial.log
d3d1489d1102321cb2dc3602a88e78e1756b48190bd869a6db84c246bde1abfb  adapter-adversarial.scm
```

No old backend crash suite or new backend schema/durability suite was rerun. The
separate adapter-to-backend-V2 proof now being prepared was not inspected. No
Book Session delegate, accepted core/UI/guest/outer source, QEMU, runsc, ARM,
image/kernel/package build, hardware, network, staging, commit, or push occurred.

## Focused next gate

The adapter owner should keep this source frozen as the failed baseline, then
prepare one narrow correction proving exact session/binding identity before
close/revoke. A focused independent recheck should replay the mismatch and the
matched revoke/commit cases.

Only after that source correction passes should the exact adapter be rebound to
accepted backend V2 source
`7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9`
and Protocol V2 source
`3e5567cad0f5c43f54a0b2abb6916dcbd3c1c7dbd922a6fb8642eb3d4c84e3cc`
with no ambient compiled-cache substitution. That rerun may establish adapter
acceptance. The private Book Session delegate remains a later, separately frozen
review unit, followed by the actual save/reopen and recovery join.

## Source-exact lifecycle correction recheck — 2026-09-06

### Disposition

**Accept adapter source
`349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769`
as the fixed backend-adapter input to the later private Book Session delegate
review.** The lifecycle-pairing blocker above is resolved, the accepted backend
V2 source was bound and exercised, and no further adapter blocker was found in
the finite recheck.

This also accepts Protocol V2 plus its one additive read-only pairing predicate
at source
`425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257`.
It does not accept or review the separately assigned Book Session
worker/delegate candidate and does not establish guest, QEMU, or reader
integration.

### Frozen packet and sources

The superseding mode-private packet was:

```text
/tmp/opencode/book-state-backend-adapter-v2-source-exact.P9rLiY
d54fb1533e08b933730e835fb98c2724f2e4e451b44e679c6fcfc9cbc48c7800  packet-manifest.json
```

The accepted source-specific inputs are:

| Input | SHA-256 |
|---|---|
| `book-state-protocol.scm` with opaque pairing predicate | `425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257` |
| `book-state-backend-adapter.scm` | `349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769` |
| `test-book-state-backend-adapter.scm` | `ac8ab91a86a9269ab789a5aeb0654948f5a736bfc4e13377180445763149258e` |
| `backend-adapter-v2-test-manifest.scm` | `19131a0e025fad63b4aeca638e8f27d4a0978b4d655b4370bf71009868b1ecf6` |
| `assert-book-state-adapter-v2-load.scm` | `34d2e10815fb44952ae806c8747e64cce28d30bca5b83050375a8ea422fd678f` |
| `assert-book-state-adapter-v2-ccache.scm` | `48aee5748ae32e2826e72d300aa3f105803b0d45713582a876e0482d21ce2793` |
| `run-book-state-backend-adapter-v2-tests.sh` | `e7f605d2939590c30025e8474d1597dd3d574ab541364ad77be624c3ca79fd2d` |
| accepted backend V2 `book-state.scm` | `7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9` |
| backend V2 immutable manifest | `6520e5ed592cbec37be4605544b7606387d8032335a474ce596a485c022f5426` |

The packet supersedes the reported earlier packet
`00107788d6242dcf3f9791615d7386f2f217a7183c3ca994274c6e6d096fccba`;
only the source-exact packet above is accepted.

### Patch provenance and Protocol V2 scope

I independently reversed both focused patches from the candidate sources. The
protocol reversal produced byte-identical accepted Protocol V2 source:

```text
3e5567cad0f5c43f54a0b2abb6916dcbd3c1c7dbd922a6fb8642eb3d4c84e3cc
```

The adapter reversal produced byte-identical blocked baseline:

```text
6c9206ad8ab4fe15a3954f3e92a3fcf9ded9bee07a53f1fb9dabbc420f01f08e
```

Both reverse applications were clean. The protocol delta exports only
`state-session-bound-to?`; the accepted seven messages, state phases,
transitions, backend-result rules, and no-read-ID decision are unchanged. The
adapter's existing public operation/revocation API remains unchanged.

### Exact opaque pairing

`state-session-bound-to?` returns true only when both arguments have the right
record types and the candidate binding is `eq?` to the opaque record retained by
the session. It returns only a boolean. It does not export the retained binding,
add a registry, compare handles structurally, expose mutation, or accept a
peer-supplied identity.

The corrected close helper now preflights, in order, the typed session, typed
binding, exact session/binding identity, typed backend store, and retained
binding/grant metadata before changing either side. A valid but unrelated
endpoint binding and a separately constructed equal-looking binding therefore
both fail before local close or backend revoke.

`revoke-state-backend-binding!` now treats only `revoked` and
`already-revoked` as successful completion. Any typed backend rejection becomes
an explicit adapter `revocation-failed` error rather than looking like a
completed close.

### Independent replay of the blocked counterexample

The independent replay used two real accepted-backend V2 namespaces and a
captured pending operation from endpoint A. It established:

1. the exact A binding matches;
2. a separate binding with the same owner, grant, handle, generation, and access
   does not match;
3. B's valid binding does not match A's session;
4. no `state-session-binding` accessor is exported;
5. the predicate checks mutate no lifecycle state;
6. closing A with B's binding returns `session-binding-mismatch` before either
   session or grant changes;
7. neither namespace is written by the rejected mismatch;
8. proper A close revokes A only;
9. A's captured operation first reaching the backend after that close returns
   typed `revoked` and writes nothing; and
10. B remains active until its own matched close.

The same replay preserved the other linearization side: an A operation that
already obtained its durable receipt before matched close remains stored, but
its receipt cannot be applied to the locally closed model. Thus local-first
close plus backend revoke still distinguishes commit-first from revoke-first
without widening the API or accepting a post-close acknowledgement.

The independent lifecycle oracle passed **19/19 checks**:

```text
LIFECYCLE-REPLAY checks=19 failures=0
```

### Accepted-backend V2 source and ccache binding

The exact runner checked the accepted backend review/packet/manifest identities,
then compiled each application module into one fresh private ccache. A separate
source-identity process loaded the five exact absolute application sources with
no non-store inherited application ccache. The functional process put only that
private ccache first and checked the accepted backend V2 schema identity before
running tests.

That independent run passed **42 real-backend assertions**: the retained 33
mapping/reopen/retry/conflict/linearization assertions plus nine lifecycle-
pairing assertions. It also retained the 16,384 ASCII-pair and 4,096 allowed-
pair predicate comparisons, zero compile warnings, and private database cleanup.

The old backend source `eeb572ef…` was not loaded and contributes no final join
evidence. Backend durability and BS1 acceptance remain owned by the separate
backend review at
`4cd0629b72c56e37ded959483d14c53e448565cac41b116910d51ebce0ee7b46`;
they were not re-audited here.

### Evidence and remaining boundary

The independent evidence root is:

```text
/tmp/opencode/book-state-backend-adapter-v2-independent-recheck-20260906
```

Key identities:

```text
e5c44b38be6aad54675f43488f2d9f37c98e0a4b40c79d8ef103921e17a55b9e  independent-recheck-manifest.json
c45798b03dcaf8558f935d95562a197801425e2d78cab4ae67d89ef0197ac7e3  adapter-v2-host-check.log
fa4135d0b9686b0f1563b9611433233b8b37d745d27051724601259e1966b714  lifecycle-replay.log
a40e59da94246bcb199153ad77f1dd7fd85555dcf75d53a295c386276e41a8ee  reverse-patch-report.txt
```

The next valid unit is the separately frozen private Book Session delegate using
these exact accepted adapter/protocol/backend identities. That review must prove
its own transition serialization, no Book Session mutex across backend I/O,
endpoint close/revoke invocation, output-queue behavior, and late-result
handling. This adapter acceptance does not pre-accept those facts.

No worker/delegate source was inspected, modified, or accepted. No QEMU, runsc,
ARM, guest, UI, outer runner, image/kernel/package build, hardware, network,
deployment, staging, commit, or push occurred.
