# The notebook: pen and paper on the PineNote

**Status (2026-09-26): on glass.**
- Generation 22 ran the notebook on wkelly's device the same day
  (`doc/status.md`).
- Generation 23 carries the fixes from that run: stylus taps on the
  panel, a flicker-free panel paint, two-finger undo, a Refresh item,
  idle-washer debt, and a pressure default.
- On generation 23 the operator confirmed the flicker-free panel, pen taps
  on the panel, two-finger undo and redo, an idle wash, and suspend/wake.
  It also cold-booted twice, and is pinned. Refresh and a KOReader restart
  passed after the cold boots (see "Glass sessions").
- Design agreed with the operator the same day.
- Generation 24's batch fixes passed basic drawing/Refresh/close-reopen,
  rotation, night mode, >45 s hover without automatic wash, and persisted
  strokes after a real KOReader process restart (operator, 2026-09-26).
  Contact-dropout and debt-ceiling edge cases still have only host coverage.
- It passes every host suite, including a replay of the operator's real
  pen captures from `doc/status.md` 2026-09-26.

This is ROADMAP §5's first stage ("continuous note-taking") and the
capture and storage half of stroke capture #20.

## Next polish: operator priorities (2026-09-26, after generation 24)

The operator finds ink responsiveness good and current ghosting/refresh
acceptable; charcoal (#83) can bring its own performance investigation.
They want a **GL16 finishing phase after writing**, with an attended feel
comparison, and consider durability important. Navigation and refresh changes
are recommendations for discussion, not an approved redesign.

- **Finishing proposal:** retain DU for live ink; after a confirmed pen leave,
  generate antialiased grayscale edges for the changed region and publish under
  GL16. First scope: solid Fine/Ball/Brush strokes. New proximity cancels pending
  work; page/rotation/suspend/close changes invalidate it. Keep the canonical
  strokes, eraser/undo semantics and journal independent of this derived render.
  Before device testing, prove replay consistency, clipping/overlap, night mode,
  cancellation and bounded host cost. Cancel stale work before publication;
  once GL16 is in flight the driver's early-cancel path only admits binary
  DU-to-DU, so renewed ink on those pixels may wait for GL16 to finish. An
  attended trial must include a quick return to the same line, not only a
  pleasant idle finish. The ordinary driver scheduler compares target with next; switching the
  hint while repainting identical binary pixels is not itself a finishing pass
  (`linux-pinenote-7.1-hrdl-direct-mode.patch`, `q8_start_scheduled` and
  `q8_start_redraw`). Its redraw hint also requires a changed target. This is
  source inspection, not an optical result. No finishing pass is implemented.
- **Navigation recommendations:** distinguish hiding the floating controls
  from returning to the reader; give notebooks human-readable names instead
  of only UTC creation times; add a picker of pages containing ink. Keep
  gestures stable in normal writing. Charcoal finger-smudge mode needs an
  explicit navigation choice because it would consume the one-finger swipe.
- **Refresh recommendations:** retain explicit Refresh, hover protection and
  debt acknowledgement. Measure redundant publishes/charges on panel close,
  page changes and finishing before adjusting washer thresholds. GL16 finishing
  is an appearance change, not proof that GC16 wash debt has been paid.
- **Durability:** pen-up appends are not fsynced until leave/close/suspend.
  A clean shutdown needs a confirmed notebook flush before services stop.
  Extended hover still has a hard-cut exposure; per-stroke blocking fsync would
  risk overflowing input. Bounded asynchronous persistence is a separate design,
  with errors and acknowledgements, rather than silently increasing pen latency.

Handwriting recognition begins with a small **labelled evaluation corpus**;
the current scribbles are not accuracy evidence. The read-only host exporter
and collection recipe are in `pinenote/tools/handwriting/README.md`. No model
has been selected, and recognition is not in the drawing path.

### Fixed paper and the handwriting sampler (2026-09-26)

Operator-approved scope: a simple notebook template; orient the device by hand.
The five-page, 20-line sampler pairs each printed prompt with a ruled writing
area. `pinenote/tools/handwriting/make-sampler.scm` generates the EPUB and a fresh
notebook from the same artwork; its README has generation, installation and
labelled-region export instructions. **Deployed as generation 25 on wkelly's
PineNote:** health passed, sampler page 0 opened through the normal notebook
path, and pen-up/append/fsync logs show new writing. Operator appearance and
interaction acceptance is still pending (`doc/status.md`). The actual native
KOReader renders the EPUB as five pages.

Paper is an immutable physical-pixel layer below the journal. Live area erasing
restores paper; replay, undo and stroke erasing start from that same paper.
Rotation keeps ink and background aligned in panel coordinates, while controls
can turn; this does not rotate existing writing upright. The `nb_background`
loader reads `backgrounds.conf` (`wilkbook-backgrounds-v1 W H`, then one signed
page number per line) and exactly sized `background-N.pgm` assets (P5, 8-bit
gray, canonical `P5\nW H\n255\n` header). It refuses mismatched geometry and
declared missing/corrupt pages before replacing the current page. Undeclared
pages and notebooks without a manifest stay blank. Only the current background
is retained (~2.6 MB on PineNote), with a second during page-load preflight.
Assets are loaded on page changes, never while stamping a pen report.

The stroke format is unchanged. Keep backgrounds with copied notebooks; older
generations ignore them, so use a background-capable reader for this sampler.
There is no reader-side importer or template picker yet: install the generated
new directory once while the notebook is closed. The reusable layer can later
hold a rendered book-page snapshot, but EPUB anchoring, repagination and book
annotation UI remain separate work.

Offline proof: full KOReader input suite, 36 dedicated background assertions
(real BB8/RGB16, both blitters, all rotations/night mode, erase/replay and region
clipping), plugin page-load/refusal/switch/close coverage, and labelled-region
export tests. On glass still owed: readability, drawing across a rule, erasing,
undo, page turns, close/reopen and orientation. DU ink policy is unchanged;
the physical appearance of restoring gray paper with the eraser is unmeasured.

## What it is

The operator's brief, 2026-09-26:

- **Paper and pen, with digital conveniences.** Nothing sits on the page
  unless asked for.
- **A notebook you open explicitly.** Open it from KOReader's menu
  (Tools → Notebook). Ink exists only inside it; everywhere else the pen
  behaves as before. Because it is an explicit UI, it ships in the reader
  without a flag. Ink anywhere (annotating a book page) is a later stage
  and stays experimental until its UX is settled.
- **The pen inks, and its rubber end erases.**
- **Touch is for space.**
  - A one-finger horizontal swipe turns the page. Pages run infinitely in
    both directions, and a blank page costs nothing until it has ink.
  - A two-finger swipe undoes (leftward) or redoes (rightward).
  - A long finger press summons a floating panel. It stays up until
    Close is tapped or it is flicked away, and a finger can drag it by
    its title.
- **The pen never opens the panel or turns a page by swiping, but it can
  tap the panel's buttons** (including ◀ ▶) (operator, 2026-09-26). A pen contact that starts on
  the open panel never inks; only a tap within 400 ms and 24 px acts, and
  the rubber end does nothing there. While the pen is in range, touch is
  ignored: palm rejection, which the operator accepted.

**The panel holds:**
- the brush:
  - pressure brushes: Ball (the default, M), Brush, Pencil;
  - fixed widths: Fine, Marker, Hilite;
- size S, M or L;
- the mode:
  - Write: the tip inks;
  - Erase: the tip rubs out an area;
  - Erase strokes: the tip removes whole strokes;
- the rubber end, `Rubber: area` or `Rubber: strokes`;
- Undo and Redo;
- page ◀ ▶;
- Refresh: closes the panel, then does one full-panel wash;
- New, Open…, Exit (close the notebook) and Close (the panel).

**The undo swipe uses two fingers, not five.** The operator asked for
five. On 2026-09-26 a touch capture of deliberate five-finger holds and
swipes peaked at **two** contacts per frame, and PINE64 records that the
factory firmware allows at most two (issue #82). Raising the limit is
hrdl's one-byte write to the touch controller's stored config, which is
the operator's call; #82 has the evidence, the risks and a read-only
first step. So the swipe fires on `multi_min_fingers = 2`
(`nb_config.lua`), and both fingers must each travel, so a resting thumb
beside one swiping finger does not undo.

## What the glass has already told us

**Display:**
- A region hinted DU (`0x00`) through `RECT_HINTS` in NORMAL was pen-class
  by blinded feel beside GL16, and whole-screen DU could not be told apart
  from FAST (`doc/status.md` 2026-09-26). The notebook therefore inks
  through a DU rectangle in NORMAL and never uses FAST. No camera timed DU
  in NORMAL.
- D8 filmed ~20 ms nib to first ink in FAST and ~40–60 ms in NORMAL
  through GL16 (`doc/status.md` 2026-08-26 part 8).
- DU drives only black and white. So every brush is binary. Pressure sets
  width, and the pencil and highlighter are dithered patterns, which DU
  shows exactly.

**The w9013 Stylus node:**
- It reports every 2.77 ms median, about 360 Hz, the same pen-down and
  hovering.
- The rubber end arrives in-band on the same node as `BTN_TOOL_RUBBER`,
  with contact and pressure (`doc/status.md` 2026-09-26).
- Its grid is 11.2× the panel's
  (`doc/artifacts/pinenote-input-clocks-20260824/RESULT.md`).
- It shares the framebuffer's landscape-native axes (`doc/status.md`
  2026-08-26 part 7).

**KOReader:**
- It has no drawing feature and no hint plumbing.
- Ink drawn by KOReader has never been measured on glass; this notebook
  is the first.

## Design

### Shape

A functional core and an imperative shell. Everything that decides is
pure Lua, tested on the host with no device and no KOReader UI. One
module talks to KOReader.

| Module (in `plugins/notebook.koplugin/`) | Role |
|---|---|
| `nb_config` | Every tunable, in one place. |
| `nb_geom` | Physical↔logical transforms for the four rotations, and digitizer→pixel mapping. |
| `nb_input` | Pen stroke assembly, touch gesture recognition and palm rejection. Raw evdev in, intents out. |
| `nb_brush` | Brush styles, pressure→radius, dither masks, the span rasterizer, and stroke-erase hit tests. |
| `nb_journal` | The page-file format, replay with undo/redo, torn-tail repair, and the notebook store over an injected filesystem. |
| `nb_panel` | The floating panel's layout, hit testing, drag and flick. |
| `nb_controller` | The session state machine. It composes the above and emits a command list; it does no IO. |
| `nb_surface` | Spans into Blitbuffers: page buffer, framebuffer alias, blit with rotation matched. |
| `nb_background` | Optional fixed physical paper, strict geometry and declared-page loading; independent of ink. |
| `nb_fs` | The filesystem over ffi: one `write(2)` per append, fsync, atomic rename. |
| `main.lua` | The KOReader shell: menu entry, the notebook window, the command executor, panel painting. |

The core is pure, and `main.lua` only executes its commands. That is
what lets a whole session run in a test: input stream in, commands out.

### Input

- **One hook, owned by `device.lua`.** KOReader cannot unregister an
  input adjust hook, and the plugin is instantiated per book. So
  `device.lua` registers one final hook that calls
  `input.wilkbook_consumer` when it is set. The notebook window sets it
  on show and clears it on close.
- **Raw pen values.** `device.lua`'s pen scaling now keeps the raw
  digitizer value (`ev.raw_value`), and clamps to the last pixel.
  Previously a raw 20966 mapped to column 1872.
- **Consumption.** While the notebook is open, its consumer takes every
  pen, touch and pen-button event, and neutralises it (`ev.type = 4`).
  So KOReader's gesture detector never sees them.
  - Touch passes through to KOReader while a KOReader dialog (the Open
    list, a message) is on top. That switch happens only with no finger
    down, with `Input:resetState()` and a touch-slot resync, so
    KOReader's slot state stays consistent.
  - `KEY_SLEEP` is swallowed only from the pen receiver, never from the
    power broker.
- **Pen rules** (from the real captures):
  - ink is gated on `BTN_TOUCH`;
  - axes are latched and committed per report;
  - a tool switch or proximity loss mid-stroke ends the stroke with a gap
    flag;
  - after `SYN_DROPPED`, the stroke ends, the report is discarded,
    proximity and tool are re-read (`EVIOCGKEY` on a transient fd), and
    ink waits for a real pen-down.
- **Palm rejection.**
  - A touch contact is dropped whole if it starts while the pen is in
    range, or within 500 ms after it leaves.
  - A gesture is vetoed if the pen came into range during its life.
  - Nothing turns the page while the pen is down.
- **Activity.** Consumed pen batches produce no KOReader input event, so
  pen-only writing would read as idle to AutoSuspend and the idle washer.
  Pen contact and accepted touches raise a synthetic `InputEvent`, at
  most once a second, on `nextTick`. Hover never counts.
- **Rotation.** `device.lua` defers a rotation while a predicate says
  so. The notebook holds it while the pen is in range, then forwards the
  rotation to the book or file manager underneath. Pages are stored and
  drawn in physical coordinates, so a page stays where it was written,
  like paper. Only the panel follows rotation.

### Ink on the glass

**The DU rectangle:**
- `device.lua`'s hint owner (`Device.hint_owner`) packs `RECT_HINTS`. It
  sets the canvas to `0x00` (DU), with the open panel's rect back at
  `0x20`.
- It exists only on the direct driver. On the old driver, command `0x03`
  is REFRESH_BARRIER.
- Every `refresh*Imp` guards it: a foreign refresh that intersects the
  armed DU rect disarms it first. So a toast or a wash never renders
  through DU.
- The notebook re-arms before its next ink.
- The plane is reset to the running module's own `default_hint` at
  module load and at each open, which clears a rectangle a crashed
  KOReader left behind. That is 32, as `pinenote-ebc-direct-params` set
  it; `device.lua` reads it once at init rather than hard-coding it.

**Live ink:**
- The hook runs the controller.
- The brush rasterizes the new segment into row spans.
- `nb_surface` fills them into the page buffer (BB8, physical) and a
  rotation-0 alias of the framebuffer (RGB565).
- `Device:publishNow()` fsyncs once per pen report. It is an untraced
  publish, so the pen path writes no log line per report.
- The ink never waits for KOReader's gesture detector.

**Brushes** (widths at 227 dpi, size M; S and L scale them):

| Brush | Width | Look |
|---|---|---|
| Fine | ~0.3 mm | solid |
| Ball | 0.3–0.7 mm from pressure | solid |
| Brush | 0.4–3 mm from pressure | solid |
| Marker | ~2 mm | solid |
| Pencil | 0.3–0.6 mm | Bayer-dithered, density from pressure; paints only black |
| Hilite | ~5 mm | 50 % checker; paints only black, so ink under it survives |

The eraser is 24–48 px wide (2.7–5.4 mm), from pressure.

**Repaints:**
- Page turns, undo/redo and stroke erase repaint through KOReader's `ui`
  refresh (GL16), with no full flash.
- The panel is composed off-screen and copied in one blit; the page is
  drawn only where the panel is not. A selection change is one refresh
  in which only the toggled buttons' pixels change. (Generation 22 drew
  the page over the panel and the panel back on top, so a deferred-io
  flush mid-paint made it vanish and reappear.)

**Ghosting** (operator, 2026-09-26: "erased stuff hangs around, previous
page is visible if you look closely"): DU and GL16 never run the
panel's clearing flash, so the cleanup is a full GC16 wash, from two
sources, not on a page turn (except the `debt_max` backstop in Known limits):
- **Refresh** on the panel. It closes the panel, publishes the page,
  waits `refresh_settle_us` (150 ms, counted from the end of the
  publish) and then washes with a refresh-only `setDirty(nil, "full")`.
  The wait exists because hrdl's `GLOBAL_REFRESH` does not flush pending
  deferred-io damage. With the pen in range the wash waits for its
  leave.
- **The idle washer**, now fed by the notebook. Area erases, stroke
  erases that removed strokes, undo/redo re-renders and panel closes
  each add one unit through the washer's new accumulate-only
  `chargeDebt()`, charged at the pen's leave and never mid-stroke; page
  turns keep `chargePageTurn()`. After `debt_min` (15) units and 45 s
  without input the washer's idle wash repaints the window and cleans
  it.

### The journal

- **One directory per notebook**: `/data/notebooks/<UTC stamp>-<hex>/`.
  - `/data` survives a reflash.
  - The notebook refuses to open unless `/data` is the real ext4
    partition, mounted read-write, and an append probe succeeds.
  - `notebook.json` is written once.
  - Each page with ink is its own append-only `page-<n>.jsonl`, so an
    open or a page turn reads one page.
- **Records**, one per line, in a restricted JSON with a fixed key
  order:
  - `s` is a stroke: tool, brush, style parameters, rotation at pen-down,
    start time, bounding box, gap flag, and its raw samples as integer
    deltas of time, x, y, pressure and the two tilts;
  - `x` removes strokes (stroke erase);
  - `u` and `r` undo and redo an action.
  - Replay derives the page. Nothing is ever rewritten, and each stroke
    replays at its recorded style, so later tuning cannot change old
    pages.
- **Durability.**
  - A stroke is written at pen-up with one `write(2)`.
  - The page is fsynced when the pen leaves range, on close and on
    Suspend. Never on a timer while the pen is in range: the Stylus evdev
    buffer holds about 100 ms of reports.
  - "Leaves range" means out of range for 150 ms (`prox_leave_us`). The
    digitizer drops proximity for 22–44 ms at the panel's top edge and
    in hover flicker, and a leave runs the fsync, releases the rotation
    hold and shows deferred panel updates.
  - On open, a page file that does not end in a newline is truncated to
    its last one. This is the one exception to append-only.
  - Any write or fsync error stops inking for the session with a
    message. No stroke is drawn that cannot be saved.
- **No sandbox.** The Book Computer design puts raw pen capture and
  stroke storage in the trusted host
  (`doc/wilkbook-self-hosting-book-computer.md` §4.3, §13.1). This
  journal is that primitive. Books would later read it through a typed
  grant, keyed by the notebook id.

### Opening, switching and reopening

- The menu entry offers Open last, New notebook and Open… (a list,
  newest first, titled by creation time in UTC).
- New or Open… from inside a notebook closes the current one through the
  normal close path first: the stroke in progress is recorded, dirty
  pages are fsynced, and the rectangle is disarmed
  (`NotebookWindow:_switch`).
- Reopening a notebook goes to the page it was last on.
- `/data/notebooks/prefs.json` records `last_id` and each notebook's
  last page. It also records the brush, size, mode and rubber setting,
  but only once the user has picked them on the panel; an absent key
  means the code default, as `doc/configuration.md` asks. It carries a
  format version.

### Not in this proof of concept

- anti-aliased or gray ink, which would need a GL16 settle pass;
- export (SVG/PNG);
- notebook names;
- annotation over books;
- handwriting recognition;
- lasso and selection;
- sync.

## Offline proof (host, 2026-09-26)

`make koreader-input-check` runs these ten suites. They are pure Lua
unless noted, each deterministic across two runs:

| Suite | What it covers |
|---|---|
| `test-notebook-geom` | Every rotation formula against KOReader's real Blitbuffer. |
| `test-notebook-input` | Pen and touch rules, and the real captures: 156 and 86 strokes, the rubber intervals as eraser strokes. |
| `test-notebook-journal` | The codec, undo/redo/erase replay, and the torn tail at every byte offset. Fault injection for `ENOSPC`, `EROFS` and `EEXIST`. |
| `test-notebook-brush` | The rasterizer against a brute-force pixel reference, and hit tests. |
| `test-notebook-panel` | Layout in both orientations, drag and flick. |
| `test-notebook-controller` | Scripted sessions for every path. The real captures replayed end to end: the live page equals the page rendered from the journal. |
| `test-notebook-render` | Pixel-exact ink, masks and blits on BB8 and RGB565 in all four rotations (Blitbuffer). |
| `test-notebook-fs` | The real ffi filesystem in a temp dir. |
| `test-notebook-plugin` | `main.lua` wired to a recording UIManager, a real framebuffer at portrait rotation and KOReader's real `Input:waitEvent` chain. |
| `test-notebook-device` | The hint owner's bytes against `ebclib.lua`, its guard math, and the no-op on the old driver. |

Two instruments sit outside the gate:
- `notebook-replay.lua` renders a raw capture to PNG. The 2026-09-26
  captures render with every brush.
- `notebook-realui/` runs a real offscreen KOReader with the plugin. It
  takes screenshots and audits every panel repaint and the Refresh wash.

## Known limits

**Hardware and input:**
- Two contacts at most on stock touch firmware (#82).
- A touch `SYN_DROPPED` can leave a phantom contact until its slot is
  reused. That needs a stall long enough to fill the touch buffer.
- evdev drains one node at a time. So a touch lift that drains before a
  same-batch pen proximity-in can still fire.

**Washes:**
- Debt charged after a hover longer than 45 s can miss the idle wash the
  washer already timed out on, and wait for the next pause or the 600 s
  deep clean.
- If debt reaches `debt_max` (60) with no 45 s pause, the next notebook
  page turn's bundled wash merges with the turn's repaint and meets the
  non-draining `GLOBAL_REFRESH` the same way reading turns do.
- Refresh leaves the washer's debt in place, so a later pause can bring
  one more idle wash.

**Durability:**
- A retried fsync on a new fd can report success after an `EIO`. That is
  why an error stops inking for the rest of the session.

**Measured on glass** (generation 22, 2026-09-26; 218 strokes, 58,868 pen
reports, 58,073 of them stamped;
`doc/artifacts/pinenote-gen22-23-notebook-20260926/`):

| Measure | Result |
|---|---|
| Stamp per stamped report | 0.20 ms mean, 8.5 ms max |
| Publish (fsync) per stamped report | 0.37 ms mean, 16.8 ms max |
| Worst event-to-handling delay per stroke (not per report) | p50 1.2 ms, p95 14.4 ms, max 34.3 ms |
| Append at pen-up | 0.4 ms mean |
| fsync at the pen's leave | 6.1 ms mean |

- 50 strokes drained a backlog of more than one report in a batch (up to
  36). So the pen path falls behind by tens of milliseconds at times; the
  cause is not yet identified.
- There was one evdev overrun (`SYN_DROPPED`) between opening and the first
  pen-up.
- Nib-to-ink was not timed.
- The operator: "very responsive and feels good and accurate".

No camera timed nib-to-ink. The `[notebook]` pen-up log line in
`/var/log/reader-session.log` carries these per stroke.

## Glass sessions

**2026-09-26.** Generations 22 and 23 were installed as cable-free kexec
trials (`doc/status.md`).
- Generation 22's checks passed: the `25cea98` note fixes, and the
  notebook's ink, brushes, erase, undo, page turns, rotation and
  notebook management.
- Generation 23 is healthy and promoted.
  - **Passed, as the operator reported:** the panel no longer flickers,
    pen taps select panel items, two-finger undo and redo work, and
    suspend/wake works.
  - **The idle wash also passed**, the operator seeing the second of the
    two that fired (`debt=60`, 23:09:53).
  - **A cold boot passed** (operator-run, UART waived). It was the first
    cold boot of the kernel generations 20–23 share.
  - **Refresh and a KOReader restart passed** after the cold boots, and 23
    is pinned (`doc/status.md`, 2026-09-26 late).

The plan the first session followed is kept below; its deploy steps are
done.

### The generation-22 session plan

Cable-free, with the operator present. The rules are CLAUDE.md's
"Cable-free kexec trial period", engaged only by the operator typing the
phrase in that session. Generation 22 is the experimental
`book-state-device-reader` flavor the device runs, carrying the notebook
and the undeployed `25cea98` note fixes. The `reader` flavor needs its
own run later.

**Offline first:**
- the flavor's pinned gate: `guix time-machine -C channels.scm -- repl
  -L . pinenote/tools/book-state-device/derive-system.scm`, which must
  resolve kernel `334ljs8q…` and gVisor `djgy782a…`;
- the build;
- `check-system-closure.sh`;
- a closure diff against generation 21: the KOReader bundles, the
  `25cea98` pieces and their dependents only.

**On glass:**

1. **Read-only preflight.** Record:
   - os2 root and the real `/data`, mounted read-write;
   - the booted generation (21) and DEFAULT;
   - the current and target system paths and kernel identities;
   - the boot ID;
   - the battery;
   - the exact bytes of `autosuspend.conf`.
2. **Pause auto-suspend** (`enabled=0`). Pin generation 18, the newest
   cold-booted one, whose kernel differs from 22's.
3. **Announce the recovery generations:** 21 for the trial; 18, then
   pinned 16, for the cold boot.
4. **Stop the note authority by hand.** The trial teardown does not stop
   it (CLAUDE.md's kexec lesson). Restart and verify it if the trial is
   refused, fails health or ends on 21.
5. **Deploy** under a ten-minute deadline:

   ```sh
   pinned_guix=$(guix time-machine -C channels.scm)
   timeout 600 env -u WILKBOOK_UART PATH="$pinned_guix/bin:$PATH" \
     make deploy DEVICE=pinenote-os2 FLAVOR=book-state-device-reader KEEP=5
   ```

6. **Note checks for `25cea98`.** Five saves in one open dialog, and a
   fast close and reopen.
7. **A ten-second touch capture** while the operator presses five
   fingers: `cat` the cyttsp5 node, plus `dmesg | grep 'Num touch err'`.
   This settles the multi-finger count.
8. **Notebook checks.** Harvest the `[notebook]` pen-up log lines.
   - open, write, and compare the feel with the 2026-09-26 `scribble.lua`
     DU;
   - every brush and size;
   - the rubber end, and the hard-ended pen's back end;
   - the Erase and Erase strokes modes;
   - a palm before and while writing;
   - a swipe with the other hand while hovering (ignored, by design);
   - the pen cannot open the panel or turn a page;
   - pages both ways past page 0;
   - undo and redo by swipe and by the panel;
   - the panel: long press, drag, flick, Close;
   - rotate the tablet;
   - New, Open…, Exit;
   - restart KOReader and reopen.
9. **Suspend and wake with the notebook open.** The broker refuses every
   suspend while it reads `enabled=0`, so:
   1. write `enabled=1` and unplug the charger;
   2. press the power button;
   3. confirm the suspend from the broker log or the wakeup count, not
      from the panel;
   4. wake;
   5. check the ink is intact and a new stroke saves;
   6. write `enabled=0` again.
10. **A cold boot of 22, only if the operator waives UART for it in that
    session.** CLAUDE.md lists cold-boot qualification among the cases
    that still require UART, and a waiver recorded in a document does not
    count.
    - The operator reboots cleanly (not a long-press power-off, which
      would leave `/data` dirty) and picks os2 and 22 at the menus.
    - **Before pinning 22, pass:**
      - `booted_generation=22`;
      - no `linux,booted-from-kexec`;
      - no `initcall_blacklist`;
      - zero `WARNING` or `timed out` lines;
      - Wi-Fi, touch, pen and display working;
      - the note and the notebook intact.
    - **On failure:** boot 18, confirm DEFAULT, and set it back to a good
      generation. Do not pin 22.
11. **Close out.**
    - restore auto-suspend byte for byte;
    - add a `doc/status.md` entry naming the invocation, any waiver, both
      system paths, every check and the metrics;
    - whether the session counts toward the three-session cable-free
      review is the operator's answer to the open question below.

## Follow-ups from the generation-23 review (2026-09-26)

These were found by the fit, logic and performance reviewers after
generation 23 was deployed. The list below describes that deployed source.
The batch fixes following it are host-tested and await a later generation.

**Washes with the pen nearby:**
- **An idle wash can land while the pen hovers.** Hover is not activity (so
  AutoSuspend still works), and the idle washer knows nothing about the
  pen. After 45 s of hovering with enough debt it washes under the pen.
  Fix: a hold predicate the washer consults, set by the notebook like the
  rotation hold.
- **A pen tap on ◀ or ▶ charges a page turn while the pen hovers.** At
  `debt_max` that fires the bundled wash under the pen. Fix: defer that
  charge to the leave, as ghost debt already is.

**Painting and stroke edge cases:**
- **Night mode breaks the one-pass paint rule.** `blit_page` copies the
  un-inverted page, then inverts the rect in place. Fix: use Blitbuffer's
  single-pass `invertblitFrom`, and add an inverted case to the paint
  audit.
- **A panel-owned pen contact can ink.** If one is dragged off the panel
  and cut by a proximity dropout, its tail becomes a new, inked stroke. Fix:
  carry panel ownership across the cut.

**Ghost-debt coverage and naming:**
- **Not every ghost-producing event is charged.** A panel drag, a
  long-press re-open, and opening, switching or exiting a notebook charge
  nothing.
- **Refresh leaves the washer's debt in place.**
- **A unit of debt is hard to judge** (the operator on generation 23: "it
  is unintuitive to me how much a debt unit represents").
  - One unit is one page turn, area erase, stroke erase that removed
    something, undo or redo that changed the page, or panel close.
  - Page turns add their unit without a log line. Only `chargeDebt` logs,
    so a `charge n (debt=N)` line's `N` includes page turns nobody saw
    logged.
  - Nothing on the glass shows the debt.
  - Fix: log page-turn charges too. Then decide with the operator whether
    the notebook should weight its charges by how much ghost they leave
    (an area erase leaves more than a panel close), or show the debt
    somewhere.
- **The op names are crossed:** `washer_charge` calls `chargePageTurn`, and
  `washer_debt` calls `chargeDebt`.
- **`idlewasher_core`'s header still says "three inputs".**
- **An `nb_config.lua` comment says a third contact "showed for ~20 ms".** In
  the capture it exists only inside a single frame.

**For the next glass run:**
- Log brush, size and span count in the pen-up line, so the heavier Ball
  default can be told apart from code changes. Or write one burst with Fine
  for a comparison.
- Find the cause of the tens-of-milliseconds backlogs, perhaps with
  `getrusage` fault counts around each stroke.

### Batch corrections, 2026-09-26 (offline)

- Panel-owned contacts retain ownership through repeated proximity dropouts,
  including tails outside the panel; they cannot become ink mid-contact.
- Night-mode pages use single-pass inverted framebuffer writes. The pinned
  blitter cannot directly invert BB8 into RGB565, so a clipped off-screen
  conversion precedes the inverted copy for mismatched formats. Native
  KOReader tests cover both rotations and inverted panel Close/full repaint.
- Proximity holds automatic washer operations without generating hover
  activity for AutoSuspend. Panel-pen page charges wait until leave;
  close/suspend/pending Refresh retain them without an immediate bundled wash.
- Refresh takes a debt receipt and retires only that receipt after successful
  publish and a successful full-refresh ioctl acknowledgement. Charges made
  after the receipt survive, including when debt saturates. Failed or missing
  acknowledgement, cancellation and teardown keep debt. **Ioctl acceptance
  is not measured physical wash completion.** The device observer is one-shot
  with a one-second timeout; older device targets keep debt conservatively.
- Window close and internal-error paths release holds and observers. Pen-up
  timing now names brush, size and emitted span count for backlog comparisons.

The remaining debt weighting/coverage, explanatory UI and event-backlog
investigation above are still open. No hardware latency improvement is claimed.

## Housekeeping found while planning (not the notebook)

These are tracked here until each lands somewhere permanent.

- **Kexec teardown gap: fixed in source, runtime qualification owed.**
  The 2026-09-26 helper stops the optional book-state authority after the
  reader, requires runtime cleanup, and refuses if the real `/data`
  cannot become read-only. Root remount remains best-effort; its other writers
  need separate quiescence work. Host tests cover refusal and partial
  restoration. Older target helpers still require the manual authority
  stop; rollback runs the target's helper (`doc/update-path.md`).
- **Ineffective negative assertions: fixed in source.** The negated greps
  in `pinenote/tools/update-path/test-static.sh` did not cause `set -e` to
  exit on a forbidden match. Checked rejection assertions and positive
  controls replace them; the obsolete blanket `/data` ban is replaced by
  the mount-inspection/reversible-remount boundary.
- **An unregistered driver finding.** hrdl's `GLOBAL_REFRESH` does not
  flush pending deferred-io damage. This batch corrected the misleading
  `device.lua` comments; it still wants a `quirk:` test and a note in
  `doc/driver-findings-report.md`.
- **`KEY_SLEEP` from the pen receiver.** Outside the notebook, a `ws8100`
  long press on its third input sends `KEY_SLEEP`. `device.lua`'s shared
  `event_map` turns that into KOReader's Suspend without checking which
  device sent it, so a pen-barrel long press can put the reader to sleep.
  The notebook swallows it while open.
- **Three direct pushes.** `9396e98`, `25cea98` and `6b9c101` reached
  `github/main` without a PR; note them in the next PR's description.

## Open questions

- Raise the touch controller's contact limit for five-finger gestures
  (#82), or keep two?
- Does the hard-ended pen report `BTN_TOOL_RUBBER` when its back end
  touches?
- The brush and eraser widths and the palm grace period are guesses to
  tune on glass.
- Where notebooks show up: only in the menu, or later as files in the
  library.
- Whether a session with a cold-boot waiver counts toward the
  three-session review of the cable-free policy.
