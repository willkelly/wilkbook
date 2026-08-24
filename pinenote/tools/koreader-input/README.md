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
| `two-finger-spread` | spread | identical stream with/without router |
| `baseline-tap` | tap at finger coords | identical stream with/without router |

`run-tests.sh` also checks output determinism across two runs.

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

## What this does and does not cover

Covers the slot-routing logic and gesture classification for the mixed
pen+touch protocol, the `findInputDevices` name→slot mapping, the
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

```sh
# from the repo root:
make koreader-input-check
# or here:
./run-tests.sh [/gnu/store/...-koreader-bin-...]
```
