# Workbench device integration contract

Investigation baseline: **`1f36e77e4a9eb14d2bef0b57e253f2ab01fc6311`**,
2026-09-26. This is a scoped implementation plan, not a deployable flavor or
device acceptance. The only implementation accompanying it is the isolated
Guile owner-receipt gate described in §9. No existing service graph is changed.

**Build the device coordinator in Guile, render through the existing KOReader
process in Lua, and retain the accepted Guile workspace authority and sandbox
owners.** Python remains an available sandbox language. The device coordinator
must not invoke `native-editor.py`, even with its sandbox option. Keep that
implementation as the accepted native/ARM reference until its replacement passes
equivalent integration gates. A Python launcher renamed or wrapped in Scheme is
not the language migration requested here.

## 1. Evidence to reuse, and its limits

| Existing result | Reusable fact | Still unproved by it |
| --- | --- | --- |
| Editor native gate, final September 19 | 58 protocol, 107 delegate, 54 surface assertions; eight runner tests; 27 integration tests and 171 Lua assertions. Real offscreen KOReader candidate Save/Read/Finish, edit serials, stale controls and terminal-backend behavior | ARM widget behavior, native containment, device power or rendering |
| **Editor ARM64 v16** | 29 assertions, nine execution domains, two concurrent during preview; real runsc, disposable Save/Read, installation/reopen, busy cancellation, timeout, owner failure, cleanup and fresh-coordinator recovery; retained filesystem/SQLite audit | A Guile coordinator, same-workspace recovery across boots, device integration, ARM KOReader widgets |
| Finite Workbench ARM64 v13 | 112 assertions across 20 executions; host-path exclusion/write denial, task-limit pressure, memcg OOM and recovery | All those policies on the long-lived composition; graceful guest fork refusal; isolated read-only-mount enforcement; complete support-process accounting |
| `book-state-device-reader`, generations 20–23 | A device composition using native KOReader, `/data`, root Guile authority, USER_NS kernel and source-built gVisor; human note saves/recovery | Workbench authoring, Workbench suspend/stop correctness |

v16 identities, from
[`reviews/2026-09-19-workbench-interactive-editor.md`](reviews/2026-09-19-workbench-interactive-editor.md):

- Image derivation: `/gnu/store/y0qvci2jyi5i28wqihdm2gvxwl1lkqlb-disk-image.drv`.
- Embedded system: `/gnu/store/qdmlr7m9l6bxa8xjk19j10h05lx1f0xs-system`.
- Immutable owner: `/gnu/store/nladwi5q2v7bva5mcpbwrq3024s7jhyd-wilkbook-book-workbench-editor-sandbox`.
- Retained workspace SHA-256:
  `aac1d410392b142d1f6f0286b7f617e8ce7a0c24407df46f3ef467c5147c4e14`.
- The audit compared 18 copied assets, 17 module-union files and seven helpers.
  Reuse requires comparing the relevant current bytes and actual derivations;
  these historical identities are evidence, not paths to deploy as a reader.

`pinenote/systems/pinenote-book-workbench.scm` inherits the execution-spike
system, mounts a dedicated `WBWorkbenchV1` volume, and selects a fixed scenario.
`pinenote/services/book-workbench.scm:guest-program` runs that scenario and
executes `halt`. **It is scenario-and-halt QEMU machinery, not an opt-in device
service.** Do not obtain a device flavor by merely suppressing the final halt.

At this baseline `doc/status.md` records generation 23 cold-booted on wkelly's
device, kernel `334ljs8q`, with the notebook and fixed note. Refresh and a
KOReader restart remain owed for that notebook session. That status supersedes
older summaries calling all generations 19–23 kexec-only. No Workbench device
result exists.

Primary specifications:
[`book-workbench-editor/README.md`](../pinenote/tools/book-workbench-editor/README.md),
[`QEMU.md`](../pinenote/tools/book-workbench-editor/QEMU.md),
[`SURFACE.md`](../pinenote/tools/book-workbench-editor/SURFACE.md),
[`WORKSPACE.md`](../pinenote/tools/book-workbench-editor/WORKSPACE.md), and
[`book-state-device/README.md`](../pinenote/tools/book-state-device/README.md).

## 2. Proposed device composition and ownership

New, explicitly selected flavor:
`pinenote/systems/pinenote-book-workbench-device-reader.scm`, inheriting
`pinenote-book-state-device-reader-operating-system`. It preserves the current
reader, notebook and fixed-note capability while adding a separately activated
Workbench. It must select exactly one KOReader package and one `reader-session`,
as the existing device flavor checks. No second reader, SDL/Mesa launcher,
temporary desktop profile, test scenario, synthetic disk or boot-time authored
execution belongs in this flavor.

| Owner | Contract |
| --- | --- |
| Existing `reader-session` and platform services | Own KOReader, framebuffer/input, rotation, refresh, library, Wi-Fi, frontlight and power. Workbench never launches/kills KOReader or writes power/display controls. |
| New Lua device entrypoint + shared editor renderer | Activation check, one authenticated private connection, native InputDialog/ConfirmBox, draft/edit serials and trusted controls. Authored labels cannot become confirmation/recovery controls. |
| New Guile device coordinator | Listen/admit trusted UI; keep independent UI/authority/book/owner channels; port `EditorSession` and `UIBridge`; snapshot source as opaque UTF-8; own author/candidate processes, timeouts, preview disposal and lifecycle quiescence. |
| Existing `editor-authority.scm` subprocess per author/candidate | Sole owner of workspace store, retained owner identity, typed delegate/surface, proposals, worker transitions and SQLite writes. `--workspace-authority` is already backend-neutral. Source is data here. |
| Existing immutable editor-sandbox command and Guile runtime owner | Prepare/check OCI execution, observe cgroups, own/reap descendants and prove runtime/mount/cgroup cleanup. One owner per author/candidate. |
| Existing editor runner inside runsc | Only place authored Guile is evaluated. Receives source snapshot and BookProtocol FD 3; no workspace database, UI/control FD, device or persistent path. |

Keep the authority subprocess boundary for the first port: incomplete private
RPC currently retires that authority permanently. Merging it into the
coordinator would change worker cancellation, SQLite lifetime and failure
isolation at the same time as the language migration.

The coordinator accepts at most **one UI endpoint, one author and one candidate**.
Candidate execution uses the same immutable backend as the author and a
different temporary SQLite store with `access=preview`. The existing note is a
different authority/database and can consume a third domain; do not call the
two-domain Workbench limit a system-wide resource bound. Coexistence must be
qualified, or a trusted cross-tool admission rule implemented, before release.

### Device UI connection

Use a fixed private Unix listener rather than inheriting a donated FD through
`reader-session`. This follows the existing note's device attachment and avoids
giving the coordinator ownership of the reader launch.

- Proposed socket: `/run/wilkbook-book-workbench-device/control.sock`, under a
  canonical root-owned mode-0700 directory; socket mode 0600, CLOEXEC.
- Validate AF_UNIX/SOCK_STREAM, peer credentials and the compile-selected
  KOReader LuaJIT executable. The note's `peer-reader-process!` is the reference.
  Its executable/UID/GID check admits a root process running that executable;
  it does **not** distinguish every invocation of that binary or provide a
  boundary against root. Retain the accepted connection/process identity, not
  a subsequently rediscovered numeric PID, for lifecycle observation.
- The socket pathname is a trusted build constant. Neither source nor UI may
  select a path, runner, language, workspace or descriptor.
- Reuse the exact `SURFACE.md` private line/hex-JSON commands on this connection.
  Native descriptor donation stays the desktop entrypoint's responsibility.
- A fresh device connection is an explicit new session: reset transport counters
  only with new endpoint identity, retire all old callbacks/tokens and read the
  durable snapshot. Never reuse a retired numeric FD or retry a lost save.
- Boot/reader startup must work when the service is disabled or failed. Register
  the experimental menu only when activated; an unavailable service produces a
  local error and preserves the visible draft. Reconnecting must be an explicit
  trusted operation, not an automatic replay of the failed request.

The current generic plugin consumes `BOOK_WORKBENCH_EDITOR_UI_FD` once at module
load and has no connect factory, activation check, suspend hook or recovery menu.
Adding a socket file alone cannot make it a device plugin. Extract its renderer
into a shared Lua module in a later reviewed package (§8), keeping the accepted
desktop entrypoint and offscreen tests as the regression reference.

## 3. Exact language migration boundary

| Python responsibility in `native-editor.py` | Guile device replacement / disposition |
| --- | --- |
| `Channel` | Incremental bounded BookProtocol frames and raw payload retention; nonblocking I/O; remaining-deadline writes/reads. Never decode/re-encode child JSON before the typed Scheme decoder checks lexical counters/duplicates. |
| `EditorSession.__init__`, `environment`, `launch` | Clean compile-fixed environment; authority socketpair/process; owner and book socketpairs; private mode-0400 source snapshots; immutable owner selection and matching environment identity. No ambient module paths, Python invocation or backend selector. |
| `rpc`, `io_budget`, `retire_authority_transport` | Serialized private authority RPC; permanent retirement on interrupted/incomplete exchange; preserve already-committed work; suppress late results. Private RPC currently has no request correlation ID, so a late reply cannot be reused. |
| `pump`, `event`, `action`, `confirm`, `cancel` | Closed child-family dispatch, six-field surface correlation through the authority, workspace operations only during an action, no `host-*` from source; original action continuity through repeated preview/confirmation. |
| `finish_preview`, `cancel_preview` | Independent candidate authority/store; cancellation while busy; final pump; stop, clean, terminal exit verdict and disposable-store removal **before** successful preview result. |
| `read_owner_control`, `stop_child`, `read_owner_diagnostic` | Exact fragmented/coalesced `ready`/`clean` receipts; bounded observation and owner wait; sidecar diagnostics only after exit; no ticket or new launch after unproved cleanup. §9 starts this port. |
| `UIBridge` | Closed private command schemas, transport sequence/view checks, separate candidate view/token, trusted single-use confirmation, terminal-backend local errors preserving draft. |
| `wait_ready`, clocks | Block on readiness and nearest deadline; keep worker-only short polling until the authority has an explicitly tested completion wake FD. No device protocol-inactivity timeout: local typing is invisible to that clock. |
| `PrivateTree`, trusted-process cleanup | Owned runtime directories under `/run`, bounded identity-checked removal, subprocess handles/ownership retained through wait; never scan global descendants or force-remove live mounts. |
| `main`, `reader_inputs`, `run_reader`, desktop profiles/Mesa setup | Desktop fixture only. Device entrypoint is a Guix program plus Shepherd listener; existing `reader-session` supplies the UI. |
| `native-child-owner.py`, native backend | Remain explicit desktop test tooling. Excluded from device coordinator inputs and all device fallback paths. |

Reuse without translation: `book-workspace.scm`, schema, `workspace-protocol.scm`,
`workspace-delegate.scm`, `editor-surface.scm`, `editor-authority.scm`, seed and
runner; `workbench-editor-sandbox.scm`, `workbench-runtime-owner.scm`, their
accepted OCI/BookProtocol/FD-adapter dependencies; Lua codec/channel/renderer
logic. Preserve the explicit `primitive-load` ordering for
`guest-book-protocol.scm` before importing the runtime modules; resolving it
under Guile 3.0.9's module loader lock is a documented deadlock trap.

Python's continued availability is separate from the coordinator port. Retain
the selected Guile/Python execution-language closure; the supervisor profile
contains Guile/JSON/gcrypt/SQLite, not Python. The editor source format is still
`guile-source-v1` and its runner ABI is
`(workbench-main receive! send! own-source)`. This task does not invent a Python
editor ABI, expose a UI interpreter selector, or remove fixed Python note/probe
support. Python host tests/scenarios remain valid reference tools. New build and
system integration scripts are Guile/Guix; reader changes are Lua.

## 4. Durable state, activation, recovery and rollback

Proposed fixed layout (new paths, not aliases of note state):

```text
/data/wilkbook/book-workbench/enabled                 # exact enabled\n, 0600
/data/wilkbook/book-workbench/workspace/              # canonical root-owned 0700
  book-workspace-v1.sqlite                           # backend's fixed name, 0600
/run/wilkbook-book-workbench-device/                  # 0700; listener/session files
/run/wilkbook-book-workbench/                         # accepted sandbox owner parent
```

An opt-in readiness service verifies the real ext4 `/data` mount and private
path/file identities before preparing the directory. Reject placeholder `/data`,
symlinks, hardlinked private files, wrong owners/modes and incompatible stores;
do not repair an unexpected existing database by replacing it. Match the existing
note's exact marker validation. Installing/booting the flavor may prepare empty
directories; without the marker it opens no workspace, listener or sandbox, and
the plugin stays dormant. Activation is a deliberate host operation, followed
by service enable/start and reader restart after unsaved text is dealt with.
Use a small Guile activation entrypoint rather than embedding shell writes in
the authored UI. Recheck activation before admitting a new connection.

Create/open the store lazily on first accepted editor request; close it after
the last view's admitted worker and owned executions have ended. An activated
listener alone should not retain a writable SQLite handle. This intentionally
improves on the note authority, which opens its database before blocking in
`accept`; it requires a new lifecycle test, not an inferred reuse claim.

Existing workspace semantics stay exact:

- Save receipt means SQLite commit (`synchronous=FULL`, DELETE journal). Source
  is limited to 8192 UTF-8 bytes; the database is limited to 8 MiB; the 128
  immutable revision slots include seed and sealed-but-uninstalled revisions.
  There is no pruning/importer. Saves do not install or execute source.
- Preview tickets name the saved source/version/activation epoch and endpoint.
  Installation requires separate trusted confirmation. Sealing and activation
  are **two transactions**; a failed activation may leave an extra revision.
  Never describe the entire seal/install sequence as atomic.
- Exports identify the installed revision, which can differ from the draft.
  Code rollback and seed recovery preserve the saved draft and never rewind the
  persistent note, notebook or OS generation ledger.
- Unsaved InputDialog text is process memory. Close/rotation preserve it in that
  reader lifetime; reader exit/power loss does not. No implicit save on suspend,
  close or installation, and no promise of crash recovery for unsaved typing.

**Recovery must be accessible without successfully executing the active source.**
The current CLI `--recover` first constructs `EditorSession`, whose `host-start`
already launches source; `host-recover` also launches the newly selected source.
For the device, supply an independent Guile recovery entrypoint using the existing
workspace APIs: exclude active sessions, finish quiescence, open the validated
store, snapshot, perform rollback or permanent-seed activation with fresh epoch
CAS, close, and only launch on a later explicit Open. Add trusted Lua recovery
controls outside the authored action list. Do not route arbitrary paths or
revision names through that UI. A storage/identity error leaves the store intact
and reports failure rather than choosing a replacement seed database.

Environment identity currently includes the SHA-256 of the **canonical immutable
sandbox command path**, prefixed `workbench-editor-v1-sandbox-`. Keep it for the
first port. A changed owner closure/path can make the old workspace refuse with
`environment-mismatch`, even when source still appears compatible. A native or
text-function workspace cannot be adopted as the device store. Cross-environment
migration is a separate decision: no silent rehash, import or reset. OS rollback
may recover use of a matching earlier environment; disabling the feature always
leaves source data intact. Record the environment with each generation's evidence.

## 5. Lifecycle contract: evidence, ordering and deadlines

Lifecycle control is host-private and separate from both source messages and
the existing `SURFACE.md` UI vocabulary. A future control endpoint must bind each
request/reply to one fresh coordinator epoch and request ID. No persistent
`clean` file, saved PID or last run's reply is evidence for this run.

### Common quiesce operation

1. Close admission first: no new views, actions, confirmations or candidate
   launches. Retire pending tokens and delegate/surface lifetime. The UI retains
   local text and never turns an unanswered save into success.
2. Cancel preview and request stop from **both** execution owners. Process them
   concurrently under one total bound, or budget both sequential 12-second
   waits explicitly. A single-owner grace copied from the note service is not
   a two-owner service-stop proof.
3. Observe each owner's exact `clean\n` and terminal wait status. For successful
   preview, additionally require zero exit and drain the receipt socket to actual
   EOF, validating every received byte. Exit may precede unread trailing bytes;
   clean plus exit alone is not a final stream verdict. EAGAIN, timeout and local
   closure are not EOF evidence. Bound this drain by the same cleanup observation
   deadline. Nonzero with proved cleanup
   is contained execution failure. Missing cleanup is a terminal coordinator
   failure, never an ordinary failed-preview receipt permitting another run.
4. Complete/join each authority's admitted worker, suppress retired completions,
   close SQLite and reap the authority. Do not close a store in use. If a bounded
   authority shutdown must escalate, wait for actual process exit and report
   interrupted completion; a committed transaction may survive. Reopen/read
   actual durable state later, without retrying a write by assumption.
5. Remove only owned disposable source/store files after execution and database
   cleanup; preserve failed-cleanup diagnostics and identities. Verify no owned
   descendants, runtime mounts/cgroups, or writable workspace handles remain.
6. Only now return a correlated quiesced acknowledgement. Keep admission closed
   until a matching resume/abort or a new explicitly authorized session. An
   expired request cannot be completed with a later epoch's cleanup.

The future acknowledgement's minimum facts are: request ID/coordinator epoch,
admission closed, author and candidate disposal proved (or never acquired),
authority workers/processes ended, stores closed, disposable trees removed,
and no owned runtime resources left. An empty owner list is meaningful only
from that live coordinator's acquisition ledger. The small receipt gate in §9
checks just one owner's portion, not these aggregate facts.

Keep accepted clocks initially: sandbox startup 20 s, action 10 s, owner cleanup
10 s observed within 12 s, private widget request 60 s. Human confirmation and
preview think time pause the author action clock; candidate actions keep their
own clocks. Partial input never renews a deadline. Check expiry before child
admission **and** authority-result publication. All blocking I/O is bounded by
remaining active time. Service-wide shutdown needs a separately measured bound
covering worker join and both owners; do not claim 12 s for it yet.

### Exit, restart and failure

- Dialog Close retires its view/preview and ends authored execution; it can keep
  an idle UI connection but no authority store or sandbox after cleanup.
- Document close, reader EOF/exit, service stop, disable and coordinator parent
  loss run the same cleanup obligations. Reader exit must be observed even while
  the plugin has unregistered idle polling. CLOEXEC prevents leaked UI endpoints
  in unrelated spawned children from extending ownership.
- Coordinator/owner failure cannot kill the reader or select native execution.
  Keep the visible local draft; require explicit fresh-session recovery once
  cleanup is proved. No automatic Shepherd respawn loop for failed cleanup.
- Disable stops admission and quiesces before removing activation. Restarting
  the reader hides the dormant plugin; removing a marker alone does not stop
  existing work. Ordinary reader startup never depends on Workbench success.

### Suspend is an integration blocker

Recommend **quiesce and discard sandbox process state on suspend**, retaining
the durable workspace and in-memory Lua draft. Resume offers an explicit fresh
Open with new grants; do not resume a pending installation or preview ticket.
This avoids carrying authored processes/action clocks through long suspend and
keeps the first device scope smaller than runtime checkpoint/restore.

The current production path is `device.lua:PineNote:suspend` sending `ready ID`
to `pinenote-power-broker.lua`. `broker_protocol.lua:tick` calls
`suspend(true, ...)` after the physical-request acknowledgement timeout. Thus a
plugin `onSuspend` callback, or withholding `ready`, **cannot enforce quiescence**:
power/cover/RTC fallback can still suspend. The source-defined editor has no
suspend hook today. The pure `power_coordinator.lua` module's capabilities are
not evidence that Workbench is integrated into this production path.

Before a device-ready build, add an opt-in host quiesce barrier to the broker's
common suspend transaction, covering both acknowledged and fallback entry, with
explicit failure/cancellation behavior and tests. Freeze Workbench admission
for the entire prepare/sleep interval. Lua must retire visible confirmation and
preview controls before acknowledging preparation; broker cleanup remains
authoritative if the reader is stuck. Resume restores reader/power state through
the existing broker, then permits a new Workbench session. If cleanup fails,
refuse that suspend and surface the failure; prevent automatic retry loops.
The operator-visible policy for a dirty local draft is a product choice (§10).

### Kexec and shutdown are separate from suspend

At this investigation's baseline, `wilkbook-generation.lua` stopped only
`reader-session` before radio-off and merely logged a failed `/data` read-only
remount. The integrated September 26 batch now stops the optional note
authority, checks runtime cleanup, and refuses failed root/data remounts
(`doc/update-path.md`, "Teardown hardening"). That change is host-tested;
older target helpers still need the manual stop used in the hardware sessions.
Workbench must extend that lifecycle for its own owners and authority, rather
than add another unmanaged writer.

Before a Workbench generation can be trialled, integrate or explicitly perform
host quiescence/stop of Workbench **and the existing note authority**, before
Wi-Fi teardown; verify actual process/FD state and read-only remount success.
The production integration must refuse the handoff on failed cleanup/remount
and retain its existing bail-out/health/promotion/watchdog behavior. A successful
Shepherd `stop` invocation or reader EOF is insufficient cleanup evidence.
Remember which services were active: refusal restores only those services and
their admission after writable mounts are restored, never replays actions.
Apply equivalent ordering to ordinary shutdown. This plan authorizes no trial;
the existing attended deployment rules still govern the eventual generation.

## 6. Dependencies and performance budget

- Reuse exact pinned USER_NS kernel
  `/gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote`
  and source-built gVisor
  `/gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0`
  when derivation checks still resolve them. Do not rebuild either merely to
  package the coordinator. The existing device flavor supplies cgroup2.
- Pin supervisor Guile/JSON/gcrypt/SQLite and the selected execution-language
  closure independently. Do not confuse the device note's current 46-path
  language closure with historical 45-path evidence or blindly substitute it
  for the Workbench owner's selected closure.
- Preserve systrap, `directfs=false`, `network=none`, `host-uds=none`, excluded
  host paths/devices and FD-3 donation. There is **no native fallback**, including
  on USER_NS, runsc, resource-control, dependency or owner-readiness failure.
- Initial per-domain observations stay `memory.max=268435456`,
  `cpu.max=50000 100000`, `pids.max=256`. Two matching domains are not a total
  machine budget: include coordinator/authorities, runtime support processes,
  KOReader and any concurrent note execution in measurements.
- Activated but closed should block in the listener, with zero periodic UI
  polling and no authored execution. Accepted open-owner observation is four Hz;
  Python coordinator quiet waits were at most 200 ms, active worker polling
  10 ms. Port scheduling deliberately and measure wakeups/CPU/RSS before
  optimizing; those numbers are scheduling behavior, not power qualification.
- Package explicit source inventories. The existing editor-assets tree contains
  Python coordinator/scenario files and a desktop reader; a new device inventory
  must select only the required Guile/Lua/runtime assets. Python in the language
  closure is expected and is not evidence of a remaining Python coordinator.

## 7. Acceptance ordering and reuse

1. **Host contract/port tests.** Run the new receipt gate; then Guile coordinator
   tests with real SQLite authority and controlled process owners. Cover exact
   raw-byte schemas, expiry before admission/publication, late commits, busy
   cancellation, coalesced owner receipts, missing cleanup, nonzero-after-clean,
   terminal authority retirement, stale UI callbacks and nonexecuting recovery.
   No hostile authored native program is needed to test this trusted boundary.
2. **Native UI.** Reuse unchanged protocol/delegate/surface/runner tests; rerun
   affected native integration tests against the new coordinator and shared Lua
   renderer. Real offscreen InputDialog Save/Read/Finish and confirmation tests
   remain necessary: mocked widgets alone do not cover native editing/rotation.
3. **Derivation and source checks.** A new device lowering gate binds kernel,
   gVisor, supervisor, language closure, owner command, plugin inventory and one
   reader. Assert no QEMU service/device/scenario/halt, no native-owner input and
   no Python coordinator argv. Lower before building. Inspect the actual built
   module/asset bytes and interpreter paths afterward.
4. **ARM64 QEMU successor gate.** Reuse the existing sandbox owner/runtime while
   driving the Guile coordinator through the v16 scenarios. This produces a new
   acceptance identity, not a retroactive Guile interpretation of v16. Add
   same-workspace **two-boot** recovery and mock broker/kexec quiescence refusal
   tests. Reuse unchanged finite resource findings only at their stated scope.
5. **Device qualification.** Only after those checks and the lifecycle adapters
   pass, build the opt-in system and arrange an attended numbered generation.
   Hardware work is not part of this investigation.

Re-run only invalidated checks. A pure coordinator/Lua change does not invalidate
the kernel/display harness evidence. It does invalidate composition/action/
cleanup claims made through the old Python coordinator. Network isolation,
scratch exhaustion, isolated read-only mounts, CPU-limit attribution, graceful
guest fork refusal and complete support-process accounting remain explicitly
unqualified until tested; v16 control samples alone do not close them.

## 8. Work packages and exact file ownership

These are future ownership assignments; this investigation edits only this
document and the isolated files in §9. `D` below means
`pinenote/tools/book-workbench-device/`. Each package should land separately;
shared-source changes need the parent project's review and regression gates.

| Order | Owned files / integration changes | Exit condition |
| --- | --- | --- |
| **W1: Guile transport and sandbox-only session port** | New `D/coordinator.scm`, `D/authority-channel.scm`, `D/test-coordinator.scm`, `D/test-authority-channel.scm`, `D/fixtures/owner.scm`; use `D/owner-control.scm` | Real existing `editor-authority.scm`/SQLite; closed dispatch; startup/action deadlines; two independent owner lifetimes; disposal-before-ticket; no native launch path. No service edits. |
| **W2: Private UI bridge parity** | New `D/ui-bridge.scm`, `D/test-ui-bridge.scm`, `D/run-tests.scm` | Exact `SURFACE.md` stream behavior and terminal-backend preservation, exercised with the existing Lua codec. Parent reruns full affected native widget gate through Guile. |
| **W3: Device attach, activation and independent recovery** | New `D/device-entry.scm`, `D/activation.scm`, `D/recover.scm`, `D/test-device-entry.scm`, `D/test-recovery.scm`; new `D/plugin/bookworkbenchdevice.koplugin/{main.lua,_meta.lua,activation.lua,device_channel.lua}` | Marker/path/peer admission, lazy DB, explicit fresh endpoint, broken-active-source recovery without evaluation. No persistent data deleted on disable. |
| **W3 shared UI extraction (same gate)** | New `pinenote/tools/book-workbench-editor/plugin/bookworkbencheditor.koplugin/editor_plugin.lua`; narrowly modify existing `main.lua` to supply the donated-FD factory, update its tests and explicit asset inventories | Shared rendering and view semantics, not a drifting device copy. Device supplies fixed-socket factory and trusted recovery/lifecycle controls. Desktop accepted behavior preserved. |
| **W4: Lifecycle adapters — deployment prerequisite** | New `D/lifecycle.scm`, `D/test-lifecycle.scm`, `D/lifecycle-control.scm`; reviewed changes in `pinenote/packages/platform-controls/pinenote-power-broker.lua`, `broker_protocol.lua`, `pinenote/packages/koreader-device/frontend/device/pinenote/device.lua`, `pinenote/packages/update-path/wilkbook-generation.lua`, and their existing power/update tests | Broker's acknowledged **and fallback** paths, reader death, service stop, shutdown, kexec refusal/restore. Notes and Workbench both release writable `/data` handles. Freeze admission until resume/abort. |
| **W5: Guix composition** | New `pinenote/packages/book-workbench-device.scm`, `pinenote/services/book-workbench-device.scm`, `pinenote/systems/pinenote-book-workbench-device-reader.scm`, `D/derive-system.scm`, `D/check-system.scm` | Separate dormant flavor; exact package/input/service graph checks, cooperative stop grace covering aggregate cleanup, no runtime selection from requests. Reuse existing owner program or factor its definition without changing its identity unnecessarily. |
| **W6: ARM composition / recovery gate** | New `D/qemu-scenario.scm`, `D/test-qemu-adapter.scm`; explicitly reviewed scenario-selection additions to the existing Workbench QEMU service/tools | Guile equivalent of v16 plus two-boot workspace recovery, lifecycle refusal and runtime-resource audit. Existing v16/finite scenarios stay reproducible. |
| **W7: Host entry and attended qualification** | Later root `Makefile` opt-in targets and deployer flavor recognition in `pinenote/tools/deploy/deploy.sh`; documentation/runbook/status entries owned by parent/operator | Derivation routing cannot select QEMU system; staged device matrix below and recorded rollback/cleanup. No default-reader adoption in this package. |

W1→W2 precedes the integration-facing packages. W3 and W4 can be developed
independently after W2, but **both** must pass before W5 is treated as device-ready.
W5 lowering may be developed earlier offline. W6 precedes W7's hardware half.
No package should silently take over another package's shared files.

**Next executable task:** W1's authority-channel slice. Implement bounded Guile
socketpair transport and launch the unchanged `editor-authority.scm` with
`--workspace-authority` against a private SQLite store; assert its `host-start`
launch event without evaluating the returned source, retire it, and close/reap
the authority. Then force a fragmented reply timeout and prove that no second
RPC is sent on that retired channel. This tests the real authority/process
boundary before porting the full session loop or touching Guix services.

## 9. Small executable boundary delivered here

`D/owner-control.scm` ports the trusted receipt-consumer boundary to Guile. It
accepts bytevector fragments of `ready\n` and `clean\n`, records stop intent and
waited terminal status separately, prohibits authored delivery before readiness
or after stop/termination, and distinguishes cleanup from preview eligibility.
Preview eligibility requires observed socket EOF as well as successful exit:
the caller feeds every received byte before reporting actual EOF, so delayed
trailing bytes can poison the state before it permits success. Cleanup alone
reports disposal evidence, not a final receipt-stream verdict. It handles
wait-before-final-socket-drain and clean-before-ready preparation failure.
Invalid input permanently retires the receipt state. Prefix checking
retains at most six bytes; this is stricter fail-fast validation than Python's
32-byte accumulation, with the same valid wire records.

It does **not** launch a process, sample cgroups, enforce deadlines, close a
database or grant a preview ticket. Its eligibility predicate is only necessary
owner evidence: trusted Finish, an accepted idle candidate form, full disposable
authority/store cleanup and current draft/epoch still need the coordinator and
delegate. The caller must stop on malformed control input and retain diagnostics;
resetting this record cannot make an unclean owner safe to replace.

Run from the repository root with an existing Guile; no Guix build is required:

```sh
guile --no-auto-compile -L pinenote/tools/book-workbench-device \
  pinenote/tools/book-workbench-device/test-owner-control.scm
```

The initial host run passed 54 assertions. The terminal-drain regression exposed
three premature-success cases in that implementation. Requiring EOF fixes them;
the expanded gate passes **88 assertions**, including every split boundary of
coalesced receipts, both exit/EOF orderings, delayed trailing bytes, nonzero/signal
outcomes, unsolicited termination, incomplete EOF, duplicate/trailing records
and permanent failure. This is a protocol-consumer proof only, not a fresh
v16/runtime proof. Parent owns the three adversarial reviews for the complete
batch.

## 10. On-device qualification matrix and remaining choices

Run the failure-injection cases offline first. Any device crash/hang/cold-boot
test must use the applicable attended/UART policy; this table is not permission.
Record device/operator, generation/system path, environment/owner identity,
source hashes, prior fallback, cleanup results and final suspend configuration.

| Case | Required observation |
| --- | --- |
| Unactivated boot | Ordinary reader, notebook and note available as before; no Workbench menu/socket/DB open/runtime; suspend behavior unchanged. |
| Activation / unavailable backend | Explicit marker/service/reader lifecycle works; missing owner/USER_NS or failed runtime produces local error, never native execution or a reader restart loop. |
| Native ARM widgets | Type/edit-away-and-back, keyboard, long title, all four rotations, Close/Back and reopen; stale callbacks cannot overwrite text; ordinary book remains usable afterward. |
| Self-authoring twice | R0 saves/previews/requests R1; trusted confirmation alone activates; reopen runs R1; R1 authors R2. Save alone/cancel do not change active revision. |
| Interactive candidate | Candidate Save/Read affects only disposable DB; author edits remain separate; Finish observes cleanup and terminal success; cancel while busy produces no ticket. |
| Broken source / backend retirement | Syntax/action failure leaves saved draft and installed revision; independent seed/rollback works; lost receipt is resolved by fresh read; reader retains unsaved local text. |
| Service/reader lifecycle | Close, document switch, clean reader restart, service stop and controlled coordinator loss leave no owned descendants/mounts/cgroups or writable DB handles; new session reads durable state. Unsaved text loss on process exit is reported accurately. |
| Suspend/resume | Power, cover, KOReader idle and RTC-backstop paths from closed, idle editor, pending save, preview and confirmation states; both broker routes honor quiescence; stale controls stay retired; local draft survives normal sleep; radio/reader resume normally. |
| Resource/power | Closed-feature wakeups, active/idle author and two-domain preview CPU/RSS/power; account for support processes and concurrent note; normal page turns remain responsive; repeated open/close shows no growing resource residue. |
| Reboot durability | Saved draft/active/previous/epoch recovered from the same `/data` workspace after an attended cold boot, with no environment substitution; separate from the v16 single-boot recovery result. |
| Generation update/refusal | Workspace and note quiesced before radio-off; real `/data` remounts read-only; refusal restores prior service state without action replay; target health plus operator checks; rollback preserves workspace bytes and either matches environment or refuses clearly. |
| Disable | Stop/cleanup, remove activation, restart reader; dormant UI with ordinary reading/suspend; DB retained. |

Choices to settle before the relevant package is accepted:

1. **Suspend UX:** recommended cancel preview/confirmation and retain local
   unsaved text without autosave. Decide whether to keep a disconnected editor
   visible or close it to the underlying book, and how cleanup failure is shown
   when the reader itself is unresponsive. This changes UI expectations, not the
   broker's obligation to prevent unquiesced sleep.
2. **Environment evolution:** keep strict mismatch refusal for the first device
   version; decide later whether an explicit reviewed importer/migration can
   carry source across owner closure changes. Never substitute a stable label
   for the present execution-input binding merely to make an upgrade open.
3. **Cross-tool concurrency:** qualify fixed-note plus two Workbench domains, or
   implement a trusted admission rule. A modal dialog is not proof that the
   other tool's sandbox has ended. Notebook/reader memory and power count too.
4. **Trusted recovery/reconnect affordance:** recommendation is independent
   Rollback/Seed recovery and explicit New session controls outside authored
   actions. Agree menu placement and dirty-buffer behavior before W3 UI work.
5. **Aggregate stop/resource budgets:** determine measured service-wide stop
   bound and memory/wakeup acceptance thresholds; neither the note's 12-second
   stop grace nor two 256 MiB domain limits supplies those answers.
6. **Scope of first operator acceptance:** one fixed Guile editor lineage and
   its existing source export are sufficient for this device step. General book
   loading, Python-authored editor ABI, multi-file workspaces, instance-state
   migrations, autosave, revision pruning and Exercise Studio are later product
   work, not implicit requirements of packaging the accepted editor.
