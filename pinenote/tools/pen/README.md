# Pen tools — the D8 latency instruments

Two on-device tools plus their host harness, built for the D8 rung of
the direct-mode ladder (`doc/glass-plan-2026-08.md`): does FAST mode
reach pen-class nib-to-ink latency?  D8 answered it on 2026-08-26 on the
study image: ~20 ms to first ink in FAST, ~40–60 ms in NORMAL through
GL16 (results at the end). The direct driver has been the product since
generation 7 (2026-09-03). On 2026-09-26 the same tools on generation 21
showed a region hinted DU in NORMAL to be pen-class by blinded feel, and
the operator could not tell whole-screen DU from FAST (`doc/status.md`
2026-09-26).

- `scribble.lua` — the measurement floor: Wacom stylus events straight
  from evdev, black ink straight into `/dev/fb0` with `write()`, one
  fsync per event batch. No toolkit, no app. `write()` queues damage at
  once, bypassing the 250 ms deferred-io timer, so this is not the path
  a KOReader canvas would take (draw into the mmap, publish every input
  batch); ink drawn by KOReader is unmeasured. Its log carries the
  software half of every batch (`lag_ms` = last event timestamp →
  fsync return), so the camera's glass number can be decomposed.
- `ebc-mode.lua` — the knob: query/set NORMAL|FAST via
  `DRM_IOCTL_ROCKCHIP_EBC_MODE` (0xC0086444) and set the default pixel
  hint via `DRM_IOCTL_ROCKCHIP_EBC_RECT_HINTS` (0x40106443). Resolves
  the card by `DRIVER=rockchip-ebc`, never by index.
- `test-scribble.lua` — `make pen-check`: everything above extracted
  verbatim and pinned, with the ioctl generator anchored to the
  hardware-proven GLOBAL_REFRESH constant `0xC0016440`.

## The D8 session recipe

Attended; the operator holds the pen and a phone filming at 240 fps
(4.2 ms/frame). D8 ran on the study image, which booted at the driver
default hint 160 (Y4 + REDRAW → GL16); the device now runs the product
image, which boots NORMAL at hint 32 (Y4 → GL16), and the 2026-09-26
session ran these tools there unchanged. Both tools staged (e.g. scp to
`/root/`), KOReader stopped.

```sh
herd stop reader-session            # ~0.5 s, INT-first
KO=$(ls -d /gnu/store/*-koreader-bin-*/lib/koreader | head -1)
LUA=$KO/luajit

# sanity: nib events arrive at all
$LUA scribble.lua --quiet &  sleep 5; kill %1   # or just scribble and look

# baseline: NORMAL mode, the product's reading hint (32 → GL16)
$LUA ebc-mode.lua --query
$LUA scribble.lua                    # scribble + film ~30 s

# pen-canvas route (felt 2026-09-26, not filmed): NORMAL, pen hint (Y1 → DU)
$LUA ebc-mode.lua --normal --hint 0
$LUA scribble.lua                    # scribble + film ~30 s

# D8's headline: FAST mode, pen hints (Y1+THRESHOLD, no REDRAW)
$LUA ebc-mode.lua --fast --hint 0
$LUA scribble.lua                    # scribble + film ~30 s

# restore the product state and hand back
$LUA ebc-mode.lua --normal --hint 32
herd start reader-session
```

Free telemetry while there: the driver's own per-frame `advance()`
instrumentation (D9) reports in dmesg during the strokes.

Orientation flags (`--swap-xy --flip-x --flip-y`) fix a mirrored or
rotated trail live; latency does not care, so a wrong first guess costs
nothing. If the ink trails look right but laggy, believe the camera,
not your eye — count frames from nib-at-corner to ink-at-corner across
a dozen sharp direction reversals and take the median.

Analysis, before D8: FAST+DU-class drive is ~3 active phases against an
~11.7 ms frame, so the driver-side floor is in the tens of milliseconds;
`lag_ms` gives the software contribution on top, and the camera gives
the truth. Embrace territory per the plan is a headline number in the
tens of milliseconds.

Results. D8 (2026-08-26, study image, 240 fps;
`doc/artifacts/pinenote-d8-pen-latency-20260826/`): FAST ~20 ms from
nib to first ink (17–25 ms, two strikes), then ~100 ms more to fully
dark; NORMAL through GL16 ~40–60 ms to first ink, then ~250–290 ms
more to fully dark; `lag_ms` 0.3 ms median. The operator called FAST
"absolutely insane" and said NORMAL "feels pretty much the same to
write on". 2026-09-26 (generation 21, no camera;
`doc/artifacts/pinenote-du-canvas-feel-20260926/`): a DU-hinted region
in NORMAL was called much faster than GL16 beside it in 2 of 2 blinded
arms, and a blinded FAST against whole-screen-DU pair could not be told
apart. There is no millisecond figure for DU in NORMAL. The same
session measured the frame at ~11.9 ms and the digitizer's report rate
at 2.77 ms median, about 360 Hz, the same pen-down and hovering. Still
unmeasured: ink drawn by KOReader, the gray settle after pen-up, and DC
balance and ghosting of FAST or DU ink over long sessions.
