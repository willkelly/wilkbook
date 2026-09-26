# Workbench sandbox and self-authoring work — 2026-09-15

Later continuation: [`2026-09-19-workbench-resource-qualification.md`](2026-09-19-workbench-resource-qualification.md)
records the finite resource/access gate, the observer retirement correction and
the final 20-execution ARM pass. Statements below retain their dated scope.

The operator reported that the desktop authoring prototype was working and
asked to advance as far as possible. The starting implementation and desktop
renderer correction are recorded in
`2026-09-11-book-workbench-adversarial.md`. Those changes, the earlier note
lifecycle fixes, and the generation-21 policy/hardware records were already
uncommitted when this work began. The preexisting `.claude/` directory is not
part of this work.

## Current disposition

- **Native source-defined editor accepted:** full R0 → R1 → R2 continuation,
  restart recovery, real KOReader widgets, trusted installation and recovery,
  13 integration tests and completed logic/UI/project-fit reviews. The visible
  desktop fixture launched successfully and later exited cleanly.
- **Text-function sandbox supervisor accepted offline:** identity-bound process
  ownership, canonical input paths and conservative cleanup failure behavior.
  Native seams do not establish gVisor enforcement.
- **ARM64 authoring scenario accepted on final v9 sources:** 92 assertions across
  14 executions, with action delivery and cleanup complete for each. Its retained
  workspace passed read-only fsck/SQLite audit and contains the exact same
  database bytes as the separately audited v8 pass. Independent final evidence
  review accepted this scope; failed attempts remain below.
- **Open product gates:** interactive candidate editing in a sandbox, the
  long-lived sandboxed editor join, hostile resource enforcement and on-tablet
  self-revision. No Workbench deployment occurred in this work.

## Scope and sequence

1. Validate and execute the source-bound Workbench OCI bundle through the
   existing owned runsc/FD-3 infrastructure.
2. Exercise the actual workspace authority and sandbox callback together in
   ARM64 QEMU, including failed execution and cleanup.
3. Implement the distinct self-authoring editor contract: endpoint-bound
   workspace operations, an authored action surface, trusted installation and
   recovery controls, and a complete editable seed program.
4. Join the editor components and exercise successor continuation with the
   trusted host held fixed.

The existing text-function runner and the new editor have separate entry
contracts. Changing a text function demonstrates authored execution; successor
continuation additionally requires the new editor to retain its authoring
workflow. Execution-isolation, native UI, QEMU, and physical-device results are
recorded at the scopes actually exercised.

## Shared authoring scenario review

An independent reviewer examined `sandbox-scenario.scm` before the QEMU run.
The initial native pass did not by itself close these findings:

| Finding | Correction |
| --- | --- |
| An arbitrary refusal could satisfy an expected broken-source check | Require explicit false success status, the matching operation and exact refusal code; require trusted execution-started evidence from the callback. |
| A subsequent successful launch did not establish prior cleanup | Require a separate trusted cleanup-complete observation for every callback, including failures. The native callback now reports both execution and cleanup observations. |
| Unactivated source and rollback were not reopened independently | Reopen SQLite/authority before activation, and again after rollback; compare saved draft and installed pointer separately and execute the recovered installed source. |
| The preview-lifetime comment lacked an outstanding ticket at close | Preview immediately before close; after constructing the new authority, require activation refusal before an `open` request can independently invalidate authorization. |

The scenario refuses a nonempty test workspace before opening the store. It
uses trusted, fixed check labels; authored output is never a console success
marker. Reopening its SQLite connection is a connection-recovery check, not a
physical-power-loss or OS-reboot claim.

## Implementation and execution record

Runtime, QEMU composition, scoped workspace authority, generic editor surface,
and authored seed/runner work have separate owners. The final checks and review
dispositions will be recorded here as each integration completes.

### Native authoring baseline

The strengthened text-function gate passed with 168 storage, 71 authority,
153 preview and 112 sandbox-seam assertions, the shared durable-authoring
scenario, 503 UI/FSM assertions and the existing real KOReader join. Its log is
`/tmp/opencode/book-workbench-sandbox-pre-qemu-check.log`. The sandbox-seam tests
use controlled native substitutions for mount/cgroup boundaries; they are not
actual runsc evidence. The newly registered QEMU adapter tests also pass under
the native supervisor Guile; that host-only run is retained in
`/tmp/opencode/book-workbench-qemu-adapter-registered.log`.

The source-defined editor's first aggregate pass contained 58 workspace-protocol,
107 delegate/SQLite and 54 surface assertions, eight real-child runner tests,
seven integration tests and 104 Lua assertions. The actual-widget join initially
failed because KOReader injects its ReaderUI owner as `plugin.dialog`. The
plugin now retains its editor separately as `editor_dialog`; the injected owner
survives Close/reopen and teardown. The real-widget test passed after that fix.

### Workspace authority review

The independent reviewer reran the protocol/delegate suites with the same
`nlkcijvhrj9xfz4dz134iwlc9z52mb4s…` supervisor used by the native composition.
Owner/grant isolation, lexical integer checks, task retirement, stale receipt
suppression, defensive copying and installation CAS held up.

- **Export identity corrected:** `source_digest` describes the saved draft,
  while export contains installed source. `exported_revision` now names the
  artifact explicitly, and the seed's action/status describe installed export.
  The regression keeps draft and installed source different and verifies no
  sealing side effect.
- **Sequence exhaustion corrected:** check exhaustion before sequence equality,
  so the final legal operation followed by another request gives the intended
  terminal refusal.
- **Partial installation progress pinned:** seal and activate are separate
  transactions. A failed activation can leave a sealed, uninstalled revision
  consuming a permanent quota slot. Tests inject failure after seal, reopen the
  store, and verify retained source with unchanged draft/pointers/epoch.

### Runtime review gates

Actual QEMU execution is held while these concrete findings are corrected:

| Finding | Observed evidence / required correction |
| --- | --- |
| Detached support processes escaped group-only reap | Both reviewers reproduced a `setsid` descendant surviving a result marked cleanup-complete. Cached gVisor source also creates separate sessions for Sentry and Gofer. Own/reap the complete execution domain. |
| Host-killing runsc bypassed container destruction | Cached nonterminal runtime source relies on deferred destruction. Use bounded owned container stop/delete operations, then verify resource cleanup on actual failures. |
| Preparation cleanup exceeded the total deadline | A late generation failure used deadline-free recursive removal. Propagate the original deadline into preparation failure cleanup. |
| Immutable validation discarded canonical paths | A mutable alias passed validation then could select different code/data. Retain canonical store targets for interpreter, adapter, closure and fixed runtime. |
| Private leaf mode did not protect mutable ancestry | A root-owned 0700 directory beneath an attacker-owned directory remained replaceable. Validate stable trusted ancestry. |

The lifecycle correction adds a separate runtime-owner input. The QEMU package
and service must include that exact immutable helper; derivation success before
this interface change does not validate the new composition.

**Package seam corrected:** the package exports the immutable owner, the service
passes it in the closed callback configuration, and the static gate checks
source bindings, module-union contents, retained profiles and SIGPIPE/load
ordering. Seventeen static checks and 237 host-only adapter checks pass after
that wiring; `/tmp/opencode/workbench-qemu-adapter-owner-wiring.log` retains the
adapter run. Previous system/image derivations are superseded by this source
change and must be regenerated after runtime review closes.

The adapter now also retains canonical store paths for its four forwarded host
executables. A symlink-retargeting regression fails on the earlier adapter and
passes on the correction; 248 adapter assertions pass. The reproduction recipe
was independently checked against staging and launch code. It captures emitted
console diagnostics explicitly because the guardian removes the inner run
directory, and shows a valid private absolute workspace-export destination.

### Generic UI and native coordinator review gates

The initial real-widget pass did not close the additional review findings:
multiline title height must participate in layout; retired Close callbacks must
retain their originating view; native Back must reach trusted Close; and idle
socket polling must stop when no reply/output is pending. Actual edit tracking
must use native text edits and observe `edit_serial`, rather than assume
`setInputText(..., true, ...)` dispatches the same callbacks as mock widgets.

The native coordinator additionally needs a complete visible graphics command
and validation before child startup, and a deadline-aware socket wait instead
of continuous 100 Hz idle polling. These are separate from the Lua polling fix.

**Coordinator fit/performance review closed:** the cached Mesa default and
early file validation now precede authority startup, with offscreen exempted.
The coordinator waits on sockets and the nearest deadline, using a 200 ms quiet
cap and short polling only while a backend worker needs observation. The
project-fit reviewer confirmed both corrections and the packaged runtime-owner
input by source inspection; no measured CPU or idle-power claim is made.

**UI-source review closed:** the four plugin findings are fixed. The current
title participates in native layout; Close captures its view/dialog; native Back
uses that guarded Close; and polling is registered only for pending replies or
output. The owner reports 125 Lua assertions, 54 Scheme assertions and actual
offscreen geometry/Back/stale-Close/idle checks passing. The independent reviewer
confirmed the source corrections without repeating the suite. Actual edit-serial
integration coverage and the host fixes below remain separate gates.

### Native host-boundary review gates

The independent host reviewer reproduced three further issues with actual
authority/SQLite sessions; the original passing suite did not cover them:

- Preview teardown reaped adopted descendants globally, killing a detached
  support process belonging to the still-running main editor. Each execution
  needs its own descendant ownership boundary.
- A draft raising an ordinary exception could reset its socket before consuming
  initialization frames; the uncaught reset escaped the preview and ended the
  application. It must become a failed-preview result with cleanup, retaining
  the installed editor for correction.
- A stalled pump admitted messages before checking the action deadline. A late
  presentation could clear the deadline, or a newly received save could commit
  after expiry before the timeout was reported. Check expiry before admission
  and distinguish it from an already-admitted transaction completing later.

**Native host review closed:** each execution now has a dedicated
`native-child-owner.py` subreaper and an explicit complete-reap acknowledgement.
Candidate resets become failed previews; cleanup failures remain errors.
Admission and presentation publication check deadlines first. The owner reports
13 integration tests passing in the aggregate gate. The independent reviewer
reran five focused cases in 3.239 seconds, covering all three original
reproductions, an admitted write with a suppressed late receipt, and retirement
during preview. Accepted scope is the explicit trusted-native demo.

**Visible native launch:** the default command launched from a new private
`/home/wkelly/workbench-editor-dev` directory. Scoped Sway metadata and a cropped
window capture show the actual rendered KOReader introduction on workspace 4;
the reader command was checked against the expected desktop wrapper. Evidence:
`/tmp/opencode/book-workbench-editor-visible-{window.json,window.png}` and
`/tmp/opencode/book-workbench-editor-visible-demo.log`. This is an agent-observed
visible startup, not a new operator acceptance of individual authoring actions.

Native editor source identity at this accepted checkpoint: **20 code/test files,
232,448 bytes**. A sorted SHA-256 manifest of all `.scm`, `.py`, `.sh` and `.lua`
files under `pinenote/tools/book-workbench-editor/` (excluding `__pycache__`) is
retained at `/tmp/opencode/book-workbench-editor-native-source.sha256`; its hash
is `b627bfbbe9f3176f484e2c2a0936e822288ad294283571dd21f57bceccab080a`.
The shared source-store backend remains `dea6439c…`, schema `8a6a9a7e…`, and
desktop wrapper `8c07c785…`. Native dependencies remain supervisor `nlkcijv…`,
KOReader `p9wkidd…` and Mesa `ikfz8dk…`, with full paths in the tool README.

### First image realization, held before boot

After the full text-function gate passed
(`/tmp/opencode/book-workbench-reviewed-runtime-check.log`: 168/71/153/145
component assertions, four shared-scenario assertions, 248 adapter checks,
503 UI/FSM checks and the existing integrations), the pinned derivation gate
passed. It realized image
`/gnu/store/aqkbg3nkl6mjhd1qqj733399bfbxshvs-disk-image`, embedded system
`/gnu/store/7q9s1k7dldshwigkik71jq24lwpmjnm4-system`, from
`/gnu/store/2biljxj4vai2s9gwnk0g7ymw1243mg5y-disk-image.drv`.
Logs: `/tmp/opencode/book-workbench-reviewed-qemu-derivation.log` and
`/tmp/opencode/book-workbench-qemu-build.log`.

The second runtime reviewer then found a remaining fallback-ordering issue:
`runsc delete --force` can signal saved numeric Sentry/Gofer PIDs. Invoking it
after reaping those processes releases their identities for reuse; our own
pidfd signals do not protect signals issued inside runsc. This image was
therefore **held before any QEMU boot**. The bounded primary `kill --all` path
and the dedicated owner/deadline corrections passed offline review, but the
unsafe force-delete fallback must be removed or supplied with complete retained
identity proof. The subsequent source correction requires new derivations.

**Final offline runtime review closed:** force-delete is removed. The only
control operation is `kill --all ID KILL`; forced pidfd termination reaps owned
children but withholds cleanup proof and retains resources. A native deletion
trap models stale numeric-PID signalling and is never invoked in the regression
cases. The owner reports 153 sandbox checks and warning-free compilation; the
reviewer confirmed the exact control allowlist, conservative proof handling and
tests by source inspection. No source-level blocker remains before QEMU.
Final owner hash: `1f4f0bbc425c7354e8be1c7e747b2bec6a2b02357d1c2d31885b4b482b747bb5`;
sandbox hash: `c8b881fa93c3156675c0a0ab1e30c3981cac5e9943c91749a42f28f39c448789`.

The refreshed gate/build passed for image
`/gnu/store/910a6jif8vzc5m7640ayld4c2rpbg8k2-disk-image`, embedded system
`/gnu/store/qc9ylyybzmz1krh7fn8nvkyrhn7cb9f9-system`, derivation
`/gnu/store/ji6x38xp3a0vjv3n39p5sbphrrbj96l6-disk-image.drv`.
Logs: `/tmp/opencode/book-workbench-qemu-derivation-v2.log` and
`/tmp/opencode/book-workbench-qemu-build-v2.log`. Kernel and source-built gVisor
remain the pinned `334ljs8q…` and `djgy782a…` outputs.

### QEMU adapter attempt 1 — preparation refusal, no boot

The final runtime image was staged successfully as
`book-execution-spike/build/artifacts/workbench-sandbox-20260915-v2`.
Source inspection of its 353-path system closure matched the exact runner,
standalone owner, guest entry, sandbox module, preview module, scenario and
workspace backend to the reviewed checkout bytes:
`/tmp/opencode/book-workbench-qemu-source-inspection-v2.log`.

The first adapter invocation failed before starting QEMU with `mkdir: File
exists`. Its added workspace preparation called the existing
`supervisor-environment` factory a second time, after the outer engine had
already created that environment's private directories. The mock adapter tests
had skipped the real factory's side effects. The fix must reuse the captured
outer environment and add that real preparation-order regression; the guest
image itself is unchanged by this host-only correction.

Evidence: `/tmp/opencode/book-workbench-qemu-v2-kpd9yw0s/runner.log` and
`/tmp/opencode/book-workbench-qemu-v2-run.json` (exact argv). The guardian removed
the inner run tree; no workspace output was published. This is not a failed ARM
boot or a sandbox-runtime result.

**Preparation correction passed:** the adapter captures the real factory's
single environment result, verifies its root identity and QEMU executable, and
restores the binding on exit. Its regression fails on the old adapter with the
same `EEXIST`, then passes with exact directory identities retained. Failed
preview diagnostics are now separately escaped and bounded in the guest, so an
early scenario assertion does not discard the cause. Newline/CR marker injection,
the 1,024-character bound and success omission are pinned. All 293 host adapter,
preflight and diagnostic assertions pass; guest compilation is warning-free.
Log: `/tmp/opencode/workbench-qemu-diagnostics-and-environment.log`.

### QEMU adapter attempt 2 — guardian argument refusal, no boot

The diagnostic-enabled image built and staged as
`/gnu/store/ns1kdz8c9pwa077zjnls3f913r5323ap-disk-image`, embedded system
`/gnu/store/4qrfrsssl6x0snj0j4v0qy5940lq3mw0-system`, from
`/gnu/store/115pf1i9pr22cy932209rr0kf6j1wwz3-disk-image.drv`.
Its reviewed runtime/module bytes and the new guest entry matched the 353-path
closure inspection (`/tmp/opencode/book-workbench-qemu-source-inspection-v3.log`).
Build/stage logs use the `book-workbench-qemu-*-v3.log` names.

The next adapter invocation again stopped before QEMU, this time because the
workspace helper passed `#f` where the real process guardian requires its root
liveness port. The fix must carry the actual retained port through preparation.
This prompted a stronger host-only integration check: real private snapshots,
real `qemu-img`/`mke2fs` and real guardians, substituting only the final QEMU
launch. The earlier fake-outer checks did not cover that complete helper join.

Evidence: `/tmp/opencode/book-workbench-qemu-v3-z9xdk1do/runner.log` and
`/tmp/opencode/book-workbench-qemu-v3-run.json`. No workspace output was published.
The guest image remains reusable for this host-only correction.

The separate native desktop demo has since exited with status zero. Its
persistent workspace remains available; the earlier window observation does
not imply that the process is still running.

**Guardian handoff corrected:** the adapter now captures and reuses the actual
outer root-liveness port, retaining outer ownership and restoring the helper
binding. All 320 adapter assertions pass. The new opt-in
`test-real-qemu-preparation.scm` reproduced the old `port-closed? #f` error and
then passed 55 checks with ten real helper calls, both real guardians, workspace
publication and cleanup. Only final QEMU execution was substituted. Logs:
`/tmp/opencode/workbench-real-preparation-{before-fix,final}.log` and
`/tmp/opencode/workbench-qemu-root-port-adapter.log`.

### Final native aggregate and inactivity correction

Both final Make entrypoints pass:

- `/tmp/opencode/book-workbench-final-integrated-check.log`: 168 storage,
  71 authority, 153 preview, 153 sandbox-seam, four shared-scenario and 320
  adapter assertions; 503 UI/FSM checks; the existing fresh-process, launcher
  and real-widget integration gates. The one optional graphics test is skipped
  without an explicit graphics input; the visible launch is separate evidence.
- `/tmp/opencode/book-workbench-editor-final-integrated-check.log`: 58 protocol,
  107 delegate, 54 surface, eight runner and 13 integration tests, plus 125 Lua
  assertions. The integration group completed in 16.936 seconds.

Desktop automatic inactivity exit is now disabled by default. The previous
timer observed protocol traffic rather than local typing and could terminate
unsaved editing after thirty minutes. A positive explicit `--idle-seconds`
retains that protocol-inactivity behavior; startup/action deadlines and process
cleanup are unchanged. The targeted CLI/idle test and the final aggregate pass
cover this small correction. Current native code/test identity: **20 files,
232,526 bytes**, manifest
`/tmp/opencode/book-workbench-editor-native-source-v2.sha256`, SHA-256
`6afff18e0b8977856f7ba8986d5f0a32a3c747c3c439fcd796e3d9edcc2faa8e`.

### ARM boot 1 — boot/shutdown observed, result transport missing

The corrected host preparation launched the v3 image in ARM64 QEMU. The guest
booted the selected system, mounted root on `vda1` and the separate workspace
on `vdb`, then shut down cleanly at kernel time 16.322 seconds. No Workbench
marker or diagnostic reached the serial console. The service used Shepherd's
default logging, which moved away from the early console after system logging
started. Therefore neither scenario success nor the cause of a possible
scenario failure can be inferred from this run.

Evidence: `/tmp/opencode/book-workbench-qemu-v3-boot1-ztdiic7g/runner.log` and
`/tmp/opencode/book-workbench-qemu-v3-boot1-run.json`. The checker correctly
refused the missing markers and did not publish a workspace. The next image
must route trusted guest stdout/stderr directly to the console before module
loading; authored output remains separately bounded and captured.

**Console routing tested:** the trusted bootstrap now opens `/dev/console`,
duplicates it onto stdout/stderr, sets both Guile ports to UTF-8, closes the
extra descriptor and emits `BOOK_WORKBENCH_BOOTSTRAP: console-ready` before
module loading. The runtime still overrides child output with its bounded
captures. Twenty-three system/console checks pass, including five fresh-process
checks of raw output, UTF-8, descriptor cleanup, module-load errors and bypass
of inherited logging. The 320 adapter assertions also pass. Logs:
`/tmp/opencode/workbench-console-routing-check.log` and
`/tmp/opencode/workbench-console-adapter-check.log`. This corrects observation
and does not retroactively qualify the unobserved boot.

### ARM boot 2 — observed closure-format refusal

The console-enabled image built and staged as
`/gnu/store/n87sfd0yz00kr3vrmsggxc7n8xamwjr9-disk-image`, embedded system
`/gnu/store/gk9wmzvbfya92qrdh6gjgqfmc0aqdsrf-system`, from
`/gnu/store/ci3b85mnnpa1wggw0i403rddjpykdxsg-disk-image.drv`.
The bootstrap marker and the scenario's initial snapshot checks reached the
console. The first preview then refused its language closure before execution:
the inherited package serializes a Scheme list, while the callback tokenized
the file as newline-separated paths. The diagnostic identified the invalid
first token exactly. Execution and cleanup flags were both false, so the
scenario correctly failed rather than accepting a preflight refusal as an
executed broken-source test.

Evidence: `/tmp/opencode/book-workbench-qemu-v4-boot2-zus2gejs/runner.log` and
`/tmp/opencode/book-workbench-qemu-v4-boot2-run.json`. The guest powered down
cleanly at kernel time 16.389 seconds; no workspace was published. The next
correction must parse the actual immutable closure representation and test
against a realized package input, retaining the canonical-path check.

The independent integration reviewer found no implementation blocker in the
environment/guardian-port reuse or early console routing. It verified binding
restoration, port ownership and the runtime's separate child capture descriptors
by inspection. Two mock mismatch cases needed stronger setup to reach their
intended correlation checks rather than the missing-port guard. Both now first
establish a live borrowed port, vary only their intended argument and require
the exact expected diagnostic; 326 adapter assertions pass after this test-only
correction (`/tmp/opencode/workbench-qemu-correlation-test.log`). Host inspection
after these four attempts found only retained
`runner.log` files in their run bases, with no leftover inner run trees or
published workspace images.

**Closure-format correction tested:** the callback now reads one Scheme list of
strings from a canonical immutable file, bounded to 262,144 UTF-8 bytes and exact
EOF. Malformed lists, extra forms, non-string entries and the old line format
are rejected. Canonical alias retention and pre-preparation requisite validation
remain in place. The 175 sandbox assertions include the actual realized ARM
profile/manifest pair from the observed image, descriptor cleanup and byte
bounds; compilation passes. The inherited manifest is
`/gnu/store/8a8c36ikjvgw0xfhwax1m5jl050g3akz-wilkbook-book-execution-language-closure`,
SHA-256 `fb9355a2dc1941ac53f11ed9c694099daffe45126b307545142a2000ecbfe79d`.
Updated sandbox hash:
`d6fa7f5b30b5df57a51bb7464892026ed3146480e7141d37604b9efde192e896`.

The independent closure review closed the correction after 16 targeted checks.
The realized manifest contains 46 paths; both language entrypoints validate
against that profile without execution. This does not substitute for the next
ARM run. The v5 image is
`/gnu/store/k5fpiza468cr1gdrwg9jh7l24pvny33l-disk-image`, embedded system
`/gnu/store/pzhfhj1vvkw669bdz91kcv7lm4xv1h8p-system`, derivation
`/gnu/store/lmfw40gqw00w8hk8bn25iz2cs7wq7vxc-disk-image.drv`.
Lowering, build, exact source inspection and staging passed before its launch;
logs use the `book-workbench-qemu-*-v5.log` names under `/tmp/opencode`.

### ARM boot 3 — task ceiling hit during runsc startup

The v5 run progressed past closure validation and into runsc. The first and
latest trusted cgroup samples matched `memory.max=268435456`,
`cpu.max=50000 100000` and `pids.max=64`. The latest sample reported
`pids.events: max 1`, CPU usage 674,602 µs, 13 throttled periods and peak retained
sample memory 38,944,768 bytes. The task counter establishes that this ceiling
was reached during the run; it is not complete support-process accounting or a
general task-exhaustion acceptance test.

Runsc reported that its Sentry started, then failed waiting for startup sync
with EOF and attempted Destroy. The ordinary protocol had not initialized;
cleanup was reported incomplete and its runtime root retained inside the guest.
The scenario and outer checker correctly refused this result. The next check is
the ARM Systrap startup thread requirement against the newly introduced 64-task
cap, before selecting a revised bounded budget.

Evidence: `/tmp/opencode/book-workbench-qemu-v5-9_asr_hb/runner.log` and
`/tmp/opencode/book-workbench-qemu-v5-run.json`. Guest power-down completed at
kernel time 19.318 seconds. The outer guardian removed its disposable disk/tree;
no workspace output was published. Retained runtime resources inside that
discarded guest are not claimed to have passed per-preview cleanup.

**Source-based task sizing:** investigation traced the substantial cost to
LisaFS services for the mounted closure, rather than a fixed ARM Systrap
minimum. The 46 requisite paths, root filesystem and four source/module binds
imply 51 connections. Socket services, two channel services and client watchdogs
give an estimate of about 204 host tasks before other runtime overhead. Exact
pinned source references and qualifications are in `book-workbench/PREVIEW.md`.
The revised candidate cap is 256; 128 would not cover that initialized layout.
This remains an estimate, not a measured minimum or evidence that startup now
succeeds.

The generator, independent spec validator and live observer now require 256;
membership inspection is bounded accordingly. Failed-result diagnostics retain
separate execution and cleanup causes plus the root and stderr ending within
1,024 characters. The runtime owner and its conservative cleanup policy are
unchanged. The owner reports 196 sandbox and 153 preview checks passing, with
no unbound-variable/arity compilation warnings (the existing preview format
warning remains). Updated preview hash:
`7fd1a203116dcd4cf5286d332baf6b80353c904e8a101762a438201f04ca96c2`;
sandbox hash: `ebaa60b1d05e2d3afeb0538a8927cd2fc3691c9ca02b89489f15d4bab56177ab`.

The independent lifecycle/performance reviewer closed this narrow change offline:
the candidate budget is source-justified, the validator remains independent and
exact, and diagnostic truncation cannot change cleanup authority. Actual
startup/headroom remains a runtime question. The refreshed v6 image is
`/gnu/store/m9ndsk512g7hpwv17sc56a47sxmjqvxf-disk-image`, embedded system
`/gnu/store/ydlzn2lfqdgyn17dsvkfxvdk24awl90w-system`, derivation
`/gnu/store/9dz9sh0xxm37czs54rjz4xkhjlfrb94f-disk-image.drv`.
Lowering, build, exact source inspection and staging passed; evidence uses the
`book-workbench-qemu-*-v6.log` and `book-workbench-qemu-v6-run.json` files under
`/tmp/opencode`.

### ARM boot 4 — 256-task startup proceeds, pre-handshake SIGKILL

The v6 runtime progressed with `pids.max=256`. Its latest sample recorded
226 tasks, zero PID-limit events, memory 73,732,096 bytes and zero OOM events.
CPU usage was 3,788,153 µs across 76 periods, 75 throttled. These are sampled
observations, not measured maxima or whole-domain accounting.

Runsc logged raw guest wait status 9 (SIGKILL) before ordinary initialization.
The callback's
execution flag remained false, but **cleanup completed**: its normal lifecycle
removed the owned processes, namespace pin, cgroup and runtime tree. This is
the first observed actual-runtime cleanup pass in this sequence; the scenario
still correctly refused the missing initialization. The call ended before its
wall deadline. The two-second guest CPU limit during Guile module loading is
the next candidate to investigate, with better bounded stderr evidence needed
because teardown debug lines displaced the earlier cause from the small tail.

Evidence: `/tmp/opencode/book-workbench-qemu-v6-ff7_s8u3/runner.log` and
`/tmp/opencode/book-workbench-qemu-v6-run.json`. Power-down completed at kernel
time 27.373 seconds, and no workspace image was published.

The full native text-function aggregate also passed on these source inputs:
`/tmp/opencode/book-workbench-task-budget-check.log` (196 sandbox, 153 preview,
326 adapter assertions, the unchanged workspace/authority/scenario suites and
real KOReader join).

**CPU-budget candidate and failure evidence:** pinned-source inspection confirms
that runsc's logged status 9 is a raw guest SIGKILL wait status (host exit 137),
and that its hard CPU-limit timer can send that signal during Guile imports.
The timer uses gVisor's approximate runnable-task CPU clock, including sentry
execution; host cgroup CPU usage is not the same clock. The v6 log does not
uniquely identify the signal sender. The next candidate therefore requests
soft/hard guest CPU limits of ten seconds while preserving the twenty-second
service wall deadline including cleanup and all other resource bounds.

Failure-only stderr capture now accumulates bounded chunks (256 KiB maximum),
selects early/late non-debug text within 8,192 characters and emits a separate
escaped, invocation-correlated record bounded to 32,768 UTF-8 bytes. Explicit
truncation fields and owner outcomes accompany it; raw output remains data.
Tests cover forged markers, terminal escapes, invalid UTF-8, boundaries and an
actual child killed before hello. The owner reports 218 sandbox, 156 preview
and 342 adapter assertions passing. All three affected modules compile without
warnings after adding the missing full-format import and a leading-zero hash
regression. The lifetime owner is unchanged.

Runtime input hashes for this candidate:

```text
101a7e06c6cf77c1d5281aafc4e8f4bd9c90e64b80314a6bbb805c810f3194e8  workbench-preview.scm
2430df3d9be1e6b20edb9c88d4d7533f13b409ef70cefd93156e144bfd197f2e  workbench-sandbox.scm
cb1852eb53edf9a4cc528ed2974cb6cc80191bcba6720a9b925ed90b4ab766e1  guest-entry.scm
```

### ARM boot 5 — authoring path runs; observation race interrupts recovery

The v7 image is `/gnu/store/qpqxr5g57z1dyw11jmmzssbzkga9w437-disk-image`,
embedded system `/gnu/store/90qm4xicrksjmq81wypd0dljya4sn9yr-system`, from
`/gnu/store/scvmw9lnlp7lv8h2lpf4md5rwqwcm4y7-disk-image.drv`. The CPU/logging
changes passed focused independent review, lowering/build/source inspection
and staging before boot. The full native Workbench gate also passed:
`/tmp/opencode/book-workbench-cpu10-integrated-check.log`.

**Six normal sandbox executions passed initialization, result and cleanup.**
The actual SQLite/authority scenario exercised seed execution, saved draft
remaining uninstalled, preview, retirement of a closed preview ticket, durable
unactivated source after reopen, successor preview and activation, installed
successor behavior, export and installed recovery after reopening. The seventh
execution rejected the syntax-broken draft with initialization and cleanup both
proven; the draft and installed pointer remained as expected.

The eighth execution initialized and runsc exited successfully, with complete
cleanup, but the callback reported `fport_read: No such device` (ENODEV). The
likely cause is a cgroup observation racing normal runsc teardown: an open
kernfs file can become inactive before its read, while the observer only treated
ENOENT as disappearance. The scenario correctly stopped at `recovery-result`
rather than claiming the remaining exception/nontermination/rollback checks.
The next correction must distinguish an obsolete sample from a live-control
failure, retaining the pre-action control check and cleanup authority.

Evidence: `/tmp/opencode/book-workbench-qemu-v7-7oshrmr6/runner.log` and
`/tmp/opencode/book-workbench-qemu-v7-run.json`. The improved stderr record
preserved the successful runtime status separately from the observer error.
Power-down completed at kernel time 91.357 seconds; no workspace was published.

**Observation correction tested:** kernfs can return ENODEV when a previously
opened attribute loses its active node reference during removal. The observer
now discards that incomplete sample only during the fixed cgroup-file read
stage and only after confirming that the cgroup directory has disappeared.
Live directories, failed absence checks, unrelated ENODEV, EACCES, EIO and
malformed observations still fail. Exception rethrowing also preserves the
original errno instead of duplicating its key. Pre-dispatch control validation,
the last valid sample and all independent cleanup checks remain intact.

The 233 sandbox assertions include actual native completion after the injected
post-dispatch race, refusal to dispatch without a valid sample, and the retained
error cases. Compilation is warning-free. Only the sandbox module, its tests and
`PREVIEW.md` changed; all resource parameters remain those exercised by v7.
Updated sandbox SHA-256:
`c894341d5dc15cac38c927c7e70c13e27440bdcea25b7734fa781d8d3f8d8349`.

### ARM boot 6 — first full scenario pass and retained-state audit

The observer correction passed focused independent review, then the v8 gate,
build, exact source inspection and staging passed. Image:
`/gnu/store/y99y7p3inf2yi8zny9hi8fpm6xvqn1qb-disk-image`; embedded system:
`/gnu/store/sy429c1s5b1s0qn7b1lzsh3k7xh44bm6-system`; derivation:
`/gnu/store/yd6k81p4ax4yc5lb1l455pgpg6mpd9sj-disk-image.drv`.

**The full scenario passed 92 assertions across 14 actual runsc executions.**
Eleven executions returned the expected text; invocations 7, 9 and 11 rejected
the syntax-error, exception and nontermination drafts respectively. All fourteen
reported initialization and complete cleanup. Each failure was followed by a
successful installed-revision execution. Preview-ticket retirement, draft and
installed persistence across close/reopen, export, rollback behavior and a final
reopen of the rolled-back state passed. The guest powered down cleanly at
kernel time 150.165 seconds and the outer checker returned zero.

Evidence base: `/tmp/opencode/book-workbench-qemu-v8-tkwptad8/`.
Exact argv and input identities: `/tmp/opencode/book-workbench-qemu-v8-run.json`.

| Artifact | SHA-256 |
| --- | --- |
| `runner.log` | `3d3b8ca5c8acebbd66c7135902f50b9393f62871a799222b0f2f9e1fa0007670` |
| `workspace.raw` (64 MiB, single-link mode 0400) | `312a7079470e160fbc0ccfe05d835a80da8e00307aa80fc88f4f5b65e41c2b12` |
| Read-only extracted SQLite file | `3dc8102db441b8a2dd9041ba968e035e5f4b97240b3c4d1b75ce6d8b2035be02` |

The inner QEMU run tree was removed. Parent audit counted the exact invocation
roster and status/cleanup flags (`audit-summary.json`), ran read-only
`e2fsck -fn` successfully, then used read-only `debugfs` to extract
`/exercise.zfDjrZ/book-workspace-v1.sqlite`. SQLite opened with
`mode=ro&immutable=1`: integrity was `ok`, foreign-key checks were empty, draft
version was 4, activation epoch 2, the active revision was the permanent seed,
the previous revision was the uppercase successor, and the nonterminating draft
remained saved. Exactly two immutable revisions existed. Audit JSON is under
`audit/`; the workspace hash was unchanged afterward. This is a retained
single-boot artifact audit, not a second-boot recovery result.

**Independent v8 audit accepted this narrow pass.** The reviewer verified the
image/system/boot relationship and immutable source hashes, independently
counted the exact markers and invocation roster, rehashed the workspace,
repeated read-only fsck and SQL inspection, and confirmed the unchanged image
hash. Retained stderr corroborates the specific syntax error and `error
"broken"`. The nontermination case records a trusted wall timeout and one owner
control operation, with forced termination false; its SIGKILL status is not
evidence that RLIMIT_CPU fired. No additional blocking gap was found in this
single-boot result. The dispatch-evidence refinement below remains required for
the general false-evidence regression.

### Final execution-evidence tightening

While v8 ran, parent review found that `execution-started?` was set on receipt
of hello, before the fresh control check and before init/action output drained.
A post-hello pre-action refusal could therefore look like an executed failed
program to the shared scenario. The correction must require completed action
delivery; this is stronger host evidence, not an assertion that the authored
body finished. Partial output and a failed send must remain false, while a
successful final send that exactly exhausts the pump budget must count as
delivered even if the pump reports `budget` rather than `drained`.

The v8 successful-result and known-failure record remains evidence at its stated
scope. Final qualification will repeat the scenario after that evidence change,
with resource budgets and independent cleanup requirements held fixed.

**Delivery evidence corrected in both callbacks:** initialize and action must be
queued successfully, with fresh matching controls first in the sandbox. An
accepted output-pump result must then leave a live active endpoint with zero
outbound frames and bytes. A final `budget` result can satisfy this condition;
partial writes, send failures and closure-cleared queues cannot. Internal hello
state remains separate. This reports delivery to the socket, not completion of
the authored body. The 261 sandbox and 177 preview assertions cover those cases,
real syntax failure after delivery and input requiring multiple production
4096-byte output pumps. Both modules compile without warnings.

The v9 gate, image build, source inspection and staging passed. Image:
`/gnu/store/v0lw4816zw6gz64gkikqxxmfa7b2w6v3-disk-image`; embedded system:
`/gnu/store/4vnw9pyswrn6p920x9kk4ym67ak59i98-system`; derivation:
`/gnu/store/bga8gabpmwnghk4gb2zprn7ggpn2vssb-disk-image.drv`.
Sandbox hash `2a2cec7d1f17ed4189d09bcb1c589229aaabe8f3d09c73c7348f2cdc1168e514`;
preview hash `85d93054df9ee0b2d5e1b92a9bbf399ab74780a704e9b829672c5737f28821c0`.

### ARM boot 7 — final delivered-action scenario pass

Focused independent review closed the delivery-evidence correction in both
executors, including the final-budget and closure-cleared-queue cases. The v9
ARM run then passed the same **92 assertions / 14 executions** with the stronger
flag: eleven successful results, three expected failures (syntax, exception and
nontermination), and successful installed execution after each failure. Action
delivery and independent cleanup were true for every invocation. The guest
powered down at kernel time **151.500818 seconds**; outer and guest checkers
both returned zero.

Final evidence base: `/tmp/opencode/book-workbench-qemu-v9-mgppquzd/`.
Exact argv/input identities: `/tmp/opencode/book-workbench-qemu-v9-run.json`.

| Artifact | SHA-256 |
| --- | --- |
| `runner.log` | `cd523603a897077223d59622a21619503eecbc115c4f8dfd1e6a44ad836ec269` |
| `workspace.raw` | `fbcacf7b617771dcdf60fef69f455ef22d67f394b9cd18b4da296090e1591775` |
| Read-only extracted SQLite file | `3dc8102db441b8a2dd9041ba968e035e5f4b97240b3c4d1b75ce6d8b2035be02` |

The image is a single-link mode-0400 64 MiB file. Read-only fsck passed, SQLite
integrity was `ok`, foreign-key checks were empty, and all metadata, draft,
activation and revision rows matched v8. The **entire extracted SQLite file is
byte-for-byte identical to v8**, not just its queried rows. Audit outputs,
including fsck/extraction logs and `summary.json`, are under `audit/`; the
workspace hash remained unchanged. Both boots used fresh workspaces, so this is
a repeated single-boot scenario, not recovery of one workspace across two boots.

The final full native text-function gate passed on these exact runtime inputs:
`/tmp/opencode/book-workbench-delivery-final-check.log` — 168 storage, 71
authority, 177 preview, 261 sandbox-seam, four shared-scenario and 342 adapter
assertions; 503 UI/FSM checks and the existing process/launcher/real KOReader
integration gates. The separate source-defined editor retains its previously
recorded final 13-integration-test native pass; its code was not changed by these
sandbox fixes. No Workbench device deployment occurred.

**Final independent evidence audit accepted v9.** The reviewer verified the
image/system/boot relationship, immutable sources and adapter hash, exact
scenario/preview/checker records, corrected action-delivery semantics, all three
artifact hashes and the byte-identical database. It found no concrete remaining
gap for this fresh-workspace, single-boot authoring/cleanup/persistence result.
Interactive sandboxed editing, same-workspace recovery across boots and general
resource-limit enforcement remain outside that acceptance.

### Project fit and scope

The project-fit reviewer found that the distinct editor contract and adapters
fit this milestone: the storage and framing are reused, authored source owns
the workflow, and trusted code retains installation/recovery authority. The
7,949-byte seed leaves only 243 bytes under the source ceiling. The demonstrated
successor edits establish continuation, not that a substantial new exercise or
adapter fits. The text-function QEMU gate, native source-defined editor, and
future long-lived sandboxed editor remain different execution results.
