# Book Workbench: offline authoring review

Session started 2026-09-11, from `7db36cb0569112e02147ad80cb27dc6e55c99a14`.
The generation-21 hardware record and cable-free policy edits already existed
in the working tree. This review concerns the subsequent Workbench prototype
and two inherited note-lifecycle fixes.

**Prototype disposition — 2026-09-12:** all reported findings are resolved for the
trusted-native prototype scope. Project-fit, logic, performance and UI reviewers
closed their findings after reinspection; the final combined gate passed after
the repeated-resync correction. This is an offline authoring result. The later
visible-desktop report and launcher correction are recorded in the follow-up
below; the offscreen gate had not exercised that renderer.

## Scope

`pinenote/tools/book-workbench/` implements one source resource, a separate
private SQLite authoring store, immutable content-addressed revisions,
endpoint-local preview authorization, explicit activation and rollback, source
export, and a generic KOReader editor. Its execution composition is an explicit
trusted-native desktop fixture. The OCI generator prepares a separate
`workbench-preview-preparation-only` contract; the fixed-note sandbox supervisor
does not accept that record. No new gVisor, ARM64 or device-runtime claim follows
from the native checks or from the generated OCI fields.

Project-fit, storage/authority logic, performance/cleanup, and final UI reviews
were assigned independently of implementation. Their dispositions distinguish
source inspection from executed regressions. The parent integration checks run
the actual source, SQLite, interpreter children and KOReader widgets.

## Findings and corrections

| Finding | Correction and regression |
| --- | --- |
| Draft changed after sealing but before installation | `workspace-activate-draft!` compares workspace version, source digest and activation epoch inside the pointer-update transaction. An interleaving test failed on the old composition, then passed while preserving the competing draft and prior installation. |
| Permanent revision quota was not explained at the UI | README/CONTRACT document the 128-revision lifetime catalog, including seed and unactivated revisions. The authority preserves `revision-quota-exhausted`; KOReader explains the available recovery operations. Real-quota tests preserve draft/save, run, export and rollback behavior. |
| Reopening consumed the only donated connection | Ordinary editor Close keeps the transport. Reopening requests a fresh snapshot and invalidates prior preview authorization; stale-view replies drain without changing the new editor. The real-widget join exercises same-FD reopen during an outstanding reply. After transport failure, README gives exit-and-rerun recovery and distinguishes saved source from process-local unsaved text. |
| Persistent counters exceeded the UI's addressable range | Schema, backend and wire now share `2147483647`. The authority test starts just below the limit, commits the final legal save/install, then verifies specific exhaustion errors and an unchanged snapshot. |
| Unread installation acknowledgements lacked a recovery test | An independent peer sends activation and rollback without reading their replies. Fresh endpoints recover the complete draft/active/previous/epoch tuple and reject stale transitions without another epoch increment. |
| Runtime-tree removal exceeded the preview deadline | Incremental `opendir`/`readdir` traversal checks the original absolute deadline. Expiry closes directory streams, reports incomplete cleanup and retains the remaining root. Deterministic traversal-expiry tests cover the failure path. |
| Second capture-pipe acquisition leaked the first pair on failure | Each pair becomes cleanup-owned immediately; `capture-pipe` also closes both ends when its own `fcntl` configuration fails. Fault injection covers the second acquisition and all eight configuration positions with strong references, without relying on garbage collection. |
| Launcher termination orphaned a preview after SQLite contention | The native authority records cancellation before unwinding, preserves cleanup across repeated signals and skips replies/new reads after cancellation. A bounded readiness wait dispatches Guile's queued idle/partial-line stop signal. Five real-process lifecycle checks pass, including the contended shutdown; the pre-fix entrypoint fails the captured-orphan regression. |

The logic review approved the counter, atomic-installation and unread-receipt
corrections on reinspection. The project-fit review closed all four of its
findings, including the stale architecture/changelog summaries.
The performance reviewer independently reran the 147-check preview suite and
closed the tree-deletion and capture-pipe findings. This verifies incremental
deadline checks and explicit descriptor cleanup, not a hard real-time bound on
individual filesystem syscalls or native-code containment.

The authority-shutdown correction passes its five lifecycle tests in 9.6 s.
Its native idle readiness wait is 200 ms so a queued Scheme signal cannot
remain behind an indefinite port read. This is a documented native-fixture
cost, not a device idle-power result. The performance reviewer independently
reran the lifecycle tests and closed all three findings in that review scope.

The final UI review additionally reproduced legitimate cross-connection saves
and rollbacks that committed successfully but were rejected by the editor's
extra snapshot assumptions. It also found two native dirty-state mismatches
and continuous 50 ms socket polling after ordinary editor Close. All four
findings were fixed and independently rechecked: genuine two-authority receipts
now pass through the UI, native Save/Close baselines agree with visible bytes,
and an idle closed editor is unregistered until reopening.

That re-review found a further ordering: a second rotation or Close/reopen
during the first resync `open` could clear draft preservation because visible
bytes still matched the stale pre-save baseline. The retained draft was then
replaced by the pending save's source. The explicit `preserve_until_snapshot`
obligation now survives control refreshes and retired replies, including a
reply drained while closed. Only a validated current-view snapshot clears it.
All three interruption variants failed before the fix, then retained the draft
and successfully saved it against the reconciled version. The UI reviewer
independently reran the real receipt generator and all 503 FSM checks and
approved the final UI scope, with no outstanding findings.

## Prototype execution and source identity before the desktop follow-up

`make book-workbench-check` passed through its default channel-pinned dependency
path after the final source change:

| Gate | Result |
| --- | --- |
| Workspace storage | 168 checks |
| Authority and private framing | 71 checks |
| Executable preview, cleanup and OCI preparation policy | 147 checks |
| Fresh-process edit/preview/activate/recover/rollback | 1 integration test |
| Independent adversarial UI peer | 10 integration tests |
| Real-process launcher/cancellation/cleanup/export | 5 integration tests |
| Channel/UI FSM | 503 checks, including two genuine two-connection authority/SQLite receipt scenarios |
| Actual KOReader + authority + SQLite + preview children | Passed, including six explicit native-widget regressions and inherited paint assertions |

Output: `/tmp/opencode/book-workbench-final-check.log`. Native dependencies:

- `/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor`
- `/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03`

New-tool code/test/schema identity: **27 files, 328,070 bytes**, aggregate
SHA-256 `04c33933433fa240cd4ebff662ccabd27f1bee13525db394506db5d0e62f2c54`.
Recompute from the repository root with:

```python
from pathlib import Path
import hashlib
root = Path("pinenote/tools/book-workbench")
files = sorted(p for p in root.rglob("*") if p.is_file()
               and p.suffix in {".scm", ".sh", ".lua", ".py", ".sql"}
               and "__pycache__" not in p.parts)
digest = hashlib.sha256()
for path in files:
    digest.update(path.relative_to(root).as_posix().encode() + b"\0")
    digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
```

The UI review independently recorded `main.lua` SHA-256
`97217438c504b06003b1bbd6b32b6954ea9c092d785e74c7bf0121bc9ec265c5`,
matching the final checked source. All new Scheme, shell, Lua and Python files
passed syntax checks, and the new source set passed whitespace checks.

## Inherited persistent-note regressions

- The fourth save could commit before its presentation hit the four-request
  limit: old save actions were never retired. The authority now locally
  cancels the ordinary action only after validating its typed storage
  completion. Presentation still has a separate correlated action. The native
  regression executes eight saves and six real quota failures on single
  endpoints, including a disconnect after receipt and recovery afterward.
- A delayed close/paint/status callback could act on a newly opened note
  because all connections used wire generation 1. Callbacks now retain exact
  channel and widget identities. The regression failed on the old plugin and
  passes with real native KOReader, including immediate close/reopen before
  old callbacks drain.

The combined `pinenote/tools/book-state-device/run-tests.sh` passed with pinned
inputs. Its full log is
`/tmp/opencode/book-state-device-workbench-followup.log`. The separate pinned
derivation gate resolved `/gnu/store/aw65hlk17l5fyzq6qzhkicwmms4394p4-system.drv`
with the existing required kernel/gVisor outputs. That system was not built or
deployed; generation 21 does not contain these fixes.

## Reproduction entrypoints

```sh
make book-workbench-check
guix time-machine -C channels.scm -- repl -L . \
  pinenote/tools/book-state-device/derive-system.scm
```

The native launcher, source contract, private-channel fields and exact proof
boundaries are documented in `pinenote/tools/book-workbench/README.md`,
`CONTRACT.md` and `PREVIEW.md`. The source-only checks are separate from the
older frozen persistent-note capsules; their earlier acceptance does not
automatically cover these files.

## Visible-desktop follow-up — 2026-09-12

The operator ran the native launcher and saw no window. The authority and
KOReader were both alive, but the reader had no mapped Sway window. A minimal
probe using the actual bundled SDL3 showed `SDL_CreateWindow` succeeding while
`SDL_CreateRenderer` returned NULL with **"Could not initialize OpenGL / GLES
library"**. KOReader's SDL adapter continued with a NULL renderer and texture.
The same probe's offscreen renderer succeeded, explaining why the prior native
checks had missed the visible-desktop dependency.

The launcher now resolves a separate, channel-pinned Mesa output and supplies
its EGL/GLES libraries to the desktop reader by exact path, selecting
`opengles2`. The first composition attempt paired libglvnd with a Mesa vendor
JSON, but the pinned Mesa is a standalone build: `libEGL_mesa.so.0` does not
exist. The parent and independent performance reviewer both identified this;
the correction lowers Mesa directly and removes the dispatcher/JSON layer.
`desktop-reader.lua` also checks SDL initialization and window/renderer/texture
creation, preserving the failing call's error before KOReader can overwrite it.
Resolved symbols are cached, with no additional proxy work on rendering or
input calls after their first lookup.

Follow-up evidence:

- The existing five launcher/lifecycle checks and a new real-SDL renderer
  failure regression passed first: **6 tests in 9.591 s**,
  `/tmp/opencode/book-workbench-desktop-launcher-tests.log`. The new test creates
  an offscreen window but requests an unavailable renderer, then requires a
  prompt nonzero exit naming `SDL_CreateRenderer` and its original error.
- The logic review found that an absent SDL library became a truthy proxy,
  changing KOReader's device-detection result. The wrapper now preserves nil;
  a regression executes the actual wrapper with that loader result. A further
  optional test selects the actual Mesa EGL/GLES libraries with `opengles2`
  under SDL offscreen and verifies successful window/renderer/texture creation
  and cleanup. With `BOOK_WORKBENCH_GRAPHICS` set to the Mesa output below, the
  final **8 launcher tests pass in 9.825 s**:
  `/tmp/opencode/book-workbench-desktop-launcher-final-tests.log`.
- The default `run-native-demo.sh` path lowers and realizes the desktop
  dependencies successfully. It selects Mesa
  `/gnu/store/ikfz8dkfrhijll2i929d9ws4ldz0i5qi-mesa-26.0.2`; the supervisor and
  KOReader identities above are unchanged. Log:
  `/tmp/opencode/book-workbench-visible-demo.log`.
- The original invisible launcher was terminated through its verified pidfd;
  both children exited and its disposable reader profile was removed. The
  replacement uses the same operator workspace. Sway reports the replacement
  reader visible and focused on workspace 2. A scoped screenshot visibly renders
  the fixture's Workbench instructions:
  `/tmp/opencode/book-workbench-visible-window.json` and `.png`.
  The demo subsequently exited with status 0, and the operator reported
  **"seems to be working"**.
- The changed Python, shell and Lua entrypoints pass syntax checks; successful
  default dependency lowering checks the Scheme input definition. Tracked and
  new-tool whitespace checks pass. The prior source/SQLite/preview/UI-FSM gates
  are reused at unchanged sources; this addendum is a launcher and visible
  desktop check, not a new execution-isolation or device result.

The independent project-fit reviewer approved the desktop dependency separation
and operator-facing documentation. The performance reviewer closed the invalid
vendor-library finding after reinspection and inspecting the successful launcher
log and screenshot. The logic reviewer closed the absent-SDL finding after
reinspecting the final wrapper and its regression; all three desktop reviews
have no remaining concrete findings.

Post-follow-up new-tool code/test/schema identity, using the aggregation recipe
above: **28 files, 334,365 bytes**, SHA-256
`eb18e2a7a94499eb766e8b7f19d2d72db88a44f01f523788b217fa93868cd047`.
