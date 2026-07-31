# ebc-damage-probe — controlled deferred-io / EBC damage-scheduling probes

Device-side LuaJIT probes that write chosen patterns straight into the mmapped
framebuffer and count EBC interrupts (one DSP_END per hardware frame, so an
interrupt delta *is* a frame count). No KOReader, no rotation, no input — the
only variables are the shape, order and timing of the damage.

They exist because a reported "portrait page turns refresh twice" observation
could not be explained by reading code, and every hypothesis formed from the
KOReader-level trace turned out to be wrong. These isolate the driver and
deferred-io behaviour from the reader entirely.

## Running

Requires the panel to be idle and owned by nobody else:

```sh
herd stop reader-session
echo 0 > /sys/class/vtconsole/vtcon1/bind      # fbcon's cursor is a damage source
LUAJIT=/run/current-system/profile/lib/koreader/luajit   # or the koreader-bin store path
$LUAJIT damage-scheduling.lua
$LUAJIT repaint-duration.lua
$LUAJIT write-cost.lua
# restore
echo 1 > /sys/class/vtconsole/vtcon1/bind
herd start reader-session
```

They leave the panel dirty; restarting the reader repaints it. Nothing else is
touched — no power, suspend, firmware, partition or boot state.

`diff_mode=1` masks pixels whose prev == next, so every pattern must genuinely
change the pixels it touches or the driver correctly does nothing. (That is
itself visible in `damage-scheduling.lua`: two full-screen writes 10 ms apart
coalesce into one damage whose final content equals `prev`, and cost **zero**
frames.)

## What they established (2026-07-30)

`damage-scheduling.lua` — each deferred-io flush costs one whole refresh pass,
and passes do **not** pipeline:

| pattern | frames |
| --- | --- |
| 1 full-screen write | 38 (1 pass) |
| 2 full-screen writes, 250 ms apart | 76 (2 passes) |
| 2 **disjoint** half writes, 250 ms apart | 76 (2 passes) |
| 2 full-screen writes, 10 ms apart | 0 (coalesced, then diff-masked) |
| 3 full-screen writes, 250 ms apart | 76 (saturates; redundant areas dropped) |

Disjoint damages cost exactly as much as overlapping ones, which refuted the
then-current "overlapping areas get serialised" explanation.

`repaint-duration.lua` — with **no transpose at all**, identical contiguous
access order, and duration as the only variable:

| write spread over | frames | passes |
| --- | --- | --- |
| 0 ms | 38 | 1.0 |
| 40 ms | 76 | 2.0 |
| 80 / 150 / 250 / 400 ms | 76 | 2.0 |

So rotation is not the defect; it is merely a way of being slow. What matters
is whether a repaint finishes inside the deferred-io window
(`drm_fbdev_shmem.c:184`, `fbdefio.delay = HZ / 20` = 50 ms).

`write-cost.lua` — full-screen write cost by access order: contiguous ~29 ms,
column-order ~255 ms. **Caveat:** these are LuaJIT per-element loops and are
loop-bound, not memory-bound, so the transpose figures do not represent
KOReader's C blitter. Only the `ffi.fill` (real C memset) numbers are
trustworthy as absolute costs.

`repaint-window.lua` — measures KOReader's page-dirtying window **as
deferred-io sees it**, by sampling `min_flt` on the reader's own process.
Deferred-io write-protects the framebuffer pages after each flush, so every
first touch of a page is a minor fault; the fault burst's wall-clock span is
exactly the window that must fit inside 50 ms. Needs the uinput injector
(`pinenote/tools/optics/optics-inject.lua`) running so page turns can be
driven without a human, and takes the reader pid as `argv[1]`.

**Sampling framebuffer *values* cannot measure this** — most of a text page is
white-on-white, so it is written but unchanged. An earlier attempt that way
reported an 11-20 ms "write window" from 57 of 936 sample points, which was
measuring content change, not writing.

Measured 2026-07-30 on a full-screen portrait repaint: **~2570 faults over
37-50 ms** (the framebuffer is 2567 pages, so KOReader rewrites *all* of it),
against the 50 ms period. Note the faults occur even on repaints that produce
zero EBC frames because `diff_mode` masks the unchanged result — which is the
direct explanation for the cost being invariant to page content.

See `doc/refresh-policy.md`, "Portrait page turns cost two refresh passes".
