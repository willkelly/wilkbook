# ebc-logic — host unit tests for the EBC driver's pure logic (offline ladder, rung 2)

Compiles the **verbatim** `drivers/gpu/drm/rockchip/rockchip_ebc.c` (and its
LUT dependency `drm_epd_helper.c`) out of
`pinenote/patches/linux-pinenote-7.0-forward-port.patch` — extracted at build
time with rung 1's `extract-from-patch.py`, so the tests always exercise
exactly the code the kernel ships — against a kernel-API shim
(`shim/kernel-shim.h`), and unit-tests the driver's pure arithmetic.  This is
the code most likely to break silently on every forward-port; these tests
make that a red `make check` instead of a wasted panel session.

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
(`ebc-logic-test.c`), the same way rung 1 includes `drm_epd_helper.c`.  That
makes the driver's `static` functions directly callable and its
module-parameter globals (`panel_reflection`, `bw_mode`, `bw_threshold`,
`fourtone_*`, `bw_dither_invert`, `split_area_limit`, `diff_mode`,
`default_waveform`) directly settable per test.  The shim has two layers:

- **faithful**: what the tested logic actually executes — `list_head` ops,
  `drm_rect` ops, `kref`, allocators — reimplemented per kernel semantics;
- **inert**: everything only reachable from probe/refresh/PM paths the tests
  never run (regmap, clk, dma, pm_runtime, kthread, iio, DRM plumbing) —
  stubs that return 0/NULL so the whole file compiles.

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

## What is not validated

- Anything touching hardware: register programming, DMA mapping/sync, IRQ
  handling, frame timing, kthread scheduling, PM. The refresh loops
  themselves (`rockchip_ebc_partial_refresh` / `_global_refresh`) are
  compiled but not executed.
- DRM atomic plumbing (plane/CRTC state lifecycles, damage iteration) —
  rung 5's vkms tests cover the client side of that.
- Whether the Y4 output looks right on a panel: rung 3's simulator plus the
  hardware-only optics checklist own that.

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
   `area->list.next` after `kfree(area)` — GCC flags it
   (`-Wuse-after-free`) when compiling this harness.  Only reachable when
   a context is torn down with damage still queued (mode-set/teardown
   races); the fix is the `_safe` iterator.  The tests only ever free
   contexts with an empty queue, so the harness itself never executes the
   UAF.

Other pinned behaviors worth knowing: `blit_fb_r4` ignores
`panel_reflection` for pixel order (only the caller mirrors the rect
position, so R4 content is *not* mirrored within the rect) and never
reports "unchanged"; a pending area fully contained in an earlier pending
area is dropped even though the covering area may repaint different
content later (the final buffer holds the newest pixels, so this is safe
today).
