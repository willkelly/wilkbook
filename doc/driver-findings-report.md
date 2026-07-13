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
code analysis and was excluded from the randomized soak so the test
binary itself stayed in-bounds. Suggested fix: target `x2 >> 1` within
the clip row, or drop the "preserve" entirely and blit inclusive
nibble-aligned spans.

**Fixed in-tree 2026-07-12.** The forward-port patch now carries hrdl's
own fix — `11c358d1ca7a` ("rockchip_ebc: rockchip_ebc_blit_pixels: fix
adjustment for odd clips", v6.19_ebc_custom, 2025-01-09) — applied
verbatim; it fixes this finding and finding 7 in one commit. The host
pins flipped to fix-regression guards, and the formerly forbidden
odd-`x2`/last-row/`x1>=2` corner is now exercised on purpose by the
blit soak. The upstream ask is unchanged: backport the fix to the
legacy branch.

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

**Fixed in-tree 2026-07-12** via a minimal translation of hrdl's
`59b2113e8b9c` ("rockchip_ebc: fix scheduling issues due to overlapping
areas", v6.19_ebc_custom, 2025-01-09): the pending-vs-pending
begin-together path now honors `do_not_start_before_frame`, forward
moves of `frame_begin` are monotone (`max()`, never an unconditional
assignment that can move a start backward into a waited-for window),
and window arithmetic is end-exclusive throughout. The deterministic
reproducer and the rung-7a device-visible test flipped to fix pins
(zero per-pixel phase conflicts), and the rung-2 soak now asserts the
pairwise no-conflict property outright. One part of hrdl's commit was
deliberately **not** adopted: it also replaces the two redundant-area
containment drops with `!drm_rect_intersect(...)` tests that can never
fire once overlap is established — his commit message misstates
`drm_rect_intersect`'s return value (mainline returns "intersection
non-empty", not "first rect not fully covered"), so the change silently
disables contained/duplicate-area dropping. Upstream should review that
piece separately when backporting. The upstream ask is unchanged.

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
  without scheduling it for refresh. (**Fixed in-tree 2026-07-12**
  together with finding 1 by hrdl's `11c358d1ca7a`, applied verbatim —
  see finding 1's note. This removed a prev/next desync primitive from
  the corruption-hunt suspect list.)

All pinned with references in `pinenote/tools/ebc-logic/README.md`
(Findings a–c) and cross-checked by the rastersim damage-composition
suite.

## Suggested disposition

**Update 2026-07-12 (see `doc/hrdl-evaluation.md`):** hrdl independently
hit and fixed findings 1, 2 and 7 in January 2025 on his custom rework
branch (`v6.19_ebc_custom`, commits `11c358d`, `59b2113`) — never
backported to the legacy branch this report targets (which is the
driver PNDeb/Debian users and wilkbook run; his legacy branch is a
159-line diff from ours). The upstream ask is therefore concrete:
backport his own fixes. His fix commit for finding 2 describes observed
"scheduling issues" in the field — finding 2 (overlapping refresh
windows) is now also the prime suspect for the session-selective panel
corruption documented below, which the 2026-07-12 instrumented run
cleared the threshold-handshake path of.

**Update 2026-07-12 (landed in wilkbook):** both fixes are now carried
in the forward-port patch as fixes with upstream provenance, not silent
patches — `11c358d1ca7a` verbatim (findings 1+7), `59b2113e8b9c` as a
minimal translation (finding 2's scheduling holes; the commit's
unrelated containment-drop removal was not adopted, see finding 2's
note). All host-suite quirk pins for these findings flipped to pin the
fixed behavior (`pinenote/tools/ebc-logic`, cherry-pick record in
`doc/kernel-forward-port.md`). Keeping the fixed scheduler as the single
changed variable also sets up the corruption A/B on the rung-7a optical
model (`doc/hrdl-evaluation.md` §5).

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
each threshold-path firing does damage. (CORRECTED by the evidence audit
below: the "0-6/48 marker decode" figures are instrument-dominated, the
threshold=8 run was in fact optically CLEAN through ~11 on-camera threshold
firings — the faster-corruption claim is retracted — and the "0.6-0.8"
cell readings were displaced-geometry samples; the directly-measured
corruption forms are whole-page ghost paints, fine marks at 0.2-0.4, and
per-event graying of 0.04 -> 0.09 across a wash. The run-level correlation
with `auto_refresh=1` survives on direct frame evidence.)
GLOBAL_REFRESH ioctl firings (userspace-triggered, same waveform) never
produced corruption across ~20 multi-wash sessions, and the ioctl works
with a live DRM master.

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

**Confirmation run 2 result (2026-07-12, repro v2,
`build/bundles/corrupter-repro`):** 60 graphic-pair toggles @2.5 s under
`threshold=20` produced exactly the rare-firing regime (6 auto-globals,
one per ~10 toggles, camera-confirmed; the 30 s inspect window stayed
washless) — kernel log SILENT again, and STILL no corruption (dark px
0.237 -> 0.240, whites 0.827 -> 0.830). Interpretation: truncation is
not deterministic per threshold firing. With a 2.5 s dwell the damage
burst has fully drained (all DSP_ENDs received) before the flag is
consumed, so the zero-gap window is empty; the straggler needs the
global to launch while frames are STILL IN FLIGHT — continuous damage
(rapid successive turns / pen strokes), or an interrupt-timing accident,
at the moment the threshold trips. That matches the campaign's
stochasticity (3/4 diverse runs corrupted; single unexplained globals at
random phase). Consequence for confirmation: an optical A/B needs a
reliable repro we don't yet have; the DECISIVE experiment is now point
(3) — the one-printk instrumented kernel (`completion_done()` check at
the global's reinit) which detects the straggler credit directly,
corruption visible or not. Faster-dwell repro (0.5-0.8 s toggles into
the firing) is the remaining cheap lever before that.

**Confirmation run 3 result (2026-07-12, repro v3):** 100 rapid
graphic-pair toggles (~1.3 s effective dwell — inside the render+refresh
window, so the 9 threshold globals launched into a CONTINUOUS damage
stream) — kernel silent, and the washless inspect frame vs the same page
post-GC16 shows ZERO scrubbed residue (dark drift +0.001, white +0.001).
Fifteen deliberate threshold firings across three regimes (per-toggle,
rare+exposed, rare-into-active-stream) have now produced no corruption.
Standing assessment, stated honestly for upstream: the hardware
correlation from the campaign is solid (auto=1 in every corrupting run,
auto=0 always clean, the firings camera-caught in the corrupting runs),
and quirk F's zero-gap launch asymmetry is source-verified — but the
truncation event is NOT reproducible on demand; its trigger has an
unisolated component (candidates: diverse-content damage shapes — the
3/4 corrupting runs were diverse pages, all three repros same-pair;
long-session accumulated state; low per-event interrupt-timing odds).
The instrumented kernel (point 3) is the decisive next instrument: it
logs the straggler credit / early wait-return per event, replacing
optical inference entirely. Until it reports, the upstream claim should
lead with the correlation + the source-level asymmetry, and present the
truncation mechanism as the best-supported hypothesis rather than a
demonstrated fault.

**Confirmation runs 4-5 (2026-07-12, diverse walks, threshold=8) and a
methods correction:** v4 (out-and-back card walk ending on a BLANK page)
initially measured dramatic dark-mark graying scrubbed by the recovery
wash — that result is VOID: blank pages render no fiducials, frame
validity collapses in the inspect window, and the measurement's frame
snaps silently fell back to unrelated mid-walk frames (t=324/345 vs the
requested 335/361). v5 (same walk ending on the graphic page; strict
snaps that refuse fallbacks >2 s) measured on validated frames: ZERO
residue (dark drift +0.001), kernel silent — fifth run. Methods
limitation now documented: on diverse content NONE of our optical
detectors can count GL16 threshold-globals — the patch-strip detector
needs mark-bearing valid frames (blanks break it; it reported 20 events
on v4 and 2 on v5 for near-identical panel activity), panel-delta scans
confuse full-page partials, and dip scans confuse dark pages (a GL16
wash only dips panel mean to ~0.6). The same-pair results (v1-v3,
where every frame carries marks and the strip detector is reliable)
stand: ~45 verified threshold firings, zero corruption, silent log.
Net for upstream: the corrupting trigger seen in the campaign
(armC/neverx3, older boot, long cumulative sessions) did not reproduce
in five deliberate same-evening regimes; candidates now include
cumulative cross-boot/session state and environment, and per-event
ground truth requires the instrumented kernel, not optics.
(Superseded in part by the evidence audit below: the campaign runs were
NOT an older boot — timeline forensics put every corrupting run on the
same boot as the clean repros, hours apart — and one campaign
"corrupt" run was itself a measurement artifact.)

### Evidence audit (2026-07-12, post-v4 methods lesson)

The v4 void raised the obvious next question: does any of the CAMPAIGN's
corruption evidence rest on the same instrument failure modes? Every
bundle behind findings 8-10 (neverx3.r00-r02, the cliff-era
sweep1.r02-gl16-never, driver-owned, armC, armB/armB2, soak1) was
re-analyzed offline with an explicit validity lens: per-frame fiducial
validity accounting at 10 fps/half-res; a second pass that warps every
frame with its OWN fiducial fit and self-checks the geometry in panel
space (fiducial squares must be dark) before reading any cell; 30 fps
frame-window extraction with per-frame tables and PNGs around every
claimed event; and a verbatim rerun of the campaign's patch-strip
detector, which reproduced every claimed event time exactly. Scripts:
`audit-validity.py`, `audit2-perframe.py`, `inspect-window.py` (session
scratchpad).

**Instrument verdicts first.** The v4 blank-page mode did NOT drive the
campaign numbers: every walk bundle holds 96-97% per-frame fiducial
validity, the only >=1 s validity holes are the sync-flash blocks, and
blank-KIND card pages carry fiducials and validate fine (v4's hole was
the marker-less sync-white page). But the audit found a SECOND, worse
failure mode: production ingest (and the campaign's cell-reading
scripts) fit ONE session homography from the capture's opening frames.
The corrupt-run captures all open on the PREVIOUS run's final page, and
when that page is a `graphic` card page (large mid-gray panels), the
Otsu panel-quad detection distorts, the session homography lands
displaced, and every downstream sample — barcode cells, reference
patches — reads fabricated mid-grays for the WHOLE run while the
per-frame validity flags stay green. never-a, never-b, driver-owned and
armC were all poisoned this way (their captures open on graphic page
46); never-c, armB, armB2, soak1 and sweep1.r02 opened on crisp pages
and their reports are quantitative. Consequence: **the campaign's
segmentation-symptom numbers (0/48, 429 pseudo-transitions, 6/48) and
armC's "4-5x" magnitude were all read through displaced geometry and
are not corruption measurements.** (This also supplies an
instrument-first candidate for cadence.r01's unexplained 19/48
under-segmentation.)

**Per-claim verdicts** (on the artifact-proof layers only:
geometry-self-verified frames + 30 fps windows + direct PNGs):

- **never-a corruption — STANDS**, on direct frame evidence, with its
  form corrected. The panel genuinely corrupts: at t≈108 the page-25
  partial paints the whole page as a barely-visible ghost (text, page
  number, fiducials, patch strip, barcode all near-white on camera —
  frames extracted and inspected), and an unexplained full-panel wash
  at t≈109.2 repaints it crisp. Where geometry verifies, marks read
  CRISP (framing cells 0.012-0.024) — the corruption is episodic
  whole-page ghost-painting, not graded mud, and it was already present
  in the run's first content pages (it did not accumulate over the
  48-turn pass). The "segmented 0/48" figure is instrument-dominated
  and should not be quoted as a residue measure.
- **never-b corruption — STANDS.** Window-verified geometry mid-run
  (t≈118-126 s) shows framing marks sustained at 0.22-0.38 reflectance
  (~10x the same-rig crisp floor) with the barcode still decoding —
  exactly the near-threshold regime that shattered segmentation. The
  onset is WITHIN the run (early bins verify crisp at 0.013-0.021,
  bins from ~90 s stop verifying, late bins partially recover) — the
  only campaign run showing a mid-run degradation onset. The "429
  pseudo-transitions" count itself is instrument-shaped (real
  near-threshold cells + displaced sampling).
- **never-c — stays clean** (as the campaign counted it): verified
  frames read 0.005-0.037 with healthy decode end to end.
- **cliff-era sweep1.r02 barcode corruption (finding 1's "cells read
  0.63-0.82") — VOID.** Geometry-verified frames are crisp through the
  entire 48-turn washless pass including the late run (framing
  0.007-0.024, 100% decode); a 30 fps window through its one anomalous
  stretch shows crisp marks and a clean partial turn. The 0.63-0.82
  cell readings reproduce only under displaced sampling (a mid-cell
  miss reads white-ish). The finding-8 "matching the original outlier"
  framing falls with it: the replication set is never-a + never-b, not
  3/3.
- **driver-owned ("threshold=8 + never still corrupted, 6/48") — VOID,
  and it flips to counter-evidence.** Its ~11 threshold auto-globals
  are beautifully on camera (metronomic strip-redraw events every
  ~14.8 s ≈ every 4th turn), and the panel is CRISP wherever geometry
  verifies (framing 0.006-0.018, ~100% decode, 51% of frames verified
  across the whole run); a 30 fps window straddling the t≈99.4 firing
  shows the barcode at 0.01-0.02 before, THROUGH, and after the wash.
  6/48 was the session-homography artifact. This run joins repro
  v1-v5: threshold firings observed, zero optical corruption.
- **armC same-pair graying — STANDS**, magnitude re-based. On verified
  frames armC's framing cells/black patch read 0.08-0.10 versus
  0.001-0.02 same-rig floors (soak1 phase A, armB, driver-owned) —
  real graying, though the original "4-5x" was computed through
  displaced geometry and should not be quoted as calibrated. Two
  sharper facts replace it: the graying was already present at the
  FIRST toggle, and its onset window (armC's own preamble: param flip
  to auto=1 + card walk) contains an unrecorded global at t≈25 on
  camera; and the t≈90 auto-global measurably grays the framing cells
  per-event, 0.04 -> 0.09, in the 30 fps table. armB2's cleanliness
  minutes later confirms the state resets with GC16 deep cleans.
- **armB/armB2 clean controls — STAND.** Same instrument, same walk:
  97% validity, 99%+ aligned decode, dark marks at the floor, and zero
  mid-walk strip-detector events (their only events are the preamble
  deep cleans). The corrupt-vs-clean contrast is not an instrument
  asymmetry: the corrupt side is re-established above by direct
  frames, the clean side measures clean on verified geometry.
- **Detector event, armC t≈90 — STANDS** (and is upgraded): full
  static-region drive in the 30 fps table (strip and framing cells
  cycle through extremes, page-id drops out and returns) followed by
  the permanent 0.04 -> 0.09 graying. Same-pair content, 100% validity
  around it — the regime where the strip detector is reliable.
- **Detector event, never-a t≈109 — STANDS as a real unexplained
  global, with its ROLE inverted.** Direct inspection shows a genuine
  whole-panel wash (static patch strip cycles dark and repaints) — but
  it RESTORES the ghost-painted page; the corrupting agent on camera
  is the preceding partial paint. "The culprit on camera" was the
  wrong gloss; "the corruption and an unexplained global, both on
  camera, seconds apart" is the defensible one.
- **soak1's two unexplained events (t≈100/105, autos off) — STAND,
  upgraded from anomaly to evidence.** Both are real static-region
  drives (strip driven to 0.28/0.42 and back within ~0.3 s; alignment
  to the soak event log is firm — the recorded GL16/GC16 interventions
  land at exactly the detector's other two events). The second event
  fires mid-dwell with NO page flip and leaves a framing cell
  permanently grayer, 0.01 -> ~0.10 (partially healed to ~0.018 by the
  later recorded GL16). So `auto_refresh=0` is NOT event-free on this
  boot: whatever issues these spontaneous global-class drives can also
  do per-event damage. The soak's headline (30 washless same-pair
  flips, no accumulation, toggling cell tracks its neighbors) stands
  on 100%-valid frames.

**Timeline forensics** (capture mtimes; all 2026-07-11/12 local, one
boot): neverx3 18:09/18:12/18:15, driver-owned 18:26, soak1 18:37, armB
19:14, armC 19:17, armB2 19:28, idlewasher 20:16-20:34, repro v1-v5
20:49-21:37. Every corrupting/graying run is on the SAME BOOT as the
clean repros — cross-boot state is dead as a co-factor. So is protocol
structure: driver-owned ran the full campaign protocol 11 minutes after
the corrupt neverx3 runs and stayed clean. The corrupted state comes
and goes within one boot (never-a catastrophic at 18:09, never-c clean
at 18:15, driver-owned clean at 18:26, armC grayed at 19:17 between
two clean armB runs), and GC16 deep cleans reset it — what distinguishes
the runs where it appears remains unisolated.

**What the audit does to the finding.** The run-level correlation
survives: every run with run-level corruption or graying (never-a,
never-b, armC) had `auto_refresh=1`, and both `auto_refresh=0` runs are
free of run-level corruption. The per-event picture is now richer and
honest: two on-camera wash events each followed by immediate permanent
graying of fine dark marks (armC t≈90, auto path; soak1 t≈105,
spontaneous with autos OFF) against ~13 on-camera threshold firings
that left fine structure crisp (driver-owned, repro v1-v5) — wash
events can do per-event damage, but rarely, which matches both the
campaign's stochasticity and the repros' nulls. Two revisions cut
against the original framing: threshold=8 did not corrupt faster (that
claim is retracted), and the damaging-drive phenomenon is not exclusive
to the auto-threshold path (soak1's events fired with autos off — the
spontaneous-global family can carry the same signature). The shipped
workaround (`auto_refresh=0`, ioctl-owned washes) remains the right
call on this evidence: it removes the only REGULAR unexplained-global
source, and every ioctl wash across the dataset (~30+ on camera,
including 6 idlewasher acceptance washes) remains corruption-free. The
zero-gap mechanism (quirk F) stays the best-supported hypothesis for
HOW a wash damages state when it does; the instrumented kernel remains
the decisive instrument. The upstream draft below has been revised to
match the audited evidence.

**Instrumented run 1 (2026-07-12, A.2.7-dbg first session): the
straggler-truncation mechanism is REFUTED on this silicon for
corrupting-class workloads.** The debug kernel ran the campaign's
corrupting regime (89-turn diverse walk, threshold=8) plus rapid
same-pair toggles (60 @0.7 s) in one session: **37 threshold-fired
globals, 33 ioctl globals — zero straggler-credit warnings, zero early
wait returns, zero frame timeouts.** Threshold- and ioctl-launched
globals are metronomically identical at the handshake (596 ms actual vs
447 ms nominal, full completion, both paths). The zero-gap launch race
exists in source (quirk F stands as a latent-robustness finding) but
does NOT manifest as wash truncation here. The surviving corruption
evidence (never-a/b ghost-paints and graying, armC per-event graying,
soak1's autos-off events) therefore needs a different mechanism — the
investigation reopens at the content-bookkeeping evidence, and the
upstream report should present quirk F as a hardening opportunity, not
the demonstrated cause. (Caveat: corruption was always
session-selective; this session's optical state was not
camera-verified. A future corrupting session under the debug kernel —
camera + instrumentation combined — is the remaining falsification
path.) Bundle: `pinenote/tools/optics/build/bundles/corrupter-repro-dbg/`.

**Instrumented kernel (built offline, staged for the next device
session):** point (3)'s decisive experiment exists as
`linux-pinenote-debug` — the primary kernel (byte-identical, untouched)
plus one printk-only patch
(`pinenote/patches/linux-pinenote-debug-dspend-straggler.patch`, applied
after the forward-port patch) — and ships in the `reader-debug` flavor
(`make rootfs-reader-debug`), which differs from the production reader
image only in kernel and host name. Three log lines: (a) `ebc-dbg:
straggler credit present at global launch (threshold=… src=…
burst_timeouts=… total_timeouts=…)` — `completion_done()` was true
immediately before the global's `reinit_completion()`, i.e. an
unconsumed DSP_END existed at launch; `src` is the launch provenance
(threshold/ioctl/init/reset/resume/offscreen), recorded at every
`do_one_full_refresh` set-site. (b) `ebc-dbg: global wait returned R
after E ms (src=… phases=… expect~X ms …)` — once per global: the
wait's return value and wall time against the nominal `num_phases` ×
11.8 ms playback; E far below expect~ is a truncated wash even when (a)
stayed silent (straggler landed inside the reinit→wait window instead
of before it). (c) rate-limited `ebc-dbg: DSP_END irq with unconsumed
credit` — the straggler at its source, in the IRQ handler. Frame
timeouts are counted per-burst and in total and carried in (a)/(b), so
timeout-desync and extra-credit stragglers separate per event. Decision
table: (a)/(c) firing with `src=threshold` and never with `src=ioctl` →
the zero-gap mechanism is confirmed as analyzed; (b) early returns
without (a) → the straggler is real but arrives inside the wait window,
and the timing numbers narrow which source (late IRQ, coalescing loss,
DSP_OUT_LOW-raised END) fits; nothing ever firing across a corrupting
workload → the straggler mechanism is refuted on this silicon and the
investigation reopens at the content-bookkeeping evidence.

### Upstream notification draft (m-weigand / PNDeb / hrdl / ayakael)

> Subject: rockchip_ebc: auto_refresh threshold path can truncate its own
> global refresh (progressive panel-state corruption); PNDeb default
> config is exposed
>
> On a PineNote v1.2 running the community rockchip_ebc (m-weigand
> lineage, carried forward to 7.0.x in wilkbook) we measured, with a
> camera rig, panel-state corruption that in our dataset appears only
> in sessions running the damage-threshold path (`auto_refresh=1`):
> partial refreshes painting entire pages as barely-visible ghosts
> (restored by the next global), fine dark marks sitting at 0.2–0.4
> reflectance instead of ~0.02, and — twice, directly on camera — a
> global-class wash event followed by immediate permanent graying of
> fine dark structure (0.04 -> 0.09 across one wash).
> GLOBAL_REFRESH-ioctl washes of the same waveform were clean in every
> one of ~30+ on-camera firings. The effect is stochastic, not
> per-firing: a `refresh_threshold=8` session with ~11 camera-confirmed
> threshold firings stayed clean, as did five deliberate same-evening
> repro sessions (~45 more firings), so we cannot claim each
> threshold firing does damage — only that every session that did
> corrupt was an `auto_refresh=1` session, plus one anomalous pair of
> spontaneous global-like events (one damaging) with autos off.
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
> `refresh_threshold=20` for redraw-heavy apps — lower thresholds mean
> more threshold-path firings, i.e. more rolls of the same dice.
> Suggested minimal fix (sketch in the doc): on
> frame timeout keep waiting for that frame's END instead of proceeding,
> and yield one frame period before a threshold-fired global; also reset
> `ctx->area_count` in the global path so firings stop being
> random-phase. hrdl's redesigned driver (per-pixel scheduling, early
> cancellation of in-flight updates) most likely does not share the
> defect. Happy to share the reproducer, the optics data, and to test
> patches on hardware.

## Note (2026-07-12): four defects in the `v6.19_ebc` EXTRACT_FBS reference implementation

Found while porting the EXTRACT_FBS buffer-dump ioctl into our debug
kernel (`linux-pinenote-debug-extract-fbs.patch`; the port is the
belief-vs-glass instrument for the corruption hunt).  The reference is
hrdl's legacy branch — `v6.19_ebc @7cb827d17`,
`drivers/gpu/drm/rockchip/rockchip_ebc.c:395-415` (`ioctl_extract_fbs`)
— the implementation PNDeb/Debian users run today.  All four are
corrected in our port and pinned by the offline harness
(`pinenote/tools/ebc-logic`, dbg suite); they should be fixed in the
lineage:

1. **Size typo `1313144`.** The true `gray4_size` at 1872×1404 is
   1872·1404/2 = **1,314,144** bytes; the hard-coded `1313144` copies
   1,000 bytes short on every Y4 plane (the last ~1.07 rows of
   prev/next/final stay stale in the dump) and the phase copies
   (`2 * 1313144`) are 2,000 short of the true 2,628,288.  Fatal for a
   belief-vs-glass instrument: bottom-of-screen divergence would be an
   artifact of the dump, not the driver.  Sizes should come from
   `ctx->gray4_size`/`ctx->phase_size`.
2. **No ctx lifetime pin.** `to_ebc_crtc_state(READ_ONCE(ebc->crtc.state))->ctx`
   is read unpinned and then used for several multi-megabyte
   `copy_to_user` calls.  The ctx is kref-owned by CRTC states; an
   atomic commit landing during the multi-ms copy can swap the state
   and drop the last reference — a use-after-free.  At a reader's ~20 Hz
   commit rate during pen strokes this is a real window, not a
   theoretical one.  Fix: take the CRTC modeset lock around the pointer
   read, `kref_get` the ctx, copy, `kref_put`.
3. **NULL dereference pre-modeset.** Before the first CRTC enable the
   state's `ctx` is NULL (allocated in atomic_check); calling the ioctl
   then oopses.  Should return `-ENODEV`.
4. **Return convention.** The OR of `copy_to_user` remainders (positive
   uncopied-byte counts) is returned straight to userspace, and the
   `access_ok` result is discarded (the code's own `todo` comment).
   Should be `-EFAULT`/0.

Our port's translation notes (locking held only around the pointer
read/snapshot; the big copies deliberately lock-free with coherence as
a dump-protocol property) are in the debug patch header.  These four
items extend the standing upstream ask — they are bugs in *his* branch's
implementation, reported here rather than silently diverged from: our
in-tree function is a fresh implementation of the same ABI.
