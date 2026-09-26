# Self-authoring Book Workbench

This directory joins a **source-defined editor** to the real SQLite workspace,
typed workspace grants, a generic KOReader editor surface, and trusted installation
confirmation. `editor-seed.scm` is the whole authored program. An installed
successor can change the editor title, available actions, and their behavior,
then author another successor without changing the authority, runner, or plugin.

The desktop command below explicitly selects the **trusted-native fixture**:
authored Guile executes with the host user's privileges. Its separate processes,
private profiles and disposable stores test lifecycle and authority, not
containment. The same coordinator can select an immutable sandbox owner with
`--sandbox-command PATH`, exclusively of `--trusted-native-fixture`. That backend
requires the prepared root-owned runtime/cgroup environment and pinned runsc;
there is no native fallback. Its separate ARM64 gate is documented in
[`QEMU.md`](QEMU.md). The older `book-workbench/run-native-demo.sh` is separate.

## Run

The launch and test scripts use these existing cached native outputs by default:

```text
BOOK_WORKBENCH_SUPERVISOR=/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor
KOREADER_NATIVE_BUNDLE=/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03
BOOK_WORKBENCH_GRAPHICS=/gnu/store/ikfz8dkfrhijll2i929d9ws4ldz0i5qi-mesa-26.0.2
```

Overrides must be explicit. The supervisor's site and compiled module paths are
provided in a newly constructed environment; inherited Guile/Lua paths, preload
variables, HOME and user plugins do not select runtime code. The default visible
SDL launch uses the cached Mesa output above; `BOOK_WORKBENCH_GRAPHICS` may select
another cached output containing `lib/libEGL.so.1` and `lib/libGLESv2.so.2`. Reader
and graphics files are checked before starting the authority or authored child,
and missing inputs produce a named dependency error. `SDL_VIDEODRIVER=offscreen`
needs no graphics output. The scripts never realize dependencies; the older
`book-workbench/derive-inputs.scm` supplies the separate native-input derivation
recipe when cached inputs are unavailable.

```sh
mkdir -m 700 /tmp/opencode/my-self-authoring-workbench
sh pinenote/tools/book-workbench-editor/run-native-editor.sh \
  --trusted-native-fixture /tmp/opencode/my-self-authoring-workbench
```

Open **More tools → Book editor (experimental)**. The default source supplies
Read, Save, Preview, Request installation, Begin successor, Insert header and
Export actions. Edit the complete source, Save, Preview, then Request
installation. Only the separate **Install revision?** host dialog can confirm
the proposal. Close and reopen the editor to execute the installed successor.
Begin successor copies that executing revision's own source into the editor.

For a first self-revision, change `workbench-title` near the top of the source
from `"Source Workbench"` to `"My Workbench"`. Save, Preview, request installation
and confirm it, then Close and reopen. The new title now comes from the installed
program. Change `header-text` in that successor and repeat; **Insert header**
then uses the successor's new text. Saved drafts and installed revisions are
separate: saving alone does not change which program runs after reopening.

Preview opens a separate candidate editor with trusted **Disposable preview**
chrome. Exercise its actions and save/read its disposable draft. **Finish preview**
accepts the tested candidate after cleanup; **Cancel preview** grants no ticket.
Neither operation installs it. A timed-out or failed candidate is cleaned up
before its failure is shown; dismiss that preview to resume the author.

The parent directory must already exist, be canonical, owned by the current user,
and mode 0700. Only `DIRECTORY/workspace` persists; each launch gets a fresh
private KOReader profile. Desktop inactivity exit is disabled by default
(`--idle-seconds 0`). A positive `--idle-seconds` opts into a protocol-inactivity
timeout: it cannot observe unsaved local typing and may close the application
while such editing continues. Source execution has its own startup/action clocks.

Trusted recovery does not execute the broken draft and does not discard it:

```sh
sh pinenote/tools/book-workbench-editor/run-native-editor.sh \
  --trusted-native-fixture --recover rollback /tmp/opencode/my-self-authoring-workbench
sh pinenote/tools/book-workbench-editor/run-native-editor.sh \
  --trusted-native-fixture --recover seed /tmp/opencode/my-self-authoring-workbench
```

Rollback selects the retained previous revision; seed selects the store's
permanent initial seed. Both use activation-generation CAS and leave the draft
and its version unchanged. Export remains the **installed artifact**, with its
own explicit exported revision identity, even when the draft differs.

## Composition and authority

- `editor-authority.scm` holds the real `(book-workspace)` store, unforgeable
  retained owner object, `(workspace-delegate)` and `(editor-surface)` instances.
  Source is stored and copied as text, never read as Scheme forms or evaluated
  in the authority. Its private coordinator connection is not donated to source.
- `native-editor.py` owns the selected execution backend, authority, reader and preview
  processes. It routes only the closed child message families; authored bytes
  cannot select its private `host-*` controls. Its private UI bridge implements
  the generic plugin's line/hex-JSON protocol from `SURFACE.md`.
- `native-child-owner.py` is a dedicated subreaper for one authored execution.
  Every author and preview gets a different owner process. Its private cleanup
  control descriptor is never donated to the runner; only an acknowledgement
  emitted after all descendants have been reaped proves execution cleanup.
- The unchanged ordinary `hello`/`initialize` exchange is followed by distinct
  workspace/editor ready messages. This is a **new editor-session successor
  composition**, not a claim that the existing BookSession core supports generic
  extensions. Ordinary compatibility limits do not authorize the editor's
  separate 8192-byte field; its typed surface grant does.
- BookProtocol owns bounded JSON frames. The coordinator retains raw child
  payloads until the Scheme workspace/editor decoders have checked their lexical
  counters, closed schemas, grant identity and request/action correlation.
- Every surface action has one deadline; workspace work is admitted only while
  an editor action is pending. Presentations cannot overtake pending workspace
  work. Startup defaults to three seconds natively and twenty in the sandbox;
  actions default to ten. Partial frames do not
  refresh those clocks. Expiry is checked before forwarding each authored frame
  and before publishing authority events, so a delayed host pump cannot admit a
  new expired save or accept a late presentation that clears its deadline.
  Already-admitted transactions may still commit; expired receipts are suppressed,
  not used to pretend such writes were undone. Waiting for human confirmation pauses the action clock;
  confirming/cancelling starts it again. Interactive preview pauses the author
  action clock while the candidate retains its own startup/action clocks.
  Optional protocol inactivity is a separate
  limit, disabled by default.
- The coordinator blocks on its sockets and the nearest action/protocol-inactivity deadline.
  Quiet sessions, including closed editors, wake at most every 200 ms to observe
  reader exit; only an active Guile worker uses the 10 ms completion poll. The
  author's worker waiting for interactive preview does not trigger that poll. Tests
  exercise real quiet waits, socket wakeups, deadline shortening and a blocked
  SQLite task. This is scheduling evidence, not a measured power result.
- SQLite/preview tasks run on a worker, outside the endpoint's serialized
  receive/take/complete transitions. Retiring a view cancels its proposal and
  preview, suppresses late completions, and waits for admitted work before
  starting the replacement. A transaction already admitted can commit; retirement
  is not an undo operation.
- Preview runs the candidate as a new child attached to a **different temporary
  SQLite store** with a preview grant. Read/save stay local to that disposable
  store; recursive preview, installation and export are rejected. The operator
  can exercise candidate actions before trusted Finish/Cancel controls close it.
  The author gets a preview result only after execution and disposable-store
  cleanup. Candidate text, edit serials, view and token are separate from the
  author's retained draft. Explicit `preview_mode="smoke"` remains a test fixture;
  launchers default to interactive preview.
  It does not prove every future authored action terminates. Authored status
  strings such as “saved” or “installed” carry no authority: only real delegate
  receipts, its retained preview ticket, trusted confirmation and SQLite CAS
  control storage or installation.
- The dedicated owner establishes native process-group ownership before source
  execution and the runner normalizes its donated socket to FD3. Input/output
  are bounded. The owner kills and reaps only its own descendants, including
  detached/double-forked `setsid` children. Preview cleanup is tested to preserve
  a detached main-editor support process and an unrelated coordinator child;
  closing the main editor then reaps that main support process. The coordinator
  never subtracts a global leader list to classify descendant ownership.
  Child stdout/stderr go to `/dev/null` rather than an unbounded capture.
  Cleanup has bounded observation and directory traversal; incomplete cleanup
  is fatal and cannot become a failed-preview receipt or authorize a new trial.
  Exceptional top-level exits retain the runtime directory for inspection.
  Native filesystem or process escape prevention is not claimed.

Fresh native workspaces bind `workbench-editor-v1` plus the pinned supervisor output name
into their environment and every revision digest. Sandboxed workspaces use a
distinct identity containing the SHA-256 of their canonical immutable owner
command path, which captures the execution inputs. Old text-function workspaces
fail with `environment-mismatch`; there is no silent migration. The runtime ABI
is `(workbench-main receive! send! own-source)`, documented in `SEED.md`.

## Verification

**Historical checkpoint, 2026-09-15:** all thirteen integration scenarios passed, including the
offscreen production-plugin/native-widget path. The earlier injected-`dialog`
collision was corrected in the generic plugin by separating `editor_dialog`
from its ReaderUI owner. The aggregate gate also passes: 58 workspace-protocol,
107 workspace-delegate, 54 surface, eight real-runner tests, and 125 generic
plugin assertions. Offscreen widget evidence does not establish a visible
desktop session or hardware rendering.

**Interactive continuation, 2026-09-19:** the complete native gate passes 27
integration tests and 171 Lua assertions, with the protocol/delegate/surface and
eight runner suites also passing. The actual offscreen KOReader widget exercises
candidate Save/Read/Finish. Additional cases cover cancellation, action failure,
stale candidate controls, independent edit retention, quiet preview waiting, and
fragmented/coalesced sandbox-owner acknowledgements, malformed candidate message
types, multi-step authored preview/confirmation chains, remaining-deadline
transport budgets and terminal owner failures after Finish's final pump.
An incomplete authority exchange retires that connection permanently; reopening
requires a new session, so a late reply cannot be mistaken for a later request.
The existing reader and its unsaved local draft remain available after backend
retirement; subsequent actions fail locally and Close/Open do not contact the
retired authority.
These controlled owner tests
do not substitute for the separate ARM64 execution gate.

**ARM64 continuation, v16:** the sandbox coordinator passes 29 QEMU assertions
across nine execution domains, including concurrent author/candidate actions,
disposable saves, trusted installation, busy cancellation, timeout and
owner-failure refusal, cleanup and fresh-coordinator recovery. The retained
filesystem/SQLite audit passes. This is separate from the native actual-widget
result above; no on-tablet authoring result is claimed. Exact evidence and
reproduction: [`QEMU.md`](QEMU.md).

```sh
sh pinenote/tools/book-workbench-editor/run-tests.sh
```

The script stops on the first failure and runs the typed workspace/surface suites,
the actual runner/socketpair suite, the real authority/SQLite integration suite,
and the generic plugin tests. The integration suite includes an offscreen
KOReader controller which uses the production plugin, native InputDialog buttons,
trusted ConfirmBox and inherited paint path. Native `addTextToInput`/`delChar`
operations must advance `edit_serial`; full-buffer replacement is only fixture
setup, not evidence of edit notification. The widget gate also checks
edit-away-and-back before transformed replies and confirmation cancellation,
stale confirmation/Close callbacks, native Back, multiline-title layout bounds,
and an open idle interval with zero private-channel polls. It never opens a
visible window.

`test-editor-integration.py` proves:

- R0 saves/previews/proposes R1; proposal alone and cancel do not activate it;
  trusted confirmation does. Reopened R1 defines a new title/action/behavior and
  authors executable R2. Authority, runner, surface and delegate files retain
  their hashes throughout the test. A full process restart recovers R2.
- The preview child really saves into its disposable database and really gets
  access-denied from privileged workspace operations, while the author snapshot
  remains byte-for-byte unchanged.
- A second real authority invalidates a retained proposal's activation CAS;
  stale confirmation and retired/forged private UI decisions cannot activate it.
- Broken source fails preview; rollback and permanent-seed recovery still work
  and preserve that broken draft for editing.
- Authored action loops time out, idle waiting does not; private coordinator
  spoofing from the child is rejected; fork/setsid descendants are cleaned up;
  retiring a running preview destroys its disposable store and suppresses its
  stale result.
- Ordinary top-level or entry exceptions produce a failed candidate result while
  preserving the main editor. Deliberately delayed pumping rejects both a queued
  late presentation and a new late save before SQLite admission. An independently
  admitted, completed transaction survives retirement while its late receipt
  remains unpublished.

The parent session owns sandbox/QEMU verification and final cross-component
review. Passing this native gate does not establish gVisor containment, hardware
rendering, or OS-image deployment.
