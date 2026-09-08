# Book State native persistence integration — adversarial review

Date: 2026-09-06

## Disposition

**Blocked as an exact-source executable-evidence packet.** The narrow native
join worked under an independently assembled, source-only execution of the
accepted component hashes, and no join-logic defect was found. However, v1's
gate does not bind all code it executes. In particular, it neither authenticates
the new integration sources before execution nor freezes/authenticates the
Python Book Protocol codec. An unlisted `book_protocol.py` placed beside the
fixture was loaded and the normal native suite still passed. **NI-1** therefore
prevents the supplied host log from proving that the frozen source packet was
what ran.

The packet's “lost-ack retry” label also exceeds its execution: both first-phase
books consume and validate `state-committed` and present its receipt before the
retry authority is started. **NI-2** does not identify a defect in receipt
replay, but the exact v1 evidence proves acknowledged replay, not one continuous
drop-before-ack/restart/retry scenario.

This verdict does not reopen the accepted backend, adapter, protocol, Book
Session, or BSD-1 reviews. It does not depend on the separately developing
completion-observer candidate. The observer remains the known future reader/UI
seam described by the candidate contract, not a blocker for this native gate.

## Frozen review boundary

The supplied identities matched:

```text
review packet
02bd736c7dd6954837ab1053b2d91692d60a723a4ede5fb80499ce2d06bac777

source snapshot MANIFEST.sha256
42053ee2907648aac4334b75bf26cc19c63f11984128705963aeae43bcdd9ffe

supplied host log
23392544b6a1339b3548a19247ad1d74eec63fb7fb8c975cc1e0f96b97a2724d

external bounded-evidence MANIFEST.sha256
167f7b6ca322f269b644e642098b5c476967d7f02964f4d9267d5497cbb25f58

new-source identity manifest
2243869939a8a04c47047e3a1c26cf367feba4e51bcd19703c7bfd59b37d65a5
```

All 50 entries in the source snapshot manifest and all five entries in the
external evidence manifest passed `sha256sum -c`. The external packet, host log,
source-identity manifest, and snapshot manifest were byte-identical to their
named repository copies. Snapshot files were regular, single-link, mode-0400
files except the mode-0500 launcher; no symlink entered the frozen tree.

Principal new source identities were:

```text
book-state-integration.scm  742fd84990597124d451b85a8b703c784f73b0bbf3d100f99268c32e0e5826d7
native-authority.scm        99b57f3a123782c9c8d64907db95dbb46a9b7b173c27aaed6b7d67a990df56f5
fixture-book.scm            e7c65713844f6bec629ece02f5cedf1519b746674f318edc95a0f31db0235431
fixture_book.py             9839ea6a7e1bf290669932692cb87bea495514f3e4cb8c7e7e7b97a39f901ee8
test-native-factory.scm     6d9b0f46e927e2a17683afc3627ab209e746a0ceb229d7c0797b871145a9bb30
test_native_restart.py      68761d514ad587797dea8208d7d02026e590d0c631ff1d3c41fc6c270a4dc27e
run-host-tests.sh           786833331f2d45030731c3bb8a352d01f427639cdc54e5030f3be1dd5f5c4979
CONTRACT.md                 c8fb471c30d34be50c85899d60cf68536a365026e3ad054f8e686149c2fc3410
```

The frozen accepted inputs matched the separately reviewed identities:

```text
Book State backend         7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9
schema v1                  70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb
state protocol             425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257
backend adapter            349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769
Book Session BSD-1 core    f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301
state delegate             eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6
Guile Book Protocol        91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44
blocking I/O               543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd
Python Book Protocol       4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735
```

The last two identities are important to NI-1: the snapshot contains the
blocking-I/O source but the v1 runner does not compare the live copy it uses;
the snapshot does not contain `book_protocol.py` at all.

## Narrow source audit

The reviewed integration module has the intended authority shape:

1. `open-native-book-state-runtime` opens one accepted Book State store at a
   trusted root.
2. `open-native-book-instance-host!` resolves the trusted revision/instance
   namespace before creating a Book Session host.
3. Its private factory captures only that store, namespace, and access.
4. `OPEN-BINDING` receives Book Session's fresh opaque owner, issues a backend
   grant for the captured namespace, and returns the accepted typed binding.
5. `RUN-OPERATION` passes the accepted typed operation to
   `run-state-backend-operation`.
6. `REVOKE-BINDING` passes only the retained exact binding to the accepted
   adapter's revoke path.

The module exports no store, namespace, path, grant, SQL object, or callback
registry. Book-controlled frames contain no revision, instance, namespace,
language, component, path, or SQL selection. The two fixture namespaces are
fixed literals in the trusted authority.

The executable path is genuinely the Book Session path, not an outer shortcut:

```text
trusted host-action!
  -> child-owned connected FD 0
  -> child state-read/state-commit frame
  -> Book Session input authority
  -> typed delegate worker
  -> accepted adapter
  -> accepted SQLite backend
  -> typed state response
  -> Book Session output queue
  -> child FD 0
```

`native-authority.scm` contains no call to the backend, adapter, SQLite, grant
issuer, or direct commit/read API. It only creates the trusted integration host,
queues `initialize`, `state-ready`, and fixed `host-action!` values, pumps the
endpoint, and classifies delegate scheduling values separately from
`<presented-text>`. The Guile and Python books each send their own `state-read`
and `state-commit` frames and validate the exact typed responses.

The outer result's receipt string remains only a book presentation claim. The
test book first validates the typed response, and the external SQLite oracle
checks durable rows, but current Book Session does not expose that asynchronous
typed completion to the outer authority. This review does not reinterpret
`present`, paint, or future UI output as a receipt.

## Independent source-only execution

The reviewer staged only the frozen files into a temporary repo-shaped source
tree, added the independently accepted Python codec at hash `4e2423e0…`, and ran
the sources interpreted (`GUILE_AUTO_COMPILE=0`, no project compilation cache)
inside the pinned, already-realized Guix environment. No live implementation
source was edited.

Observed independently:

```text
real backend/factory/locking assertions       13 passed
fresh Guile authority processes                6
fresh Guile/Python book processes             12
unique PID/start-time child identities        12
unique session/surface/state-grant handles    12 each
normal trusted namespaces                      2
normal save/reopen/replay/CAS                 passed
4,096-NUL namespaces                           2
NUL save/fresh reopen/second commit           passed
```

The process checks are based on PID plus Linux `/proc/<pid>/stat` start time,
not process names. Each child stops before protocol work, establishes its own
process group, and is resumed only after the authority records that identity.
The authority checks the identity before group signalling, reaps the child, and
removes each `.pid` record. Both fixtures verified connected AF_UNIX stream FD
0, cleared `FD_CLOEXEC` only on that donated descriptor, no duplicate donated
socket, and no unrelated non-CLOEXEC descriptor.

Both endpoints exist before either child starts. Thus the passing child-side FD
checks also cover sibling endpoint and authority SQLite descriptor leakage.
Fixture load views contain no state, adapter, backend, namespace, path, or SQL
module. Python remains a sequential fixture/oracle language; Guile remains the
state authority.

### Recovery provenance counterfactual

An independent run saved two nonce-bearing Unicode values, allowed the first
authority and both books to exit, deleted every database file, then invoked the
fresh replay phase with only the two operation IDs. The result was:

```text
saved database files:       book-state-v1.sqlite
deleted-database recovery:  REJECTED
failure:                    authority replay exited 1
```

The fresh books therefore cannot recover the values from authority memory,
argv, environment, a replayed expected-value file, or a hardcoded fixture. In
the passing run, later processes receive no value/state nonce; their only value
source is the reopened backend's `state-value`. The external Python oracle alone
retains expected values for comparison after those processes exit.

### Namespace-misrouting counterfactual

After an independent two-language save, the reviewer swapped the two durable
namespace texts with an external SQLite mutation and ran a fresh
`save-loaded` phase. The authority/books completed against the misrouted values,
but the independent label-specific oracle rejected the result:

```text
swapped namespace oracle:  REJECTED
failure:                   guile loaded the wrong trusted namespace value
```

The ordinary factory test separately passed cross-grant rejection: presenting
endpoint A's retained grant to endpoint B closed only B, wrote nothing, and left
A usable. Fresh B still read absent state.

### NUL provenance and scope

For each language, the `boundary-save` book itself constructs exactly 4,096 NUL
characters after a fixed trusted action. The value crosses the book's FD,
Book Session decoder, typed state parser, worker, adapter, and SQLite. A fresh
authority and fresh book then receive a 24,666-byte version-1 framed
`state-value`, recover all 4,096 bytes, and commit the same value from version 1
to 2. The SQLite oracle checks the exact NUL text and two receipts per boundary
namespace.

This is valid Protocol-V2 state text and exercises the accepted BSD-1 bound. It
does not authorize NUL in any later private UI protocol, relax ordinary UI
validation, or establish rendering behavior.

### Close/locking result

The 13-assertion test drives a real commit to the accepted backend's
`before-commit` fault point, starts endpoint close, and confirms local endpoint
invalidation while close waits outside the endpoint mutex for backend/revocation
linearization. After the commit wins, no late acknowledgement enters the closed
endpoint. A fresh endpoint reads version 1 and the runtime closes cleanly.

This proves commit-first close behavior and honest write uncertainty. It does
not claim unsafe thread cancellation or cancellation of a write that may have
committed.

## NI-1 — executable source closure is not sealed

**Severity: blocking for exact-source acceptance.**

The exact v1 `run-host-tests.sh` never checks
`SOURCE-IDENTITIES.sha256`. It compiles and runs mutable files directly from
`$tool_dir`, including the integration module, authority, both fixtures, and
both test programs. The later source snapshot manifest proves what was copied
into the snapshot, but no check in the authenticated host log links those bytes
to the bytes executed earlier.

Two accepted protocol dependencies are also mishandled:

- `book-protocol/blocking-io.scm` is compiled from the live protocol directory,
  but its live hash is never checked. Its frozen copy does not establish what
  the runner loaded.
- `fixture_book.py` imports `book_protocol`, but `book_protocol.py` is neither
  hashed by the runner nor present in the frozen source snapshot. Python puts
  the fixture's own `$tool_dir` first on `sys.path`, ahead of the supplied
  `PYTHONPATH`, and the gate does not reject extra files or assert the imported
  module's origin/hash.

The accepted Book Session boundary is configurable rather than fixed as well.
Before entering the pure Guix shell, the runner accepts external
`BOOK_SESSION_STATE_SOURCE_DIR` and four external expected-hash variables. A
caller can therefore replace both a source path and the value against which it
is checked. The separately hardcoded patch hash is checked as a file but is not
applied or compared to the candidate source, so it does not repair that gap.

### Reproduction

In a temporary repo-shaped copy, the reviewer placed an unlisted
`book_protocol.py` beside `fixture_book.py`. It was the accepted codec plus one
import-time marker write, giving a different executable hash:

```text
accepted codec:              4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735
loaded unlisted codec:       ee7438b4aa8c2f38b40120cf5811660cf73b98fafd4ccd441fec013ee5382b09
Python fixture imports:      4
normal native suite:         PASS
```

The four marker writes correspond to the four normal Python book processes.
The test's framing and persistence checks all remained green because the added
code preserved codec behavior. This is not a hypothetical post-run hash concern:
arbitrary unmanifested executable Python ran inside the exact test topology
without being noticed.

Consequences:

1. host-log hash `23392544…` authenticates the log text, not the complete code
   that produced it;
2. source-manifest hash `42053ee2…` authenticates the frozen snapshot, not its
   temporal identity with that execution; and
3. v1 cannot support the requested exact-chain acceptance even though the
   independently pinned replay passes.

### Required correction

Produce a successor packet that, before any compile or execution:

1. authenticates the new integration source manifest against a fixed expected
   hash, then checks every entry before execution;
2. hardcodes the accepted Book Session source/delegate/packet hashes for the
   review gate, without caller-replaceable expected hashes;
3. hashes the exact live blocking-I/O source at `54357076…`;
4. freezes and hashes Python codec `4e2423e0…`;
5. prevents script-directory shadowing or asserts the imported codec's resolved
   path and hash; and
6. executes from a manifest-populated private source tree, then freezes the raw
   log and complete tree together.

The successor should reject unexpected executable files in import-precedence
locations. Any intentional alternate candidate needs a distinct manifest and
review packet, not environment variables that redefine what “accepted” means.

## NI-2 — retry evidence is acknowledged replay, not lost acknowledgement

**Severity: claim blocker; not a backend or replay-logic rejection.**

In both fixtures, every commit path calls `read_type(...,
"state-committed")`, validates operation ID, resulting version, and text byte
count, then sends a receipt-summary `present`. The trusted authority does not
consider a peer finished until that presentation moves it to `done` and the
child exits zero. `test_native_restart.py` checks the saved phase's exact receipt
before launching its replay authority.

Therefore phases 2 and 4 prove exact operation-ID replay after a known
acknowledged commit, including preservation of the original version-1 receipt
after a later version-2 CAS. They do not prove that the first acknowledgement
was dropped.

The factory race covers the complementary half: a commit wins while close
prevents a late acknowledgement from queueing, and a fresh endpoint reads the
durable value. It does **not** retry `LateClose_1` or validate the cached receipt,
and it does not continue through a fresh authority/book process. Calling the
separate successful replay phases “lost-ack retry” joins two unconnected test
histories.

Either relabel v1 as **exact persisted-receipt replay before and after later
CAS**, or add one continuous scenario that establishes all of the following:

1. the actual book sends a commit through its owned FD;
2. that commit becomes durable;
3. no `state-committed` frame is delivered/consumed before endpoint/process
   loss;
4. a fresh authority and fresh book retain only the operation ID, recover exact
   text from durable state, and retry; and
5. the old receipt returns without rolling back the later state.

No new backend semantics are required; this is an evidence/topology correction.

## Accepted and rejected claims

Subject to NI-1's evidence block, the independent run supports these narrow
functional findings for the listed source hashes:

- the real native Book Session/delegate/adapter/backend chain works for trusted
  Guile and Python fixture processes;
- state survives authority and book process exit/reopen on the host filesystem;
- two fixed trusted namespaces remain isolated;
- ordinary and 4,096-NUL values survive fresh SQLite reopen;
- CAS advances version 1 to 2;
- exact persisted receipts replay before and after later CAS without rollback;
- close/revoke occurs outside the endpoint mutex and no late acknowledgement is
  queued after local close; and
- the fixtures receive only their connected protocol FD and restricted language
  views in this native test topology.

Not accepted from v1:

- exact-source attribution of the supplied host log;
- the label “actual lost-ack retry”;
- sandbox-runtime or hostile-book isolation;
- gVisor/runsc, QEMU, ARM, KOReader, image, rendering, UI, completion-observer,
  cancellation, timer, or hardware behavior; or
- physical-power-loss or device-cache durability.

The accepted 45-path sandbox language closure remains separately unchanged;
this native test does not execute in that sandbox and adds no sandbox claim.
Python's SQLite reads are test-oracle activity after trusted authorities exit,
not production authority behavior.

## Next review boundary

NI-1 requires a fresh packet, manifest, and execution log. If the corrected gate
keeps the reviewed join and test sources byte-identical, the next review can focus
on source attribution, imported-module provenance, and the corrected/relabelled
retry evidence rather than reopening accepted component audits.

No implementation or frozen-packet file was modified in this review. Reviewer
temporary sources, databases, sockets, processes, and marker files were removed.
No QEMU, runsc, ARM execution, KOReader, image/kernel/Guix/Bazel build, mount,
network investigation, deployment, hardware action, staging, commit, push,
fetch, merge, or rebase occurred.

---

## NI-1/NI-2 successor v2 recheck — accepted — 2026-09-06

### Disposition

**NI-1 and NI-2 are closed for the exact v2 boundary below.** The v2 packet is
accepted as source-exact native host evidence for the trusted Book Session →
delegate → adapter → SQLite persistence join. It is fit to serve as the native
persistence checkpoint for later separately reviewed integration.

This acceptance does not include the completion-observer candidate, reader/UI
mapping, sandbox runtime, or any guest/device execution. In particular, the
existing contract remains correct that a future reader needs its separate
trusted typed completion observer before private `commit-ok`; a book's later
`present` is not a storage receipt.

The blocked v1 findings above remain exact historical findings for v1. V2 does
not relabel its acknowledged retries as lost acknowledgements and does not
modify the immutable v1 packet.

### Frozen v2 identities

The supplied identities matched independently:

```text
review packet v2
264bbfab85e4393322a6bba2051fe29f54be5958be3e50eb0c15e46888997224

host log v2
2f1dedbf08c3020869005b9b162b9188f63befde1a729bc4f376df0cc5c5c385

evidence manifest v2
85d33f8cd172c88f618fa0428e7424bf56ba80a51bc5f00fc1e756e406be805d

snapshot MANIFEST.sha256
261b5f018af7c00afe8b3b8db81c42e14bd4efde85ac85a465a459f2ce89013f

snapshot executable SOURCE-IDENTITIES.sha256
45f37e2fa154fb8593c7d0fc178c5d1b4a443dd7b2316dcddae1680ed86759f2

snapshot PACKET-ROSTER.txt
7594bb800f5dba727ecfdd6a555cd779520bc0ca53efed0db42596de6c98bc66

outer runner
3221517730e58671046e5cdbae01aa0491a5bca1c4fb808bf1ea328d728c1bcd

live source register
69df121f48e203a9577d29dc61c3a4b64bec934acd104cc74298c6541957056c
```

All seven entries in `book-state-native-integration-evidence-v2.sha256` passed.
The snapshot had exactly the 29 rostered regular files, no symlink or special
file, mode-0500 directories, mode-0400 files, and one link per file. All 28
entries in `MANIFEST.sha256` and all 25 executable project inputs in
`SOURCE-IDENTITIES.sha256` matched. The live integration sources named by the
live register were byte-identical to their snapshot copies.

The accepted executable inputs remained:

```text
backend                     7c3a507d8f10bef6dc81683a5459464aa99378a762fe1d407fa44b749f28dab9
schema                      70db8c3c6782a0b8d383f33c37fed06b2b67bd9f6915e21a9d7dacf042c97bdb
Scheme Book Protocol        91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44
Scheme blocking I/O         543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd
Python Book Protocol        4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735
operation-ID helper         dab6c72bd6f22fab7ae15b25ed415bb3564eb7f974740e9cf27352a7525870ee
state protocol              425ccc468b49f126c561d029d5c4aa61e73d6cc807cfb15e464067f31d7f7257
backend adapter             349c960b63981b1ed39d8fc99b95dafaba2040623463a11a04878c8ac933f769
Book Session                f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301
state delegate              eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6
channels.scm                661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1
```

V1's three immutable identities also remained unchanged: packet `02bd736c…`,
snapshot manifest `42053ee2…`, and host log `23392544…`.

### NI-1 closure: fixed before execution

The exact outer runner accepts no arguments and hard-codes the v2 snapshot path
and the snapshot manifest, source-manifest, and roster hashes. Before copying or
execution it:

1. computes the actual regular-file roster and compares its hash with the fixed
   roster identity;
2. verifies every snapshot manifest entry;
3. copies only that authenticated snapshot to a fresh private run root;
4. changes the private copy to 0500 directories and 0400 files; and
5. invokes the copied, authenticated structural/source verifier before entering
   the native test runner.

The verifier checks canonical absolute root identity, exact roster, file types,
modes, all 25 project source identities, the full snapshot manifest, and the ten
hard-coded accepted code/schema hashes. Expected hashes cannot arrive through
argv or environment. The outer runner removes every legacy
`BOOK_SESSION_STATE_*` selector before calling the inner runner.

The 25-entry executable project closure includes the previously missing Python
codec and Scheme blocking-I/O helper, all accepted state/session sources and
schema, both ordinary fixtures, both lost-ack components, both test programs,
the integration module, exact Python loader, Scheme origin checker, source gate,
inner runner, test manifest, and channels file. No consumed project Scheme or
Python source was found outside that list.

#### Independent mutation replay

The authenticated verifier and exact source-gate test were run twice from fresh
private copies. On each pass all six targeted mutations rejected and no external
execution canary appeared:

```text
changed Python codec                         rejected before execution
changed Scheme blocking-I/O helper           rejected before execution
changed codec + blessing source manifest     rejected before execution
unlisted Python shadow module                rejected before execution
caller-selected Book Session path/hash       rejected before execution
caller-supplied expected-hash argument       rejected before execution

passes                                       2
mutations per pass                           6
execution canaries                           0
```

Two additional reviewer-created shadows carried direct external marker writes:

- `integration/book_protocol.py`, at Python script-import precedence; and
- `accepted-inputs/session/book-protocol/blocking-io.scm`, ahead of the real
  protocol directory in Scheme source-path order.

The exact verifier rejected both as roster additions before either file ran.
Both external markers remained absent.

#### Runtime origin and cache boundary

Python fixture books are launched with `python3 -I -S` through exact loader
`f791c8c1…`. The loader requires canonical, single-link regular codec and fixture
paths, hashes the codec against accepted `4e2423e0…`, installs only that exact
module in `sys.modules`, checks its resolved origin, and emits one origin marker.
Every ordinary Python child log in the frozen run contained exactly one such
marker.

An independent launch supplied hostile `PYTHONPATH`, `PYTHONSTARTUP`, and a
script-directory `book_protocol.py` with an external marker. The exact snapshot
codec loaded; neither hostile marker appeared. A changed exact-path codec was
also rejected before its fixture's external marker could run.

The inner gate removes ambient Python and Guile source/cache selectors before
entering the pure pinned environment. Project Scheme sources compile only into a
fresh private cache. The supplied log records all nine project modules resolving
from that cache after source authentication; no ambient project bytecode path is
accepted. Fixture Guile processes receive only the exact protocol/json source
and compiled views and run with auto-compilation disabled.

#### Bootstrap boundary

The immutable 25-source closure begins after the outer launcher has authenticated
and copied the snapshot. The normal `make check` bootstrap additionally depends
on exact Makefile `925212a3…` and outer runner `32215177…`; both are bound through
live register `69df121f…` and evidence manifest `85d33f8c…`, and both matched in
this review. This is the explicit launcher boundary—not a dependency on a Git
branch name, old HEAD, or root package source.

If a base fast-forward changes the Makefile, outer runner, live source register,
or snapshot path/hash constants, the normal-command attribution requires a new
check even if immutable inner snapshot `261b5f01…` remains unchanged. The frozen
inner result itself does not depend on that future base movement.

The supplied packet retains one complete 169-line, 15,906-byte status-zero host
log. The stated earlier consecutive run is not separately frozen, so this review
uses the final frozen run plus independent mutation and source-only replays; it
does not manufacture a second historical log.

**NI-1 is closed.** The v1 fake-codec reproduction cannot cross either the
pre-execution roster/source gate or the exact Python loader in v2.

### NI-2 closure: one actual dropped acknowledgement

V2 correctly renames the retained two-language phases as acknowledged persisted
receipt replay. Its new loss scenario is a separate continuous execution, not a
label attached to those old phases.

The loss path is:

1. A real fresh Guile book receives generated Unicode edit text only through the
   ordinary trusted `edit-save` action.
2. It sends an ordinary typed commit with expected version 0 through its owned
   connected Book Session FD.
3. The delegate worker calls a test factory whose `RUN-OPERATION` wrapper invokes
   exact accepted `run-state-backend-operation`.
4. Only after that adapter returns, the wrapper holds a condition-variable baton
   before returning the result to delegate completion.
5. A separate close thread invalidates/detaches the endpoint, closes transport,
   begins exact revocation outside the endpoint mutex, and waits for the worker.
6. The book's blocked frame read receives EOF, records that it did not parse
   `state-committed`, exits, and is reaped. The endpoint has zero outbound frames.
7. While the adapter result is still held, a separate read-only Python SQLite
   connection verifies exact generated text at version 1 and exactly one receipt
   with expected/resulting versions 0→1.
8. Only then does the oracle release the baton, allowing close/reap and original
   authority exit to complete.
9. A fresh authority and fresh Guile book receive only the same operation ID.
   The book reloads text exclusively via `state-value`, submits the exact retry
   with expected version 0, consumes the original version-1 receipt, and rereads
   current version 1.
10. A second SQLite inspection proves text, version, receipt identity, and the
    one-receipt count unchanged: no second commit occurred.

The reviewer independently executed this three-phase, six-process scenario from
the exact snapshot sources without project compilation. It reported:

```text
adapter returned                             yes
endpoint closed                              yes
outbound frames                              0
book EOF before state-committed              yes
fresh retry authority/book                   yes / yes
retry expected/receipt/current versions      0 / 1 / 1
receipt count                                1
state unchanged                              yes
acknowledged counterexample rejected         yes
```

The third fresh authority/book deliberately consumes the real receipt and then
prints a pretend-loss marker. `validate_lost_ack_evidence` rejected it because
`state_committed_consumed` was true. This directly closes v1's semantic-label
counterexample.

Two additional negative executions modified only the reviewer test environment
after the real lost commit and before fresh retry:

```text
database removed before retry                rejected
durable text replaced before exact retry     rejected
```

Both fresh retry authorities exited nonzero. Thus the successful retry does not
come from argv/environment, an expected-value replay, absent storage, or an
arbitrary reopened value. The exact operation ID is legitimate test-client
state; recovery text comes from the reopened backend.

The completion baton is test-only scheduling around the actual adapter result.
It neither replaces the adapter/backend call nor adds the future reader
completion observer. It deterministically holds the sole worker before response
publication so the test can prove commit-first transport loss.

**NI-2 is closed.** V2 proves one actual commit whose acknowledgement was not
queued or consumed, followed by exact fresh-process receipt replay without a
second commit.

### Retained native coverage

The full v2 source suite was also rerun interpreted from the authenticated
snapshot in the pinned, already-realized native environment. It passed:

```text
real factory/locking assertions              13
ordinary/boundary authority phases            6
ordinary Guile/Python books                   12
lost/retry/counterexample authorities          3
lost/retry/counterexample Guile books          3
combined fresh authorities                     9
combined fresh book/session/surface/grants    15 each
4,096-NUL save/reopen/second commit           pass
```

The retained factory test still proves cross-grant isolation and commit-first
close/revoke ordering. The ordinary phases still prove two trusted namespaces,
fresh process identities, Unicode save/reopen, CAS 1→2, and original receipt
replay before and after later CAS. Both language fixtures retain connected-FD,
`FD_CLOEXEC`, duplicate-FD, process-group, bounded-log, and exact child reap
checks. The NUL case still traverses the real worker and reopened SQLite store.

No direct backend shortcut was added to the ordinary authority. The lost-ack
authority's explicit adapter call occurs only inside the test factory's
`RUN-OPERATION` callback reached from the book's commit frame; it is not an outer
commit impersonation.

### Exact accepted scope

Accepted for v2:

- source-exact trusted-native Book Session/delegate/adapter/SQLite execution;
- fixed trusted namespace authority with no peer path/namespace/SQL selection;
- fresh Guile/Python process and owned-FD integration;
- process-exit/reopen persistence on the host filesystem;
- CAS and durable exact-receipt replay without rollback;
- one deterministic actual drop-before-ack and fresh-process exact retry;
- namespace/grant isolation and close/revoke ordering; and
- exact 4,096-byte NUL worker framing and SQLite reopen.

Still excluded:

- hostile-book isolation or a sandbox-runtime claim;
- production lifecycle, cancellation, timer, or arbitrary kernel-I/O bounds;
- completion-observer or private reader `commit-ok` behavior;
- UI, present/paint receipt authority, rendering, KOReader, runsc, QEMU, ARM,
  image, kernel, device, or hardware behavior; and
- physical-power-loss or device-cache durability.

The accepted 45-path language closure remains separately unchanged. Its hash
check does not make this native execution sandboxed. Guile remains the sole
state authority; Python remains a sequential fixture and external SQLite oracle.

Any change to the 25-source identity manifest, roster, snapshot manifest,
accepted component hashes, exact Python loader, Scheme origin checker, outer
runner/bootstrap identities, or tests requires fresh review.

No implementation, frozen packet, v1 evidence, observer, UI, or central
architecture/protocol document was modified during this recheck. Reviewer
temporary sources, databases, process records, sockets, processes, and marker
files were removed. No QEMU, runsc, ARM, KOReader, image/kernel/Guix/Bazel build,
mount, network investigation, deployment, hardware action, staging, commit,
push, fetch, merge, rebase, or base fast-forward was performed.
