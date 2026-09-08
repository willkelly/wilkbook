# Book State reader join — independent adversarial review

Date: 2026-09-06

## Disposition

**Reject the frozen reader-join packet as the native persistent-note editor
gate.** Its stated twelve-lifecycle suite is source-authenticated and passes,
and the first-save/reopen, receipt-to-UI, paint, failure, and recovery evidence
is real within its narrow scenarios. However, the ordinary fixed books reuse a
durable operation ID after every process restart. A first changed save in the
same persistent namespace after reopening therefore fails instead of advancing
the note from version 1 to version 2. This is an immediate basic-editor failure,
not the accepted backend's eventual 64-receipt limit.

The exact independent counterexample was:

```text
save A -> fresh authority/book/KOReader load A
       -> fresh authority/book/KOReader edit+save B
       -> fresh authority/book/KOReader load

wanted: B, version 2, a new operation ID
actual: save lifecycle exits 1; final load is A, version 1
```

There is a second exact-source issue in the outer owner: it authenticates the
live `process-identity.sh`, but later sources that same mutable path from its
exit trap rather than a read-only copied closure. That helper remains exposed to
a check/use race and does not meet the packet's otherwise strong source-closure
standard.

This disposition does **not** reopen or reject the accepted Backend V2,
Protocol V2, corrected adapter, BSD-1 delegate, completion observer, native-v2,
or KOReader UI packet. The blocker is in this join's operation-ID strategy; the
runner-helper issue is in this packet's evidence owner. It also does not alter
any gVisor, Systrap, kernel, language-closure, QEMU, guest, or release decision.

## Frozen boundary

I reviewed the final immutable join source and evidence snapshots, not mutable
join implementation roots or failed-run source trees:

```text
pinenote/tools/book-state-reader-join/build/artifacts/
  book-state-reader-join-sources-20260906-v1/
pinenote/tools/book-state-reader-join/build/artifacts/
  book-state-reader-join-evidence-20260906-v1/
```

The identities reproduced during review were:

| Input or record | SHA-256 |
|---|---|
| review packet | `8d4982ebf9b7c7c1b4893037364557702f239ad2e2c6fa0ef3f7b976b15c560d` |
| source `MANIFEST.sha256` | `8560bf282b4ac30a107c5804684774a5c2847bbe92aa18c732b07ff96fc95b5e` |
| source `SOURCE-IDENTITIES.sha256` | `b033ee2cd92aa1a34ccf6f4104f721a512cf6fa7014aa48d1c43f125944b8660` |
| source `PACKET-ROSTER.txt` | `d2034eedb442945f76a3e82beef05c618c60e7b1b44c69a11e3b31e9fc9a29c3` |
| evidence `EVIDENCE.sha256` | `370ef1d5cae4e40b8cc395012c6f1d852fc691888b6bffb7df5a279a9dcb32dd` |
| evidence `PACKET-ROSTER.txt` | `96f0f3ccd1d7758db329ef0272de257211ede59817eeb19020cc40dd7b7554ec` |
| frozen host log | `77d444bb0bb4078412187e10fcac0b137001f5fb3278fa0fbc57c94d300474a8` |
| frozen SQLite database | `25a1bcda6d232b28938c8c0b454cbc715b410293b2ea03d1cdb7c806712e5dae` |
| active outer runner | `838882f28935d202d2df7ab9c07c8b893d2c704da337604ac654677c04cefcd5` |
| active Makefile | `e201f3fb1a70eaaf8303874b80796e2e855a26545ac42fe14869e2a0909d4188` |
| pinned `channels.scm` | `661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1` |

All 23 source-manifest entries and all 73 evidence-manifest entries passed
`sha256sum --check --strict`. The source packet is based on repository commit
`549dded816e5f73d2c11557ffcd3130a018b82a8`.

The accepted prerequisites matched the identities recorded by the packet:

- native-v2 review `928885be26b58469c9012848260035428ac2eb1494f47bc9a90f940df4777c51`;
- native-v2 source manifest `261b5f018af7c00afe8b3b8db81c42e14bd4efde85ac85a465a459f2ce89013f`;
- KOReader UI packet `a77c989accef03d2a4698a6483b0d8968b8712dacbb097f69eaf4b5095f7d9ab`;
- KOReader UI review `56a23f3acc1b2010a89ea8f00134687a0d07f290572f218477361cf0b6222301`;
- completion observer candidate `0342e87c665626b01c5318d125d7f96a152e16ebe25cc310499ca92698002c8f`;
- completion observer packet `e45002e153ce6ae94cd2ddfff2c1a3a9551ce0a0b9046c6cee9c7a08bea50d36`;
- completion observer review `e4f1ae002ba07268c825ddc24b02477ba259a16226ca5a1e42344a6fdd0286a5`;
  and
- the observer review's literal, honestly retained evidence attestation
  `90362b51099718e710c2a4c42bf6d07f173b4136d980d5d6db536f18e5e68bb1`.

The absent historical observer `EVIDENCE.sha256` was not recreated.

## Independent method

I first traced the exact frozen authority, bridge, fixed books, source gates,
launchers, and external oracle. At the explicit join points I inspected the
read-only accepted observer/native/UI copies used by the authenticated private
closure; I did not re-audit their already accepted internal behavior.

I then ran the provided bounded command exactly once:

```sh
make -C pinenote/tools/book-state-reader-join check
```

It passed in 25 seconds. The retained run root is:

```text
pinenote/tools/book-state-reader-join/build/runs/20260906T210234Z-3048979
8ff5250db1833a9ace7ccedcd72c098b1cae97c6a4bc66f17318a0a32f4671d3  host.log
```

That replay authenticated the private closure before compilation, rejected all
six supplied source mutations, compiled without warnings, resolved all eleven
project Scheme interfaces to the private cache, used Python `-I -S`, ran the
exact KOReader v2026.03 store output, and passed its twelve fresh process
lifecycles.

Reviewer-owned finite counterexamples are retained under:

```text
/tmp/opencode/book-state-reader-join-independent-review-20260906
03f1723084c3bc78d580ee13c3fa808a0582a320c2035c477dd8c7f0ef2beca3  EVIDENCE.sha256
```

Important records are:

| Record | SHA-256 |
|---|---|
| restart/save counterexample source | `d4fafce10b9b0b504d539c749203194e38e0c4cc6728a2c3c5c21a10b68635a9` |
| restart/save runner | `370b03b21eaab3a46d33d6051c2785830a0aada4190156a83931724aca8a30af` |
| restart/save final log | `160641fe368cef6ee9a45bc5c531befa8a49f04a6b0e05a30c8e4d7248a25ac1` |
| restart/save result | `281e38bb845416c44716879fd694289ff57f6285727617855d12707c1dcc75f7` |
| database counterexample source | `25341f9648099c27e4724207f92625baa15eff1ecbd669f54fcadd3684bc2999` |
| database counterexample runner | `a29d10f987c7bed2ef5012f8ac8cc64add9f7d2b617d33520210638de88e492e` |
| database final log | `1755c02df6f4a4836bd191767cfbf9f76b5d538602671e2f2b7bf82d65db807f` |
| database result | `23d18bb55d0abd1d3c801e970d9a93a9ef85b872dc1e5082566ef01fbb7c2691` |

The reviewer attempt ledger records one assertion that was initially too
specific about how the accepted state FSM exposes `operation-conflict`, one
pre-execution existing-directory mistake, and one copied-database mode mistake.
The failed diagnostics were retained rather than overwritten. The corrected
runs are the records above.

## RJ-1 — operation IDs collide on the first changed save after restart

**Severity: blocking for the native persistent-note editor gate.**

The collision follows directly from the frozen joins:

1. Every accepted fresh Book Session starts at surface generation `1` and
   sequence `0` (`observer-v1/candidate/book-session.scm:628-633`).
2. `host-action!` increments that per-session sequence, so the first Save in
   every fresh authority lifetime has generation `1`, sequence `1`
   (`candidate/book-session.scm:1618-1655`). No database or book-instance value
   seeds either counter.
3. The Guile book derives its durable ID only as
   `note_s<SURFACE_GENERATION>_q<SEQUENCE>`
   (`joined-note-book.scm:104-108`). The Python book does exactly the same
   (`joined_note_book.py:126-127`). The bridge independently predicts and binds
   that same ID (`book-state-reader-bridge.scm:278-286`).
4. The backend keys receipts by `(namespace_id, operation_id)`. If a prior ID
   exists, only identical expected version/text/byte count is an idempotent
   retry; changed content or version returns `operation-conflict`
   (`book-state.scm:711-778`).
5. The accepted state FSM maps stale-version to a typed conflict and three
   selected terminal codes to `state-commit-failed`; another backend rejection,
   including `operation-conflict`, closes the state session
   (`book-state-protocol.scm:1011-1052`). The fixed book consequently sees EOF.

The supplied suite does not cross this case. For each ordinary Guile/Python
namespace it performs one save and then one read-only reopen
(`test_reader_join.py:454-465`). Its read-only retry creates `q1` and `q2`, but
both fail without creating a receipt. Every successful frozen namespace has
only `note_s1_q1`, which is evidence of the reset rather than evidence of
cross-restart uniqueness.

### Executed reproduction

The reviewer counterexample used the authenticated private source closure and
the exact pinned Guix/KOReader environment. It retained four fresh identities
for each role:

| Phase | Authority PID/start | Book PID/start | KOReader PID/start |
|---|---|---|---|
| save A | `3057548/92652420` | `3057567/92652426` | `3057565/92652425` |
| fresh load A | `3057665/92652547` | `3057684/92652552` | `3057682/92652551` |
| fresh changed save B | `3057723/92652598` | `3057742/92652603` | `3057740/92652603` |
| fresh final load | `3057779/92652670` | `3057798/92652676` | `3057796/92652675` |

All twelve identities were distinct and absent at terminal inspection. The
observed sequence was:

- save A committed as `note_s1_q1`, version 1;
- the first fresh lifecycle loaded and painted A at version 1;
- the fresh changed-save lifecycle loaded version 1, performed a genuine widget
  edit, invoked generated Save, emitted the private submit, and painted Dirty
  then Pending;
- its fixed book attempted the restarted first-action ID `note_s1_q1` with
  expected version 1 and text B;
- the backend's prior receipt had expected version 0 and text A, so the
  `operation-conflict` branch closed the state session;
- the book exited 1 with `unexpected commit response (#f)` and the authority
  exited 1 rather than producing a result; and
- the final fresh lifecycle loaded and painted A, still version 1.

The failed lifecycle's KOReader log contains no Saved paint. It records the
real loaded-value, dirty, submit, and pending sequence, followed by teardown:

```text
BOOK_STATE_READER: submit:generation=1:text-bytes=43
BOOK_STATE_READER_UI_AUDIT: paintTo-state:generation=1:state=pending:text-bytes=43
BOOK_STATE_READER: status-painted:generation=1:state=pending
BOOK_STATE_READER: closed:generation=1
BOOK_STATE_READER: FAIL:private control write failed
```

Terminal SQLite inspection found `integrity_check = ok`, exactly one receipt
(`note_s1_q1`, expected 0, A, resulting version 1), and the durable state row
still A/version 1. The failure is fail-closed—there is no false Saved state or
silent B commit—but the editor cannot perform its basic second persistent edit.

Both fixed languages have the same derivation. The Guile execution is therefore
a concrete reproduction of a shared strategy defect, not a Guile-only parser
problem.

### Required correction

A successor must give each ordinary book a book-owned operation identity that
does not collide across fresh authority/session lifetimes in the same durable
namespace, while preserving the accepted exact-retry identity rule. Neither UI
nor the outer authority may select the operation ID, and the wire grammar must
remain `[A-Za-z0-9_-]{1,128}`.

The successor gate must include, for at least the Guile namespace and preferably
both fixed languages, this exact topology:

```text
save A -> all three processes exit
fresh all three load A -> edit/save B -> all three exit
fresh all three load B
```

It must prove distinct operation IDs, version 2, exact B in SQLite and the fresh
UI paint, and exact retry retaining the original operation identity. Repairing
this does not require weakening the accepted backend's operation-conflict rule.
A changed source or test requires a new frozen packet and identities.

## RJ-2 — cleanup helper is checked, then sourced from a mutable path

**Severity: blocking for strict exact-source execution evidence.**

The outer runner sets:

```text
process_identity=$repo/pinenote/tools/book-reader/process-identity.sh
```

It verifies that live file against
`97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354`
before copying and running the private closure (`run-tests.sh:79-96`). But the
exit trap later executes:

```sh
. "$process_identity"
```

from the original mutable repository path (`run-tests.sh:43-55`). The helper is
not copied into `source-closure`, made mode 0400, or reauthenticated immediately
before sourcing. A concurrent replacement between the initial hash and the
trap can therefore execute unlisted shell code during cleanup and can affect
cleanup, evidence, or final status.

The file still had the expected hash before and after this review, and no such
replacement was observed in the passing run. That is not a proof that the
public command closes the race. The correction is mechanical: copy the
authenticated helper into the private read-only closure before candidate
execution and source only that copy (or inline and manifest the required
functions). The source gate should reject additions and omissions there just as
it does for Scheme, Python, Lua, and codec sources.

The active outer runner is itself intentionally outside the self-referential
snapshot and is identified by hash in the review packet. That is acceptable as
a review boundary only when the caller authenticates the runner; the public
command cannot establish its own identity. The mutable helper is different: it
is a second executable file used later by that runner and can be sealed.

## What the frozen packet does establish

The blocking findings should not erase real narrower results. For the exact
hashes above, the source and one-time runtime review support all of the
following:

- The trusted authority fixes language/profile to book revision, instance ID,
  access, and exact book implementation before opening an endpoint. Wire
  handles do not choose a namespace, path, or book identity.
- Guile and Python books originate reads and commits on their connected Book
  Protocol peer. The outer authority does not call the backend as a book.
- Each book executes with only stdio and its connected socket at FD 3; it gets
  no state root, namespace, expected value, database path, or SQLite module.
  Python uses its exact-path launcher under `-I -S` and verifies accepted codec
  hash `4e2423e0…` before import.
- The successful UI chain is genuine generated Save -> private submit ->
  `host-action!` -> book `state-commit` -> accepted adapter/SQLite transaction
  -> endpoint-owned typed completion -> exact pending correlation ->
  `commit-ok` -> Saved paint. A separate `present-saved` action and presentation
  follow that receipt.
- The paint marker wraps the exact retained `InputDialog:paintTo`, invokes the
  inherited implementation first, and records only a matching topmost widget.
- A forged early presentation produced neither a storage completion nor Saved;
  a durable mismatched-text commit was rejected as the pending draft's receipt;
  and a delayed receipt after a real newer widget edit left the new draft Dirty.
- The read-only case retained the exact draft and made a fresh second
  submission. Pending Save was disabled and duplicate dispatch remained
  suppressed.
- The frozen evidence records 12 authority, 12 book, and 12 KOReader
  PID/start-time identities—fresh processes, not twelve widgets or five UI
  generations. Endpoint/grant release preceded UI finish, children exited or
  were identity-safely reaped, and captures remained bounded.
- The final frozen database has seven fixed namespaces, five receipts,
  `integrity_check = ok`, no foreign-key violations, SQL NULL for absent state,
  and non-NULL empty text for present-empty state.

Independent recovery counterexamples additionally copied only reviewer-owned
databases and then ran fresh exact authority/book/KOReader lifecycles:

| Database condition | Fresh UI load |
|---|---|
| deleted | absent, version 0, empty text |
| state row tampered | exact injected text, version 1 |
| swapped with the valid frozen suite DB | exact frozen multilingual Guile text, version 1 |

All three disagreed with the externally expected A. Their nine
authority/book/KOReader PID/start-time identities were distinct and absent
afterward. This confirms that recovery reaches Lua from SQLite through the
book-issued `state-read` path; it is not supplied by argv, environment, fixture
files, authority memory, console markers, or the Python oracle.

These are supported findings, not acceptance of the broken repeated-edit
topology or the wider release boundary.

## Present-empty scope and clear-and-save gap

The packet is honest at review-packet lines 177-180 and
`CONTRACT.md:71-82`: its present-empty scenario is **storage-only**. A fixed
book commits empty text after the authority sends the nonempty `EMPTY-SEED`
marker. A fresh lifecycle proves `present=true`, version 1, text `""` reaches
the real UI and paints the distinct loaded-value state. It does not invoke the
UI Save callback for empty text and is not evidence of a user clearing a note.

This is more than an unexecuted permutation. The accepted UI codec admits empty
ordinary text and can submit a cleared widget, but accepted `host-action!`
rejects every empty action text (`candidate/book-session.scm:497-505,
1618-1626`). The current join would therefore tear down rather than durably
save a user-cleared note. No final report should say that empty UI Save was
proved.

For a deliberately narrow **nonempty, first-save-only demonstration**, this was
already an explicit non-claim rather than packet misrepresentation. For a
usable small persistent-text editor, clear-and-save is missing product behavior
and needs either an actual joined UI implementation/test or an explicit product
decision that empty drafts cannot be saved. The backend's accepted
absent/present-empty distinction should not be weakened to hide the gap.

## Reproducibility concern: live review documents

The source gate copies the current append-only acceptance reviews from
`doc/reviews/` and then requires literal hashes in the private closure
(`run-tests.sh:103-112`, `verify-source-closure.sh:116-135`). This authenticated
the exact provenance used by both frozen and reviewer runs. But an honest later
append to one of those live review documents will make the old packet's public
command fail even when every executable source is unchanged.

That is a reproducibility concern, not a core authority/correlation defect.
Future packets should include frozen copies of accepted review records or bind a
stable immutable review artifact instead of making mutable live append-only
documents part of an old execution gate.

## Scope and remaining gates

This review establishes only native SDL-offscreen host behavior for the exact
sources and counterexamples identified above. It does not establish sandbox,
QEMU, runsc, Systrap, ARM64, image, kernel, named virtio-port, outer guardian,
hostile-book isolation, output import, production cgroups/resources, physical
power-loss durability, panel paint, operator workflow, device behavior, or
release acceptance.

No QEMU, runsc, ARM, image/package/kernel build, device, SSH, UART, mount,
network, staging, commit, push, PR, merge, fetch, or rebase occurred. No
implementation file, frozen packet, accepted UI, or prerequisite was edited.
The only non-ignored repository path added or edited by this review is this
document; the authorized gate retained its normal ignored `build/runs/`
artifacts.

## V2 successor recheck — accepted

**Disposition (2026-09-06): accept the exact reader-join v2 successor at the
native persistent-note editor gate.** The v1 packet and the blocking findings
above remain immutable history; they are not retroactively accepted. V2 fixes
RJ-1 and RJ-2, supplies the previously missing real clear-and-save path, and
does not weaken the accepted backend's conflict semantics.

This acceptance means that the exact frozen Guile/Python Book Session,
KOReader, completion-observer successor, and SQLite join is fit for the native
SDL-offscreen persistent-note demonstration. It is not acceptance of a
shipping integration or any QEMU/gVisor/ARM/device boundary.

### V2 frozen boundary

I authenticated these successor identities:

| Input or record | SHA-256 |
|---|---|
| v2 review packet | `87ae3ac25265f2d15fa125e7f1fb2522d481f0cbaeb2995a3ad9fe88f4e716b2` |
| aggregate `book-state-reader-join-evidence-v2.sha256` | `250199d5bcd97dccffaf28b8adc236c00e6cc6975ad432da773a3610f7fafc2b` |
| source `MANIFEST.sha256` | `6fcbb5b7b8766f5cbc8802ad84c4b28d500c5941b0f2dc6f871d4ec8976c82e0` |
| source `SOURCE-IDENTITIES.sha256` | `a40b9bee10fd78055a27e68e2f4acf091e5d4250d1ce697a967001d0cdbc9282` |
| source `PACKET-ROSTER.txt` | `f08f5ef425eb775d1ed18f972b204f5504ee98369b5ed27c7c96820cfb4c548d` |
| evidence `EVIDENCE.sha256` | `a98b186807627e8687075420875137e1b5beb4a4d6011a5628edc54d190c419c` |
| evidence `PACKET-ROSTER.txt` | `9923aa801f896473cefcca03fa016e754ac8cc0f8fda620d6bbd8362814c419d` |
| active outer runner | `64bc7b1d6d22af0ba688a3443988086bf632173647325659e2789ba064c201bb` |
| active Makefile | `e201f3fb1a70eaaf8303874b80796e2e855a26545ac42fe14869e2a0909d4188` |

The complete 38-file source roster and 121-file evidence roster matched their
frozen rosters, all listed hashes passed `sha256sum --check --strict`, and all
packet directories/files had the claimed `0500`/`0400` modes. The aggregate
digest authenticated the packet, both manifests and rosters, canonical evidence
copies, active runner, and Makefile. The separately retained first v2 sealing
attempt remains identified as `26c08925…` / `b0c664a7…`; it was not substituted
for the corrected evidence packet. The v1 packet/source/evidence identities
remain `8d4982eb…`, `8560bf28…`, and `370ef1d5…`, respectively, and its failed
attempt records remain present.

The successor carries immutable copies of the prerequisite reviews. It no
longer reads mutable live review documents during execution, so the v1
reproducibility concern at lines 358–370 is also closed for this packet. The
historically absent observer `EVIDENCE.sha256` was not recreated; the exact
`90362b…` attestation remains a literal in the frozen accepted review copy.

### Independent execution and evidence

I ran the provided bounded command exactly once for this successor:

```sh
make -C pinenote/tools/book-state-reader-join check
```

It passed in 38 seconds and retained:

```text
pinenote/tools/book-state-reader-join/build/runs/20260906T215919Z-3153463
af6c278b681b5d2eeef9ee4cec48b0f2b13cae30155468b8b6bdcfb356b7cc99  host.log
92925dc7e7fdfed5e06b9864e014119db77a0043718bf2973020a1b177605062  suite/joined-evidence.json
a2ce8b8dd648653fa887a0d4e3e042d2916f9bd367dd19dec3b93c5b93794574  suite/state/book-state-v1.sqlite
```

The run authenticated and copied the complete private source closure before
project execution, rejected all eight supplied source/shadow mutations,
compiled without warnings, resolved all eleven project Scheme modules to the
private source/cache, used Python `-I -S`, and ran exact KOReader
`/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03`.
The unchanged 227 Book Session, 61 state-integration, and 37 completion-observer
tests passed, as did the seven new state-text policy tests.

I then independently joined every per-lifecycle result and KOReader log to a
read-only query of the quiescent run database rather than trusting the suite's
summary markers. Reviewer-owned evidence is retained at:

```text
/tmp/opencode/book-state-reader-join-v2-independent-review-20260906
f0128637886e5b0f73f9a9a1081391218fe3b22c33c746bce3f3367631bcb4d5  EVIDENCE.sha256
```

That manifest binds the independent run audit, helper check/use counterexample,
focused policy source/log, static audit, and reviewer-attempt ledger. The
reviewer ledger records two transcript/setup assertion mistakes, one ambient
Guile path omission, and one omitted test import. None changed a repository or
frozen source. The one failed policy attempt that reached candidate checks is
retained with its backtrace; the corrected finite policy run passed nine
assertions.

### RJ-1 closed — restart-safe book operation identity

The Guile and Python books now derive:

```text
note_<surface handle>_s<surface generation>_q<action sequence>
```

The surface handle is a fresh accepted strong-random Book Session value created
by trusted host construction and delivered in the initialize envelope
(`empty-action-successor/book-session.scm:125-126,639-658`). The fixed book,
not the UI or runner, constructs the operation ID
(`joined-note-book.scm:119-130`, `joined_note_book.py:132-139`). The bridge
independently predicts the same ID only to bind a pending UI action to its typed
completion (`book-state-reader-bridge.scm:279-289`); it does not send the ID to
the book.

All observed IDs matched `[A-Za-z0-9_-]{1,128}`. Namespace, path, book identity,
access, owner, and grant authority remain in the retained endpoint/backend
binding; neither a surface handle nor operation ID selects them. A malicious
book can choose a bad ID only within its already granted namespace and thereby
fail its own operation. The relevant freshness claim is collision resistance
for the fixed books, supplied by the existing strong random-token generator,
not authority encoded in the wire string.

The exact rejected-v1 topology now succeeds in both languages, extended by one
additional changed save:

| Language | Same durable namespace | Fresh-save versions | Distinct operation IDs |
|---|---|---|---|
| Guile | `reader-note/guile@1` / `persistent-note-guile` | `1 → 2 → 3` | `note_surface_-4UhO7NrZLLoHxybdl5RIBP6_s1_q1`, `note_surface_lrKhLlkBM_PB0A68MgCMvMJ__s1_q1`, `note_surface_w-h8ObP0makjjAFMv3VqW4yc_s1_q1` |
| Python | `reader-note/python@1` / `persistent-note-python` | `1 → 2 → 3` | `note_surface_QgiMOJIPSZHQmgCRU4KrWWcr_s1_q1`, `note_surface_2VJwgpjbUbMG2xcaJxGvqZAU_s1_q1`, `note_surface_r0oj8mYGNpmlccCMWuXmty5q_s1_q1` |

Each B lifecycle used fresh authority/book/KOReader/session/surface/grant
identities, first loaded and painted A/version 1, then saved exact B/version 2.
Each C lifecycle freshly loaded B/version 2 and saved exact C/version 3. A final
fresh lifecycle loaded and painted exact C/version 3. The database contains
three receipts under each unchanged namespace with expected/resulting versions
`0/1`, `1/2`, and `2/3` and the exact multilingual text. The fact that every
first action is still local `s1_q1` no longer causes reuse because its fresh
strong-random surface component differs.

Retry semantics are separately correct. One book internally resent the exact
operation
`note_surface_5Wp4SWfvB9GEMmqxz7vTnWcv_s1_q1`, retaining expected version 0
and all 55 text bytes. Both typed completions returned the same version-1
receipt; dispatch reported the retry as cached, SQLite contained one receipt,
and state advanced only once. Conversely, the two real UI Save callbacks in the
read-only case were distinct new intents with `q1` and `q2` IDs. No retry path
regenerates an identity, and no new intent reuses one.

### RJ-2 closed — actual private helper source

`process-identity.sh` is now a source-profiled file in the frozen join packet at
`97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354`.
The outer runner authenticates the source packet, copies it into its private
closure, seals files `0400`, verifies the complete closure, hashes the private
helper, and then executes the literal source operation:

```sh
. "$private_process_identity"
```

The exit trap calls the resulting in-memory `owned_process_terminate_record`
function and never rereads either a repository helper or closure source path
(`run-tests.sh:43-57,77-125`). The inner consumer likewise sources its exact
private helper; the authority and Python fork/process helpers are themselves in
authenticated source files rather than inferred from a hash-list claim.

In an independent `/tmp/opencode` check/use counterexample, I copied and
authenticated the `97ef8053…` helper privately, replaced the external source
copy with executable canary code, and then sourced the private copy. Its process
function ran and the external canary remained absent. A separately changed
private copy no longer matched the literal identity and was not sourced. This
directly closes the mutable-repository-helper race identified in v1.

### New state-text policy and actual empty UI save accepted narrowly

The empty-action change is **not** covered by the old observer `0342e87c…`
acceptance. The exact successor identities accepted at this join are:

| Source | SHA-256 |
|---|---|
| candidate `empty-action-successor/book-session.scm` | `a6d904a0bc30237de4dc1ccc0e61e955e4def8e10037478505a33a5d15a934e7` |
| patch over observer `0342e87c…` | `cbfe3b42d077b7fcfa2d44bb2f64fed5801131249375f062af160adcc9e43d57` |
| focused seven-test policy regression | `ed4b3f96da86dbca1a0d15e141c2ff9669a221db43da680ba5be140e6feb404e` |

I independently applied the patch to accepted observer candidate `0342e87c…`;
the result byte-compared equal and hashed to `a6d904a0…`. The delta adds one
trusted constructor and one host property. Existing constructors retain
nonempty actions and the 2,048-byte action bound. Only explicit
`make-book-session-host-with-state-text-observer` construction permits the
Book State text range of 0 through 4,096 UTF-8 bytes. `host-action!` and
per-endpoint peer presentation decode consult that same property before
dispatch. There is no sentinel/prefix, lower limit, caller-selected bound,
wire-schema addition, generic RPC registry, or accepted worker/adapter/backend/UI
change.

The additional reviewer policy run established at runtime that:

- ordinary endpoints reject empty `save-note` and enable-looking action names;
- a peer-added policy flag is rejected as an unknown exact-schema member;
- an existing ordinary pending action cannot be used to present empty text;
- a peer-added presentation flag is likewise rejected; and
- an explicitly constructed state-text endpoint accepts exact empty action and
  matching presentation, accepts 4,096 bytes, and rejects 4,097 bytes.

The joined clear path is now real UI evidence, not the v1 storage-only case. A
fresh accepted `InputDialog` loaded the nonempty version-1 note, received an
actual clear edit, and invoked its real Save callback. Its exact log then
recorded Dirty(0), submit(0), Pending(0), inherited topmost Saved paint(0), and
separate presentation paint(0). The book issued an empty `state-commit`; the
accepted adapter/backend stored a version-2 zero-byte receipt; only the matching
typed completion caused `commit-ok` and Saved. A separate fresh lifecycle loaded
`present=true`, version 2, text `""`. Absent remains separately proved as
`present=false`, version 0, text `""`.

Two real read-only Save callbacks retained and resubmitted the exact blank
draft, received distinct typed read-only failures, painted Failed twice and
never Saved, and left SQLite at the original nonempty version 1. An exact 4,096
non-NUL-byte UI edit traversed submit, book commit, receipt, Saved paint,
presentation, SQLite, and fresh reopen without a sentinel or lost byte. Its text
SHA-256 is `a2e659dacb4691e887ac0139f8893d04764ee197d70fb73d3190d56113d18e3e`.
The inherited delayed-edit, forged-presentation, and mismatched-commit cases
still produced no false Saved paint.

### Terminal process, database, and scope result

The 22 lifecycles supplied 66 globally distinct authority/book/KOReader
PID/start-time identities. Independent `/proc` inspection found none of those
exact identities alive afterward. All children exited cleanly, endpoint/grant
release preceded UI finish, and authority/book/reader logs remained below the
128 KiB fixture bound.

Independent immutable read-only SQLite queries found nine namespaces, thirteen
distinct receipts, `integrity_check = ok`, zero foreign-key violations, and no
journal/WAL/SHM sidecar. They confirmed Guile/Python versions 3, present-empty
version 2, unchanged read-only version 1, exact 4,096-byte state, and one durable
row for the same-operation retry.

No concrete native reader-join defect remains within this frozen v2 boundary.
The native persistent-note demonstration may proceed on these exact identities.
QEMU guest/outer joining, gVisor/Systrap execution, ARM64 behavior, image and
kernel acceptance, named virtio-port discovery, hostile-book isolation, output
import, production resources, physical durability, panel/device behavior,
deployment, and release acceptance remain separate future gates.

No QEMU, runsc, ARM, image/package/kernel build, device, SSH, UART, mount,
network, staging, commit, push, PR, merge, fetch, or rebase occurred. No
implementation, frozen packet, accepted UI, or prerequisite was edited. This
append is the only repository-path change made by the v2 recheck; the authorized
run retained only its normal ignored `build/runs/` artifacts.
