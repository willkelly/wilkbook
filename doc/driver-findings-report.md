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
userspace via the ioctl. Needs a driver-level look at the
`do_one_full_refresh` threshold path vs the ioctl path before upstreaming.
