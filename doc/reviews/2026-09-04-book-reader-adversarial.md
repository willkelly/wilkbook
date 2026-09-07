# Adversarial review: KOReader book-reader probe

Date: 2026-09-04
Scope: `pinenote/tools/book-reader/` and
`doc/book-computer-reader-spike.md` only. The packaged KOReader files named
below were read as the external oracle used by the probe.
Reviewed tree: `50572d7796abdb0928969f4db8836fc5e30aeb58`, with both scoped
artifacts untracked at review time.
Disposition: **reader gate not accepted; fixes and an adversarial recheck are
required.**

This review did not use hardware, SSH, UART, a VM, or the network, and did not
build or realize a package. All executions and mutations used isolated copies
below `/tmp/opencode/book-reader-adversarial.roA7pw`; the active implementation
and user profiles were not changed. The one resistant process created by the
watchdog-loss test is recorded below and was killed by its exact PID after its
command line was checked. The only repository file written by this review is
this report.

## Findings

### BR-1 — Medium — callback reentrancy defeats the claimed per-poll work bound

Kind: fixture-only runtime/design bug, **not a shipping-reader bug** (there is
no production bridge in this spike).

`interaction_source.lua:36-51` says returning `nil` after one callback keeps
work per UI tick bounded. That only holds if `receive` never re-enters
`waitEvent`. The source has no busy/reentrancy guard. A callback can enqueue one
replacement and recursively call `waitEvent`; queue occupancy remains at the
configured maximum while one outer poll performs unbounded work.

Expected: with `max_queued = 1`, one outer `waitEvent()` invokes at most one
callback.
Actual: the isolated counterexample performed 128 callbacks from one outer
call while never needing queue capacity above one:

```text
one-outer-waitEvent callbacks=128 callback_count=128 queue=0 max_queued=1
```

The constructor also does not establish a well-typed finite count bound.
`max_queued = 1.5` and `math.huge` are accepted; a string fails with an
incidental comparison error. The docs correctly disclose that the fixture
does **not** bound message bytes, depth, framing, identity, or cross-process
backpressure. Those disclosed exclusions are not findings. The issue here is
the stronger count/work claim made by the source and README.

Required fix: reject non-numeric, non-finite, non-integral queue limits; guard
`waitEvent` against callback reentrancy; and add a test in which `receive`
tries to enqueue and recursively poll. A future production adapter still
needs separate byte/depth/decoding/time budgets.

### BR-2 — Medium — watchdog loss fails open, and signal cleanup can orphan a resistant reader

Kind: test-runner runtime bug.

The watchdog at `run-tests.sh:120-137` is an unsupervised background shell.
The runner deliberately kills it after a normal reader exit and ignores its
status, so it cannot distinguish that path from the watchdog dying early. The
cleanup trap at lines 48-58 sends the reader one ordinary `TERM` and then
waits forever; unlike the watchdog path, it has no timed `KILL` escalation.

Expected:

1. loss of the deadline mechanism is itself a failure;
2. a wedged/TERM-resistant reader remains bounded; and
3. cleanup leaves no child.

Actual:

- A shortened, functioning watchdog killed a wedged fixture and the runner
  failed in 3.00 s (`w1`, rc 1), so the timeout sentinel correctly defeats a
  signal-induced clean application status.
- Replacing the watchdog sleep with an immediate exit was not noticed by a
  fast run (`w2`, rc 0 and the ordinary PASS line).
- With that lost watchdog and a wedged fixture, the runner needed an
  independent `timeout --kill-after` (`w3`, rc 137 after 6.00 s). Its cleanup
  blocked waiting for the reader; killing the runner left reader PID 804349
  reparented to PID 1. I verified that PID's command line contained only the
  isolated `w3-watchdog-lost-hang` path, sent `KILL` to that exact PID, and
  confirmed no matching process remained.

Required fix: put the reader under one fail-closed foreground timeout owner
(or equivalently supervise watchdog death), and make every signal/exit cleanup
path use a bounded TERM-to-KILL escalation. Add a helper that deliberately
ignores TERM and assert both failure status and zero process residue.

### BR-3 — Medium — lifecycle, removal, and drop oracles are not independent enough

Kind: test-harness scope/oracle gaps; the reviewed active fixture does call the
real APIs.

The exact marker comparison is useful for ordering, but most markers and
counters are emitted or maintained by the same fixture that performs the
operation. Four targeted substitutions remained fully green with the exact
expected markers and clean UIManager teardown:

| Mutation | Expected | Actual |
|---|---|---|
| Replace `self.ui:onClose(false)` with `self:onCloseDocument()` | Fail because ReaderUI's close path was bypassed | rc 0, PASS |
| Replace highlight removal's return value with local `expected`, leaving `_highlight_buttons[ACTION_KEY]` registered | Fail removal assertion | rc 0, PASS |
| Omit `self.queue = {}` in `stop()` | Fail because queued payloads were retained | rc 0, PASS |
| Replace public `UIManager:insertZMQ(source)` with direct insertion into private `_zeromqs` | Fail the public-seam claim | rc 0, PASS |

The first is a one-line synthetic-vs-real counterexample: `close_document_seen`
and the marker sequence do not distinguish ReaderUI dispatch from directly
calling the fixture's handler, while a clean `UIManager:quit(0)` does not prove
the document close path ran. The second trusts the return value instead of
checking registry absence. The third increments `dropped_count` before
retaining the payloads, so the count is not proof of disposal.

There is also no graceful test of closing the document/application **while an
interaction is active**. The only real ReaderUI close occurs after both
interactions have already cleaned up; `onCloseDocument` treats an active
interaction as a fixture failure. Thus the gate proves suppression behind
normal interaction-close and callback-error, but not the production-relevant
document-close race. `doc/book-computer-reader-spike.md:299-301` accurately
says that the tested close finds no active interaction; broader “no
post-close work” wording should not be inferred from it.

Required fix: add independent postconditions (`ui.document == nil`, action key
absent, stopped queue actually empty, public seam call counts), and run a
separate active-interaction document-close scenario followed by an explicit
stale `waitEvent`/enqueue attempt. Keep markers as diagnostics, not as the sole
oracle for the operation that emitted them.

### BR-4 — Medium — “pinned bundle” verification can be spoofed by the writable fixture

Kind: test-harness pin-verification gap, not evidence that the reviewed bundle
is wrong.

`run-tests.sh:150-154` accepts the expected version string anywhere in the
combined process log. The plugin under test can print an unprefixed matching
line after it loads. In `m6`, the isolated repository pin was changed to
`2099.99` and one fixture print was added. The unchanged v2026.03 bundle log
contained both:

```text
 [*] Version: v2026.03
 [*] Version: v2099.99
```

The runner returned 0 and printed `PASS: pinned KOReader...`. An explicit
`KOREADER_BUNDLE` is otherwise checked only for executable/file layout. The
fixture can similarly author marker and teardown-looking text, although the
process exit status remains independent.

The reviewed baseline itself was independently consistent: the package says
`2026.03`, the path is a root-owned mode-0555 Guix store item named
`koreader-bin-2026.03`, `guix gc --derivers` returned
`/gnu/store/amd75p0f3namp1x2kwhkhipd568s9na2-koreader-bin-2026.03.drv`, and
the real startup line reported v2026.03. This finding is about what the gate
would catch after a change.

Required fix: require exactly one anchored official version line before any
plugin-discovery/fixture output. For a run described as package-pinned, also
compare the canonical store output/deriver with the repository evaluation;
otherwise label an arbitrary override a compatibility bundle, not a verified
package pin.

### BR-5 — Low — the no-write source tripwire is trivially bypassable

Kind: test-harness scope gap.

The lexical scan at `run-tests.sh:68-81` catches only dotted spellings such as
`io.open` plus quoted strings beginning with `/`. In `m3`, bracket access
`io["open"]` and a slash constructed with `%c` acquired a writer. The full
gate returned 0 and created:

```text
.../build/run.2WEIp9/home/tripwire-bypass
writer acquired
```

This write stayed inside the isolated review tree; no profile or active source
was touched. Source review found no writer in the active fixture, and the
baseline's retained writes were all below its mode-0700 run directory. The
documentation repeatedly says the fixture is trusted and this is not a Lua
sandbox/security proof, which correctly limits severity. Nevertheless,
`doc/book-computer-reader-spike.md:303-306` says the runner “pins” absence of a
file operation; the mutation shows that it does not.

Required fix: either narrow the claim to the exact forbidden spellings, or
enforce write confinement outside Lua (sandbox/mount namespace or syscall
trace with an allowed run-root policy). Do not grow a regex into a claimed Lua
security boundary.

## What the probe does establish

This is not a claim that the active run was synthetic. Source inspection and
positive instrumentation established the following:

- The baseline command passed, opened the temporary text document in real
  `ReaderUI`, displayed an editable real `InputDialog`, traversed its generated
  Trapper-wrapped Save callback, and reached normal UIManager teardown.
- An isolated assertion that `debug.getinfo(2, "n").name == "processZMQs"`
  inside `waitEvent` passed. The messages in the active test therefore were
  driven by KOReader's real event loop, not direct fixture polling.
- The active source calls `ReaderHighlight:addToHighlightDialog`, matching
  removal, `UIManager:insertZMQ`, and `removeZMQ`; the inspected v2026.03
  implementations have the documented effects.
- Control mutations were killed: an off-by-one queue cap failed with
  `source queue bound was not enforced`; omitted `removeZMQ` failed with
  `source remained registered after close`; omitted generation comparison
  failed (rc 2 / fixture rc 1).
- Direct action-factory invocation rather than a touch/highlight-menu flow is
  clearly disclosed. This gate proves the registered factory/action callback,
  not menu layout or user input.
- The immutable-vs-writable trust boundary is accurately disclosed. The
  bundle and `reader.lua` were root-owned mode 0555 and not writable; the
  copied fixture was mode 0664 and writable; the fixture was absent from the
  bundle. The spike explicitly says no plugin was shipped and leaves an
  immutable production-graft structural gate for later.
- Normal temporary-path handling is narrow: `mktemp` produced a mode-0700
  directory below this tool's `build/`; cleanup has no empty-variable or broad
  fallback target; the baseline left no process residue. The BR-2 failure is
  specifically the resistant-child/signal path.

No shipping runtime bridge, wire codec, durable save, capability boundary,
hardware path, or writable production plugin was present to review. The spike
document's exclusions on those points are appropriate.

## Reproduction record

### Baseline and oracle commands

The isolated copy retained at the review root was made with:

```sh
review_root=$(mktemp -d /tmp/opencode/book-reader-adversarial.XXXXXX)
mkdir -p "$review_root/baseline/repo/pinenote/tools" \
  "$review_root/baseline/repo/pinenote/packages" "$review_root/baseline/repo/doc"
cp -R pinenote/tools/book-reader "$review_root/baseline/repo/pinenote/tools/"
cp pinenote/packages/koreader.scm "$review_root/baseline/repo/pinenote/packages/"
cp doc/book-computer-reader-spike.md "$review_root/baseline/repo/doc/"
KOREADER_BUNDLE=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03 \
  KEEP_ARTIFACTS=1 \
  make -C "$review_root/baseline/repo/pinenote/tools/book-reader" check
guix gc --derivers \
  /gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
guix gc --references \
  /gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
sh -n pinenote/tools/book-reader/run-tests.sh
```

Baseline result: rc 0, all 29 expected markers in exact order, reported
v2026.03, clean teardown, and
`PASS: pinned KOReader offscreen reader integration probe`. Retained log SHA256:
`c718c7069fdd53a6add285c5292fb0275f6f4c24fe75cbd8a95f9395ff466242`.
`shellcheck` was unavailable; `sh -n` passed.

Mutation commands and outputs are retained under
`/tmp/opencode/book-reader-adversarial.roA7pw`. The exact drivers were:

```sh
/tmp/opencode/book-reader-adversarial.roA7pw/run-mutations.sh
/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03/lib/koreader/luajit \
  /tmp/opencode/book-reader-adversarial.roA7pw/reentrant-counterexample.lua \
  /tmp/opencode/book-reader-adversarial.roA7pw/baseline/repo/pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin
/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03/lib/koreader/luajit \
  /tmp/opencode/book-reader-adversarial.roA7pw/queue-constructor-counterexample.lua \
  /tmp/opencode/book-reader-adversarial.roA7pw/baseline/repo/pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin
/tmp/opencode/book-reader-adversarial.roA7pw/run-watchdog-tests.sh
```

Driver SHA256 values, to make the exact ephemeral commands auditable:

```text
6902ac44aa90499a351bbd671660b24a9294c34e51d7b79d6d1a73fc69bf5b2f  run-mutations.sh
b9ed7b616ed4d0299fa439a0e66af2af140b189b1534bdc5bda171ac1c6377f2  run-watchdog-tests.sh
a8fb382b388f210d7933fe5ce19a14ba2b7e19d0d40a7ce5901f797302b8a6f3  reentrant-counterexample.lua
4cb46ab8b7ed384d10c00293a740d86edbf4113290a1996a9c937182b83a30ad  queue-constructor-counterexample.lua
```

The mutation driver contains each exact `sed`/Python substitution, creates a
fresh scoped copy for every case, and invokes this command for each:

```sh
KOREADER_BUNDLE="$BUNDLE" KEEP_ARTIFACTS=1 \
  make -C "$ROOT/$case/repo/pinenote/tools/book-reader" check
```

All per-case result files were written before `run-mutations.sh` itself
returned 1: its final summary-only `cat` used brace expansion under `/bin/sh`,
which did not expand. That reviewer-script typo did not skip or alter any test;
the six survivor and two killed-control statuses were read directly from their
individual result files. The separately invoked third killed control was the
generation-guard mutation.

The watchdog driver records its exact `/usr/bin/time` and
`/usr/bin/timeout --foreground --signal=TERM --kill-after=2s 4s` commands.
It returned 1 intentionally when its final residue check found the orphan.
After observing the isolated orphan, cleanup was exactly:

```sh
# Only after /proc/804349/cmdline matched the isolated w3 path:
kill -KILL 804349
ps -eo pid=,ppid=,stat=,args= | \
  grep -F '/tmp/opencode/book-reader-adversarial.roA7pw/' | grep -v grep || true
```

The final process search was empty.

### Reviewed source hashes

```text
181314065df2f2fdaf920b1a8b5311daa216a2d6489a06ada5b49cc514d89417  pinenote/tools/book-reader/.gitignore
922840fd8eb448ca229d7d7385bb87b6bf6a442e6bd13b68431601458a4e7983  pinenote/tools/book-reader/Makefile
e3870282a94a351e8b89278d408da758f2bfc70b552efaab5e6483b7a0267834  pinenote/tools/book-reader/README.md
332c56aa9e445f4fe2a1d984f17e1ce3e92fc248897653f7357d0c25e244b964  pinenote/tools/book-reader/expected-markers.txt
4cba23d37267091b9d7579b4f7e3dcce410cb64e9885974a61b49d7871195a8c  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/_meta.lua
e5aeb65242239110ccf7368fc4f7fa68afc3d018c9ba5e0f91f746d4f06ef379  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/main.lua
2b351007655c47563a8b9241a9cdf6eaacc77fc9493bec683ee831ee8b4b387b  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/interaction_source.lua
e84463462c0a90f9fe02a894f7c41fbab317d8a49df398b39ff6f0336198f832  pinenote/tools/book-reader/run-tests.sh
4d957423e1fab35fb4c1d5a8c5de528640a959447f7d934ddc07b17c136ddb8f  doc/book-computer-reader-spike.md
81c075b539803e1ffb1a67724cfa57c7f38698edbaff2889ebaaea00a5da8567  pinenote/packages/koreader.scm (pin oracle only)
```

## Implementation disposition after the independent recheck

Implementer note, 2026-09-04. This appendix does **not** change the reviewer’s
open BR-3 or overall not-accepted verdict above; a quick independent recheck is
still required.

The three remaining BR-3 cases are now covered by state assertions rather than
new success markers:

- `public_seam_probe.lua` wraps the real
  `ReaderHighlight:addToHighlightDialog()` and
  `removeFromHighlightDialog()` methods, scoped to the observed action key.
  Immediately after registration its independent add/remove counts must be
  exactly `1/0`; after teardown they must be `1/1`. The existing actual-registry
  checks remain separate.
- `_closeInteraction()` returns the original dialog reference before clearing
  the plugin field. Normal close, callback-error close, and active-document
  close each assert `dialog ~= nil` and
  `not UIManager:isWidgetShown(dialog)` against UIManager’s actual stack.
- `run-mutation-tests.sh` now includes the recheck’s exact realistic bypasses:
  direct private highlight registration, direct private highlight deletion
  with the expected local return value, and omission of
  `UIManager:close(dialog)`. They fail respectively with the public-add,
  public-remove, and dialog-stack diagnostics.

Implementer reruns completed with the canonical pinned v2026.03 output:

```text
make -C pinenote/tools/book-reader check
PASS: pinned KOReader offscreen reader integration probe

make -C pinenote/tools/book-reader mutation-check
PASS: mutation killed: private-highlight-add
PASS: mutation killed: private-highlight-remove
PASS: mutation killed: omitted-dialog-close
RESULT: all reader adversarial mutations were killed
```

All fifteen mutations passed by turning the gate red for their expected
diagnostic. The baseline retained its 33-marker order; no marker was added as a
substitute for these state postconditions. Shell/whitespace checks passed, the
timeout regressions remained green, and no scoped run, mutation, timeout, or
reader process residue remained. No shipping, protocol, Guile runtime, system,
or hardware file was changed.

Relevant immutable bundle hashes:

```text
a189ca83623153f2a1b048c7bc04eba1fca76068bd9705dc71296d26292613cc  reader.lua
6d436af3a5abfdd9e28e54eb53dd7ddbb0bf66187adb02a3f526b196a077f8a1  frontend/pluginloader.lua
3adcfabb4e786301c241d957e0985273fe362dee858ff6f2fa414aae617f1470  frontend/apps/reader/readerui.lua
1f6bde433c349ef8e07f2ca8f2d24b209127ca9d1a80e1a89b710a27d403e711  frontend/apps/reader/modules/readerhighlight.lua
f74b56b1885647770da9596e753990dd065032b6f85777260c841c19b1999464  frontend/ui/uimanager.lua
a03bdd3827a3108d313a19407c7e2db6176e20c3066595356f4c86e3a50930b4  frontend/ui/widget/inputdialog.lua
```

## Recheck gate

Do not accept this as the reader gate until BR-1 through BR-4 are fixed and
rerun. BR-5 may be resolved by honest narrowing rather than pretending a Lua
regex is confinement. On recheck, all six currently surviving mutations must
fail for the property they remove, the three killed controls must remain red,
the reentrant callback must not exceed one callback per outer poll, and the
TERM-resistant watchdog test must leave no process.

## Independent recheck — 2026-09-04

Recheck input: the same repository HEAD
`50572d7796abdb0928969f4db8836fc5e30aeb58`, with a revised untracked
`pinenote/tools/book-reader/` and revised untracked
`doc/book-computer-reader-spike.md`. Tests used isolated copies below
`/tmp/opencode/book-reader-recheck.z01WI7`. No implementation file or user
profile was edited. No hardware, SSH, UART, VM, network access, package build,
or package realisation was used.

### Recheck disposition

| Finding | Status | Independent result |
|---|---|---|
| BR-1, queue type/reentrancy | **Closed** | The original recursive counterexample is stopped at one callback; fractional, infinite, and string limits are rejected. |
| BR-2, watchdog/cleanup | **Closed** | Deadline, owner signal, GNU-timeout loss, top-supervisor loss, runner signal, and stale-start-time cases all failed closed with no process residue. |
| BR-3, independent lifecycle/removal/drop oracles | **Open (partially fixed)** | Original mutations are killed, but three new state-preserving bypasses pass: private highlight add, private highlight remove, and omitted dialog close. |
| BR-4, package pin | **Closed** | Canonical derivation/output and immutable `git-rev` are checked before fixture execution; spoof, duplicate-line, compatibility-label, and attempted-realisation controls behave correctly. |
| BR-5, write tripwire | **Closed by scope correction** | Common bracket spelling is caught, while a dynamic spelling still bypasses the lint as the revised docs explicitly say it can. No confinement claim remains. |

**Overall disposition remains: reader gate not accepted.** BR-3 still needs a
fix and another independent recheck. This is a gate-oracle defect, not evidence
that the currently reviewed fixture happens to use the wrong APIs: source
inspection confirms that it presently calls both ReaderHighlight methods and
closes each dialog.

### BR-1 — Closed

`interaction_source.lua` now requires `max_queued` to be numeric, finite,
positive, and integral. `in_wait` rejects recursive `waitEvent` calls and is
cleared before error cleanup. `test-interaction-source.lua` independently
checks malformed limits, recursive receive, error cleanup, queue emptiness,
and a stale poll.

I reran the original review scripts against the revised source rather than
only accepting the new suite:

```text
old reentrant counterexample: rc 1
one-outer-waitEvent callbacks=1 callback_count=1 queue=1 max_queued=1

fraction: rejected ... max_queued must be a finite positive integer
infinity: rejected ... max_queued must be a finite positive integer
string: rejected ... max_queued must be a finite positive integer
```

The queue remains intentionally a **message-count** bound over trusted
in-memory Lua values. It is not a byte, depth, decode-time, framing, identity,
or cross-process bound. The spike continues to defer those properties to the
future protocol/adapter, which is accurate.

### BR-2 — Closed

The unsupervised sleep watchdog is gone. `timeout-owner.sh` places the command
under one GNU `timeout --foreground` deadline with TERM-to-KILL escalation.
`record-exec.sh` records exact PID plus Linux `/proc` start time before each
exec. Both `timeout-owner.sh` and `run-tests.sh` clean their recorded command
and supervisor identities on every exit/signal path.

The ordinary baseline's three timeout regressions passed. I then used a
separate driver, not `test-timeout-owner.sh`, for six targeted cases:

```text
PASS independent-deadline rc=137 no-recorded-process
PASS independent-owner-signal rc=143 no-recorded-process
PASS independent-timeout-loss rc=137 no-recorded-process
PASS independent-top-owner-loss rc=1 no-recorded-process
PASS independent-runner-signal rc=143 no-recorded-process
PASS independent-stale-starttime-does-not-kill
RESULT independent owner tests ok
```

The top-owner-loss case wedged the Lua fixture, killed the exact
`timeout-owner.sh` child above GNU timeout, and verified that `run-tests.sh`
failed and removed both remaining recorded identities. The runner-signal case
sent TERM to `run-tests.sh` while the fixture ignored TERM and obtained rc 143
with no remaining reader, timeout, or supervisor. The stale-identity case
gave `owned_process_terminate_record` the PID of a process created by the test
but a start time one tick too new; it correctly left that process alive. The
test then terminated that same process using its real recorded identity.

Every final search for a command line below the recheck root was empty. No
process-name match or broad kill was used. This proves the one-command fixture
scope; it is not a general descendant-process/cgroup claim.

### BR-3 — Open: public highlight seams and dialog disposal still have false-positive paths

The revision fixes substantial parts of BR-3:

- a synthetic direct `onCloseDocument` call now fails because
  `ui.document` remains non-nil;
- retained source payloads fail the pure test;
- leaving the highlight key registered fails the registry postcondition;
- private ZMQ insertion fails the independent insert call count;
- omitted ZMQ removal fails the live registry check;
- normal, callback-error, and active-document closure all perform stale poll
  and enqueue checks; and
- the active-document case really enters `ReaderUI:onClose`, emits one
  `CloseDocument`, clears `ui.document`, and cleans a queued source.

The original synthetic-close, retained-queue, retained-highlight,
private-ZMQ-insert, omitted-remove, off-by-one, and omitted-generation
mutations all returned nonzero for their intended diagnostics in independently
constructed copies.

However, three bounded mutations not present in the provided twelve remain
green:

| Independent mutation | Expected | Actual |
|---|---|---|
| Replace `ReaderHighlight:addToHighlightDialog(...)` with direct assignment to `_highlight_buttons[ACTION_KEY]` | Fail the claim that the public registration seam ran | rc 0, pinned PASS |
| Replace `removeFromHighlightDialog(...)` with local `removed = expected` **and** direct deletion of `_highlight_buttons[ACTION_KEY]` | Fail the claim that the public removal seam ran | rc 0, pinned PASS |
| Omit `UIManager:close(dialog)` while preserving all source cleanup | Fail dialog-cleanup postcondition | rc 0, pinned PASS |

The first two survive because `public_seam_probe.lua` wraps only UIManager's
ZMQ methods. ReaderHighlight is checked only for final table state, so direct
private mutations are indistinguishable from calls through the documented
public methods.

The third is not merely equivalent cleanup. I added an unprefixed independent
observation around the active ReaderUI close in that isolated mutant. The gate
still printed its pinned PASS, while the retained KOReader log said:

```text
INDEPENDENT_DIALOG_STILL_SHOWN: true
```

Upstream `UIManager:close(self.dialog)` removes only the ReaderUI widget, not a
different InputDialog above it. The final `UIManager:quit(0)` clears the window
stack and lets the marker gate finish, masking that the interaction dialog did
not receive its close path. Setting `self.interaction_dialog = nil` before
cleanup also makes the fixture's idempotency check unable to find that orphan.

Required fix before acceptance:

1. independently instrument `ReaderHighlight:addToHighlightDialog` and
   `removeFromHighlightDialog`, with exactly one expected call to each for the
   observed action key; and
2. retain each dialog reference long enough to assert
   `not UIManager:isWidgetShown(dialog)` after normal, error, and active
   document cleanup. Add the omitted-dialog-close mutation to the gate.

The two private-highlight mutations and omitted-dialog mutation must then turn
red for those specific reasons.

### BR-4 — Closed

The canonical Guile evaluator returned exactly:

```text
/gnu/store/amd75p0f3namp1x2kwhkhipd568s9na2-koreader-bin-2026.03.drv
/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
```

The bundle's one-line `git-rev` is `v2026.03` (SHA256
`846aed94948bfa1c155325770bf4df8673850a14395ec585c3d594c859d5b2d5`),
and `guix gc --derivers` returned the same evaluated derivation. The baseline
therefore reported `bundle-mode: package-pinned`.

Independent controls established:

- changing package output version to `2099.99` plus printing a forged fixture
  line failed on immutable `git-rev` **before** any fixture marker;
- a duplicate forged official line failed the exactly-one check;
- a symlink to the same v2026.03 store bundle was conservatively reported as
  `bundle-mode: compatibility` and ended only with
  `PASS: KOReader offscreen compatibility probe (...)`, never pinned PASS; and
- forcing `built-derivations` for a deliberately missing 2099.98 output failed
  with `canonical KOReader evaluation attempted a build` before fixture
  execution. No realisation occurred. Calling the same function for the
  already-present 2026.03 output returned normally because no build request
  was needed; that is not a bypass of the handler.

Changing `%koreader-version` itself also failed before fixture execution (the
missing source/output path reached the fail-closed build handler). Thus a
writable fixture cannot establish package-pinned status. A writable alternate
bundle can still claim its own compatible `git-rev`, but it receives only the
explicit compatibility label; that is the intended trust boundary.

### BR-5 — Closed by honest narrowing, not by confinement

The original bracket spelling `io["open"]` is now among the convenience lint's
literal patterns and failed before fixture execution. I also constructed a
writer through `io[string.char(...)]`. The gate passed and the fixture wrote
only this isolated evidence file:

```text
/tmp/opencode/book-reader-recheck.z01WI7/independent/dynamic-writer-lint-bypass/runs/book-reader-run.kzF3Ko/home/dynamic-writer
lint is not confinement
```

That green bypass is now **expected**. `lint-fixture.sh`, its comments, the
README, and the spike all explicitly call the check lexical convenience only,
say alternate spellings can bypass it, and say trusted Lua is not constrained
by path redirection. Source review found no arbitrary-path writer in the
active fixture. BR-5 is therefore closed using the allowed scope correction;
the reader gate must never be cited as a write-confinement or sandbox proof.

### Baseline, provided controls, and scope truth

The isolated original command passed with 33 ordered markers, exact canonical
derivation/output, v2026.03, three pure adapter checks, active-document
postconditions, and one clean UIManager teardown:

```sh
TMPDIR=/tmp/opencode/book-reader-recheck.z01WI7/runs \
BOOK_READER_TMPDIR=/tmp/opencode/book-reader-recheck.z01WI7/runs \
KOREADER_BUNDLE=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03 \
KEEP_ARTIFACTS=1 \
make -C /tmp/opencode/book-reader-recheck.z01WI7/baseline/repo/pinenote/tools/book-reader check
```

Baseline log SHA256:
`7221664d82859b08c3fe0f6eacdde549028f23e8d1696b416262a255630957f4`.
Actual markers SHA256:
`7f589405a070907509ceca8b962ca44724d7b982e9ef8d9185c766e5484a8eaa`.

I also ran the implementer's suite in the isolated copy:

```sh
TMPDIR=/tmp/opencode/book-reader-recheck.z01WI7/provided-runs \
BOOK_READER_TMPDIR=/tmp/opencode/book-reader-recheck.z01WI7/provided-runs \
KOREADER_BUNDLE=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03 \
make -C /tmp/opencode/book-reader-recheck.z01WI7/baseline/repo/pinenote/tools/book-reader mutation-check
```

It killed all twelve listed mutations and returned
`RESULT: all reader adversarial mutations were killed`. Output SHA256:
`56897d199b1436a2545c5fc85f2c38f0383a68c84b5e2151f3b61deb8cb0d422`.
That result is valid but does not cover the three BR-3 survivors above.

The independent commands were captured in these exact drivers:

```sh
/tmp/opencode/book-reader-recheck.z01WI7/independent-mutations.sh
/tmp/opencode/book-reader-recheck.z01WI7/independent-owner-tests.sh

/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03/lib/koreader/luajit \
  /tmp/opencode/book-reader-adversarial.roA7pw/reentrant-counterexample.lua \
  /tmp/opencode/book-reader-recheck.z01WI7/baseline/repo/pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin

/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03/lib/koreader/luajit \
  /tmp/opencode/book-reader-adversarial.roA7pw/queue-constructor-counterexample.lua \
  /tmp/opencode/book-reader-recheck.z01WI7/baseline/repo/pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin
```

Driver/output hashes:

```text
341360d522371fda18a3423a2eb9594e72f745a879051502c596ca3779dbc9dc  independent-mutations.sh
140c0db98610ec23cdabbe1a5d3409822aa309dc1c27c2b28621107bda080215  independent-owner-tests.sh
55b965d831ef336100c63b96fed120b8e6e4453e53f75a507c0a6f57a9a2623a  baseline-check.out
7e6b7035bc4105701285217271a789e2e52ec5bbba4fe3a3b3c21f603d89fead  old-reentrant.out
2b3519416e60c10856909602fb1b39fc3181825c907d37854b0036e3e883f421  old-constructor.out
6ca325b7c1f05b08021e1b7252b6ec0fa8b57798f808b6f1d60e79e5176707d7  independent-owner-tests.out
2dd715e22794d09ddda88435a72303d3b0f1c2d84bce2944ce5a9d25f8913047  omitted-dialog-close KOReader log
```

The independent mutation driver contains the exact source substitutions and
runs each copy with isolated `TMPDIR`, `BOOK_READER_TMPDIR`, repository root,
and explicit bundle. Additional exact commands after that driver changed the
package's `(version %koreader-version)` to `(version "2099.99")`, exercised a
symlinked compatibility bundle, inserted a missing-output
`built-derivations`, and added the independent dialog-state print. Their logs
remain below the same recheck root. All shell files in the active tool passed
`sh -n`; `shellcheck` was unavailable.

`python3` occurs only in `run-mutation-tests.sh`, where it rewrites isolated
host test copies. It is not used by `make check`, KOReader, the Lua fixture, or
the canonical Guile evaluator, and it is **not** a production runtime
requirement. The selected production Book runtime remains Guile; no Guile
broker/wire integration is implemented or validated by this reader fixture.

This recheck accepts only the desktop/offscreen KOReader seam once BR-3 is
fixed. It does not accept a wire protocol, broker, capability model, durable
save path, immutable production plugin graft, ARM64 service wiring, or any
hardware/display/input/power property.

### Recheck input hashes

```text
9b455fcd58eeb2ab03e18d94237de3052a43a8de1a85d4466e7d75c4a9f1d239  pinenote/tools/book-reader/canonical-koreader-output.scm
7f589405a070907509ceca8b962ca44724d7b982e9ef8d9185c766e5484a8eaa  pinenote/tools/book-reader/expected-markers.txt
df6be0be682fa21859a63f1a3d914e7e1ee1be63b6eb0ddb01667b98217e7291  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/interaction_source.lua
e4b86953d177f6a3cb005d817543d56d5f2996be3dcf8bc80cd415bb3fb9dd65  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/main.lua
4cba23d37267091b9d7579b4f7e3dcce410cb64e9885974a61b49d7871195a8c  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/_meta.lua
40f0c16112b8734c3d36a187df8854d7bfb151c7868f4ec074ebb396ad656a65  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/public_seam_probe.lua
3051d24090152fd873a197cab6bfcbc88f977dbb4124ddf1ddbf910e62c9b7ff  pinenote/tools/book-reader/lint-fixture.sh
db5abdf7c44086b80117b7bbd78a12bc1af50b19fa468f03a8aea383abb75653  pinenote/tools/book-reader/Makefile
97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354  pinenote/tools/book-reader/process-identity.sh
b3ab5a29bc1ce414f8c5992fa87da7592574d2c99ae48ec189fec99881ca3c05  pinenote/tools/book-reader/README.md
fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c  pinenote/tools/book-reader/record-exec.sh
d08c65c69ca8ce04ec93780cd03ec5bf4353ba86c0294960fc25657a8034a5c2  pinenote/tools/book-reader/run-mutation-tests.sh
5a551e449af3bed3538e713a2bfaa761ce4b8ce920be78e53ffd93858180dfde  pinenote/tools/book-reader/run-tests.sh
1d2f15c92182376df69249933cfcb060a9d3a39b0ec2eb62e3086be15861c43f  pinenote/tools/book-reader/term-resistant-helper.sh
07c15cc7316d6ee714f7a2c03e2cdd7d9848bda2b5f09aba10372b28d6ddf624  pinenote/tools/book-reader/test-interaction-source.lua
6c8d4386996fe85c235d9670799fd87377b93015de47b159f4d5631b01c664a6  pinenote/tools/book-reader/test-timeout-owner.sh
e1507aeb8f0d2ac36efcead795bebdf28c9bb067dd52550e10bd64c26e7a080e  pinenote/tools/book-reader/timeout-owner.sh
27c80a8ba9def0a154970358138ba81629cf3514eba12a7417535454502fca71  doc/book-computer-reader-spike.md
81c075b539803e1ffb1a67724cfa57c7f38698edbaff2889ebaaea00a5da8567  pinenote/packages/koreader.scm (pin oracle only)
```

## Focused independent final recheck: BR-3 — 2026-09-04

Recheck root: `/tmp/opencode/book-reader-br3-final.msNEMF`. The active source
was copied there before execution; only isolated copies were instrumented or
mutated. No implementation file, user profile, package output, or device was
changed. No build, realisation, network, hardware, SSH, UART, or VM was used.

### Final verdict

**BR-3 is closed. All BR-1 through BR-5 are now closed, and the scoped
desktop/offscreen KOReader reader gate is accepted.**

This acceptance is deliberately limited to the existing trusted fixture and
the pinned KOReader seams it exercises. It is not acceptance of malicious or
self-modifying trusted fixture code, a wire protocol, broker, Guile service,
capability model, durable save path, production plugin graft, ARM64 system
wiring, or hardware behavior.

### Positive baseline

The independently copied baseline passed its ordinary timeout-owner checks,
pure Lua checks, real offscreen ReaderUI flow, and package-pin checks. Its 33
markers exactly matched `expected-markers.txt`; no new success marker stood in
for a state assertion. It ended with:

```text
close-document:active-interaction
source-removed:document
selection-action:removed
document-close:postconditions
result:ok
PASS: pinned KOReader offscreen reader integration probe
```

The exact command was:

```sh
TMPDIR=/tmp/opencode/book-reader-br3-final.msNEMF/runs \
BOOK_READER_TMPDIR=/tmp/opencode/book-reader-br3-final.msNEMF/runs \
KOREADER_BUNDLE=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03 \
KEEP_ARTIFACTS=1 \
make -C /tmp/opencode/book-reader-br3-final.msNEMF/baseline/repo/pinenote/tools/book-reader check
```

### Independent replay of the three prior survivors

I recreated the three mutations directly in fresh copies rather than using
`run-mutation-tests.sh` as the oracle:

| Mutation | Result | Intended diagnostic |
|---|---:|---|
| Replace public highlight add with direct `_highlight_buttons[ACTION_KEY]` assignment | rc 1 | `selection action did not use public ReaderHighlight add seam` |
| Replace public highlight remove with `removed = expected` plus direct registry deletion | rc 1 | `selection action did not use public ReaderHighlight removal seam` |
| Omit `UIManager:close(dialog)` | rc 1 | `interaction dialog remained in UIManager stack after normal close` |

The omitted-close copy also printed an unprefixed independent observation from
the retained function argument:

```text
INDEPENDENT_RETAINED_DIALOG_SHOWN:normal close:true
```

That demonstrates that the mutation creates the same real widget-stack defect
as before and that the revised gate now catches it.

For the positive path, another isolated copy printed the same observation
without removing `UIManager:close(dialog)`. It retained each original dialog
reference and queried KOReader's actual `UIManager:isWidgetShown`:

```text
INDEPENDENT_CLOSED_DIALOG_SHOWN:normal close:false
INDEPENDENT_CLOSED_DIALOG_SHOWN:callback error:false
INDEPENDENT_CLOSED_DIALOG_SHOWN:active document close:false
PASS: pinned KOReader offscreen reader integration probe
```

Thus clearing `self.interaction_dialog` cannot satisfy the revised check: the
normal and error paths carry the returned dialog into their delayed
postconditions, while the active-document path captures it before
`ReaderUI:onClose` emits `CloseDocument`.

### Public-method counters are attached before the calls

Source inspection confirms the counters are method wrappers, not fixture
assignments that merely manufacture expected values:

1. `Probe:init()` installs `PublicSeamProbe` on the actual
   `self.ui.highlight` before `plugin-init`, `ReaderReady`, or action
   registration.
2. `public_seam_probe.lua` saves the two original ReaderHighlight methods,
   installs wrappers on that object, increments only the entry for an observed
   action key, and then calls the corresponding original method.
3. `observeAction(ACTION_KEY)` creates the `0/0` counter immediately before
   the fixture invokes `addToHighlightDialog`.
4. The fixture requires add/remove `1/0` immediately after registration and
   `1/1` after teardown, alongside independent registry checks for the exact
   factory and then nil.
5. A source search found no other writes to action `counts.add` or
   `counts.remove`. The fixture only stores and reads the returned counter
   table. The observer restores all wrapped methods and the fixture checks the
   restored function identities.

The direct-private add and state-equivalent direct-private remove mutations
therefore preserve registry effects but cannot increment the public-method
counters; both turn the gate red as required.

### Supplied mutation suite and residue

After the independent three-case replay, I also ran the supplied suite in the
isolated copy:

```sh
TMPDIR=/tmp/opencode/book-reader-br3-final.msNEMF/mutation-runs \
BOOK_READER_TMPDIR=/tmp/opencode/book-reader-br3-final.msNEMF/mutation-runs \
KOREADER_BUNDLE=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03 \
make -C /tmp/opencode/book-reader-br3-final.msNEMF/baseline/repo/pinenote/tools/book-reader mutation-check
```

It killed all fifteen mutations for their named diagnostics and returned
`RESULT: all reader adversarial mutations were killed`. Its temporary mutation
root was removed. Final process searches for the full BR-3 recheck root were
empty.

The independent mutation and positive-instrumentation commands are captured
verbatim in:

```text
/tmp/opencode/book-reader-br3-final.msNEMF/independent-br3.sh
SHA256 d8aa929aca4b317a42602903b112019480374d8bb7ca77dec48f918f1b01d24b
```

Evidence hashes:

```text
eacc2f2e0aaa4123b97f3f7d81bb2f082507dee552011d5b6857654bd31590c7  baseline.out
c3d85f5e57d07a760b742e7ca11aa8341faaff56685b0bf09bd2c64a09cbf4ad  mutation-check.out
a2115f81dd394b91a432a16c293627594a6aa8d01002adc3656bb1a9f1164fbd  baseline koreader.log
7f589405a070907509ceca8b962ca44724d7b982e9ef8d9185c766e5484a8eaa  baseline actual-markers.txt
92589cb1fc316e0907acbd567529d9bc4fd291463fe3ed4081d9353ba38412e2  independent private-add output
9f32822c3077ce2e018bf9277ed4d4c7f740a3412b07f5c41c94cabc3e9f9f1f  independent private-remove output
d750a7f6aff83a691f1486f33b5c72c93fb60bd5408289957831ab9bbc52888c  independent omitted-close output
0f58e18cd2d14f8e9d5dcb8e129ff6672cb75315c613c5ed22d83eb84ca21703  omitted-close KOReader log
e6496350a08f34660dabacd933a16c22a10da14fa96c1378a65e65d57f6422ba  positive widget-stack output
9e65bd430711bfeb6c68c0e6df7cebc16f4dcf8b49977c099270863c37e4bc03  positive widget-stack KOReader log
```

### Final recheck input hashes

```text
9b455fcd58eeb2ab03e18d94237de3052a43a8de1a85d4466e7d75c4a9f1d239  pinenote/tools/book-reader/canonical-koreader-output.scm
7f589405a070907509ceca8b962ca44724d7b982e9ef8d9185c766e5484a8eaa  pinenote/tools/book-reader/expected-markers.txt
df6be0be682fa21859a63f1a3d914e7e1ee1be63b6eb0ddb01667b98217e7291  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/interaction_source.lua
7f4eeb0b951756bd06131aae6d70220c1695489b482c5bd8dca0f85f161ea236  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/main.lua
4cba23d37267091b9d7579b4f7e3dcce410cb64e9885974a61b49d7871195a8c  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/_meta.lua
0dd89a8a27c53ec515324446e1b9927e64e090d52c1bd0e41fe76d78b4d04bdb  pinenote/tools/book-reader/fixture/bookreaderprobe.koplugin/public_seam_probe.lua
3051d24090152fd873a197cab6bfcbc88f977dbb4124ddf1ddbf910e62c9b7ff  pinenote/tools/book-reader/lint-fixture.sh
db5abdf7c44086b80117b7bbd78a12bc1af50b19fa468f03a8aea383abb75653  pinenote/tools/book-reader/Makefile
97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354  pinenote/tools/book-reader/process-identity.sh
bee9b5097a9372dc6e2c3d428b7cb2e38fda035ebb58f10069796339e0196908  pinenote/tools/book-reader/README.md
fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c  pinenote/tools/book-reader/record-exec.sh
50794ee7e000069fe7ff7bf23e6a12716336f89ef790fa7f6abae89a2350eb28  pinenote/tools/book-reader/run-mutation-tests.sh
5a551e449af3bed3538e713a2bfaa761ce4b8ce920be78e53ffd93858180dfde  pinenote/tools/book-reader/run-tests.sh
1d2f15c92182376df69249933cfcb060a9d3a39b0ec2eb62e3086be15861c43f  pinenote/tools/book-reader/term-resistant-helper.sh
07c15cc7316d6ee714f7a2c03e2cdd7d9848bda2b5f09aba10372b28d6ddf624  pinenote/tools/book-reader/test-interaction-source.lua
6c8d4386996fe85c235d9670799fd87377b93015de47b159f4d5631b01c664a6  pinenote/tools/book-reader/test-timeout-owner.sh
e1507aeb8f0d2ac36efcead795bebdf28c9bb067dd52550e10bd64c26e7a080e  pinenote/tools/book-reader/timeout-owner.sh
b209359a61943f1fdaf7d9987f7d6c163bc64e7260c1c8a101c54d277865badd  doc/book-computer-reader-spike.md
81c075b539803e1ffb1a67724cfa57c7f38698edbaff2889ebaaea00a5da8567  pinenote/packages/koreader.scm (pin oracle only)
```
