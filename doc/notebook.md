# The notebook: pen and paper on the PineNote

**Status (2026-09-26): proof of concept built and host-tested; nothing has
run on glass.**
- Design agreed with the operator the same day.
- It passes every host suite, including a replay of the operator's real
  pen captures from `doc/status.md` 2026-09-26.
- Its first glass run is planned below as generation 22.

This is ROADMAP §5's first stage ("continuous note-taking") and the
capture and storage half of stroke capture #20.

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
  - A swipe with several fingers undoes (leftward) or redoes (rightward).
  - A long finger press summons a floating panel. It stays up until
    Close is tapped or it is flicked away, and it can be dragged by its
    title.
- **The pen never opens the panel or turns a page.** While the pen is in
  range, touch is ignored: palm rejection, which the operator accepted.

**The panel holds:**
- the brush:
  - pressure brushes: Ball, Brush, Pencil;
  - fixed widths: Fine, Marker, Hilite;
- size S, M or L;
- the mode:
  - Write: the tip inks;
  - Erase: the tip rubs out an area;
  - Erase strokes: the tip removes whole strokes;
- the rubber end, `Rubber: area` or `Rubber: strokes`;
- Undo and Redo;
- page ◀ ▶;
- New, Open…, Exit (close the notebook) and Close (the panel).

**The undo swipe needs three fingers, not five.** The operator asked for
five. The cyttsp5 touch controller, as configured, has never reported
more than 3 simultaneous contacts
(`doc/artifacts/pinenote-input-clocks-20260824/RESULT.md`). Raising that
is a persistent flash write to the touch controller, which is the
operator's call. So the swipe fires on at least `multi_min_fingers`
(default 3, `nb_config.lua`). A ten-second touch capture on glass
settles it.

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
- A page turn charges the idle washer's debt through its new public
  `chargePageTurn()`, as a reading turn does.

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
- `notebook-realui/` runs a real offscreen KOReader with the plugin and
  takes screenshots.

## Known limits

**Hardware and input:**
- The multi-finger count above.
- A touch `SYN_DROPPED` can leave a phantom contact until its slot is
  reused. That needs a stall long enough to fill the touch buffer.
- evdev drains one node at a time. So a touch lift that drains before a
  same-batch pen proximity-in can still fire.

**Durability:**
- A retried fsync on a new fd can report success after an `EIO`. That is
  why an error stops inking for the rest of the session.

**Not measured:**
- Nothing is timed on the Cortex-A55. Host timings are a Ryzen 9950X3D:
  about 1-3 µs per inked sample in the controller, 0.2 µs per ballpoint
  segment, and 4-9 µs per large highlighter segment.
- The mmap-plus-fsync publish cost per report is unmeasured. So is
  KOReader's own event-to-publish time. The per-pen-up log line
  (`[notebook]`) records both.

## The generation-22 session

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

## Housekeeping found while planning (not the notebook)

These are tracked here until each lands somewhere permanent.

- **Kexec teardown gap.** CLAUDE.md's kexec lesson now says so. The
  teardown stops only `reader-session` and only logs a failed read-only
  remount of `/data`, after Wi-Fi is off. The fix is to stop the
  book-state authority and refuse the kexec when the real `/data` will
  not go read-only. It changes the shared update path, so it takes a
  review.
- **A test that cannot fail.** The 14 negated pipelines in
  `pinenote/tools/update-path/test-static.sh` pass whatever they find,
  because `set -e` ignores a pipeline that starts with `!`. Line 50 is
  already violated.
- **An unregistered driver finding.** hrdl's `GLOBAL_REFRESH` does not
  flush pending deferred-io damage, and the comments in `device.lua`
  assume it does. It wants a `quirk:` test and a note in
  `doc/driver-findings-report.md`.
- **`KEY_SLEEP` from the pen receiver.** Outside the notebook, a `ws8100`
  long press on its third input sends `KEY_SLEEP`. `device.lua`'s shared
  `event_map` turns that into KOReader's Suspend without checking which
  device sent it, so a pen-barrel long press can put the reader to sleep.
  The notebook swallows it while open.
- **Three direct pushes.** `9396e98`, `25cea98` and `6b9c101` reached
  `github/main` without a PR; note them in the next PR's description.

## Open questions

- Raise the touch controller's contact limit for five-finger undo, or
  keep three?
- Does the hard-ended pen report `BTN_TOOL_RUBBER` when its back end
  touches?
- The brush and eraser widths and the palm grace period are guesses to
  tune on glass.
- Where notebooks show up: only in the menu, or later as files in the
  library.
- Whether a session with a cold-boot waiver counts toward the
  three-session review of the cable-free policy.
