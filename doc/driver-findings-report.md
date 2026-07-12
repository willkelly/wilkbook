# rockchip_ebc findings — draft report for the PineNote kernel community

Status: draft, 2026-07-04. Intended audience: hrdl (git.sr.ht/~hrdl/linux),
ayakael (postmarketOS PineNote kernel), m-weigand/linux issues, and — for
finding 1 — potentially dri-devel if the driver is ever resubmitted.
Post as-is or trimmed; everything below is machine-verified against the
driver source, not just read.

## Context and method

wilkbook carries the community `rockchip_ebc` driver as a forward-port on
vanilla 7.0.x (hardware-validated on a PineNote v1.2: display, gadget,
PREEMPT_RT). To protect the port across rebases we compile the *verbatim*
driver source into host-side test harnesses
(`pinenote/tools/ebc-logic/`, `pinenote/tools/rastersim/` in
https://…/wkelly/wilkbook). The suites compare the driver's blit/scheduling
code against independent references over randomized and corner-case
inputs, and decode the panel's own PVI waveform. Seven latent issues fell
out. None affect the default PineNote configuration visibly
(`direct_mode=0`, full-width fbcon damage), which is presumably why they
have survived; several bite as soon as clients send arbitrary damage
clips, which is exactly what a damage-aware Wayland compositor or a
KOReader DRM backend will do.

Line references are to the driver as carried in our tree (equivalent code
exists in the hrdl/ayakael 6.19 lineage; re-check before applying).
Deterministic reproducers for each live in the two tool directories.

## 1. One-byte kernel heap overrun in `rockchip_ebc_blit_pixels` (odd-`x2` edge)

The odd-`x2` "preserve the out-of-clip nibble" step indexes the *last
byte of the row pitch* (`dst_line + pitch - 1`) instead of the byte at
the clip edge (`x2/2`). Two consequences:

- For any partial-width clip it silently read-modify-writes the wrong
  byte (value-preserving, so usually invisible).
- When the damage clip touches the **last row** and `x1 >= 2`, the
  computed address is one byte **past the end of the allocation**:
  a read + write heap overrun (value-preserving write, so it corrupts
  the neighboring allocation's byte only transiently — still UB and
  KASAN-visible).

Reproducer: `pinenote/tools/ebc-logic` `quirk:` test; the exact
triggering condition (odd `x2` && last row && `x1 >= 2`) is asserted by
code analysis and excluded from the randomized soak so the test binary
itself stays in-bounds. Suggested fix: target `x2 >> 1` within the clip
row, or drop the "preserve" entirely and blit inclusive nibble-aligned
spans.

## 2. Overlapping refresh windows: `rockchip_ebc_schedule_area` ignores `do_not_start_before_frame` in its begin-together/wait paths

When a new area overlaps an in-flight area, the scheduler computes
`do_not_start_before_frame`, but the code paths that (a) let two areas
begin together and (b) queue an area to wait, never consult it — so an
area can be scheduled to *begin inside an overlapping area's active
refresh window*. The panel then gets two concurrent waveform playbacks
over the same pixels with different phase offsets (ghosting/artifact
source, not memory-unsafe). More likely under the PineNote images'
shipped `split_area_limit=0`.

Reproducer: `test_schedule_quirk_begin_together_conflict` in
`pinenote/tools/ebc-logic/ebc-logic-test.c` (deterministic). The suite's
coverage soak confirms no pixels are ever *lost* — the hole is purely
temporal.

## 3. Use-after-free in `rockchip_ebc_ctx_free`

The teardown path kfrees queued damage-area nodes inside
`list_for_each_entry` (iterating a node after freeing it). Only
triggers if the device is torn down with damage still queued (rare:
unbind/unload under load). GCC's `-Wuse-after-free` flags it in our host
build. Fix: `list_for_each_entry_safe`.

## 4. `rockchip_ebc_blit_direct` reads the LUT transposed (latent, `direct_mode=1` only)

The packed-LUT lookup is `word[next] >> (2*prev)`, but three independent
lines of waveform-content evidence (documented in
`pinenote/tools/rastersim/README.md`) establish the file/hardware
semantics as `lut[phase][prev][next]`: the software direct-mode path
applies **reversed transitions**. Harmless on shipped configs
(`direct_mode=0`; the silicon indexes from `MST0=prev/MST1=next` in
hardware LUT mode), but anyone flipping `direct_mode=1` gets subtly
wrong drive sequences that mostly still converge — the worst kind of
wrong. Fix: swap the indices; our RSL1 dump + crosscheck in
`pinenote/tools/wbf/wbf-info.c --dump-lut` can serve as the regression
test.

## 5–7. Blit edge-case quirks (`rockchip_ebc_blit_fb_xrgb8888`, `blit_pixels`)

- Odd-x damage-edge preservation in the XRGB8888 blitter is keyed on the
  wrong adjust flag after `panel_reflection` mirroring (stale pixel left
  on odd-`x1`/even-`x2` damage), and one preservation branch (`x == x2`)
  is unreachable dead code.
- With `panel_reflection=0` the blitter loops `height-1` rows and never
  reads the last source row; a 1-row damage clip blits nothing. (The
  PineNote ships `panel_reflection=1`, hiding this.)
- `blit_pixels` odd-`x1` "preserve" restores the *source's* low nibble —
  a no-op that leaks one out-of-clip column of `final` into `next`
  without scheduling it for refresh.

All pinned with references in `pinenote/tools/ebc-logic/README.md`
(Findings a–c) and cross-checked by the rastersim damage-composition
suite.

## Suggested disposition

1 and 3 are ordinary memory-safety fixes (small, obviously correct).
2 needs a design decision from whoever owns the scheduler (respect
`do_not_start_before_frame` in both paths, or document why concurrent
windows are acceptable). 4 should be fixed before anyone builds on
direct mode. 5–7 matter once damage-aware clients land; fixing them
together with 1 in one blitter-hygiene pass would be natural.

## Finding (2026-07-11, live): portrait rotation wedges the EBC; module reload is not a safe recovery

Reproduced twice on the A.2.6 image (7.0.11, rockchip_ebc 0.3.0, GL16 policy):
with KOReader rendering in **portrait** (`copt_rotation_mode=1` on the
landscape-native 1872x1404 fb), the first portrait refresh leaves the panel
**unresponsive to every subsequent framebuffer write** — deferred-io partials
and the GLOBAL_REFRESH ioctl are logged/accepted but nothing reaches glass,
with no dmesg errors. Landscape rendering never triggers it (hundreds of
refreshes across the same session, including a 48-turn scripted run).

Recovery via `rmmod + modprobe` restores drive (verified: raw fb writes reach
glass again) but the reloaded driver starts with `using zero-initialized flat
cache, this may cause unexpected behavior` — and indeed it **re-wedged within
~10 partial refreshes** of normal landscape use. A full reboot is the only
clean recovery found. Workaround adopted by the optics harness: never rotate —
the test card is generated landscape-native (1872x1404) and
`copt_rotation_mode` is pinned to 0.

Upstream relevance: hrdl's redesigned driver (per-pixel scheduling) likely
does not share the wedge; m-weigand-lineage users running portrait readers
would hit this on any mainline-ish kernel. Repro recipe: fbdev client renders
90°-rotated full-screen content -> first full refresh -> panel frozen;
`echo 1 > .../vtcon1/bind` unaffected. Needs a minimal fb-level reproducer
(FBIOPUT_VSCREENINFO/rotated-blit sequence) before reporting upstream.

## Finding (2026-07-12, live): threshold-triggered auto-globals corrupt panel state; ioctl-triggered globals are clean

On the A.2.6 image (7.0.11, rockchip_ebc 0.3.0, GL16 global waveform), full
refreshes fired by the driver's own damage-threshold path (`auto_refresh=1`,
`area_count >= refresh_threshold * one_screen_area`) progressively corrupt
displayed state: after such a firing, frequently-updated fine structure (1-bit
barcode cells) reads 0.6-0.8 reflectance instead of ~0/~1, and the corruption
snowballs. Reproduced across a 2x2 (page-diversity x auto_refresh): every
corrupting run had `auto_refresh=1`; disabling it makes the same 48-turn
diverse workload clean (45/48 marker decode vs 0-6/48), and a video-side
detector (only globals redraw static screen regions) catches unexplained
global events precisely in the auto=1 runs, including the corrupted ones.
Lowering the threshold makes corruption FASTER (threshold=8 -> 6/48), i.e.
each threshold-path firing does damage. GLOBAL_REFRESH ioctl firings
(userspace-triggered, same waveform) never produced corruption across ~20
multi-wash sessions, and the ioctl works with a live DRM master.

Suspected mechanism: the threshold path fires from the middle of the update
stream and races in-flight partials' prev/next bookkeeping (same family as
quirk 3: "manual washes never reset the accumulator" — the accumulator also
persists across sessions, making firings random-phase). One further anomaly
retained honestly: two unexplained global-like events in one auto=0 soak
(t≈100/105 s) — possibly the known spontaneous-global flakiness.

Workaround shipped in wilkbook: `auto_refresh=0`; all full refreshes owned by
userspace via the ioctl. Root cause below (offline analysis + quirk F).

### Root cause: the threshold path is the driver's only zero-gap launcher, and the refresh handshake cannot survive one

Line numbers are patch lines in our tree
(`pinenote/patches/linux-pinenote-7.0-forward-port.patch`; the same code
ships in m-weigand 6.6/6.12 and everything derived from it).

**What is NOT the cause.** Both full-refresh paths execute the identical
code from `do_one_full_refresh` onward: the ioctl handler (3110–3117) and
the threshold epilogue (4271–4280) set the same flag, consumed at the same
place in the refresh thread (4361–4369 → `rockchip_ebc_refresh(…, true,
refresh_waveform)` at 4380). We traced the CPU-side content bookkeeping end
to end — double-buffered `final` switching (3419–3426/3921–3929/4067–4081
vs `plane_atomic_update` 5158–5177), queue splice + delete-under-global
(3453–3457, safe because `next <- final` at 3441 covers all pending damage),
`prev <- next` discipline (3463, 4006–4008) — and it is coherent for both
paths under every interleaving the locks allow. The rung-7a harness
executes exactly these paths against the fake device and confirms:
identical update streams produce identical pixel outcomes through either
path. The corruption is not a buffer-state bug the ioctl path avoids.

**The asymmetry.** The threshold path has exactly one property the ioctl
path never exhibits in practice: **zero-gap chaining**. The flag is set in
the epilogue of the very partial refresh that crossed the threshold —
i.e. microseconds after the burst's last frame — and the thread's
`continue` (4386–4387) consumes it without sleeping. An ioctl wash instead
fires while the refresh thread idles (KOReader's wash beats the ~50 ms
deferred-io flush; the thread sleeps at 4389–4395), so the panel pipeline
has been quiet for at least tens of milliseconds when the global starts.

**Why zero-gap kills it.** The per-frame handshake in
`rockchip_ebc_partial_refresh` is fragile in precisely the way a zero-gap
global exposes:

- `display_end` is a **counting** completion, and only the global path
  ever re-zeroes it (`reinit_completion`, 3446). The partial path pairs
  each `DSP_START` (4058–4060) with one wait (4091–4093) and trusts the
  count.
- `EBC_FRAME_TIMEOUT` is 25 ms (2942) — 2.1 frame periods at 85 Hz. A
  DSP_END interrupt delayed past it (threaded IRQ under PREEMPT_RT with
  gadget/Wi-Fi load; or an END lost to the handler's read-clear
  coalescing, 5468–5480) is *logged* ("Frame %d timed out!") but the
  handshake is never resynchronized: every subsequent wait in the burst is
  satisfied by the **previous** frame's END — returning while its own
  frame still plays — and the burst exits with its final END still in
  flight.
- The threshold global then opens its `reinit_completion` → wait window
  (3446 → 3459) a few milliseconds later, while that straggler is en
  route. The straggler credits the completion and **the global's wait
  returns while the `num_phases`-frame LUT playback is still driving
  glass** — up to ~470 ms early (GL16), ~1.5 s (GC16 cold bins).

After the early return the driver, believing the wash done, immediately:
commits `prev <- next` for the whole screen (3463), drives the outputs low
(4265–4267), re-enters `rockchip_ebc_refresh` for the queued damage,
uploads the *partial* waveform's LUT over the live one (4211–4215, the
GL16→GC16 switch back), reprograms the mode bits, and starts three-window
frames — all against a panel mid-wash. The hardware re-fetches `prev`/
`next` per frame, so pixels whose LUT row changes mid-waveform stop at
whatever intermediate reflectance the truncated/wrong drive sequence
leaves. Pixels with `prev == next` play the diagonal row throughout and
are immune — which is why the optics runs show **static regions clean and
recently-updated fine structure at 0.6–0.8 reflectance**. Because the
driver's books now say the wash landed, subsequent partials keep computing
transitions from a `prev` the glass does not hold, and the error compounds
— the observed snowballing. More threshold firings = more zero-gap
launches = faster corruption (threshold=8 corrupted faster than 60, as
measured). Firing phase is randomized by finding 7 (the accumulator never
resets on manual washes and persists across sessions), matching the
stochastic on-camera timing.

The ioctl path is structurally immune in the shipped stack: stragglers
land during the idle gap where nobody waits, and the next global's
`reinit_completion` absorbs the stale credit before arming its wait.

**Executed evidence (offline).** `pinenote/tools/ebc-logic/ebc-refresh-test`
quirk F (`test_quirk_threshold_zero_gap_global`): the fake device gained an
IRQ-latency knob, and one scripted session — partial burst whose final
frame's DSP_END is delivered late, then a full refresh, then more damage —
runs through both launch contexts. Identical stream, identical
perturbation: only the threshold-fired variant ends with a residual
`display_end` credit (a wait satisfied by the straggler; on hardware, a
wait that returned mid-playback), and the test also pins the harness
limit honestly — the synchronous device model shows identical final pixels
for both paths, so the optical corruption itself stays hardware-only.
Which straggler source dominates on silicon (late IRQ delivery, coalescing
losing an END, or an unmodeled DSP_END raised by the `DSP_OUT_LOW`
epilogue) is the remaining on-device question; the zero-gap structure is
what turns any of them into a truncated wash.

**Minimal fix sketch** (not applied in our tree per the no-silent-driver-
fix policy):

```diff
@@ rockchip_ebc_partial_refresh @@
 		if (!wait_for_completion_timeout(&ebc->display_end,
-						 EBC_FRAME_TIMEOUT))
+						 EBC_FRAME_TIMEOUT)) {
 			drm_err(drm, "Frame %d timed out!\n", frame);
+			/*
+			 * This frame's DSP_END is still in flight.  Keep
+			 * waiting for it rather than letting its completion
+			 * credit satisfy the next wait (or a subsequent
+			 * global's) while the hardware is still driving.
+			 */
+			if (!wait_for_completion_timeout(&ebc->display_end,
+							 EBC_REFRESH_TIMEOUT))
+				drm_err(drm, "Frame %d: no DSP_END\n", frame);
+		}
@@ rockchip_ebc_refresh_thread @@
 			if (one_full_refresh) {
 				spin_lock(&ebc->refresh_once_lock);
 				ebc->do_one_full_refresh = false;
 				spin_unlock(&ebc->refresh_once_lock);
+				/*
+				 * A threshold-fired global otherwise launches
+				 * back-to-back with the partial burst that
+				 * crossed the threshold.  Yield one frame
+				 * period so a straggling DSP_END lands before
+				 * reinit_completion() re-arms the wait.
+				 */
+				usleep_range(12000, 13000);
 				rockchip_ebc_refresh(ebc, ctx, true,
 						     refresh_waveform);
```

Companion (also closes finding 7 and makes auto firings deterministic):
`ctx->area_count = 0;` at the end of `rockchip_ebc_global_refresh`.
A deeper fix would defer threshold-flag consumption to the thread's idle
point (making auto washes launch exactly like ioctl washes), or replace
the counting completion with a sequence-checked per-frame handshake.

**Needs on-device confirmation** (next hardware session; module params and
log harvest only, plus one A/B kernel):

1. Harvest the kernel log after a corrupting `auto_refresh=1` run and a
   clean `auto_refresh=0` run: the mechanism predicts `Frame %d timed
   out!` lines correlated with (and preceding) corrupting auto-washes.
   (The existing optics datasets only captured KOReader-side logs.)
2. A/B the two-hunk fix on os2: rerun the armC same-pair soak with
   `auto_refresh=1`; the wash detector should still see the auto firings,
   and the graying should not occur.
3. If (1) shows no timeouts, instrument the remaining straggler candidate:
   one `printk` when `completion_done(&ebc->display_end)` is true right
   after `reinit_completion` would have run with a gap — or simply check
   whether `DSP_OUT_LOW` raises DSP_END on this silicon (TRM question to
   the community).

**Confirmation run 1 result (2026-07-12, instrumented repro v1,
`build/bundles/corrupter-repro-v1`):** 30 same-pair page toggles under
`auto_refresh=1 refresh_threshold=2` with a live `dmesg --follow` watch.
The patch-strip detector saw a threshold auto-global ride EVERY toggle
(30/30, camera-confirmed) and the kernel log stayed COMPLETELY SILENT —
zero `Frame %d timed out!` / `Refresh timed out!` lines. Point (1)'s
timeout-correlation is therefore answered: the 25 ms frame-timeout
desync is NOT the straggler source in this workload; the timeout-free
candidate (extra DSP_END credit, point 3) is now the prime suspect.
No graying was measurable in v1 (dark strokes 0.263 -> 0.263 over the
run) — expected in hindsight: at threshold=2 a wash follows every
toggle, so any truncated wash is healed ~2.5 s later by the next one.
The corrupting regime needs RARE firings with long washless exposure
(exactly armC's shape); repro v2 targets it (graphic pair, threshold=20,
60 toggles, 30 s washless inspect window).

### Upstream notification draft (m-weigand / PNDeb / hrdl / ayakael)

> Subject: rockchip_ebc: auto_refresh threshold path can truncate its own
> global refresh (progressive panel-state corruption); PNDeb default
> config is exposed
>
> On a PineNote v1.2 running the community rockchip_ebc (m-weigand
> lineage, carried forward to 7.0.x in wilkbook) we measured, with a
> camera rig, that full refreshes fired by the damage-threshold path
> (`auto_refresh=1`) progressively corrupt recently-updated pixels
> (1-bit test cells drift to 0.6–0.8 reflectance and the error
> compounds), while GLOBAL_REFRESH-ioctl washes of the same waveform are
> always clean. Lowering `refresh_threshold` corrupts faster.
>
> Root cause (host-side analysis + a deterministic reproducer that
> compiles the verbatim driver against a behavioral device model —
> details and line numbers in wilkbook's doc/driver-findings-report.md):
> the threshold path is the only place a global refresh launches
> *zero-gap* after a partial burst. `display_end` is a counting
> completion that the partial path never reinits, `EBC_FRAME_TIMEOUT` is
> only ~2 frame periods, and a timed-out frame is logged but never
> resynchronized — so a straggling DSP_END from the burst can land inside
> the global's `reinit_completion`→wait window and satisfy the wait while
> the LUT playback is still driving glass. The driver then commits
> `prev <- next`, drives outputs low, re-uploads the partial LUT and
> starts three-window frames mid-wash: every `prev != next` pixel
> switches LUT rows mid-waveform and lands at an intermediate gray, and
> the books say the wash landed, so partials keep compounding the error.
> Ioctl washes launch from an idle thread, so stragglers are absorbed
> harmlessly — matching the clean ioctl behavior we measured across ~20
> sessions.
>
> Note PNDeb currently ships the exposed configuration
> (`auto_refresh=1 refresh_threshold=60`), and its user guide suggests
> `refresh_threshold=20` for redraw-heavy apps — which our measurements
> say corrupts *faster*. Suggested minimal fix (sketch in the doc): on
> frame timeout keep waiting for that frame's END instead of proceeding,
> and yield one frame period before a threshold-fired global; also reset
> `ctx->area_count` in the global path so firings stop being
> random-phase. hrdl's redesigned driver (per-pixel scheduling, early
> cancellation of in-flight updates) most likely does not share the
> defect. Happy to share the reproducer, the optics data, and to test
> patches on hardware.
