# E-ink state of the art — what the wider ecosystem knows (2026-07-12)

A state-of-the-art review for wilkbook, synthesized from four
adversarially-reviewed research passes (academic/standards, commercial
stacks, open-source driver ecosystem, rendering & writing), each run with
claim-level verification against primary sources. Reviewer corrections
are folded inline; where a verifier could only corroborate at
report-level (abstract, search snippet, unfetchable page), the claim says
so. Folklore is marked as folklore. Companion to `doc/eink-research.md`
(domain background — this doc deliberately does **not** repeat it),
`doc/refresh-policy.md` (findings 1–12 + Decisions), and
`doc/pageturn-program.md` (the active latency program). Corrections this
review forces on those docs are collected in §5.

Method note: one finding below (§1.1.6, the 5-bit hint states) was not
just literature — it was verified offline against this device's own
`ebc.wbf` with our `wbf` tool, and independently reproduced bit-for-bit
by the report's reviewer. The dumps are reproducible any time with
`pinenote/tools/wbf/build/wbf-info --dump-lut <MODE> 28 <out> <ebc.wbf>`.

## 1. What the wider world knows that our docs did not

### 1.1 Waveform theory

**1. The GC16 flash has a formal name and theory: rail-stabilized
driving.** `doc/refresh-policy.md` decoded *what* the flash is (all
pixels run the full LUT, diagonals included); the literature supplies
*why*: intermediate gray states are not reproducible as starting points,
so waveforms first reset pixels to a "rail" (saturated black or white,
where particle distribution reaches a physical limit state) and then
drive to target from that known reference. Accurate graytones are only
reachable from rails; the black/white excursion is the acknowledged cost.
[US7839381B2](https://patents.google.com/patent/US7839381B2/en)
(Koninklijke Philips) additionally shows rail waveforms using long frame
times for the reset portion and short frame times only near target
(20 ms reset vs 10 ms greyscale frames in its example) — time resolution
matters only near the terminal gray. A 2021 variant resets to a *black*
reference to cut the excursion
([Frontiers in Physics 2021](https://www.frontiersin.org/articles/10.3389/fphy.2021.723106/full)).
Consequence for us: GL16's (15,15)-neutral row is exactly "skip the rail
reset for already-at-rail pixels", and gray-heavy content (images) can
never get a cheap wash — grays need the rail.
wilkbook layers: waveform selection, `doc/refresh-policy.md` vocabulary.

**2. The canonical three-stage waveform anatomy: erase → activation →
drive.** Academic waveform papers decompose driving waveforms into an
erasing stage, a particle-**activation** stage (high-frequency shaking
pulses that break particle stiction/agglomeration and raise mobility),
and a drive stage
([Micromachines 2020](https://doi.org/10.3390/mi11050498);
[Micromachines 2022](https://pmc.ncbi.nlm.nih.gov/articles/PMC8875704/)
uses a 30 ms-period, 30-cycle activation square wave; both
report-level-verified). This explains the decoded GC16 white→white "14
phases driven dark" prefix as erase+activation, not waste — and it gives
PNDeb's `trim_waveform.py` failure mode ("black sometimes gray",
`doc/eink-research.md` §8) a mechanism: trimming eats the activation
stage. If we ever run a trim experiment: trim from the erase/reset side,
never the activation side.
wilkbook layers: waveform selection, workbench trim experiments.

**3. DC balance and remnant voltage are quantified in the patent
record.** E Ink defines DC balance as the pixel-wise **integral of
applied voltage over time** ≈ 0 (∫V·dt — not net charge; see §5), with a
numeric budget: imbalance **< 90 V·s accumulated over ≥ 60 s** (better:
60 min–60 h) — from the "driving methods for bi-stable displays" family
[US9373289](https://patents.google.com/patent/US9373289) /
[US10002575](https://patents.google.com/patent/US10002575) /
[US10535312](https://patents.google.com/patent/US10535312). Remnant
voltage (ionic polarization at material interfaces) has explicit targets:
< 1 V, preferably < 0.2 V, decaying within 1 s, preferably 50 ms
([US9881564](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9881564),
verbatim). Consequences of imbalance: polarization kickback (optical
state changes *after* driving concludes), altered efficacy of the next
pulse, electrode electrochemistry at the extreme. Literature mitigations:
pulse-pair ratio cancellation and **post-update discharge** (0 V hold /
drain paths)
([US8558783](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/8558783),
[US20070262949](https://patents.google.com/patent/US20070262949)).
wilkbook layers: test methodology (a per-pixel ∫V·dt accumulator in
`ebc-replay` — steal #1), driver scheduling (post-update electrode
state — §4.1).

**4. Dwell-time dependence (DTD): the (from,to) LUT model is
known-insufficient by E Ink itself.**
[WO2005101363A2](https://patents.google.com/patent/WO2005101363A2)
(verified verbatim) states the impulse needed for a transition varies
with the *residence time* in the prior state — the impulse for a 0→1
transition differs across 0-0-1 vs 1-0-1 vs 3-0-1 histories. The pixel
is **non-Markovian in (from,to)**. E Ink's production compensation is
open-loop: a "memory function M(t)" characterizing decaying
remnant-field efficacy, folded into waveform design on average — no
per-pixel history tracking exists even in their controllers. This is the
theoretical grounding for a fact our corruption hunt keeps circling:
believed-state bookkeeping can be **bit-perfect and the glass still
diverges**, because even a correct prev buffer under-specifies the
physical state. See §4.1.
wilkbook layers: test methodology (dwell-time as a controlled sweep
axis), the corruption-family taxonomy.

**5. Edge ghosting/blooming is a modeled, quantified phenomenon — and it
is our text-CLEAR shimmer.** A driven pixel's fringing field switches
medium beyond its own electrode — up to ~1/5 of a neighboring pixel
(report-level; [US11568827](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11568827))
— leaving a gray transition halo. Zeng et al. simulated it with coupled
particle-dynamics + light-scattering models, tied magnitude to
back-binder-layer thickness/dielectric constant, and validated on two
panels ([JSID 2023](https://sid.onlinelibrary.wiley.com/doi/abs/10.1002/jsid.1255));
a waveform-side countermeasure exists
([Micromachines 2018](https://doi.org/10.3390/mi9040143)). Our finding-2
shimmer (whites adjacent to *erasing* text dip 0.148 ± 0.032, absent on
text-appear) is textbook asymmetric blooming. The subtle part: halo
pixels are exactly pixels the driver correctly believes unchanged — a
**physical** believed-state divergence channel distinct from bookkeeping
bugs, and an argument for occasional whole-region washes even where the
diff says nothing changed.
wilkbook layers: test methodology (edge-halo classifier), update policy.

**6. THE HEADLINE: the REGAL machinery is physically present in our own
`ebc.wbf`, as reachable 5-bit hint states — verified on this device's
file.** The official E Ink "800-1101 REV01 AF 16 TONE GRAYSCALE 5-BIT
WAVEFORM" spec ([Waveshare mirror](https://www.waveshare.net/w/upload/c/c4/E-paper-mode-declaration.pdf);
the public PDF appears truncated after the header tables) is for exactly
our mode version 0x19 and AF type (our header byte 0x13 = 0x51 = AF ✓).
What it adds to `doc/eink-research.md` §2:

- The AF waveform is a **5-bit, 32-state representation**: graytones
  1–16 live on even states 0,2,…,30. Odd states are unused **except 29
  and 31**, which "denote graytone 16" and "are used to invoke special
  transitions to graytone 16" (§2.2).
- GLR16 (=REGAL) and GLD16 (=REGAL-D): when only even states are used
  they behave exactly as GL16 — the file "assures GLR16/GLD16 waveform
  data points to the same voltage lists as GL16" (§2.3.5–2.3.6). So
  refresh-policy's "GLR16/GLD16 sha-identical to GL16" observation is
  **by-design mode-pointer aliasing, not absence of REGAL data**.
- Verified offline on our `ebc.wbf` (28 °C bin, full 32×32 5-bit
  matrices; independently reproduced by the report's reviewer):
  - `30→29` in the GL16-family table:
    `.DDDDDDDDDDDDDDDDDDLLLLLLLLLLLLLLLLLL.` — a **full 38-phase
    black-excursion scrub for a single believed-white pixel**. A
    per-pixel GC16-grade white clean inside an otherwise GL16 update.
  - `30→31`: `...............................DLDLL..` — a 5-frame
    (~59 ms) gentle background agitation, matching the spec's GLD16
    text: "refresh the background with a lighter flash compared to GC16
    mode following a predetermined pixel map as encoded in the waveform
    file".
  - All other `g→29/31` entries are neutral (only white pixels may be
    hinted), and from-rows 29/31 behave identically to from-30 — so
    prev-state bookkeeping stays sound if hinted pixels are recorded as
    white. In the GC16 table the 29/31 targets are neutral (GC16
    already scrubs whites).
- Spec Table 1 also pins the per-mode transition domains: A2 accepts
  from-states **[0, 29, 30, 31] only**; DU accepts all even + 29/31;
  DU4 targets [0, 10, 20, 30] (tones 1/6/11/16 — promoting
  eink-research §8's search-snippet lore to primary-sourced). The A2
  bracketing rule (in via white, out via white→GC16) is now citable to
  the primary spec rather than folklore. And official ghosting ratings
  put GLR16/GLD16 at "Low" vs GL16 "Medium" — the delta is entirely the
  29/31 hinting.
- **Reachability**: our driver structurally cannot touch these today —
  `rockchip_ebc` requests `DRM_EPD_LUT_4BIT_PACKED` and keeps Y4
  prev/next buffers, so only even states are ever indexed. But
  `drm_epd_helper` already defines `DRM_EPD_LUT_5BIT`/`5BIT_PACKED`
  (that is how the dump worked). Two open questions cut both ways:
  whether the EBC hardware LUT mode can index 32 states at all (a
  29/31 experiment may be confined to direct/software-waveform mode),
  and the prev/next plumbing needed beyond Y4.
- **Licensing**: the waveform data ships in every device's file; the
  licensed piece is the host preprocessing that decides *which* white
  pixels get hinted (NXP community thread, corroborated at snippet
  level: REGAL "requires an additional algorithm on host image
  processing and is not based on tweaking the waveform" —
  [NXP thread](https://community.nxp.com/t5/Other-NXP-Products/EInk-waveform-conversion-and-REGAL-support/m-p/1134785)).
  Caveat from review: on i.MX EPDC platforms a hardware waveform engine
  also participates, so "only the algorithm is licensed" would
  overstate. The academic lens confirms independently that all public
  "how REGAL works" accounts are trade press — **folklore**; E Ink keeps
  the algorithm NDA'd
  ([Good e-Reader](https://goodereader.com/blog/e-paper/e-ink-waveforms-are-a-closely-guarded-secret)).
  The composition: the *algorithm* stays secret; the *waveform-side
  mechanism* is now primary-sourced and decoded from our own file.

What REGAL is *for*, from the patent side:
[US11520202B2](https://patents.google.com/patent/US11520202B2/en)
(E Ink) describes content classification selecting waveform families
("GL16 … for display text, … GC16 … for grayscale images, … GCC16 …
for color"), Regal algorithms "configured to clear edge ghosting or
blooming artifacts" — i.e. REAGL is fundamentally an
**edge-ghost/blooming corrector**, not a background scrubber — and
"twiddle pulses" (variable count and location, plus top-off pulses)
that erase edge ghosting **without any full-screen refresh**. Kindle's
own header calls REAGL a "Ghost compensation waveform"
([mxcfb-kindle.h](https://github.com/koreader/koreader-base/blob/master/ffi-cdecl/include/mxcfb-kindle.h)).
This collapses refresh-policy finding 2's dilemma ("the only mechanism
that re-scrubs whites is a GC16 deep clean") from an architectural truth
to a limitation of our 4-bit driver path.
wilkbook layers: waveform selection, driver scheduling (community-owned
5-bit path), test methodology (replay hint policies offline; optics can
measure 30→29 ≡ GC16-white-scrub equivalence), wbf tool (decode 29/31
sub-tables as first-class — no open decoder we found does, a lead).

**7. Our `.wbf` carries sections our decoder ignores.** Header byte
0x27 (AWV) = **0x03** on our file: it ships both a Voltage Control
Information (VCI) section and an **Algorithm Control** section
(plausibly the GLD16 "predetermined pixel map" and/or REGAL
parameters) — unparsed by our tool, by
[inkwave](https://github.com/fread-ink/inkwave)
([issue #13](https://github.com/fread-ink/inkwave/issues/13)), and as
far as we found by any open decoder (lead, not proven). Header byte
0x19 (VCOM OFFSET) = 0x00, whose spec meaning is "applied VCOM =
module-flash VCOM **plus the VCOM_OFFSET in the VCI**" — our stack
programs the TPS65185 with the bare per-device VCOM, so if our VCI
carries a nonzero offset we are ignoring a spec-mandated correction.
Decodable, offline-checkable. (Implementation caution from review: the
spec's CS1 checksum range "bytes 0-30" is decimal-vs-hex ambiguous —
verify before coding.) Also worth pinning as a `quirk:` test: the
driver-enum↔file-mode index mapping (driver GL16=6 vs file mode 3 —
different index spaces, currently only pinned by inference; spec
Table 2 is the authority).
wilkbook layers: wbf tool, waveform selection (VCOM fidelity).

**8. Adaptive/ML waveform work exists and is recent** (all
report-level, paywalled abstracts): CNN ghost recognition + NN-driven
dynamic waveform adjustment
([JSID 2025 review](https://sid.onlinelibrary.wiley.com/doi/10.1002/jsid.70044?af=R)),
an auto-iterating optimization rig tuning response time on real hardware
([SID Digest 2025 P-12.21](https://sid.onlinelibrary.wiley.com/doi/abs/10.1002/sdtp.19152?af=R)),
dynamic programming over a physical simulation to jointly minimize
ghost/flicker/response
([JSID 2025](https://sid.onlinelibrary.wiley.com/doi/abs/10.1002/jsid.2113)).
Every one needs exactly the apparatus we already own (decoder +
deterministic replay + camera scoring). The realistic wilkbook-scale
version is not LUT synthesis (DC-balance risk, per-device .wbf policy)
but **auto-search over the policy space we already expose**, with the
optics rig as fitness function. The field's consolidated reference is
the "Driving Waveforms and Image Processing for Electrophoretic
Displays" chapter in *E-Paper Displays* (ed. Bo-Ru Yang, Wiley 2022,
[ch. 3](https://onlinelibrary.wiley.com/doi/10.1002/9781119745624.ch3)).

**9. EPDiy independently converges on GL16's structure — and hand-rolls
waveforms wholesale.** The [EPDiy](https://github.com/vroland/epdiy)
project (active, ESP32-S3 driving bare panels via the LCD peripheral —
the same "abuse a scan-out engine" trick as rM2/EBC direct mode)
*generates* waveforms per panel: GC16 as a drive-to-black then lighten
ramp (15+15 frames), and its generated GL16 is the same table with
diagonal entries zeroed — a convergent diagonal-neutral structure
(EPDiy additionally zeros black→black, where our .wbf's GL16 neutralizes
only (15,15)). Their grayscale axis is **per-frame duration modulation**
(phase times 0.3–120 ms per panel-specific tables) rather than a fixed
frame clock — an axis our fixed-85 Hz EBC cannot exercise. Folklore,
marked as such: the EPDiy community has driven panels for years on
hand-made, not-necessarily-DC-balanced waveforms without reported mass
film degradation — informal counterevidence to strict
"never-leave-the-shipped-LUTs" dogma; no controlled aging data exists.
It calibrates (but does not license) trim experiments.
wilkbook layers: waveform selection (independent structural validation
of our GL16 decode), workbench.

### 1.2 Driver architecture

**10. There are exactly three proven architectures for concurrent
regional + global updates**, ranked by where the complexity lives:

1. **Hardware multi-LUT + collision queue** (i.MX EPDC: 16 LUT engines
   in V1, 64 in V2 → MTK "hwtcon"). Verified mechanics from
   [mxc_epdc_v2_fb.c](https://github.com/nxp-imx/linux-imx/blob/lf-6.6.y/drivers/video/fbdev/mxc/mxc_epdc_v2_fb.c):
   each in-flight update owns LUT(s); on overlap the update parks on a
   collision list with a `collision_mask` of the LUTs it hit; when the
   mask clears it is **resubmitted with waveform mode forced to AUTO**;
   queue merge is tri-state (OK/FAIL/BLOCK); dry-run
   `EPDC_FLAG_TEST_COLLISION` updates are never merged; and
   **REAGL/-D quality updates are demoted if they would collide**
   ("collision detected, can not do REAGL/-D"). Complexity lives in
   driver queue policy.
2. **Per-pixel state + early cancellation** (Modos Caster in silicon;
   xochitl SWTCON and timower's reimplementation in userspace; hrdl in
   kernel). No collision concept at all — overlap resolves per pixel
   per frame. Complexity lives in memory bandwidth and state layout:
   Caster's price is explicit, 4.5 B/px/frame vs 1 B/px for region
   controllers.
3. **Single-update-in-flight + merging** (waved; our
   m-weigand-lineage `rockchip_ebc`). Simplest — and exactly where our
   bug classes (prev-buffer desync, one global `refresh_waveform`,
   serialization) live.

The cheapest class-1 robustness ideas that fit our class-3 driver
without a per-pixel port: (a) collision-mask/defer/resubmit semantics in
the software area queue, (b) resubmitted regions re-decide their
waveform from content, (c) quality-mode-only-when-collision-free as a
scheduling invariant. All three are expressible in `ebc-replay` today.

**11. The mxcfb contract outlived its silicon — and the MTK generation
grew the UAPI we keep wishing for.** Both Kindle and Kobo left i.MX for
MediaTek and **reimplemented the same update-struct contract** —
`{region, waveform_mode, update_mode, marker, temp, flags, dither_mode}`
plus WAIT_FOR_UPDATE_COMPLETE/SUBMISSION — across a full silicon-vendor
change, 15 years running
([mtk-kindle.h](https://github.com/koreader/koreader-base/blob/master/ffi-cdecl/include/mtk-kindle.h),
[mtk-kobo.h](https://github.com/koreader/koreader-base/blob/master/ffi-cdecl/include/mtk-kobo.h),
all constants verified). Per-update features now in that UAPI, none of
which exist in any open PineNote stack (framing is a lead, not an
exhaustively-proven negative):

- **In-driver dithering selection per update**: Kindle {passthrough,
  Floyd-Steinberg, Atkinson, ordered, quant-only}; Kobo encodes
  algorithm × target depth (Y8→Y4/Y2/Y1).
- **Night-mode waveform families** GCK16/GLKW16 (+GCK16_PARTIAL):
  dedicated LUTs for white-on-black rendering. (The K = black-background
  reading is community interpretation à la FBInk, not header text.)
- **Hardware swipe animation**: `MTK_EPDC_FLAG_ENABLE_SWIPE` +
  `mxcfb_swipe_data{direction, steps}` — page-turn animation executed
  by the display pipeline.
- **Pen-oriented A2**: Kobo `HWTCON_FLAG_FORCE_A2_OUTPUT` with
  _WHITE/_BLACK variants and auto pen-color detection.
- **Userspace temperature override**: `HWTCON_SET_TEMPERATURE` /
  `MXCFB_SET_TEMPERATURE` + GET — the temp-bin choice is UAPI there.
- **`HWTCON_GET_WORK_BUFFER`** — live working-buffer readback: their
  EXTRACT_FBS, as a shipping ioctl.
- **GC16 auto-degrades to GL16 on PARTIAL** in the Kobo driver
  (mtk-kobo.h:95) — our Decision 3 ("partials: GL16 ≡ GC16")
  implemented as driver policy.
- Kindle-side scheme enum: `UPDATE_SCHEME_SNAPSHOT` (framebuffer
  captured at ioctl time — atomic content-with-request), `QUEUE`, and
  `QUEUE_AND_MERGE`; plus `MXCFB_SET_PAUSE`/`SET_RESUME`/
  `CLEAR_UPDATE_QUEUE` and two-stage completion (submission vs
  complete, marker-based).

Pacing folklore worth knowing (KOReader source comments, marked
folklore): on both MTK vendors userspace must yield ~175 ms to the EPDC
or highlights get optimized out/flicker; Kindle waits on the *previous*
update's submission, Kobo MTK on the *just-sent* one
([framebuffer_mxcfb.lua](https://github.com/koreader/koreader-base/blob/master/ffi/framebuffer_mxcfb.lua)).
wilkbook layers: driver scheduling (this is the priority-ordered menu
for any future hint UAPI), KOReader render.

**12. The reMarkable 2 software-TCON ecosystem is now readable source,
three ways.** Beyond eink-research §3's existence-proof:
(a) [rm2fb](https://github.com/ddvk/remarkable2-framebuffer) wraps
xochitl's swtcon (LD_PRELOAD; clients send `{rect, waveform, flags}`
over shm+msgq). Per the rm2fb README's mapping table, xochitl's internal
tables collapse the public modes into **four** classes (DU/pen,
GL16+INIT shared, GC16/UI, A2/pan) — a shipped product runs on a
handful of internal waveforms. (b)
[timower's clean reimplementation](https://github.com/timower/rM2-stuff)
(supported through xochitl 3.23): vsync + generator threads, a ring of
**16 pan buffers** ("phases") panned via FBIOPAN, **per-phase per-column
dirty tracking** (`dirtyColumns[phase][x]`), and concurrent regional
updates **composited into the shared upcoming phase frames** rather than
queued per-update; temperature re-read every 60 s. (c)
[waved](https://github.com/matteodelabre/waved) (GPL-3, zero xochitl
code): parses the device's own .wbf; generator/vsync thread pair;
same-mode update merging; and — verified verbatim — the **"prevent
frying pan" mode**: its buffer holds 17 frames and frame 16 is kept
permanently null because the MXSFB driver auto-flips to the *last*
frame after each vsync unless re-panned — a hardware dead-man's-switch
guaranteeing no charge is held on the film if the software wedges
(`lib/display.hpp` ~187–202). waved also ships `ENABLE_PERF_REPORT`:
per-update CSV with per-frame generate and vsync completion timestamps.
(The reMarkable Paper Pro reportedly moved to an E Ink hardware TCON
for color — **folklore**, unconfirmed:
[Good e-Reader](https://goodereader.com/blog/electronic-readers/everything-you-need-to-know-about-the-remarkable-paper-pro-with-color-e-paper).)
wilkbook layers: driver scheduling (per-column dirty + shared-phase
composition is a middle rung between our area queue and hrdl's
per-pixel port), test methodology (frying-pan-style neutral-scanout
assertion for rung 7a; waved's timestamp schema for ebc-replay).

**13. Modos Caster/Glider: an open (CERN-OHL-P) per-pixel EPDC, with
reusable tooling.** [Caster](https://github.com/Modos-Labs/Caster) /
[Glider](https://github.com/Modos-Labs/Glider) (crowdfunded dev kit
Aug 2025; [CNX](https://www.cnx-software.com/2025/08/06/fpga-modos-paper-dev-kit-supports-e-ink-displays-75-hz-refresh-rate/)):
**16 bits of state per pixel** (two 4-bit old values + a per-pixel
frame counter — note: two history values is also what REAGL-class edge
compensation needs), every pixel its own update region, early
cancellation (retargeted mid-drive pixels get their counter recomputed),
<20 µs processing latency, and **hybrid greyscale**: fast binary
per-pixel while content changes, automatic greyscale re-render once it
settles — hrdl's `redraw_delay` generalized to per-pixel, in silicon;
Modos notes commercial e-readers have no incentive to build this.
Hardware Bayer/blue-noise/error-diffusion dithering at no added
latency. Defines **IWF (Interchangeable Waveform Format)** — ini
descriptor + per-LUT CSV — **with converters from E Ink .wbf** and iMX
formats: the only public waveform interchange attempt, and an
independent decoder to cross-check `pinenote/tools/wbf` against. Their
EPDC logic is tested in RTL simulation offline — the same ladder
philosophy as ours, in silicon.
wilkbook layers: driver scheduling (the design ceiling for per-pixel),
dithering, test methodology (IWF cross-validation).

**14. Mainline status: "the patch is permanent" re-verified, one
nuance.** No EPD infrastructure has landed or been re-proposed since
the 2022 RFCs (search-absence over patchwork + dri-devel archives:
probably true, unproven). Linux 6.18 did add a second e-paper driver —
`drm/tiny` **Pixpaper** (122×250 SPI panel; no waveforms, no EPD helper;
[Phoronix](https://www.phoronix.com/news/Linux-6.18-DRM-Pixpaper)) —
tiny SPI panels trickle in; controller-class infrastructure does not.
Kemnade is mainlining EPD *peripherals* (regulators, PMIC DTS) while
the EPDC display driver itself stays out-of-tree after 4+ years. Other
RK3566 EBC vendors remain closed: Boox (ongoing GPL violation, no
kernel source), PocketBook (B288 e-ink path is a closed blob that
"emulates the MXC interface but works rather differently" —
[koreader-base #1202](https://github.com/koreader/koreader-base/issues/1202),
now a primary source for eink-research §7's cautionary tale). PineNote
is still the only open RK3566 e-ink stack.
wilkbook layers: kernel forward-port planning; the "emulate mxcfb
faithfully or not at all" rule, reinforced.

### 1.3 Update policy

**15. KOReader's policy machinery is a fixed slot vocabulary — and
`fast` is DU, not A2, on every device.** The per-device policy is named
slots: `waveform_a2, fast, ui, flashui, partial, full, reagl, night,
flashnight` ([framebuffer_mxcfb.lua](https://github.com/koreader/koreader-base/blob/master/ffi/framebuffer_mxcfb.lua),
verified). Kobo mk7+: a2=A2, fast=DU, ui=AUTO, full=GC16,
**partial=REAGL**; Kindle zelda: partial=GLR16. A2 is reserved for the
explicit `a2` refreshtype (panning/scrolling). Night mode gets dedicated
K-waveforms on newer panels; **our mode-0x19 file has none**, so
KOReader nightmode on PineNote will software-invert through normal
modes — under GL16 globals that preserves exactly the wrong thing
(whites are now content). Two corollaries: our native
`framebuffer_rockchip.lua` should implement the slot vocabulary; and
nightmode policy should flip washes to GC16 while inversion is on.
wilkbook layers: KOReader render, waveform selection.

**16. Quality page turns demand an empty pipeline — as shipping
discipline.** KOReader submits REAGL partials as `UPDATE_MODE_FULL`
(full-screen, *non-flashing*) and **blocks on the previous update's
completion marker before submitting any REAGL update** (verified). The
quality turn is deliberately never allowed to collide with an in-flight
update. Composes with EPDC's driver-side version (REAGL demoted on
collision, §1.2.10). This is external validation of pageturn-program
d2/the quiesce-fence shape, from two independent layers of the
commercial stack.
wilkbook layers: KOReader render, driver scheduling; workbench-testable.

**17. AUTO mode is in-kernel content classification.** The i.MX EPDC
implements `WAVEFORM_MODE_AUTO` by running a PxP **histogram over the
update region** and picking the waveform from status bits (DU/GC4/GC8/
GC16, falling back up the ladder to GC32 —
[mxc_epdc_fb.c](https://github.com/UDOOboard/Kernel_Unico/blob/master/drivers/video/mxc/mxc_epdc_fb.c),
verified; the per-update `hist_bw/hist_gray_waveform_mode` fallback
fields are Kindle/Kobo UAPI, not the NXP file). KOReader's `ui=AUTO`
*depends* on this — much of "per-update waveform mapping" is actually
delegated to kernel content analysis. ("GL16 is what AUTO often falls
back to" is vendor-kernel lore in tension with the verified code ladder
— marked folklore.) For us this is the one route to AUTO semantics with
**no new UAPI**: the driver already diffs Y4 buffers per damage rect;
histogramming the rect (all-B/W → DU, else GC16) is community-owned
driver work, prototypable as a replay policy first — or a KOReader-side
prepass ("is this damage rect strictly B/W?") in our native fb target.
wilkbook layers: driver scheduling, KOReader render.

**18. The tap-feedback and coalescing semantics worth copying.**
flash_ui v3 ordering: highlight (fast) → fence (force queue drain) →
wait on marker → run callback → enqueue unhighlight *before* the
callback result repaint ([PR #7262](https://github.com/koreader/koreader/pull/7262)).
`setDirty` only enqueues; rects merge at repaint; refreshtypes form a
priority lattice (`full > flashpartial > flashui > partial > ui > fast >
a2`); and **only partial-class refreshes advance the flash-promotion
counter** — UI damage deliberately doesn't
([uimanager.lua](https://github.com/koreader/koreader/blob/master/frontend/ui/uimanager.lua)).
Our idle-washer's debt accounting should mirror that last rule: menu/UI
damage must not accrue wash debt.
wilkbook layers: KOReader render, idle-washer.

**19. Boox's two-tier ghost management matches finding 10.** Via the
KOReader Android launcher work
([android-luajit-launcher #250](https://github.com/koreader/android-luajit-launcher/pull/250);
thin sourcing, mostly SDK constants): Boox runs system-owned auto washes
*plus* app-requested modes, and apps must explicitly opt out of the
system's flashes — the commercial cousin of our
"`auto_refresh=0`, own all washes from userspace" policy. Their
`HAND_WRITING_REPAINT_MODE` is precedent for a first-class
pen-repaint policy slot. (X-mode lore: community folklore.)
wilkbook layers: update policy architecture (validates finding 10's
shape), future pen surface.

**20. "Fast now, clean later" has deep prior art at every layer.**
Patents: Ricoh
[US8416197](https://patents.google.com/patent/US8416197B2/en) (pen
strokes rendered immediately, independent of display cadence; also —
patent-encumbered, E Ink-assigned — predictive pre-activation with
DC-balanced undo), E Ink
[US10282033](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10282033) /
[US9996195](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9996195)
(draw segments with a short low-contrast waveform first, re-render with
the full-contrast scheme) — report-level. Silicon: Caster hybrid mode
(per-pixel). Kernel: hrdl `redraw_delay`. Userland: KOReader flash_ui;
Onyx `openRawDrawing`/post-lift reconcile with a user-facing "time to
refresh after lifting stylus" knob
([Onyx Pen SDK](https://github.com/onyx-intl/OnyxAndroidDemo/blob/master/doc/Onyx-Pen-SDK.md));
Microsoft wet/dry ink
([US9633466](https://patents.google.com/patent/US9633466B2/en)). Our
idle-washer and pageturn policy (a) sit squarely in this lineage. The
refinement frontier is **granularity**: Caster re-renders only pixels
last driven fast; hrdl's REDRAW hint is per-rect; our wash debt is a
scalar today.
wilkbook layers: KOReader render, idle-washer (per-region debt),
future pen surface.

**21. E Ink itself sells shortened waveforms.** `GC16_FAST`/`GL16_FAST`
("medium fidelity") are shipped Kindle modes — commercial precedent
that trimmed GC-class waveforms are a legitimate product tier, not just
PNDeb hackery. Combined with §1.1.2's trim-side rule, a trimmed-GL16
page-turn candidate is a defensible workbench experiment.
wilkbook layers: waveform selection, workbench.

**22. Frontlight choreography conceals flashes.** Kindle's
`MXCFB_SET_NIGHTMODE` behavior is documented in the header comments
(verified verbatim): before a GCK16 wash, **drop the frontlight to zero
and restore it gradually** (per-platform stride constants). We own the
backlight device — flash concealment by frontlight dip is pure
userspace on our stack, a zero-driver-work comfort feature no open
stack has. The optics rig can quantify perceived-flash reduction
directly.
wilkbook layers: KOReader render; camera validation.

### 1.4 Rendering and writing

**23. The DU/antialiasing contract, industry-wide.** On every mxcfb
device, a DU update without dithering sets `EPDC_FLAG_FORCE_MONOCHROME`
— the controller threshold-binarizes the region *in the update path*,
explicitly to (KOReader's comment) "crush antialiasing on text"; with
dithering it sets `quant_bit=1` + ordered dither instead. The
framebuffer always keeps grayscale AA; **binarization/dithering happens
only per-update, at update time**. Never feed raw AA grays to DU; let
the next quality pass restore AA. Our equivalents are `bw_mode`/
`bw_threshold=7` (threshold) and hrdl-style tables (dither); the native
fb target needs a per-update choice between them for `fast`/`a2`. The
PineNote community's own ground truth agrees (Xournal++ AA "does not
work well" on A1;
[Pine64 wiki](https://wiki.pine64.org/wiki/PineNote_Development/Apps)).
wilkbook layers: KOReader render, driver scheduling; rastersim can
measure glyph-stroke survival at threshold 7.

**24. The dithering verdict for diff-masked e-ink paths: error
diffusion is disqualified by masking, not quality.** Ordered/threshold
dithers (Bayer, blue-noise) are position-deterministic — unchanged
source pixels dither identically and diff-mask to nothing. Error
diffusion is globally input-dependent: any content shift re-randomizes
downstream pixels, producing spurious diffs — peterme's e-paper-laptop
writeup names this the "dependency problem" and reports visible
"lightning" artifacts on shifting content
([peterme.net](https://peterme.net/building-an-epaper-laptop-dithering.html);
his ~280× speed figure is GPU-ordered vs CPU-Floyd-Steinberg — hardware
confound, don't quote as algorithm cost). Quality pick: blue-noise
threshold matrix ("looks best most of the time" on rM DU updates —
[rmkit PR #63](https://github.com/rmkit-dev/rmkit/pull/63)); cheap
pick: Bayer; what silicon ships in fast paths: ordered (Kobo mk7).
For DU4, dither to the panel's actual 4-tone targets {1,6,11,16}. A
gamma question rides along from Modos' gamma-aware dithering: are we
dithering in sRGB or linear?
wilkbook layers: dithering (wherever it lands — fb blit or driver);
rastersim can quantify driven-pixel counts under scroll for ED vs
blue-noise, making the disqualifier a measured claim on our stack.

**25. Dithering is applied surgically, not globally.** KOReader enables
HW dithering only for screensaver, ImageViewer, book covers, and reader
pages where **image content exceeds 7.5% of screen area** — rationale
(NiLuJe): "quantization is [technically] a highly destructive process";
dithering text degrades it
([PR #4541](https://github.com/koreader/koreader/pull/4541), verified).
Dither is a per-refresh parameter riding alongside the refreshtype.
wilkbook layers: KOReader render (content-classifier-gated dithering).

**26. Text legibility levers around binarization** (folklore until
measured): KOReader users pair per-document gamma (1.2–2.6) with
synthetic base font weight ("+1 weight step before +1 size step");
mechanistically — inference — thicker strokes + higher gamma push AA
halo pixels across the binarization threshold so DU-crushed glyphs keep
their skeleton. rastersim can turn this folklore into a
stroke-preservation-vs-gamma/weight curve under `bw_threshold=7`, and
the rig can validate the winner.
wilkbook layers: KOReader render defaults, test methodology.

**27. Pen latency: the perceptual budget is ~50 ms for inking, not
2 ms.** Annett/Ng HPSS studies: latency JNDs while *inking* are ~50 ms
median (drawing 21–82 ms, writing 32–87 ms, overall median 53 ms), vs
2–7 ms for dragging UI objects
([GI 2014](https://webdocs.cs.ualberta.ca/~wfb/publications/C-2014-GI-Latency.pdf),
[CHI 2014](https://webdocs.cs.ualberta.ca/~wfb/publications/C-2014-SIGCHI-Latency.pdf);
the paper attributes higher inking thresholds to cognitive/attentional
task demands — a visible stylus actually *improves* latency
discrimination). rM2's famous ~21 ms is past diminishing returns; our
A2's 118 ms playback overshoots the budget but ink is visible from the
first darkening phases, well before completion (inference — measurable
on the rig). Prediction is optional garnish, not required. The portable
pen pattern (from Onyx/Microsoft/rM2, §1.3.20): wet strokes as small
stroke-following DU/A2 rects with binarized pixels, an exclusion-rect
input gate (pairs with our mixedrouter work), and a post-lift GC16-class
partial reconcile on a timer.
wilkbook layers: future pen surface, driver scheduling (the structural
bottleneck is our one-update-in-flight queue).

**28. Render-layer ghost compensation is publishable, working
research.** "Ghostbuster" (Hu et al., IEEE TCAD 43(11) 2024, pp.
3780–3791, [IEEE Xplore 10745867](https://ieeexplore.ieee.org/document/10745867/);
paywalled, corroborated bibliographically) builds analytical models
*predicting* ghosting under fast-refresh regimes and **adjusts the
source image** to counteract the predicted shift, validated on real EPD
hardware, from a real-time-systems lab. The strongest external
validation that ghost management can live in userspace pixel
preparation — and of the ebc-replay premise (model in software, verify
on camera). A bounded future experiment: predicted-residue-aware
pre-biasing of grays at render time, scored by the rig.
wilkbook layers: KOReader render (research-grade, not near-term).

### 1.5 Measurement methodology

**29. Our rig has a standards anchor — and it's 62679-3-3, not 3-1.**
[IEC 62679-3-1:2014](https://cdn.standards.iteh.ai/samples/19758/f2179b92d8d84ad6b0e270f8aafabf8f/IEC-62679-3-1-2014.pdf)
is the international EPD optical-measurement standard (verified against
the official preview): reflective mode, integrated lighting **off**,
25 ± 3 °C, dark room (background ≤ 1/100 of black-state radiance),
directional source 45°/detector 0°, indoor metrics at 300 lx diffuse +
200 lx directional, §5.11 defines a ghosting characterization pattern,
§5.5 grayscale-matrix cross-talk via window patterns. Critically,
**[IEC 62679-3-3:2016](https://www.intertekinform.com/en-us/standards/nen-iec-62679-3-3-2016-822172_saig_nen_nen_1961289/)
covers optical measurement with the integrated lighting unit on** — our
frontlight-as-illuminant rig is formally a 3-3-type measurement. SID
IDMS v1.2 (2023, free download) has a checkerboard residual-image
method — the standards-track ancestor of our test card's toggle block
([overview](https://sid.onlinelibrary.wiley.com/doi/full/10.1002/msid.1241);
details report-level). Academic convention: **"flicker intensity" = max
luminance excursion on the luminance-vs-time curve during an update** —
our "flash depth" is the same quantity; ghosting = gray-value delta vs
intended state; a representative rig (Admesy Arges-45 colorimeter)
samples at 0.11 s — our 30 fps camera out-samples the field's
instrument ([PMC8875704](https://pmc.ncbi.nlm.nih.gov/articles/PMC8875704/)).
Adopting the names and citing the standards makes our numbers
externally legible at zero instrument cost.
wilkbook layers: test methodology / `pinenote/tools/optics` docs.

**30. No closed-loop optical-feedback EPD driving was found in the
literature** — photodiode-feedback patents exist for emissive displays,
not reflective EPD matrices; E Ink's production answer to state
divergence is open-loop (M(t) compensation + discharge + rail resets).
This is an **absence-of-evidence claim from a search**, not a sourced
fact — but it strengthens §3's novelty assessment.

## 2. The steal list

Ranked by evidence-per-effort. "Rung" = cheapest validation:
**docs** < **offline tools** (wbf/ebc-logic/rastersim/koreader-input,
rung 0–3) < **workbench** (`ebc-replay`, rung 7a) < **instrumented
kernel** (dbg v2 session) < **camera** (optics rig).

| # | Steal | Layer | Cheapest rung |
|---|---|---|---|
| 1 | **Per-pixel DC-imbalance (∫V·dt) accumulator** in ebc-replay; budget yardstick < 90 V·s over ≥ 60 s (§1.1.3). Film-stress metric per policy candidate; also a corruption-hunt discriminator (§4.1) | test methodology | offline tools |
| 2 | **wbf tool: decode the 29/31 hint sub-tables + VCI/Algorithm Control sections; check the VCOM offset; `quirk:`-pin the 0x19 driver-enum↔file-mode mapping** (§1.1.6–7; CS1 range ambiguity caution) | wbf tool / waveform selection | offline tools |
| 3 | **Quiesce-fence + post-flush wash ordering** — KOReader REAGL discipline + Kindle SNAPSHOT semantics (§1.3.16, §1.2.11); confirms and upgrades pageturn d2 | KOReader render / driver scheduling | workbench |
| 4 | **Blue-noise threshold-matrix dithering for fast modes** (DU per-update threshold-or-dither choice; DU4 dithered to {1,6,11,16}); **ban error diffusion from diff-masked paths**, measured (§1.4.23–24) | dithering / KOReader render | offline tools → camera |
| 5 | **Dwell-time sweep + no-drive relaxation microtests** (same transition, varied dwell; burst-of-partials then long camera dwell with zero driving) (§1.1.4, §1.1.3) | test methodology | camera (cheap protocol add) |
| 6 | **Content-histogram AUTO per damage rect** (all-B/W → DU, else GC16) — driver-side (community-owned) or KOReader prepass (§1.3.17) | driver scheduling / KOReader render | offline tools → workbench |
| 7 | **Re-anchor rig docs**: IEC 62679-3-3, IDMS checkerboard mapping, "flicker intensity" naming (§1.5.29) | test methodology | docs |
| 8 | **Night-mode policy**: flip washes to GC16 under inversion (no K-modes in our file) + **frontlight-dip flash concealment** (§1.3.15, §1.3.22) | KOReader render | offline (rung 4) → camera |
| 9 | **Per-region wash debt** (idle-washer scalar → rects last painted fast) — the granularity frontier of fast-now-clean-later (§1.3.20) | idle-washer | workbench |
| 10 | **UI damage must not accrue wash debt** (KOReader promotion-counter rule) (§1.3.18) | idle-washer / KOReader render | offline tools (koreader-input) |
| 11 | **Collision-semantics policy experiments**: defer/resubmit with re-decided waveform; quality-only-when-quiescent as invariant (§1.2.10) | driver scheduling | workbench |
| 12 | **Frying-pan neutral-scanout assertion** in the rung-7a fake device (stalled refresh thread ⇒ scan-out lands neutral) (§1.2.12) | test methodology | offline tools |
| 13 | **waved-style per-frame generate/vsync timestamps** as ebc-replay's metrics schema; **Modos IWF converters** as a decoder cross-check (§1.2.12–13) | test methodology | offline tools |
| 14 | **Gamma/font-weight × bw_threshold stroke-survival curves** (turn §1.4.26 folklore into a curve) | KOReader render | offline tools → camera |
| 15 | **Trimmed GL16/GC16 "FAST" wash candidates** — trim the erase side, never activation; commercial precedent GC16_FAST (§1.1.2, §1.3.21) | waveform selection | workbench → camera |
| 16 | **Edge-halo classifier** for the rig (spatial rings around driven regions vs in-region residue) (§1.1.5) | test methodology | offline tools (synthetic clips) |
| 17 | **5-bit hint experiment**: hint stale believed-whites to 29 during a GL16 wash (selective deep clean, no black flash); 31 + blue-noise spatial mask as an unlicensed REGAL-D stand-in (§1.1.6). Gated on the EBC 32-state question; community-owned driver work | waveform selection / driver scheduling | workbench (hint-policy replay) → camera |
| 18 | **Pen program pattern**: wet DU rects + exclusion-rect gate + post-lift reconcile + user knob (§1.4.27, §1.3.19–20) | future pen surface | offline tools (koreader-input) |
| 19 | **Render-layer ghost pre-compensation** (Ghostbuster-shaped) (§1.4.28) | KOReader render | workbench → camera |
| 20 | **Policy auto-search** with the rig as fitness function — the field's direction (§1.1.8), over our existing policy space, not LUT synthesis | test methodology | workbench → camera |

Items 1–2 are pure offline and produce new instruments; 3–4 feed the
page-turn program directly; 5 feeds the corruption hunt. Everything at
"workbench" or cheaper needs zero glass time to reach a go/no-go.

## 3. What wilkbook has that the wider ecosystem lacks

Candid, in both directions.

**Genuinely novel, as far as four research passes could determine:**

- **The calibrated optics rig as a policy instrument.** No open
  community (PineNote, reMarkable, Kobo/Kindle modding) has an optical
  measurement rig at all (re-confirmed; closest prior art remains
  Krasnow-style scope hacking). Academic practice is LED + photodiode
  point measurements at ~110 ms sampling — our 30 fps full-frame camera
  out-samples the field's instrument and adds spatial attribution. The
  standards (IEC 62679, IDMS) define patterns and metrics but we found
  no open implementation.
- **The closed loop.** Nothing in the literature closes the loop
  between driver-believed state and measured glass state
  (§1.5.30 — absence-of-evidence). E Ink's own production stack is
  open-loop by design. EXTRACT_FBS (once ported — it is stubbed in our
  7.0 kernel, see `doc/pageturn-program.md` §5.2) + the calibrated
  camera is a comparison rig the field does not have. Worth saying
  explicitly in the community-facing report.
- **Verbatim-driver host execution.** Rung 7a + ebc-replay execute the
  *shipping* driver's refresh machine offline. The nearest analogue is
  Modos testing Caster's RTL in simulation — same philosophy, different
  substrate; no kernel-driver community does this. The 2025
  auto-iteration literature (§1.1.8) needs exactly the
  decoder + deterministic-replay + camera-fitness triple; we own all
  three pieces and nobody else owns more than one.
- **The evidence-audit culture.** Per-claim verdicts, corrections
  preserved inline, instrument-artifact hunting (the 2026-07-12 audit)
  — unusual even by academic standards, and the reason this doc can be
  trusted to be wrong loudly rather than quietly.
- **Firsts on the platform**: only public 7.0.x, only PREEMPT_RT
  PineNote, only native KOReader framebuffer target (no compositor),
  pen-barrel page turns, and — new with this review — the first decode
  of the 29/31 hint states in a PineNote waveform (no open decoder
  parses them; lead-grade negative).
- **The attributed transition corpus** (110 partials with
  per-update wash attribution, `doc/pageturn-program.md` §1) — the MTK
  drivers can report what they did, but nobody publishes joined
  intent↔action↔glass datasets.

**What the ecosystem has that we lack** (the honest column):

- Per-update waveform selection UAPI — 15 years of mxcfb practice; we
  have two global module params (refresh-policy "Context").
- Per-pixel scheduling + early cancellation — three public
  implementations (Caster, xochitl/timower, hrdl); we serialize
  back-to-back turns (pageturn ground truth 9).
- In-path dithering — our fourtone path is pure thresholding (task 26);
  MTK does per-update algorithm × depth in hardware.
- Night-mode waveforms, working-buffer readback as shipping UAPI,
  collision introspection, hardware swipe animation.
- Any pen path at all; and our camera undersamples fast waveforms
  (pageturn §2.3) where academic colorimeters and Caster's counters do
  not.

## 4. Implications for the two open hunts

### 4.1 The session-selective corruption mechanism

State of the hunt (`doc/driver-findings-report.md`, instrumented run 1):
the straggler-truncation mechanism is **refuted on this silicon** for
corrupting-class workloads; the run-level correlation with
`auto_refresh=1` survives; per-event damage is rare, stochastic, and not
exclusive to the threshold path (soak1's autos-off events); corruption
comes and goes within one boot; ioctl washes (~30+ on camera) have never
corrupted. The investigation reopened at content-bookkeeping evidence.

The external physics adds three candidate channels that require **no
driver bug at all**, and a taxonomy the report should adopt:

1. **Dwell-time dependence (§1.1.4) predicts the diverse-vs-same-pair
   split we measured.** DTD says drive efficacy depends on per-cell
   residence-time history, not just (from,to). Diverse-page walks
   generate wide dwell/history diversity per cell; same-pair toggles
   generate uniform, short histories. The physics therefore predicts
   diverse content diverging where toggle soaks stay clean — exactly
   finding 9's discrimination — with bit-perfect bookkeeping. What DTD
   does *not* explain: session-selectivity within the same regime
   (never-c clean at 18:15 between corrupt runs), or the two on-camera
   wash-adjacent graying events. So: candidate contributor, not the
   whole story. Discriminating test: steal #5's dwell-controlled sweep
   (same transition, varied dwell → ghost delta).
2. **Remnant voltage / self-erasing (§1.1.3) matches the autos-off
   anomalies phenomenologically.** Post-update optical drift with ~1 s
   non-exponential decay, severity varying with inter-update spacing;
   patent-documented consequences include optical state changing
   *after* driving concludes. soak1's two real static-region events
   (autos off; the second permanently graying a framing cell
   0.01 → 0.10) and never-a's episodic ghost-paints-restored-by-a-wash
   are consistent with remnant-field relaxation ± blooming, not only
   with rogue driver events. Two cheap probes: (a) source-inspect
   whether `rockchip_ebc` holds electrodes at neutral vs floating after
   updates (the literature's mitigation is an explicit post-update
   discharge); (b) steal #5's no-drive relaxation dwell — drift with
   zero driving separates electrical relaxation from driver activity.
3. **Blooming (§1.1.5) is a believed-state divergence channel with
   perfect bookkeeping.** Halo pixels are pixels the driver *correctly*
   marks unchanged. Any hunt logic that treats "prev buffer provably
   matches submitted content" as exonerating the display path is
   blind to this channel by construction.

Taxonomy consequence: split the corruption family into
**driver-believed-state desync** (bookkeeping — fixable in software) vs
**physics-inherent divergence** (DTD / remnant / blooming — only
washable; E Ink's own answer is open-loop compensation plus rail
resets). The instrumented kernel discriminates the first class; only
dwell/relaxation-controlled optics discriminate the second. Steal #1's
∫V·dt accumulator adds a third axis: whether corrupting regimes carry
unusual net-impulse stress that clean regimes don't.

One more external echo: commercial drivers treat *overlap with in-flight
updates* as the quality hazard (REAGL demoted on collision, resubmit
forced to AUTO — §1.2.10). Our analogue is the splice-into-running-call
window (pageturn ground truth 2). ebc-replay can already ask whether
corrupting traces are splice-heavy — a content-bookkeeping lead that
needs no new instrument.

### 4.2 The page-turn program (`doc/pageturn-program.md`)

The external record mostly *confirms the program's ranking* and
sharpens a few verdicts:

- **d2 (post-flush wash alignment) gains two independent shipping
  precedents**: Kindle SNAPSHOT semantics (content captured atomically
  at ioctl time) and KOReader's REAGL wait-for-previous-marker fence
  (§1.3.16). Three layers of the commercial stack agree the quality
  update must see quiesced content. Confidence upgrade; no plan change.
- **Policy a (DU + delayed quality repaint) is validated at every layer
  of the industry** (§1.3.20) — silicon, kernel, userland, pen stacks,
  patents. The industry-wide refinement is per-pixel/per-region
  granularity (steal #9). The A3/DU binarization contract (§1.4.23)
  confirms the `bw_mode` shape and adds the per-update
  threshold-vs-dither choice; task 26's dither should be blue-noise and
  must never be error diffusion (§1.4.24 — diff-masking disqualifier,
  measurable on rastersim first).
- **e3 (A2 elimination) is corroborated twice more**: KOReader maps
  `fast`=DU on every commercial device, reserving A2 for explicit
  panning (§1.3.15); and the AF spec's A2 from-domain is
  [0, 29, 30, 31] **only** (§1.1.6) — A2's legality window is even
  narrower than "B/W targets". hrdl dropping A2 was not an outlier;
  it's the industry position.
- **The ux-page family (finding 1.1a) has a commercial answer:
  content classification.** EPDC AUTO histograms the rect in-kernel;
  US11520202B2 classifies content into waveform families. A
  mostly-inverting rect is exactly what classification exists to catch
  — steal #6 (histogram prepass) is the cheap version, and the
  workbench can test "classify ux rects → promote to wash-class"
  against the existing traces before any glass time.
- **DU4 needs its dither to target {1,6,11,16}** (the spec-confirmed
  tone set) for policy b to be judged fairly — folds into task 26.
- **The MTK pacing folklore (~175 ms yield, §1.2.11) is a caution for
  d1**: commercial EPDC stacks have pacing windows for reasons that are
  not in their public source. d1's plan already carries the coalescing
  check; keep it.
- **Measurement**: report flash-depth as "flicker intensity" and anchor
  the verdict-vector docs to IEC 62679-3-3/IDMS (steal #7) so the
  program's numbers are citable outside the project. The 60 fps
  recalibration doctrine for DU verdicts stands; academic instruments
  sample slower than our camera (§1.5.29), so no rig envy is warranted.
- **Later horizon**: if the 5-bit hint experiment (steal #17) ever
  lands, "GL16 wash + hinted white scrub" becomes a page-turn-adjacent
  wash primitive — a deep clean without the GC16 black flash —
  interacting with the idle-washer's debt model (steal #9) and
  Decision 2's deep-clean gesture.

## 5. Corrections to fold back into existing docs

Recorded here so the next touch of each doc picks them up (this review
does not edit them):

1. `doc/eink-research.md` §1: "net charge ≈ 0" → DC balance is the
   pixel-wise **voltage-time integral** (∫V·dt ≈ 0), budgeted
   < 90 V·s/≥ 60 s in the E Ink patent family (§1.1.3). Same intent,
   correct quantity.
2. `doc/eink-research.md` §2 (GLR16/GLD16 row): "= GL16 unless E Ink's
   licensed REGAL preprocessor injects hint states" understates — the
   hint *data* (29/31 transitions) is present in our own file; the
   aliasing is by-design; our 4-bit driver path simply cannot index it
   (§1.1.6).
3. `doc/eink-research.md` §2 (A2 row): the from-domain is
   [0, 29, 30, 31] per the AF spec Table 1 — stricter than "B/W only",
   and the bracketing rule is now primary-sourced.
4. `doc/eink-research.md` §8 (trim_waveform): the "black sometimes
   gray" tradeoff now has a mechanism — trims that eat the activation
   stage (§1.1.2). Trim from the erase side.
5. `doc/refresh-policy.md` "Context" bullet on KOReader's canonical
   mapping: should read ui→AUTO, **partial→REAGL/GLR16** (not
   "ui/partial→AUTO") per the verified device tables (§1.3.15).
6. `doc/refresh-policy.md` finding 2 / Decision 2 framing: "the only
   mechanism that re-scrubs whites is a GC16 deep clean" is true of the
   4-bit driver path, not of the waveform file — note the 29/31
   alternative as gated future work (§1.1.6).
7. `doc/driver-findings-report.md`: adopt the
   bookkeeping-vs-physics taxonomy and the three physical channels
   (§4.1) in the corruption family's language; note blooming as a
   perfect-bookkeeping divergence channel.
8. `pinenote/tools/optics/README.md`: cite IEC 62679-3-3 (not 3-1) as
   the standards anchor; report flash depth as flicker intensity
   alongside our name; map ghost-rms to the IDMS checkerboard
   convention (§1.5.29).

---

*Sources are linked inline. Confidence markers: "verified" = fetched
and checked at source by a reviewer; "report-level" = corroborated but
not fetched (paywall/403); "folklore" = community lore, no primary
source; "lead" = unproven negative or single-source detail. The 5-bit
LUT dumps behind §1.1.6 are reproducible from the device's own
`ebc.wbf` with `wbf-info --dump-lut`; the spec PDF's public mirror is
truncated after its header tables — acquiring the full document (and
IEC 62679-3-1's §5.11 pattern) is worthwhile before publishing rig
numbers for comparability.*
