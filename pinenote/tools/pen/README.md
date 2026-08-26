# Pen tools — the D8 latency instruments

Two on-device tools plus their host harness, built for the D8 rung of
the direct-mode ladder (`doc/glass-plan-2026-08.md`): does FAST mode
reach pen-class nib-to-ink latency?  That number is the entire reason
the direct-mode experiment exists, and after the 2026-08-26 operator
verdict that direct-mode page turns still read worse than the shipping
driver, it is the pivot of embrace-or-reject: without a pen-class
number on this side of the scale, there is nothing to weigh against the
reading regression.

- `scribble.lua` — the measurement floor: Wacom stylus events straight
  from evdev, black ink straight into `/dev/fb0`, one fsync per event
  batch (the same publish-on-call seam a page turn uses). No toolkit,
  no app. Its log carries the software half of every batch
  (`lag_ms` = last event timestamp → fsync return), so the camera's
  glass number can be decomposed.
- `ebc-mode.lua` — the knob: query/set NORMAL|FAST via
  `DRM_IOCTL_ROCKCHIP_EBC_MODE` (0xC0086444) and set the default pixel
  hint via `DRM_IOCTL_ROCKCHIP_EBC_RECT_HINTS` (0x40106443). Resolves
  the card by `DRIVER=rockchip-ebc`, never by index.
- `test-scribble.lua` — `make pen-check`: everything above extracted
  verbatim and pinned, with the ioctl generator anchored to the
  hardware-proven GLOBAL_REFRESH constant `0xC0016440`.

## The D8 session recipe

Attended; the operator holds the pen and a phone filming at 240 fps
(4.2 ms/frame). The device runs the study image; both tools staged
(e.g. scp to `/root/`), KOReader stopped.

```sh
herd stop reader-session            # ~0.5 s, INT-first
KO=$(ls -d /gnu/store/*-koreader-bin-*/lib/koreader | head -1)
LUA=$KO/luajit

# sanity: nib events arrive at all
$LUA scribble.lua --quiet &  sleep 5; kill %1   # or just scribble and look

# baseline: NORMAL mode, driver-default hints
$LUA ebc-mode.lua --query
$LUA scribble.lua                    # scribble + film ~30 s

# the headline: FAST mode, pen hints (Y1+THRESHOLD, no REDRAW)
$LUA ebc-mode.lua --fast --hint 0
$LUA scribble.lua                    # scribble + film ~30 s

# restore and hand back
$LUA ebc-mode.lua --normal --hint 160
herd start reader-session
```

Free telemetry while there: the driver's own per-frame `advance()`
instrumentation (D9) reports in dmesg during the strokes.

Orientation flags (`--swap-xy --flip-x --flip-y`) fix a mirrored or
rotated trail live; latency does not care, so a wrong first guess costs
nothing. If the ink trails look right but laggy, believe the camera,
not your eye — count frames from nib-at-corner to ink-at-corner across
a dozen sharp direction reversals and take the median.

Analysis: FAST+DU-class drive is ~3 active phases against an ~11.7 ms
frame, so the driver-side floor is in the tens of milliseconds;
`lag_ms` gives the software contribution on top, and the camera gives
the truth. Embrace territory per the plan is a headline number in the
tens of milliseconds.
