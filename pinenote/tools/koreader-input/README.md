# koreader-input — host tests for KOReader's input routing (offline ladder)

`touch_target_epub.py` is a separate Pillow-based calibration aid for manual
finger/pen investigation.  It generates and self-checks a single-page EPUB3
fixed at the corrected 1404x1872 portrait coordinate space, with numbered
crosshair targets, quarter-grid lines, and edge rulers.  The page is a
full-resolution grayscale PNG in the same fixed-layout XHTML packaging used by
the hardware-proven optics card (rather than inline SVG).  Its default output
is `/tmp/wilkbook/pinenote-touch-targets.epub`; pass another path to override
it, or use `--check PATH` to validate an existing artifact.

```sh
python3 pinenote/tools/koreader-input/touch_target_epub.py
```

The host suite runs entirely on the workstation — no device or KOReader UI:

1. **`test-mixedrouter.lua`** — the pen-hover tap-capture bug in
   upstream KOReader's input stack and the repo's fix
   (`pinenote/packages/koreader-device/frontend/device/pinenote/mixedrouter.lua`).
2. **`test-optics-inject.lua`** — the optics harness's page-turn
   injector chain (`pinenote/tools/optics/PLAN.md` task 1): the REPO
   `device.lua`'s `wilkbook-optics` device-name whitelist (real
   `findInputDevices` against a fake sysfs tree) and the exact event
   stream `optics-inject.lua` emits (`KEY 159`/`KEY 158` → press + SYN +
   release + SYN) mapping to `RPgFwd`/`RPgBack` through the bundle's
   verbatim `Input:handleKeyBoardEv` with `device.lua`'s `event_map` —
   including amid pen hover + finger taps with the mixedrouter
   installed.  Where the host grants `/dev/uinput` write access,
   `run-tests.sh` additionally runs the **daemon body live**: it must
   create a uinput device named `wilkbook-optics` with exactly keybits
   139/158/159 + EV_SYN|EV_KEY and destroy it on `QUIT` (no key event is
   ever emitted). The repo evdev backend opens that live node as required;
   destroying it must return a fatal error so reader-session can respawn
   KOReader and enumerate a replacement. These checks skip cleanly where
   host uinput access is unavailable.
3. **`test-touch-normalization.lua`** — cyttsp5's source-gated MT X/Y
   mirroring using the measured axis ranges and five static TOP-mode
   calibration points, including no-op behavior for pen, foreign, legacy,
   and unavailable-range events.
4. **`test-idlewasher-logic.lua`** — the idle-washer policy core and plugin
   integration against KOReader's hook container.
5. **`test-required-device.lua`** — required evdev-node loss returns the
   fatal sentinel; `run-tests.sh` executes it through a deterministic FIFO.
6. **`test-continuous-gesture-cost.lua`** — what a continuous two-finger
   gesture actually costs on this panel (issue #26): one terminal
   `pinch`/`spread` per interaction whatever the frame count, the
   mid-gesture variants having no consumer anywhere in the tree,
   upstream's own `gesToFontSize` arithmetic, the 900 ms ceiling above
   which a pinch silently does nothing, and the reachability of the
   two-finger family on this input stack.
7. **`test-slotguard.lua`** — the 2026-09-02 glass crash
   (`gesturedetector.lua:325`, nil `initial_tev.x` in the two-finger
   path), reproduced deterministically from the verbatim upstream files:
   a pinch's re-render calls `Input:resetState()` under a finger still on
   the glass, whose next delta-only frame becomes a ghost contact that
   the next finger pairs with.  Pinned as `quirk:` cases that MUST throw
   without the repo's `slotguard.lua`, proven fixed with it, with
   neutrality controls (`doc/upstream-register.md` item 21).
8. **`replay-evdev.lua`** — not a test: an instrument that feeds a raw
   `cat /dev/input/eventN` capture from the device through the same
   verbatim stack (device-layer frame rewrite applied), reporting every
   warning with its preceding frames and catching a throw mid-frame.
   `luajit replay-evdev.lua KOREADER_DIR MIXEDROUTER touch=CAPTURE`
   (host luajit needs the Lua 5.2 `table.pack` shim it carries).

**The bug** (hardware-observed 2026-07-05, mechanism in
`mixedrouter.lua`'s header): upstream `Input` keeps ONE global
`cur_slot` for all input devices.  With `wacom_protocol`,
`BTN_TOOL_PEN:1` parks it on the pen slot (4); the kernel deduplicates
`ABS_MT_SLOT`, so a single-finger touch session (always slot 0) never
moves it back.  While the pen hovers, a finger tap's MT events land in
the pen slot, interleaved pen hover `ABS_X/ABS_Y` rewrite the contact
mid-gesture, the >= `PAN_THRESHOLD` (scaleByDPI(35) = 50 px at 227 DPI)
displacement flips the tap into a pan, and a <900 ms lift emits a swipe:
every TOC tap "paged forward".

## How it works

`run-tests.sh` resolves the **native x86_64** `koreader-bin` bundle
(`guix build -L <repo> koreader-bin`, cached; override with
`KOREADER_BUNDLE=` or argv) and runs `test-mixedrouter.lua` under the
bundle's own `luajit`.  The harness:

- requires the bundle's **verbatim** `frontend/device/input.lua` and
  `frontend/device/gesturedetector.lua` (plus their real `ui/time`,
  `ui/geometry`, `ui/event`, `device/key`, `optmath` and ffi cdef
  dependencies), stubbing only I/O-flavored modules via
  `package.preload` (`logger`, `dbg`, `datastorage`, `gettext`, `util`,
  `ffi/framebuffer`, `G_reader_settings`) and a 1872x1404 @ 227 DPI
  screen;
- builds the `Input` instance exactly like
  `device/pinenote/device.lua`: `Input:new{ wacom_protocol = true,
  input = <stub backend> }`, then `handleTouchEv = handleMixedTouchEv`,
  then (in "mixedrouter" mode) `MixedRouter.install(input, pen, touch)`;
- feeds synthetic evdev frames through the same dispatch
  `Input:waitEvent` uses (EV_KEY -> `handleKeyBoardEv`, EV_ABS/EV_SYN ->
  `handleTouchEv`), with `src` device tags and a fake clock, collecting
  the returned Gesture events.  Streams model the *post-adjust-hook*
  reality: pen coords in screen space, the touchscreen's legacy ST
  aliases already neutralized (device.lua does both on hardware), and
  kernel-side dedup (no `ABS_MT_SLOT`, no repeated ABS values) honored.

Tap deferral: upstream `Input.disable_double_tap` defaults to `true`
(the harness also passes it explicitly), so taps are emitted
synchronously at contact lift; hold/double-tap timers are registered but
never pumped, which keeps every scenario timer-free.

Each scenario runs twice — without the router (expects upstream's buggy
behavior) and with it (expects the fix):

| Scenario | no-router expectation | mixedrouter expectation |
| --- | --- | --- |
| `quirk:pen-hover-tap-capture` | NO tap; the finger tap re-emerges as pan(s) + swipe at pen-bearing coords | exactly one tap at (500,700) |
| `pen-contact-after-interleave` | pen tap works (upstream baseline) | pen tap AND the finger tap both survive |
| `pen-hover-finger-slot3` | tap at (500,700); pen and finger keep separate slots | identical stream with/without router |
| `quirk:pen-slot-collision` | NO tap; pan at pen coords + swipe | **identical** — the router does not address this |
| `quirk:pen-slot-collision-tip` | neither the pen's nor the finger's tap survives | **identical** — as above |
| `two-finger-spread` | spread (slots 0+1) | identical stream with/without router |
| `quirk:buddy-slots-0-1-only` | the same two fingers in slots 0+2: no spread, two independent swipes | **identical** — not a routing problem |
| `baseline-tap` | tap at finger coords | identical stream with/without router |

`run-tests.sh` also checks output determinism across two runs.

## The pen-slot collision (`quirk:pen-slot-collision`)

Upstream keeps **one** `ev_slots` table for every input device, and parks
the pen at `main_finger_slot + 4` = slot **4**.  The touchscreen's slot
numbers come from the controller, so if it ever hands a contact slot 4,
the pen and that finger are the same table entry.

This was long recorded as needing five simultaneous fingers.  It does
not.  cyttsp5 advertises **32** MT slots (`ABS_MT_SLOT` max = 31) and does
not allocate them densely: a 120 s live capture whose peak was **three**
simultaneous contacts used slots **{0, 1, 2, 5}**
(`doc/artifacts/pinenote-input-clocks-20260824/`).  A lone finger can
land on slot 4.

The three scenarios above are a one-variable A/B — same coordinates, same
timing, same frames, only the touchscreen slot number differs:

```
pen-hover-finger-slot3   touch@(500,700); tap@(500,700)
  after contact  pen_slot(4): id=nil x=1202 y=301 tool=1   touch slot 3: id=77 x=500 y=700 tool=nil

quirk:pen-slot-collision touch@(500,700); pan@(1206,303) dir=east dist=810.0;
                         pan@(1208,304) dir=east dist=811.2; swipe@(500,700) dir=east dist=811.2
  after contact  pen_slot(4): id=77 x=500  y=700 tool=1    touch slot 4: id=77 x=500  y=700 tool=1
  after hover    pen_slot(4): id=77 x=1208 y=304 tool=1    touch slot 4: id=77 x=1208 y=304 tool=1
```

The finger's tracking id and coordinates land in the pen's slot, on an
entry still marked `tool=TOOL_TYPE_PEN`; the next hover frame is therefore
honored by `handleMixedTouchEv`'s `ABS_X`/`ABS_Y` branch and rewrites the
live contact to the pen's position.  The resulting gesture stream is
**byte-identical** to `quirk:pen-hover-tap-capture`'s buggy no-router
stream — same mechanism, reached by a different route.

**The router is neutral here, by design.** It disambiguates by *source*;
when both sources agree on the slot *number* there is nothing left to
disambiguate.  A fix has to move the pen out of the panel's slot space,
which is a different job from restoring the routing upstream already
assumes.  So all three scenarios assert **today's** behavior, and
`compare_streams` pins the router's neutrality: a fix in either place
turns them red on purpose.  The case for reporting rather than patching
is `doc/upstream-register.md` item 11.

### The same assumption costs two-finger gestures too

`quirk:buddy-slots-0-1-only` is the second consequence of upstream
treating a slot *number* as an identity.  `GestureDetector:newContact`
pairs a contact with a "buddy" only when the two slots are exactly
`main_finger_slot` and `main_finger_slot + 1`; any other slot has no
buddy and is classified alone.  So the identical two-finger stream in
slots `{0,2}` yields **two independent swipes** rather than one spread —
on a reader, two page turns instead of a font-size change.

Pinch working in the field is therefore not evidence that slot numbers
are handled generally: it works because the controller usually hands the
first two contacts slots 0 and 1.  The capture that used `{0,1,2,5}`
shows it does not always.  How often the panel actually breaks the pair
is a *hardware* question this suite cannot answer.

The fake-sysfs portion additionally proves that only the exact
`wilkbook-orientation` virtual-device name becomes the PineNote G-sensor slot.
Its Linux-standard `EV_MSC/MSC_RAW` values 0--3 translate to KOReader's private
`MSC_GYRO` 71 only from that source; invalid and foreign-source values are inert.
The PineNote adapter defers a gyro event while a finger or pen contact is down,
then appends only the latest pending rotation after the lift gesture; pen hover
alone does not block rotation.
Re-enabling the accelerometer handler replays the bridge's current `/run`
state, covering rotations that occurred while automatic events were ignored.
The bridge classifier itself is tested separately with `make orientation-check`.

## What a pinch costs (issue #26, measured 2026-08-24)

`test-continuous-gesture-cost.lua` exists because issue #26 assumed a
pinch "spans several size steps, and each step presumably re-renders and
re-publishes the whole page" — seconds of panel activity at ~596 ms per
GL16/GC16 full update.  Measured against the verbatim upstream stack,
**that premise is false, and the deferral the issue asks for already
exists.**

`pinch` and `spread` are *terminal* gestures.  `Contact:panState` only
builds them on the contact-lift branch (`tev.id == -1`), so a pinch
spanning 1, 12 or 40 evdev frames emits exactly **one** of them, with the
same `distance` every time — the field is the summed travel of both
contacts, so the sample rate cannot change the outcome either:

```
pinch-emits-once: exactly one pinch per interaction across 1..40
  intermediate frames, distance=760 px every time;
  unconsumed mid-gesture pans (steps:n) 1:1 2:2 6:6 12:11 20:18 40:35
one-gesture-one-font-step: one pinch -> one delta of 4 point(s) (cap 5)
  for every frame count (steps:delta 1:4 2:4 6:4 12:4 20:4 40:4)
```

The detector *does* emit an `inward_pan`/`outward_pan` per frame while
the fingers move — the "unconsumed mid-gesture pans" column above.  A
whole-tree scan of the bundle's `frontend/` and `plugins/` plus this
repo's `koreader-device` overlay (482 `.lua` files) finds **no consumer
for any of them**, nor for `two_finger_pan`, `two_finger_hold_pan` or
`two_finger_pan_release`, outside the detector that emits them.  Every
two-finger consumer in KOReader binds a terminal gesture.  So the
per-frame events cost Lua cycles and zero panel passes, and this suite
goes red the day upstream adds a subscriber.

(The *value* of the delta — 4 above — is a function of the screen
dimension `gesToFontSize` divides by, and this harness uses
test-mixedrouter's 1872x1404 convention.  What the case pins is that the
delta is **the same for every frame count** and within the steps table's
cap, not that a field pinch is worth four points.)

### The failure mode is the opposite one: slow pinches do nothing

`Contact:isSwipe()` gates the whole terminal-gesture branch on the
interaction finishing inside `ges_swipe_interval`
(`SWIPE_INTERVAL_MS = 900`).  Past that, the lift is a
`two_finger_pan_release` — which, per the scan above, nothing consumes:

```
quirk:slow-pinch-is-a-silent-no-op: SWIPE_INTERVAL_MS=900; the same pinch
  geometry over 1040 ms gives [inward_pan=11 touch=2
  two_finger_pan_release=1] (no pinch, and two_finger_pan_release has no
  consumer), over 260 ms gives [inward_pan=11 pinch=1 touch=2]
```

So the more carefully and slowly you pinch, the more likely it is that
nothing at all happens, with no feedback saying why.  On a ~600 ms panel
that is exactly the wrong incentive — deliberate input is what the
display encourages.  Pinned, not fixed: `doc/upstream-register.md`
item 12.

### Reachability of the two-finger family

All five terminal two-finger gestures classify correctly on this stack
from slots `{0,1}`: `pinch`, `spread`, `rotate`, `two_finger_tap`,
`two_finger_swipe`.  In the shipped reader defaults `pinch_gesture` and
`spread_gesture` are bound to `decrease_font`/`increase_font` at value 0,
which is the Dispatcher's `incrementalnumber` branch that forwards the
*gesture object* — so the one delta really does come from the one
gesture.  `rotate_cw`/`rotate_ccw` ship unbound.

Every one of them inherits the slot constraint above.  The pinch half is
pinned here (`quirk:buddy-slots-0-1-only:pinch`): the same pinch in slots
`{0,2}` produces no two-finger gesture at all — it becomes 22 pans and
2 swipes, and pans and swipes *are* consumed, so a mis-slotted pinch can
turn pages instead of changing the font size.

## What this does and does not cover

Covers the slot-routing logic and gesture classification for the mixed
pen+touch protocol, the continuous-gesture cost measurement above, the
`findInputDevices` name→slot mapping, the
injector's key-event chain (159/158 → RPgFwd/RPgBack), and — where the
host permits — the injector daemon's uinput create/destroy path and required-fd
loss, plus the pure source-gated touch adjustment seam (MT mirroring and
legacy alias neutralization). Does **not** cover: ordinary evdev event delivery
(`ffi/input_evdev` is stubbed in gesture scenarios), registration of the
adjust hook or `device.lua` `init()` glue (such as the
`input:open(devs.optics_inject, ...)` line), the live
create-before-KOReader-enumerates ordering, timer-driven gestures
(hold, double-tap), or real touch panel timing/noise — those stay on
the QEMU-visual and hardware rungs.

It does **not** cover how many `[pn-refresh]` traces the *downstream*
repaint of a font-size change costs.  That needs UIManager + ReaderUI,
which this harness does not run; the source-derived count is in
`doc/refresh-policy.md` and labelled there as source-derived.  Nothing in
this file has been seen on a panel.

It also cannot tell you **which slots the controller actually assigns**.
The slot-collision and buddy-slot scenarios prove what happens *given* a
slot number; how often cyttsp5 hands out a colliding or non-adjacent one
is a hardware question. The one capture we have
(`doc/artifacts/pinenote-input-clocks-20260824/`) says the answer is not
"never", which is what makes the pins worth having; it does not say how
often. `pinenote/scripts/preflight/pm-ground-truth.sh` now records the
advertised `ABS_MT_SLOT` range on every run, but not the assignments.

```sh
# from the repo root:
make koreader-input-check
# or here:
./run-tests.sh [/gnu/store/...-koreader-bin-...]
```
