# ebc-logic — host tests for the EBC driver (offline ladder, rungs 2 and 7a)

Compiles the **verbatim** `drivers/gpu/drm/rockchip/rockchip_ebc.c` (and its
LUT dependency `drm_epd_helper.c`) out of
`pinenote/patches/linux-pinenote-7.0-forward-port.patch` — extracted at build
time with rung 1's `extract-from-patch.py`, so the tests always exercise
exactly the code the kernel ships — against a kernel-API shim
(`shim/kernel-shim.h`).  Three binaries:

- **`ebc-logic-test`** (rung 2): unit tests for the driver's pure
  arithmetic — blitters, damage scheduling, threshold/dither paths.
- **`ebc-refresh-test`** (rung 7a, scoped in `doc/ebc-harness-spike.md`):
  *executes* the hardware-facing half — probe, the global/partial refresh
  state machine, LUT upload, DMA windowing, the IRQ/completion contract —
  against a behavioral device model (`shim/fake-ebc.h`), under ASan.
- **`ebc-replay`** (the rung-7a phase-B workbench, results in
  `doc/refresh-policy.md`): replays KOReader `[pn-refresh]` intent traces
  through the same machine under candidate refresh policies and reports
  washes, the black-flash census, settle latency and scrub staleness.

This is the code most likely to break silently on every forward-port; these
tests make that a red `make check` instead of a wasted panel session.

```sh
# from the repo root:
make ebc-logic-check [WBF=/path/to/ebc.wbf]
# or here:
guix shell gcc-toolchain python -- make check [WBF=/path/to/ebc.wbf]
```

`WBF` is optional and per-device (never committed; see the repo
firmware/waveform policy and `doc/device-runbook.md`): with it, a few
waveform-dependent tests run; without it they are skipped with a clear
message.

## How it works

Both driver files are `#include`d into a single test translation unit
(one per binary: `ebc-logic-test.c`, `ebc-refresh-test.c`), the same way
rung 1 includes `drm_epd_helper.c`.  That
makes the driver's `static` functions directly callable and its
module-parameter globals (`panel_reflection`, `bw_mode`, `bw_threshold`,
`fourtone_*`, `bw_dither_invert`, `split_area_limit`, `diff_mode`,
`default_waveform`) directly settable per test.  The shim has three layers:

- **faithful**: what the tested logic actually executes — `list_head` ops,
  `drm_rect` ops, `kref`, allocators — reimplemented per kernel semantics;
- **harness**: the hardware-facing seams the refresh harness runs through —
  regmap (a RAM register file with a device write-hook), dma-mapping (a
  32-bit bus-handle registry that validates unmap/sync), completion
  (kernel counting semantics: an unsignalled wait is a visible timeout),
  pm_runtime (refcount + suspended flag calling the driver's real runtime
  callbacks), kthread (recorded and flag-driven so the thread body runs
  synchronously), irq registration.  With no hooks installed these degrade
  to the old inert behavior, so rung 2 is unaffected;
- **inert**: everything else — stubs that return 0/NULL so the whole file
  compiles.

Buffer geometry comes from the driver's own `rockchip_ebc_ctx_alloc`
(`gray4_pitch = width/2` etc.), and the blitters are driven through an exact
replica of `rockchip_ebc_plane_atomic_update`'s coordinate adjustment
(2px alignment + x-mirror/y-flip), the scheduler through a replica of
`rockchip_ebc_partial_refresh`'s scheduling loop.  All randomized tests use a
fixed-seed xorshift32; output is byte-identical across runs (asserted by
`run-tests.sh`).

## What is validated

- **`rockchip_ebc_blit_fb_xrgb8888`** (XRGB8888 → packed Y4): compared
  whole-buffer against an independent reference on ~300 randomized damage
  rects per configuration plus hand-built corner cases (odd/even x1/x2,
  1x1, single row/column, full screen), with non-trivial fb pitch, for
  `panel_reflection` on and off and `bw_mode` 0–3.  Gray extraction is pinned
  independently: `gray = (2*R5 + 5*G5 + B5 + 7) >> 4` with the X byte
  ignored (the multiply-trick decoded by hand).  Threshold boundaries are
  walked over all 32 gray inputs with the exact values
  `pinenote/services/ebc.scm` ships (it does not override them, so the
  driver defaults apply: `bw_threshold=7`, fourtone `4/7/12`,
  `bw_dither_invert=0`); the `changed`-flag drop semantics are pinned.
- **`rockchip_ebc_blit_fb_r4`**: byte-rect copy semantics on 200 randomized
  clips with odd pitch; always reports change.
- **`try_to_split_area` / `rockchip_ebc_schedule_area`**: disjoint areas pass
  through; contained/duplicate pending areas drop; partial overlaps split
  per-axis or into quadrants with a coverage-bitmap check (union of
  scheduled rects == union of requested rects); in-flight collisions defer
  to `other_end+1` or split so only the overlap waits; `split_area_limit`
  budget (0 — the value ebc.scm ships —, 1, and 12) and the 2px minimum
  split size; multi-round randomized soak asserting list integrity
  (forward/backward traversal), coverage preservation, and the guarantee
  that new areas never begin inside a *started* area's window.
- **`convert_final_buf_to_target`**: full-screen A2 ordered dither against a
  reference (both `bw_dither_invert` values, extremes pinned) and DU4
  fourtone with all 16 gray levels over the shipped thresholds; GC16 no-op.
- **`rockchip_ebc_blit_pixels`** (Y4 rect copy used for prev/next/final):
  randomized + corner cases, including its odd-x behaviors (see Findings).
- **`rockchip_ebc_blit_direct`**: note the from/to axis order here follows
  the driver's own convention; whether that convention matches the
  waveform *file* semantics is pinned in `pinenote/tools/rastersim/`
  (it does not — `blit_direct` reads the LUT transposed; unused
  `direct_mode=1` path).
- **`rockchip_ebc_blit_direct`** (packing): the 2-bit LUT packing compared against an
  independent LUT-lookup reference on a synthetic random LUT, with
  `diff_mode` on and off.
- **With `WBF=`** (device's own waveform, mode-version 0x19): the LUT loads
  exactly like `rockchip_ebc_drm_init` does (`DRM_EPD_LUT_4BIT_PACKED`, 256
  max phases, 25 °C), and — the assumption the whole partial-refresh path
  rests on — phase number 0xff *and* the last real phase are neutral
  (all-zero LUT data) for **all nine** waveforms.

## The refresh harness (`ebc-refresh-test`, rung 7a)

`shim/fake-ebc.h` implements the EBC block's behavior as enumerated in
`doc/ebc-harness-spike.md` §2: config registers latch on `CONFIG_DONE`; a
`DSP_START` write with `DSP_FRM_START` plays `DSP_FRM_TOTAL+1` LUT phases
(global mode) or one three-window frame with per-pixel phase indices from
`WIN_MST2`; per pixel the 2-bit drive code comes from the LUT **as the
driver uploaded it into the LUT registers** (word `[phase*16+from]`, bit
pair `2*to` — the axis convention pinned by rung 1/3's crosscheck);
`DSP_DIFF_MODE` masks unchanged pixels; completion is one `DSP_END` status
bit raised through the driver's own registered `rockchip_ebc_irq()` —
synchronously, inside the triggering register write, so no threads are
needed and a sequencing bug becomes a visible driver timeout.

DMA is modelled as **non-coherent**, like the arm64 SoC: every
`dma_map_single` mapping keeps a shadow copy that only the map itself
(whole buffer — the arch cleans caches when mapping `TO_DEVICE`) and
`dma_sync_single_for_device` (the synced range only) update, and the fake
device reads exclusively from the shadows.  A CPU write the driver
forgets to sync is therefore *invisible to the device* and fails the
pixel-level assertions instead of passing silently.  This is the guard
that made the hrdl `dma_sync`-shrink cherry-pick (2026-07-04, see
`doc/kernel-forward-port.md`) provable offline: with per-frame row-span
syncs in place of full-buffer cleans, the 256-transition differential
and the goldens still pass.  A self-test (`dma shadow:`) pins the model's
own contract.

What it executes and asserts (`quirk:`-policy applies as in rung 2):

- **`mode_set_nofb`**: the full ED103TC2 timing-register set, hand-derived
  from the mode + the documented SDCK translation (12-register golden).
- **Global refresh**: LUT-mode contract (`FRM_TOTAL = num_phases-1`, one
  frame event, one `DSP_END`), `WIN_MST0/1` resolving to `ctx->prev/next`
  through the DMA registry, `next <- final` / `prev <- next` buffer
  discipline, queue draining, `DSP_OUT_LOW` epilogue, INT_STATUS
  write-1-to-clear, per-pixel drive counts vs an independent formula.
- **Partial refresh**: `num_phases` three-window frames with per-frame
  `CONFIG_DONE` discipline, the full per-pixel drive *sequence* (real
  phases then the 0xff neutral tail) vs the independent formula, silence
  outside the damage, `prev` catch-up, and two rendered PGM goldens.
- **`diff_mode`**: the driver sets `DSP_DIFF_MODE`, and unchanged pixels
  get zero drives even where the LUT drives the diagonal.
- **Mid-refresh commits** (injected from the device's frame hook, i.e.
  while the "hardware" refreshes): queue splice into a running refresh,
  final-buffer switch delivering the new frame to the later area,
  in-flight collision deferral to the window end — with a per-pixel
  phase-regression detector proving no conflicting waveform data.
- **Scheduler QUIRK E made device-visible**: with the shipped
  `split_area_limit=0`, the rung-2 chained-begin-together scenario makes
  overlap pixels' phase indices regress mid-sequence (conflicting drive
  data on real hardware).
- **QUIRK F (the 2026-07-12 threshold-global finding), executed**: the
  fake device gained an IRQ-latency knob (`defer_dsp_end` +
  `fake_ebc_deliver_dsp_end()`), and one scripted session — partial
  burst with its final frame's DSP_END delivered late, then a full
  refresh, then more partial damage — runs through both launch
  contexts: the driver's own threshold epilogue (zero-gap) vs the real
  `GLOBAL_REFRESH` ioctl from idle.  Identical stream, identical
  perturbation; only the threshold-fired variant ends with a residual
  `display_end` credit (a wait satisfied by the straggler — on hardware,
  mid-playback).  See Findings 8.
- **The rung-2 teardown UAF, executed**: `run-tests.sh` runs
  `ebc-refresh-test quirk-ctx-free-uaf` as a subprocess and asserts it
  dies with an ASan heap-use-after-free.
- **With `WBF=`**: the real `rockchip_ebc_probe()` (the shim's firmware
  loader honors `EBC_SHIM_FW_DIR`, so the driver's own
  `rockchip/ebc.wbf` request resolves), the real
  `rockchip_ebc_refresh()` (temperature via the stub IIO's 25 °C, LUT
  upload exactly when `lut_changed`, re-upload skipped when nothing
  changed), the refresh-thread body run synchronously through a scripted
  session (RESET global → full refresh → partial damage → off-screen
  global), and the **drive-sequence differential**: all 256 Y4 (from,to)
  transitions refreshed through the driver, and every observed sequence
  compared against `rastersim`'s independent decode of the same waveform
  (`wbf-info --dump-lut`).  That closes the loop driver-blit → scheduler →
  LUT-upload → device-LUT-readback vs an independent derivation of the
  waveform format.
- **Cold-bin selection (`wbf cold:`)**: the stub IIO is settable
  (`ebc_shim.iio_temp_override`); at 0 °C the driver must select this
  waveform's 131-phase GC16 cold bin and orchestrate it cleanly.  This
  is the evidence behind rejecting hrdl's ≥19 °C temperature clamp
  (a workaround for *their* rework's early-cancellation feature — see
  `doc/kernel-forward-port.md`): our copy handles cold bins fine, and
  clamping would discard per-device calibration data.

**Limits** (see `doc/ebc-harness-spike.md` §4): the device model encodes
*our understanding* of the silicon, so agreement proves consistency, not
hardware truth — the on-device `EXTRACT_FBS` differential stays the ground
truth, and optics stay hardware-only.  Concurrency is not modeled (the
device completes synchronously), so the races the driver tolerates by
design never overlap here.  `direct_mode` is unmodeled (off in the shipped
config).  The real probe path uses the DRM-core shim stubs, not the real
DRM core — that is option (b)'s territory.

## The trace-replay workbench (`ebc-replay`, rung 7a phase B)

The measurement tool the refresh-policy program runs on
(`doc/refresh-policy.md` has the program and the study results).  It
parses `[pn-refresh]` lines out of `/var/log/reader-session.log` (or a
`synth`-generated session), re-decides each intent under a candidate
policy — the KOReader-side layer our device target implements: the
area-thresholded flash policy, waveform choices, and the driver params
(`auto_refresh`, `refresh_threshold`, `split_area_limit`) — and drives
the damage and global-refresh requests through the **real refresh-thread
body** against the fake device, on a modeled 85 Hz frame clock (trace
wall-clock gaps become idle frames; events landing mid-refresh inject
from the device's frame hook, exactly like a concurrent atomic update).

Faithfulness details that matter and are modeled:

- **"partial" trace lines are annotations, not commands**: on the device
  the pixels travel via fbdev deferred-io, whose damage is page-granular
  — traced rects are widened to full-width row bands covering their fb
  pages (`defio=bands`, the default; `defio=rect` for comparison).
  Content is painted only inside the traced rect, so the band's
  out-of-rect rows stay byte-identical and diff-mask to nothing,
  exactly like the device.  `defio-delay-ms=` models the flush timer
  (device ~50 ms): with it, a wash ioctl beats the flush and runs on
  the stale page, and a follow-up partial draws the new content.
- **The driver's auto-refresh accumulator** runs verbatim, so untraced
  auto washes appear where the device would fire them (the hardcoded
  screen-area unit is compensated when replaying at reduced geometry).
- **Globals coalesce** through the same boolean flag the ioctl sets.
- Content is deterministic pseudo-text (policies compare on identical
  content streams; absolute pixel counts are model-relative).

Per run it reports: washes by cause (reset/boot/ioctl/auto) with a
per-wash census — believed-white pixels and how many of them the
selected waveform drives dark (the black-flash number) — pixel-phases
of drive, per-event settle latency in frames/ms, and end-of-trace
**scrub staleness** (how long pixels have gone without an active drive
— the honest proxy for GL16 residue risk; actual residue physics is
hardware-only).  `pgm-dir=` additionally renders per-frame PGMs through
a crude optical integrator at small scales (qualitative, for eyeballing
flash patterns).

```sh
build/ebc-replay synth build/session.trace pages=120 menus=6 full-every=6
build/ebc-replay replay build/fw build/session.trace scale=2 \
  refresh-waveform=GL16 refresh-threshold=60
```

Built without ASan (it scans full-panel buffers per frame; the same
driver paths run under ASan in `ebc-refresh-test`).  Its self-tests run
in `make check`: parser/policy/deferred-io/content tests always, the
replay tests (including the GC16-vs-GL16 differential and the
accumulator quirk below) with `WBF=`.

## What is not validated

- Real kernel concurrency: kthread preemption, IRQ timing, PM races.
- DRM atomic plumbing (plane/CRTC state lifecycles, damage iteration) —
  rung 5's vkms tests cover the client side of that.
- Whether the Y4 output looks right on a panel: rung 3's simulator plus the
  hardware-only optics checklist own that.
- What the panel optically shows during/after a replay: the workbench
  measures what the driver *drives*; ghosting, residue and flash
  perception stay hardware-only.

## Findings (driver oddities discovered by these tests)

The driver is hardware-validated, so the tests pin the code's *actual*
behavior (test names prefixed `quirk:`); these notes record where that
behavior diverges from the apparent intent.  Patch line numbers refer to
`pinenote/patches/linux-pinenote-7.0-forward-port.patch`.  **Do not fix
these silently in the patch** — they are candidates for upstream discussion
(ayakael/hrdl trees carry the same code) and for cherry-pick review.

1. **`blit_fb_xrgb8888` odd-x edge preservation is cross-wired** (patch
   ~4815–4869).  The blit preserves the old destination value of exactly one
   pixel per row — the first output byte's low nibble — keyed on
   `panel_reflection ? adjust_x1 : adjust_x2`.  Because of the x-mirror,
   that nibble corresponds to the *opposite* end of the clip, so a damage
   rect with odd x1 and even x2 (reflection on) leaves its highest-x pixel
   **stale** while overwriting the out-of-clip padding pixel instead.  The
   matching preservation for the other end (`if (x == src_clip->x2 ...)`,
   line 4862) is dead code: the loop condition `x < x2` makes it
   unreachable.  Visible effect: a one-pixel column of stale content on
   odd-aligned damage; compositor damage is usually 2px-aligned, which is
   why the panel never showed it.
2. **`blit_fb_xrgb8888` y-flip path drops a row** (patch 4815–4821,
   `panel_reflection=0` only).  `start_y = y2 - 2` with `end_y2 = y2 - 1`
   iterates height−1 rows: the last source row is never read, the last
   destination row is never written, and a 1-row-high damage clip blits
   nothing at all (`delta_y` is computed and never used).  Irrelevant for
   the shipped `panel_reflection=1`, but anyone flipping that param gets a
   subtly shifted, one-row-stale image.
3. **`blit_pixels` odd-x1 "preserve" reads the wrong buffer** (patch 3808).
   `first_odd` is read from `*src_line` instead of the destination, making
   the restore a no-op: the out-of-clip even pixel is copied from source
   too.  Benign for content (source is the composed final buffer) but the
   pixel changes without being phase-tracked.
4. **`blit_pixels` odd-x2 "preserve" targets byte `pitch-1`, not
   `width-1`** (patch 3810, 3824), plus an **out-of-bounds access**: for any
   clip narrower than the full row the save/restore is a value-preserving
   no-op on an unrelated byte one row down, and the odd-end pixel is copied
   instead of preserved.  When the clip touches the last row and
   `x1 >= 2`, the no-op read *and write* land one byte **past the end** of
   the kmalloc'd prev/next buffer — a real (if value-preserving) kernel
   heap overrun reachable from userspace damage rects.  This is the
   strongest candidate for an upstream fix (`width - 1` was clearly
   intended).
5. **`schedule_area`'s begin-together path ignores the dead zone** (patch
   3677–3682).  `do_not_start_before_frame` is only honored in the
   in-flight branch; the pending-vs-pending "begin together" assignment
   (and the wait branch) can therefore schedule an area to start *inside*
   an overlapping area's refresh window when splitting is unavailable —
   and the shipped configuration (`split_area_limit=0` in ebc.scm) never
   splits.  Deterministic reproducer in
   `test_schedule_quirk_begin_together_conflict`; on hardware the overlap
   pixels get conflicting phase data (transient artifacts, no memory
   unsafety).

6. **`rockchip_ebc_ctx_free` iterates while freeing** (patch 3206):
   `list_for_each_entry(area, &ctx->queue, list) kfree(area);` reads
   `area->list.next` after `kfree(area)`.  Only reachable when a context
   is torn down with damage still queued (mode-set/teardown races); the
   fix is the `_safe` iterator.  **Executed, no longer just read**: the
   rung-7a reproducer (`ebc-refresh-test quirk-ctx-free-uaf`) frees a
   context with one queued area and dies with an ASan
   heap-use-after-free; `run-tests.sh` asserts exactly that.

7. **Manual global washes do not reset the auto-refresh accumulator**
   (patch: `rockchip_ebc_refresh`'s epilogue).  `ctx->area_count` only
   accumulates in the partial path and only clears when the auto
   threshold itself fires (or when `auto_refresh=0`); the global-refresh
   path neither counts nor clears.  With `auto_refresh=1` the driver
   therefore schedules its own whole-panel wash purely on partial-damage
   volume, even immediately after a user-triggered wash that already
   cleaned the panel — a redundant flash every `refresh_threshold`
   half-screens regardless of interleaved manual washes.  Executed by
   `ebc-replay selftest` ("quirk: manual washes do not reset...") and
   quantified in `doc/refresh-policy.md`'s replay study.  Policy-level
   inefficiency, not memory unsafety; an upstream fix would zero the
   accumulator in `rockchip_ebc_global_refresh`.

8. **The threshold-fired auto-global launches zero-gap and lets a
   straggling DSP_END satisfy its wait (QUIRK F; the 2026-07-12 hardware
   finding's root-cause candidate).**  Both full-refresh paths run the
   identical code from `do_one_full_refresh` onward, and the harness
   confirms the CPU-side content bookkeeping (double-buffered `final`,
   queue splice/delete, `prev`/`next` discipline) is coherent for both —
   so the hardware divergence (threshold-path globals progressively
   corrupt recently-updated pixels at 0.6–0.8 reflectance; ioctl-path
   globals never do) has to come from launch context, and the code gives
   the threshold path exactly one unique property: **zero-gap chaining**.
   The flag is set in the epilogue of the very partial refresh that
   crossed the threshold (patch 4271–4280) and consumed immediately
   (4386–4387 skips the sleep, 4361–4369 consumes), so the global runs
   microseconds after a partial burst.  Meanwhile the per-frame handshake
   is fragile there: `display_end` is a *counting* completion that the
   partial path never reinits, `EBC_FRAME_TIMEOUT` is only 25 ms (2.1
   frame periods at 85 Hz, patch 2942), and a timed-out frame is logged
   but never resynchronized — one late IRQ order-skews every following
   wait (satisfied by the previous frame's END while its own frame still
   plays) and the burst exits with its final END in flight.  In the
   threshold path that straggler lands inside the global's
   `reinit_completion`→wait window (patch 3446→3459) and the global's
   wait returns while the num_phases-frame LUT playback is still driving
   glass — after which the driver commits `prev <- next` (3463), writes
   `DSP_OUT_LOW` (4265), uploads the next waveform's LUT (4211) and
   starts three-window frames against a panel mid-wash.  Pixels with
   `prev != next` (exactly the recently-updated ones) switch LUT rows
   mid-waveform and land at intermediate reflectance; the bookkeeping
   believes the wash landed, so the error compounds.  Ioctl washes
   launch from thread-idle (the wash beats the deferred-io flush), so
   stragglers land in the gap and the reinit absorbs them.  Executed as
   `quirk F` in `ebc-refresh-test` using the fake device's IRQ-latency
   knob (`defer_dsp_end`/`fake_ebc_deliver_dsp_end`): the identical
   session with the identical late-IRQ perturbation ends with a residual
   `display_end` credit **iff** the global was threshold-fired, and the
   test also pins the model's limit — the synchronous playback shows
   identical pixels for both paths, so the mid-playback corruption
   itself stays hardware-only.  Which straggler source dominates on
   silicon (late threaded-IRQ delivery, handler-vs-END coalescing losing
   an END, or an unmodeled `DSP_OUT_LOW` completion) is an on-device
   question; the zero-gap structure is what makes all of them land in
   the global's wait window.  Full mechanism, fix sketch and upstream
   draft in `doc/driver-findings-report.md` (2026-07-12 entry).

The rung-7a WBF drive-sequence differential also re-confirmed the
rastersim finding that **`blit_direct` reads the LUT transposed** from
the hardware side: the device model only matches the independent
waveform decode with the `[from]`-word/`[to]`-bit-pair axis convention,
which is the opposite of what `blit_direct` (unused, `direct_mode=0`)
implements.

Other pinned behaviors worth knowing: `blit_fb_r4` ignores
`panel_reflection` for pixel order (only the caller mirrors the rect
position, so R4 content is *not* mirrored within the rect) and never
reports "unchanged"; a pending area fully contained in an earlier pending
area is dropped even though the covering area may repaint different
content later (the final buffer holds the newest pixels, so this is safe
today).
