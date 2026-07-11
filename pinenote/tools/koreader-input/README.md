# koreader-input — host tests for KOReader's input routing (offline ladder)

Two proof sets, entirely on the workstation — no device, no KOReader UI:

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
   ever emitted); skipped cleanly elsewhere.

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

## What this does and does not cover

Covers the slot-routing logic and gesture classification for the mixed
pen+touch protocol, the `findInputDevices` name→slot mapping, the
injector's key-event chain (159/158 → RPgFwd/RPgBack), and — where the
host permits — the injector daemon's uinput create/destroy path.  Does
**not** cover: evdev delivery (`ffi/input_evdev` is stubbed), the
adjust hooks themselves, `device.lua` `init()` glue (the
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
