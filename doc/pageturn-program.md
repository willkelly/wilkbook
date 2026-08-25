# The page-turn program — cost map, instruments, candidates, ladder

The working plan for improving page-turn draws (speed and visual quality)
for KOReader running natively on the rockchip_ebc framebuffer. Companion
to `doc/refresh-policy.md` (the display-quality evidence base, findings
1–12 + Decisions), `doc/eink-research.md` (domain background), and
`pinenote/tools/optics/PLAN.md` (the rig's build queue). Written
2026-07-12 from four adversarially-reviewed investigations (corpus
mining, driver policy enumeration, workbench capability audit,
instrument-gap analysis); every number below either survived its review
or carries the correction inline. Line numbers cite the verbatim
extracted driver `pinenote/tools/ebc-logic/build/drivers/gpu/drm/rockchip/rockchip_ebc.c`
unless noted.

> **Status (2026-08-06): this is the campaign record, not current
> state.** The portrait two-pass defect this program chased was **fixed
> on glass 2026-08-01** by publish-on-call: `defio_delay_ms` became a
> driver parameter (chosen value 250, pinned in
> `pinenote-apply-ebc-params`), KOReader publishes damage via fsync at
> every refresh intent, and the global-refresh ioctl drains pending
> damage before arming the wash — eight of eight uinput-driven portrait
> turns cost exactly one pass on the deployed image (see
> `doc/refresh-policy.md` § "The adopted fix: publish-on-call" and
> `doc/status.md`). Consequences for reading this doc: the §0 cost
> model (50 ms flush, ~750 ms felt) describes the **pre-fix** image;
> the 2026-07-15 single-flush-paint candidate and d1's stagger caveat
> are retired (painting is now single-flush by construction); and
> candidate d2 is DONE, landed driver-side rather than as the userspace
> timing proposed below (§3.2). The rest — the attributed corpus, the
> instrument doctrine, and the still-untried candidates (d1, a, b, e4)
> — stands.

## 0. The shape of the problem

A partial page turn today is: KOReader paints → fbdev deferred-io flush
(~50 ms) → the driver's `atomic_update` sleeps `delay_b` = **100 ms**
before waking the refresh thread (:2345–2347, :2386–2389; every page
turn exceeds the 100 000 px cutoff) → 38-phase GC16 partial, 596 ms.
Felt turn ≈ **750 ms** (50 + 100 + 596 — a model sum, not a measurement),
of which the waveform is 596 ms, i.e. ~80 %. The
median turn is *fine* — the felt cost concentrates in specific
transition families, in the latency tail, and in the two-pass structure
of promoted fulls. §1 quantifies where; §3 ranks what to do about it.

**Field confirmation of the defio-band stagger (2026-07-15, portrait
dogfooding):** in portrait the page turn visibly lands as two chunks —
top ~60–75 % in one drive, the bottom band arriving later as an
independent second drive. Mechanism: portrait is software-rotated, so
KOReader's full-page paint is a scattered (column-order) write into the
fb mmap instead of a linear memcpy; the paint spans multiple defio
flush cycles and outlives `delay_b`'s 100 ms coalescing window, so the
late bands miss the first wakeup. Landscape paints complete inside one
flush window, which is why this was invisible until portrait worked.
Two consequences: (1) d1 (`delay_b` → 2 ms) makes the stagger *worse*
in portrait until painting is single-flush — the go/no-go's
staggered-band check is not hypothetical; (2) a new candidate fix
upstream of the driver: **single-flush paint** — render the page into
an offscreen portrait buffer and blit it into the fb in native linear
order (~10.5 MB memcpy, one defio window, one damage rect). Userspace
only; belongs in the d-series when the program resumes.

## 1. Where the cost and ugliness concentrate (the attributed corpus)

**Sources and their honesty caveats.** ~30 capture bundles under
`pinenote/tools/optics/build/bundles/` (gitignored; the committed v1
reports live under `doc/datasets/2026-07-optics/`, but the attributed
v3 reports — `sweep1.r0{0,1}-report-v3.json` and a fresh
`cadence.r02` re-analysis — exist only in `build/bundles/` and analysis
scratchpads, **not in git**; committing the v3 generation is open
housekeeping). Pooled attributed corpus: **110 src=ko-partial, 17
src=ko-full, 10 src=none transitions** — all synthetic test card,
23–24 °C single temperature bin, frontlight 255/255, ~3.7 s/page
injector pacing. One cross-run confound to carry: the GC16-fulls run
(r01) was analyzed at 30 fps, the GL16 runs at 10 fps, and 10 fps
decimation roughly halves measured depth on short dips — no cross-run
depth comparison below survives unless it is an order-of-magnitude
difference. Thresholds: flash severe ≥ 0.15 reflectance dip; settle
on-time ≤ 0.581 s (**stale** — that cut is `expected_settle_s` 0.447 × 1.3;
the corrected 0.596 s moves it to 0.775 s, so every on-time/slow count in
this section was scored at the old cut and is pending regeneration);
blank-reveal ghost floor 0.121 ± 0.009.

**Headline partial-turn profile (n=110):** 34/110 clean on all axes.
Flash: 63 none / 30 mild / 17 severe. Settle: 48 on-time / 52 slow /
10 incomplete; 22/110 exceed 1.0 s. Median settle 0.4–0.6 s ≈ the
596 ms GC16 decode — the measured median now sits at or slightly below the
drive time, so the panel reaches optical quiescence before the waveform ends;
the old "+ frame quantization" gloss no longer applies. **Baseline partial speed is
waveform-bound and fine; the felt cost is the tail and the families.**

| to-class | n | flash depth p50 / p90 (severe) | settle p50 | ghost note |
|---|---|---|---|---|
| text (novel/textbook/index) | 62 | 0.015 / 0.244 (10) | 0.60 s, tail to 2.5 s | corr-gated (uncalibrated on content) |
| graphic | 27 | 0.019 / 0.048 (0) | 0.60 s | corr-gated |
| blank | 14 | 0.054 / 0.175 (3) | 0.30 s | **0.118–0.142 — at the floor** |
| ux (menu page) | 7 | 0.387 / 0.404 (4) | 0.60 s, tail incl. one 2.5 s incomplete | corr-gated |

Blank-reveal partial ghost sitting at the 0.121 ± 0.009 floor is the
per-turn confirmation of findings 6–7: **no ghost accumulation under
cadence 6 or 20**. 9 of the text class's 10 severe flashes are
inherited from ux→text pairs — the *pair* is the variable, not the
class.

### 1.1 The four concentration findings

**(a) The ux (menu-style) page, both directions — the worst partial
family in the corpus.** `ux→novel`: 9/9 severe, depth 0.205–0.516
pooled (GL16 runs n=6, GC16 run n=3), and the three highest flash
energies in the attributed corpus (0.574 / 0.552 / 0.524 refl·s, all
r01). `index→ux`: 4/7 severe, up to 0.409. The trace shows each issued
as a **single plain `partial rect=0,0,1872,1404`** — the driver's
diff-masked partial on a mostly-inverting page is what flashes. Two
sub-signals are real and unexplained, flagged for per-frame diagnosis:
the dark excursion lasts ~2.4 s in the GC16-run captures vs 0.2–0.4 s
in the GL16 runs, and the flash attributes to ux-*entry* in the GL16
runs but ux-*exit* in the GC16 run — most plausibly one event family
shifting attribution between adjacent transitions, not two phenomena.
(The original investigation read the depth difference as
waveform-linked; review rejected that — cross-fps confound, and per
Decision 3 `refresh_waveform` cannot touch a diff-masked partial.)
This is a **reader-policy target**: promote ux enter/leave, or apply
the fast-then-clean pattern (§3 policy a).

**(b) The text-CLEAR shimmer — the most reproducible defect.**
Erasing ink transiently drives adjacent whites down: text→blank depth
p50 0.153 (30 fps run), mean 0.148 ± 0.03 on the 10-repeat noise pilot,
22/37 severe in the v1 GL16 pool — and **direction-asymmetric**
(blank→novel p50 0.007, zero severe). Intrinsic to the DU-component of
GC16 partial erase; matches finding 2. A waveform-side question, not a
policy one — bank it as a known cost.

**(c) Graphic-source turns are the slow class.** graphic→novel
partial settles pooled: 0.7 / 0.9 / 2.5 / 2.5 s (4/4 slow or
incomplete; the graphic→novel *full* also hit 2.5 s incomplete);
graphic→textbook 7/8 slow (p50 0.90 s); textbook→novel p50 0.97 s.
Versus text→graphic 0.60 s and blank→text 0.30–0.40 s. Clearing dense
pixels costs ~1.5× the waveform time (0.90 s p50 vs the 596 ms GC16 drive);
flash stays mild (≤ 0.098). This
is drive-cost, not flash — the DU/DU4 speed policies (§3) attack it
directly.

**(d) Promoted fulls arrive ~0.45 s late on glass.** Trace-line→
wash-onset dt: partials p50 +0.018 s; fulls p50 **−0.428 s** (n=17,
both runs, exactly reproduced under review). Consistent with the
two-pass wash-stale-page-then-repaint structure the workbench measured
(refresh-policy "What the numbers say" §5 — the ioctl races the
deferred-io flush and wins; onset detection likely catches the second
pass). A full is the only turn a reader consciously *waits* on, and it
is structurally delayed — §3 policy d2 is the fix.

Also noted: the two ugliest events in the corpus (depth 0.702 and
0.558, both settle-incomplete) are src=none rows from the
auto_refresh=1-era GC16 run — unattributed (src=none means
driver-initiated global *or* trace gap), plausibly autos. Consistent
with finding 10's policy, not additional proof; 8 of the 10 src=none
rows are shallow and benign.

### 1.2 What the corpus cannot answer

Carried verbatim from review; each is a gap a ladder rung below must
close or explicitly descope.

- **G1 Absolute tap→ink latency** — nothing measures it; the trace
  join fits its own offset. Needs the kernel timing plane (§2).
- **G2 Real content** — 100% synthetic card; no crengine reflow, no
  real typography (card-v2 TTF task unshipped).
- **G3 Fast modes** — zero A2/DU/DU4 optical data; the entire speed
  frontier is optically unmeasured.
- **G4 flash_area_fraction boundary** — every page-turn rect is
  full-viewport; the 0.60 boundary has never been sampled (needs
  controlled-rect flashui / fb backend).
- **G5 UI interactions** — menu open/close overlay-ghost path has no
  data; the ux-*pair* data is a proxy.
- **G6 The ux event-family bimodality** (see 1.1a) — needs per-frame
  diagnosis of where the dip lives.
- **G7 Fulls are thin** — n=17 over 7 pair types; the GL16 index→ux
  0.351 outlier (finding 12) stays n=1.
- **G8 Temporal resolution** — 10 fps quantizes settle to 0.1 s across
  the on-time boundary and halves short-dip depth vs 30 fps.
- **G9 Temperature** — single bin (descoped per PLAN §1a, but a corpus
  fact).
- **G10 Pacing** — all captures ~3.7 s/page; rapid-turn bursts (where
  queueing hurts, §3 ground truth 9) are unrepresented.
- **G11 Ghost on non-blank content** — corr-gated to none everywhere;
  needs card-v2 checker/grayfield/probe pages.
- **G12 Re-analysis portability** — bounded decimation is not
  uniformly valid (one bundle segmented 4/47, another shattered
  48→495 pseudo-transitions); v1 reports carry NaN flash on a large
  minority of rows (order ~80/~300, dominated by novel→graphic) plus
  the known displaced-geometry artifacts (2026-07-12 evidence audit).
  Corpus-wide v3 re-analysis needs full-rate runs.
- **G13 `gray-corrupt:mild` fires on ~every transition** (placeholder
  thresholds, optics.py) — zero-information until recalibrated.

## 2. Instrument doctrine: the debug kernel does not replace the camera

### 2.1 Four measurement planes

- **Camera** — *glass truth* (reflectance over time). Cannot attribute
  cause (finding 10's corrections were all attribution failures) and
  undersamples fast waveforms (§2.3).
- **Historical v1 debug kernel** — *driver action*. The retired
  dspend-straggler patch logged **globals only**: it was blind to the partial path —
  where every page turn lives — and cannot even distinguish GC16 from
  GL16 (both 38 phases; v1 logs `num_phases`, not the waveform id) nor
  report the temperature/LUT bin. v2 (§5.1) closes the partial path.
- **[pn-refresh] trace** — *reader intent*: what KOReader asked for,
  never what happened (the A.2 config bug is the canonical
  intent≠reality failure).
- **EXTRACT_FBS** — *driver belief* (live prev/next buffers).
  The primary 7.0 forward-port intentionally retains the
  `return -EOPNOTSUPP` stub (:398–402), but the separate
  `linux-pinenote-debug` kernel gained the port on 2026-07-12 (§5.2).
  Its idle `--verify` device smoke passed under the live DRM master on
  2026-07-13 and decoded a pixel-faithful KOReader screen; camera
  correlation and a mid-scribble sample remain.

Composition is where the value is: divergence between intent, action,
belief, and glass IS the diagnosis. All clocks align for free through
the sync-flash globals (ioctl-fired, hence visible simultaneously in
camera frames, the kernel log, and the trace).

### 2.2 Coverage matrix

**D** direct, **P** partial/one-segment, **X** proxy/inference, **–** blind.

| Metric | Camera | dbg v1 | dbg v2 (proposed) | [pn-refresh] | EXTRACT_FBS (debug kernel) |
|---|---|---|---|---|---|
| Turn-to-glass latency | P — end anchor only, ±1 frame each end | P — globals only | **D** driver segment: intent→blit→burst→last DSP_END, ms precision | P — start anchor | – |
| Drive duration | P — optical envelope; quantization kills fast modes | D globals / **– partials** | **D** — frames + ms per partial burst | – | – |
| Flash depth | **D** — the only instrument (exposure-attenuation caveat, §2.3) | – | X — predicts flash *class*, never observes | X — intent class | – |
| Ghost | **D** — rms vs floor | – | – | – | P — supplies the belief half of glass−belief |
| Believed-state divergence | P — glass half, by inference | P — global truncation events (:668 memcpy regardless) | P — + partial timeout counts (:1211 prev copy regardless) | – | **D** for belief; divergence needs the camera join |
| Waveform actually used per update | X — GL16/GC16 optically indistinguishable (finding 12) | **P — cannot tell GC16 from GL16** | **D** — waveform enum + `mode_index`/`temp_index` per refresh | X — the inference the A.2 bug falsified | X |

**The honest answer to "does the debug kernel replace the camera?": no,
and it isn't trying to.** The kernel never sees a flash — flash and
ghost are reflectance phenomena. What v2 does is make every camera
number *attributable* (which update, which waveform, which surviving
damage, how long driven) and every latency *decomposable*
(intent→blit / blit→last-DSP_END / optical settle tail — each segment
owned by exactly one instrument). That composition **shrinks** the
camera requirement (§2.3) but replaces nothing: flash depth, ghost,
end-state quality, and the settle tail stay camera-only forever.

### 2.3 Camera limits for fast waveforms

Calibrated point: 30 fps / exposure 312 (31.2 ms) / gain 32 → whites
214/255 (recorder.py). At 30 fps: A2 (157 ms) = 4.7 samples, each
integrating ~94% of the frame period — a single-phase (11.8 ms)
excursion reads at ~38% of true depth and the envelope shape is
unrecoverable; DU (298 ms) = 8.9 samples, depth OK for multi-frame
excursions, shape crude; GC16's 220 ms dark push = 6.6 frames,
which is why 30 fps has sufficed. Latency anchors carry ±1 frame at
both ends → ±67 ms — unusable for ranking 157–314 ms policies.

60 fps halves both problems and costs exactly one photometric stop
(exposure caps at ~156). **CORRECTION: the proposed "gain 64 restores
the operating point" arithmetic is unproven** — the Brio's gain units
are not a linear doubling (gain 64 at *full* exposure measured 238,
not a clipped ~428), so the 60 fps operating point must be
**recalibrated empirically at session start** (one whites-level check),
not derived. Qualitatively "one gain stop, not a rig rebuild" is
plausible but unverified. 90 fps needs ~1.6 stops with the frontlight
already maxed — only physically more light (camera closer + full
recalibration session) gets there.

Doctrine: **30 fps for GC16/GL16-class candidates; the 60 fps
recalibration only when DU/A2 transient optics are themselves the
question** — and A2 is an eliminate-candidate (§3 e3, hrdl dropped it),
so that may only ever mean DU. Per ME9/ME8: `exposure_dynamic_framerate=0`
lock and the PTS timebase (task 13) are mandatory for any 60 fps run.

### 2.4 The combined single-session protocol (one candidate, ~30–45 min)

Preconditions, all offline: debug kernel v2 built with rungs 1–4 green
and its burst counters asserted on the host harness (§5.1 — requires
the ebc-logic Makefile debug-build variant, currently unbuilt); card
v2; injector proven; params one-shot carries the candidate config.

1. **Boot + config assert.** Params one-shot applies the candidate
   (`ebc` + `ko` namespaces) with `auto_refresh=0` (finding 10);
   sysfs readback assert kills the intent≠reality class before capture.
2. **camera_lock + readback into session.json.** 30 fps default; the
   60 fps empirically-recalibrated point iff DU/A2 is in the candidate
   (record the operating point in bundle metadata).
3. **Panel reset + clocks.** 3× GC16 deep clean via ioctl — each now
   *verified* by its kernel log line, not assumed — then sync flashes:
   the triple-clock alignment event (camera ↔ dmesg ↔ trace).
4. **ABBA arms via injector** (per ME3 — the investigation proposed
   ABA; ABBA's counterbalancing is the standing protocol and costs one
   lap): candidate / baseline / baseline / candidate, one video + one
   bundle per arm; the stress ×3 block supplies within-lap repeats
   against the σ 0.003–0.006 floor.
5. **Belief probes — available on the debug image** (§5.2). The idle
   live-DRM path is hardware-proven; capture a mid-scribble dump and join
   its patch means to camera regions for the first full correlation run.
6. **Harvest per arm:** video, `optics-koreader.log` trace, dmesg
   (`ebc-dbg` lines via the standing post-mortem protocol). Nothing
   else touches the device.
7. **Offline joins, same night:** per transition require the triple
   match intent(trace) ↔ burst(kernel: waveform used, surviving damage
   px, frames, blit→DSP_END ms, timeouts) ↔ camera transition (flash
   depth/energy, ghost-excess, settle). Unmatched anything = flagged.
8. **Verdict vector** (PLAN §4): flash energy p95, flash count/page,
   ghost-rms-excess p95, latency p50 *decomposed*, wash rate, plus
   v2-only guards: per-update waveform confirmation and
   straggler/timeout count (expected 0 with autos off — regression
   sentinel for the quirk-F family and the soak1 t≈105 anomaly).

## 3. Candidate policies, ranked

### 3.1 Driver ground truths that constrain everything (line-cited)

1. **Waveform granularity = per refresh-thread invocation**, never
   per-update or per-frame: params read once per call (:1585/:1588),
   LUT latched and uploaded before any frame starts (:1370,
   :1416–1420). Param flips are atomic w.r.t. an in-flight wash.
2. **But one partial "call" is not one update**: the frame loop
   splices newly arriving damage into itself (:1125–1135, trylock
   :1277–1294) and exits only when the area list drains (:1253). All
   damage absorbed by a running call drives under the LUT latched at
   call start.
3. **Every page turn pays a hidden 100 ms**: `atomic_update` sleeps
   `fsleep(delay_b)` *before* waking the refresh thread (:2345–2347,
   :2386–2389; cutoff 100 000 px, a page turn is 2.63 Mpx). Runtime-
   writable, unmodeled in ebc-replay (the shim no-ops `fsleep`), the
   cheapest untried lever in the space.
4. **`prev` is unconditionally overwritten with `next`** after the
   last phase (:1200–1213) whether or not the waveform could reach
   `next` — the DU-desync-ghost mechanism. The sanctioned guard is
   render-side quantization at the fb blit (`bw_mode` 1/2/3; the
   fourtone path has **no dithering**, :2141–2199). The diff runs
   *after* quantization, which makes delayed-quality repaint work by
   construction.
5. **A global absorbs and cancels all queued partial damage**
   (:624–662) and paints latest content in one pass — a wash fired
   after the flush lands is a legitimate single-pass page turn.
6. `dclk_select` is read at mode-set only (:1712–1716, :1816–1820) —
   boot-time knob.
7. `refresh_threshold` units, **resolved fresh against source**: the
   accumulator counts *pixels* (:1167) against
   `one_screen_area = 1 314 144` (:1341) = **half** the panel's
   2 628 288 px — so threshold 60 fires after ~30 full-page turns of
   damage. (refresh-policy oscillates between "half-screens" and
   "screen-areas"/"~60 turns"; the ~30-turns reading is correct.)
8. `prepare_prev_before_a2` guards on `lut_changed && waveform == 1`
   (:1380–1381) — **A2 entry only**; a structural no-op for DU
   experiments.
9. With shipped `split_area_limit=0` nothing splits (:697); an
   overlapping in-flight area serializes the next turn to
   `other_end + 1` (:874–875) — back-to-back turns queue 38 phases
   apart under GC16. Only hrdl-style early cancellation fixes rapid
   flipping, and that is redesign-scale (§5.4).

### 3.2 The ranked table

| rank | Policy | Mechanism | Layer | Expected gain (vs ~750 ms felt / 596 ms drive) | Quality risk | Prerequisites |
|---|---|---|---|---|---|---|
| 1 | **d1: `delay_b` 100 ms → 2 ms** | Kill the pre-wake sleep (ground truth 3) | One runtime param write | ~−100 ms felt on **every** turn, waveform untouched | **Low, verify coalescing**: delay_b is also a damage-coalescing window — with 2 ms, a paint spread over multiple defio flushes starts driving on the first band with later bands joining mid-call (visibly staggered start the 100 ms currently hides). Replay + rig A/B catch it | `delay_b` in paramspace; wake-delay term in ebc-replay (see ladder rung 0 for the corrected prediction) |
| 2 | **d2: post-flush wash alignment — DONE (2026-07-31, proven on glass 2026-08-01)** | Delay the promoted-full/bundled-wash ioctl one defio period (~60 ms) so the wash paints the NEW page: single 596 ms pass instead of wash-stale + repaint (ground truths 3/5; corpus finding 1.1d) | Plugin timing (idle-washer skeleton) | −596 ms on every promoted/bundled turn; kills the residual "draws then redraws" | ~zero — mis-timing degrades to status quo | defio-settle heuristic in device.lua/idlewasher; workbench-provable now. **Landed differently than proposed**: not this userspace timing but a driver-side drain — `ioctl_trigger_global_refresh` flushes deferred-io + the damage worker before arming the wash, so "the wash paints the new page" holds by construction; `doc/refresh-policy.md` ("The adopted fix: publish-on-call") credits it as fulfilling d2 |
| 3 | **a: DU turn + delayed GC16-quality repaint** (hrdl's fast-now-clean-later, in userspace) | Reading profile: `default_waveform=2` + `bw_mode=2` (binarize → `next` reachable, avoids ground-truth-4 desync); turn drives DU 298 ms; after 0.5–2.4 s idle, restore `bw_mode=0`+GC16 and re-flush — post-quantization diff repaints only lost-fidelity pixels. Idle-washer debt/timer machinery is the skeleton | KOReader plugin + 2 param flips; zero driver changes | drive 596→298 ms; felt ~750→~452 ms; stacks with d1 | Binarized text during interaction; visible deferred repaint; flip races (see c-risks) can leave DU sticky or land a turn on GC16; needs an images-page escape hatch | paramspace `ko`/`ebc`; flip-verify discipline; E2+E3 replay extensions; 60 fps recalibration for the optical verdict |
| 4 | **b: DU4 + dither, resident profile** | `default_waveform=3` + `bw_mode=3` set once per session (no per-turn flips → no races); `globre_convert_before=1` as wash-exit bracket (already in the patch — §5.3); task 26 adds dither (fourtone is pure thresholding today) | Param set + task-26 dither | drive 596→377 ms; felt ~750→~531 ms | Antialiasing crushed to 4 tones; images banded without dither; DU4 ghosting "moderate" (eink-research §2); whole-UI 4-tone | task 25 residue (paramspace + rung asserts); task 26; grayramp card kind |
| 5 | **e2: `dclk_select=1` (250 MHz)** | Higher pixel clock; field-stable per PNDeb dev branch. Boot param (ground truth 6) | Boot param | **REJECTED 2026-07-30, REINSTATED 2026-08-24 — the rejection's premise was wrong.** `DCLK_EBC` is a divider-less 3-way mux over {gpll_400m, cpll_333m, gpll_200m} (`clk-rk3568.c:1129`, `:286`) and Linux picks the fastest parent ≤ request (`clk.c:729`, `:626`) — all correct. But `cpll_333m` runs at **250 MHz**, not 333, so the request finds an exact parent and lands there. Measured both directions on glass (#23). The *scaling* is now derived exactly (frame = htotal×vtotal/dclk) — 250 MHz gives 79.68 Hz and GC16 ~477 ms — and that rate was **reached on glass 2026-08-24 with `dclk_select=1` alone**, no CRU/DT work: `cpll_333m` already runs at 250 MHz, so the mux finds an exact parent (the [e2 is BACK] note below; NOT cleared to ship) | ~20% less drive integral per phase if frames shorten → undershoot/ghost risk; PNDeb field evidence mitigates | rung-4 live-value assert; cheap piggyback A/B on any session |
| — | **c: per-update waveform via flip-around-the-turn** | Race analysis (source-exact): no per-frame hazard, but (i) an in-flight call absorbs the new turn's damage under the OLD LUT — the flip silently loses exactly when turns arrive fast (the case it targets); (ii) flip/restore pairs can be consumed whole by a long call; (iii) sticky-DU if the restorer dies | Plugin (sanctioned workaround) | Same as a/b when the flip wins; **zero when it loses** | All of (a)'s plus nondeterminism and attribution pain | Quiesce-before-flip discipline; E3; per-turn waveform confirmation from dbg v2. Treat as (a)'s degraded fallback, not a rank of its own |
| — | **e1: turn = GL16 full wash** | Context-conditional (nav-heavy usage only) | Plugin | Always one predictable pass | Finding 3 measured full-every-1 as pure cost — **likely reject for linear reading** | none new; half-answered already |
| — | **e3: A2 anything** | — | — | 157 ms drive | hrdl dropped A2 entirely; PNDeb ships a trimmer accepting gray blacks | **Eliminate-candidate, not tune** (PLAN §1b). Revisit only if DU measures insufficient |
| — | **e4: early cancellation / per-pixel scheduling (hrdl port)** | Fixes turn serialization (ground truth 9) for rapid flipping | Driver redesign, community-owned | The only fix for "flip 5 pages fast" | Rebase-scale; violates report-don't-fork economics today | Not now — §5.4 |

### 3.3 Sequencing (evidence density per hardware-session-minute)

1. **d1** — one param, low risk, one-variable rig A/B. First.
2. **d2** — **DONE** (landed driver-side in publish-on-call
   2026-07-31, proven on glass 2026-08-01 — see the table row).
3. **a** — highest ceiling; prove the flip choreography offline
   (rung-7a replay + koreader-input harness) before any glass time.
4. **b** — the no-race fallback if (a)'s interaction-burst artifacts
   measure ugly; needs task 26 to be judged fairly.

(e2 left the sequence 2026-07-30: the table rejects it — `DCLK_EBC`
is a divider-less mux with no 250 MHz parent, so `dclk_select=1` is a
no-op on this kernel.)

**[e2 is BACK, 2026-08-24.]** That rejection rested on the mux having no
250 MHz parent. It has one: **`cpll_333m` runs at 250 MHz, not 333** —
`cpll` is 1000 MHz and the CRU divider is ÷4. Measured on glass, both
directions: `dclk_select=1` moves `dclk_ebc` to exactly 250 MHz on
`cpll_333m`, so the ×1.25 the row itself computed (79.68 Hz, GC16 ~477 ms)
is real and costs **one module parameter** — no DT, no driver change.
Not cleared to ship: the failure mode is silent corruption and the check
so far is webcam-grade (`doc/artifacts/pinenote-dclk-reclock-20260824/`,
issue #23).

## 4. The experiment ladder

Cheapest first, stop at the first failure, per `doc/testing.md`. Each
rung's go/no-go is written before the rung runs.

### Rung 0 — workbench matrix (offline, CPU-minutes)

**What runs today, verified live:** ebc-replay executes the verbatim
refresh thread on real + synth traces. DU on the page-turn-dominated
cadence.r01 trace: settle med 22 frames/345 ms vs 38/596 ms GC16;
partial px-phases 91.6 M vs 300.6 M (3.3× drive spread). DU4: 55.4 M
px-phases, settle min 24, on the a2 trace. Runtime 1.6–5.2 s/run at
scale 2; the full ~280-run matrix (7 traces × ~40 pruned configs) is
**15–30 CPU-min, embarrassingly parallel** — repeats are free.

**Honesty caveats on today's numbers:** (i) the DU4 runs never
exercise the fourtone conversion — `convert_final_buf_to_target` is
called only from global refresh behind `globre_convert_before`
(default off), and the on-device partial-path conversion lives in the
fb blit (`bw_mode`), which replay bypasses entirely — so DU/DU4
*quality* is currently invisible to replay, only speed and drive cost
are real; (ii) real traces top out at 197 s — session-scale staleness
is synth-only (`period=` covers it; idle is skipped so runtime stays
seconds); (iii) cadence cannot be re-decided from real traces
(promotion is baked into intents upstream of the trace); (iv) finding
12 is standing proof that decode-level proxies *overpredict* optical
differences (with one n=1 counter-direction outlier) — replay ranks,
camera anchors calibrate.

**Extensions before full value** (~1–2 focused days, all offline):

- **E1** partial-event census (S): per-partial (from,to) histogram ×
  LUT-reachability → the DU unsoundness number.
- **E2** believed-vs-physical desync shadow (M): track what the LUT
  actually lands vs what `prev` claims — **THE quality proxy for every
  non-GC16-partial policy**, currently invisible.
- **E3** scripted param-flip schedule (M): unlocks policies a/c as
  interleaved policies (not bounding pairs), all flip races decidable
  offline (semantics exact per :1585/:1588), and the idle-washer's
  GC16 deep-clean leg (a refresh_waveform flip — E4 alone cannot
  simulate it).
- **E4** trace rewriter (S–M): inserts delayed repaints/globals;
  simulates the idle-washer's deterministic debt/idle rules.
- **E5** content realism (S–M): antialiased-gray content histogram
  (today's `content_paint` inks only grays 0–3 + white).
- **E6** blit-path bw_mode emulation — **rescoped from the original
  "expose the globals, 30 lines"**: exposing them is inert because
  replay bypasses the blit; the conversion must be emulated in the
  content path (E5-sized), or DU/DU4 quality claims don't attach.
- **d1 wake-delay term**: model `fsleep(delay_b)`. **Corrected
  prediction** (the investigation inverted the bookkeeping): the
  current 42-frame median was measured with `fsleep` stubbed, so
  adding the term raises the modeled *baseline* to ~50–51 frames;
  `delay_b=2 ms` should recover ~42. The device-felt −100 ms claim is
  unaffected.

**Go/no-go:** a policy advances to rung 1 only if replay shows ≥25%
settle-floor or drive-cost improvement on ≥2 trace regimes **with no
E2 desync-shadow regression vs GC16 partials** and no new scheduler
conflicts. d1 advances iff the wake-term model reproduces the +~8-frame
baseline and 2 ms recovers it without staggered-band artifacts on the
defio-bands runs. Anything that fails here never touches the device.

### Rung 1 — instrumented-kernel timing (device session, dbg v2)

Prerequisites: §5.1's v2 patch with its host-harness assertions green
(needs the ebc-logic Makefile debug-build variant first), rungs 1–4
green, params one-shot asserts.

Measures, per turn, at ms precision: intent→blit, blit→last-DSP_END,
waveform actually used (+ temp/LUT bin), damage sent vs damage
surviving the pixel diff, mid-burst splice extension, timeouts. Runs
inside the §2.4 protocol (same session as rung 2 when a camera verdict
is also due — the rungs share glass time, not gates).

**Go/no-go:** the latency decomposition confirms replay's *ranking*
(not absolute numbers) for the candidates on board; the d1 A/B
(`delay_b` ∈ {2 ms, 100 ms}) shows the ~100 ms segment moving and no
staggered-start regressions in the burst lines; config asserts and
straggler/timeout counters stay clean. A candidate whose kernel-side
numbers contradict its replay win goes back to rung 0 with the trace.

### Rung 2 — camera sessions (glass verdicts)

The §2.4 protocol: ABBA arms, triple-clock joins, verdict vector.
30 fps for GC16/GL16-class; the empirically-recalibrated 60 fps point
only when DU transients are the question. Camera-side open items that
gate specific verdicts: card v2 tasks for G2/G11 (glyphs, grayramp,
checker), the turn-latency join (task 10) for G1, G13 recalibration
before gray_crush can rank anything.

**Go/no-go (ship gate):** a candidate becomes a refresh-policy
Decision iff, vs the ABBA baseline arms: flash energy p95 and flash
count/page do not regress, ghost-rms-excess p95 stays within the
noise floor's 2σ, gray_crush passes (post-G13 thresholds), latency
p50 improves by at least the replay-predicted magnitude ×0.5, and the
deferred-repaint visibility (policy a only) passes a human look at the
capture video. Partial wins get recorded as findings, not Decisions.

## 5. Open driver and tooling work

### 5.1 Debug-kernel patch v2 (extends v1, same removal contract)

Three hooks, printk/counters only, no logic or locking changes; full
sketch in the instruments investigation, summarized here as the work
item. Hook A — `rockchip_ebc_refresh` (:1330, before :1461): waveform
enum, `lut.mode_index`/`num_phases`/`temp_index` + raw temp,
accumulator snapshot — fixes both v1 gaps (GC16-vs-GL16, temp bin) in
one chokepoint. Hook B — `atomic_update` (:2217): counters only under
the existing queue_lock (first-enqueue timestamp, commits, blit_area,
diff-masked skipped-clip count) — **no printk** (~20 Hz during pen
strokes). Hook C — `partial_refresh` (:1078–1328): one `pr_info` per
burst at loop exit: waveform, frames, blit→last-DSP_END ms, areas/px,
bbox, redundant drops, splits (**needs new per-burst accumulation —
the existing `split_counter` resets every frame iteration**),
late-splice px, timeouts, temp idx, accumulator.

Cautions from review: use `pr_info_ratelimited` on the burst line (a
redundant-damage storm can drain at frame 0, beating the
num_phases+1-frame floor); never printk inside the 63.744 Hz frame loop;
keep output ring-buffer-only under PREEMPT_RT (loglevel or
`printk_deferred`) so console TX can't jitter frame timing.
**Precondition — BUILT (2026-07-12, with the EXTRACT_FBS port):** the
ebc-logic Makefile now has the debug-patched build variant
(`ebc-refresh-test-dbg`: the extraction with the full
  configured `linux-pinenote-debug-*.patch` stack applied, run by `make
  ebc-logic-check`'s dbg half).  The current stack contains only the
  EXTRACT_FBS port and asserts that it changes no refresh behavior
  (identical goldens); any future v2 counters get their offline assertions
  the same way before that patch ships.

### 5.2 EXTRACT_FBS port (unblocks PLAN task 23) — LANDED 2026-07-12

Ported into `linux-pinenote-debug` as
`pinenote/patches/linux-pinenote-debug-extract-fbs.patch` (the primary
kernel keeps the stub), from hrdl's `v6.19_ebc` reference with four
reference defects corrected (size typo, unpinned ctx lifetime,
pre-modeset NULL deref, return convention — reported upstream, see
`doc/driver-findings-report.md`).  Because it exceeds v2's printk-only
discipline it carries its own offline proof: the ebc-logic dbg suite
executes the ioctl end to end (pre-modeset -ENODEV, fake-device
roundtrip, exact sizes under ASan, NULL planes, -EFAULT injection, the
mid-copy kref lifetime guarantee) and the dump/decode pair
(`ebc-dump-grab` on-device via the `pinenote-ebc-dump` package;
`ebc-dump` host decoder, pinned to the driver's Y4 conventions by a
decode differential). The 2026-07-13 idle `--verify` smoke passed under
the live DRM master: it produced a double-read-stable 9,199,048-byte dump,
and the decoded `final` plane was a pixel-faithful KOReader screen.
Still untested are fault/pagefault behavior during real `copy_to_user`, a
mid-scribble dump against the live commit stream, and RT timing under that
load. Protocol step 5 (belief probes) is available on the debug image;
camera correlation remains to be run.

### 5.3 Tasks 25/26 placement

**Task 25 is already half-done**: `globre_convert_before` is *in* the
forward-port patch and the extracted source (5 hits; :287–289,
:611–644) — the "port" reduces to paramspace exposure + rung-1–3
asserts. Note its scope honestly: it converts the final buffers on
*global* refresh keyed off `default_waveform` ∈ {A2, DU4} — a
wash-exit bracket for low-bit partial regimes, structurally inert
while partials stay GC16. **Task 26** (blue-noise tables into the
fourtone/bw path, or dither in KOReader render) is the fairness
prerequisite for policy b's verdict — the fourtone path today is pure
thresholding. hrdl's dither constants are extractable.

### 5.4 Community-lineage items (report, don't fork)

- **Early cancellation / per-pixel scheduling** (policy e4): the only
  fix for back-to-back-turn serialization (ground truth 9). Not now —
  but ebc-replay can *model* cancellation as a candidate scheduler to
  size the win before any port decision, and the hrdl/ayakael 6.19
  diff is the reference at the next patch refresh.
- **Per-update waveform UAPI**: absent (refresh-policy "Context"). The
  dead driver field `waveform_at_beggining_of_update` (:183 — declared,
  never used) is plausibly the lineage's abandoned start toward
  per-update latching and the natural seam to cite in any community
  proposal. (Inference, not documented fact.)
- **delay_b belongs in the parameter table**: refresh-policy's
  paramspace lists "delays" under held-fixed; ground truth 3 shows
  `delay_b` sitting in the page-turn critical path. Move it to the
  swept set when paramspace (task 16) lands.

## Where this leaves us

The program in one sentence: fix the two structural latencies that
cost nothing (d1, d2 — the latter since landed driver-side, see the
status note up top), then buy the big win (DU + delayed repaint)
only after the workbench's new desync shadow and flip scheduler say
it's sound, with the v2 debug kernel making every camera number
attributable and the camera keeping the final word on glass.

## 6. Issue #14 — the repeated full-screen update: trigger analysis (2026-08-24, offline)

Issue #14 established *that* KOReader occasionally issues two or more
identical full-page refresh requests in quick succession, and that the
cause sits above the driver. It left the **trigger** open, with three
candidates. This section is the offline attempt to narrow them. Nothing
in it is hardware-proven; no panel ran while it was written.

**Everything below is re-derivable from committed data by one command:**

```
make refresh-trigger-check          # the pinned numbers
python3 pinenote/tools/refresh-episodes/refresh-triggers.py \
    doc/artifacts/pinenote-refresh-traces-20260815/reader-session-*.log
```

The corpus is the committed
`doc/artifacts/pinenote-refresh-traces-20260815/` — 764 traces over
6.19 days on image `9a08803e…`, one operator. The analyser needs the
**whole** session log, not a grep of the `[pn-refresh]` lines: KOReader's
other INFO lines are what separate a page turn from a document
re-render (see §6.2 D).

### 6.1 Three corrections to the issue's framing

**(a) Two identical full-panel traces cannot share one repaint drain —
so the second request is a separate turn of the event loop.**
`UIManager:_refresh` merges any enqueued refresh whose region
`openIntersectWith`es the new one; identical rects always intersect,
`update_mode("partial","partial")` is `"partial"`, and `region:combine`
of two identical rects is that rect. A same-drain duplicate is therefore
impossible *by construction*. The log shows the contrast directly: 173
adjacent trace pairs cover **disjoint** rects (the footer strip and the
config-dialog body do not intersect) and their minimum gap is **2.2 ms**
— those genuinely do share one drain. The minimum gap between two
*identical* rect+intent traces is 68.3 ms. The issue's "the cause is
above the driver" holds for a stronger reason than it stated.

**(b) 131 ms is not a floor of the mechanism.** The same corpus contains
three identical full-panel `ui/partial` repaints at 2026-08-09 01:34:07
with gaps of **210 ms and 68 ms**. Fastest identical repeat, by rect
class and intent:

| class / intent | n | fastest |
| --- | --- | --- |
| full-panel `ui/partial` | 3 | **68.3 ms** |
| full-panel `partial/partial` | 347 | 131.0 ms |
| bottom-strip `ui/partial` | 12 | 167.0 ms |
| full-panel `flashui/global` | 1 | 196.8 ms |
| full-panel `full/global` | 14 | 451.4 ms |

131 ms is the low end of a 347-sample tail, not a hard floor: a
full-screen repaint is demonstrably re-issuable in 68 ms on this device.
The issue's *inference* that "the 131 ms floor argues the second repaint
is waiting on the previous e-ink pass" is therefore **not supported**. It
also has no mechanism: `refreshPartialImp` traces and then `publish()`,
which is `fsync` on the fbdev fd — `fb_deferred_io_fsync`, i.e. run the
pending deferred-io flush *now*. It does not wait for the e-ink pass,
and `device.lua` says so at the definition. There is no path by which
KOReader blocks on the panel.

**(c) The population was too narrow.** Counting only `partial/partial`
gives 5 runs. Over **all** full-panel repaints regardless of intent
there are **11**, and the largest is **10 traces in 3.73 s**:

| when | n | gaps (ms) | intents |
| --- | --- | --- | --- |
| 2026-08-09 00:42:16 | 10 | 858, 615, 503, 277, 232, 307, 298, 322, 322 | `flashui/global` + `ui/partial` + 8× `partial/partial` |
| 2026-08-09 01:22:26 | 2 | 451 | 2× `full/global` |
| 2026-08-09 01:34:07 | 3 | 210, 68 | 3× `ui/partial` |
| 2026-08-09 22:08:10 | 2 | 861 | `flashui/global` + `ui/partial` |
| 2026-08-10 00:51:10 | 2 | 131 | 2× `partial/partial` |
| 2026-08-10 04:16:27 | 2 | 875 | `flashui/global` + `ui/partial` |
| 2026-08-10 04:54:12 | 2 | 741 | `full/global` + `partial/partial` |
| 2026-08-10 15:16:46 | 2 | 787 | `flashui/global` + `ui/partial` |
| 2026-08-10 15:16:55 | 2 | 933 | 2× `partial/partial` |
| 2026-08-12 07:19:15 | 6 | 184, 746, 214, 166, 197 | 4× `partial/partial` + 2× `flashui/global` |
| 2026-08-12 07:20:23 | 2 | 391 | 2× `partial/partial` |

The "asked twice" behaviour is not confined to the page-turn intent — it
appears on `ui`, on `flash*`, and on `full`. A fix aimed only at
`refreshPartial` would leave most of this table standing.

### 6.2 Candidate scorecard

**A. A footer / progress-bar repaint promoted to full page — EXCLUDED.**
Source: `ReaderFooter`'s two repaint paths (`readerfooter.lua` ~2339 and
~2344) both pass a region — `footer_content.dimen`, or the footer strip
— and both ask for `"ui"`/`"fast"`. The one region-less `"partial"` the
footer can request (`refreshFooter`'s `signal` branch, :2619) is guarded
by `document.provider ~= "crengine"`, which an epub cannot reach. And
UIManager never *enlarges* a region except by the colliding merge above,
which yields one trace. Data: 100 bottom-strip repaints exist, all
`ui/partial` at `0,1836,1404,36` (1.9 % of the panel); **0** fall inside
an episode, **0** land within 2 s of an episode start, and **0 of 412**
full-panel page turns have a footer repaint within 0.5 s. In this corpus
the footer does not repaint on page turns at all — its traces cluster
with the config-dialog body, milliseconds apart, which is the
disjoint-rect case from §6.1(a).

**B. A second paint from the page-turn / animation path — EXCLUDED.**
Every animation-ish path downgrades to `"fast"` or `"a2"`
(`UIManager.currently_scrolling`, `ReaderScrolling`). The corpus has
**one** `fast` trace in 6.19 days and **zero** `a2`; neither is within
15 s of an episode. The strongest mechanistic version of this candidate
was crengine's **partial-rerendering cascade**: `ReaderView:paintTo`
calls `ReaderRolling:handlePartialRerendering`, which on a changed
rerender count fires a `PageUpdate` *from inside the paint*, producing
another repaint on the next tick — a plausible generator for a run of
eight at the reader's own render rate. It is excluded on trace evidence:
that automation repaints ReaderFlipping's status icon
(`cre.render.partial/working/ready/reload`) with mode `"ui"` on **every**
state change, at least three per run, and **zero** small `ui` rects
repeat three or more times anywhere in the corpus. `reader-session.scm`
also seeds `cre_partial_rerendering=false`, but that seed is weaker than
it looks — it writes `settings.reader.lua` only when the file is absent,
and `partial_rerendering` is read from the book's `.sdr` sidecar first —
so the icon count, not the seed, is what closes this.

**C. A genuine double input event — NOT SEPARABLE FROM THIS DATA.**
No input event is logged anywhere, and no refresh trace can see a tap.
What can be said:

- The episodes' cadence does **not** identify a machine repeat. Episode
  CVs are 0.244 (the 8-run) and 0.677 (the 4-run), against 28 ordinary
  reading runs of ≥4 turns whose CVs span 0.077–1.247, median 0.571 —
  two of those 28 ordinary runs are tighter than 0.244. The 8-run's last
  six gaps average 293 ms at CV 0.107, but ~300 ms is roughly what the
  reader needs to render and publish a page, so *any* producer faster
  than the reader lands at that cadence, human or not. Cadence cannot
  discriminate here.
- **Kernel key auto-repeat is not the mechanism today.** Checked three
  ways, all offline: no patch in `pinenote/patches/` sets `EV_REP` or an
  `autorepeat` DT property; the **built** `rk3566-pinenote-v1.2.dtb`
  from the 7.0.11 store output — the kernel the device was running when
  these traces were taken — contains **zero** `autorepeat` properties,
  and its `gpio-keys` node holds only the cover switch (`EV_SW`), no key
  at all; and `ws8100_pen_input` reports every pen button as an
  immediate press *and* release in the same call. This is worth stating
  because KOReader would act on repeats if they existed:
  `InputContainer:onKeyRepeat` is a verbatim copy of `onKeyPress`,
  `RPgFwd`/`RPgBack` are bound to `GotoViewRel` (the PineNote device
  sets `hasKeys = yes`), and `Input:handleKeyBoardEv` throttles repeats
  only to ≥80 ms. If any input node ever gains `EV_REP`, a held
  page-turn button becomes a repeating page turn.
- What remains is a duplicated **touch** gesture, and the repo already
  pins inherited warts of that shape: `make koreader-input-check` carries
  `quirk:buddy-slots-0-1-only`, where two contacts in slots `{0,2}` leave
  as **two swipes** rather than one spread. A thumb resting while a
  finger swipes is the right shape. That is a mechanism, not evidence.

**D. A document re-render (`ReaderRolling:onUpdatePos`) — EXCLUDED for
these episodes, but a confound worth recording.** `onUpdatePos` ends in
`UIManager:setDirty(self.view.dialog, "partial")` with no region
(`readerrolling.lua:1056`), i.e. a full-panel `partial/partial` trace
**identical in every field to a page turn**. Any analysis that reads
"full-panel `partial/partial`" as "page turn" is silently counting
re-renders too. It *is* separable, because it brackets itself:
`Input:inhibitInput(true)` and the 0.2 s `inhibitInputUntil` release log
"Inhibiting user input" / "Restoring user input handling"
(`input.lua:1610/1650`). Data: 14 brackets in the corpus; **7 of 412**
full-panel partials (1.7 %) sit inside one; one bracket held two.
**0 of 18** episode traces sit inside a bracket.

**E. The wilkbook idle washer — EXCLUDED.** It only ever calls
`UIManager:setDirty("all","full")`, which reaches `refreshFullImp` and
traces as `full/global` — never a partial. 28 `[idlewasher]` action
lines; **0** episodes have one within 15 s. (22 of the 82 global traces
sit within 2 s of an `[idlewasher]` line; the rest are KOReader's own
promotion and menu washes.)

### 6.3 What the data does point at (association, not cause)

- **2 of the 5 episode starts are immediately preceded by a full-panel
  `ui/partial`** — the menu-dismissal repaint — against a base rate of
  6/412 = 1.46 % over the population. P(≥2 of 5) = **2.1e-3**.
- At session granularity (a >900 s gap splits a session): **3 of the 4**
  episode-bearing sessions contained menu activity, base rate 8/36 =
  22.2 %, P(≥3) = **0.037**. That is the issue's per-episode 15 s
  antecedent (4/5, P≈1e-4) surviving on a coarser unit.
- **A distinct, much more regular two-step exists at menu dismissal.**
  6 of 27 `flash*/global` washes are followed within 3 s by a full-panel
  `ui` repaint; four of those at **0.787 / 0.858 / 0.861 / 0.875 s**, i.e.
  0.845 ± 0.034 s (the other two are 2.12 and 2.33 s). That is two
  full-screen updates for one dismissal, on a near-constant latency. It
  is a different phenomenon from the page-turn doubling, far more
  reproducible, and **not explained here** — of the two, it is the
  tractable target. Nobody has watched the panel during one, so whether
  it is visible as a double draw is unknown.
- **No clustering by orientation**: the corpus holds 3 landscape
  full-panel traces in total, and every episode trace is portrait.
- **No readable clustering by time of day**: 5 episode starts over the
  15 hours-of-day that saw any reading. Reported, not read.
- **Episodes do not need a preceding pause**: the gaps before the five
  starts are 0.6, 18.2, 8.7, 2.7 and 1.2 s, against a median inter-turn
  gap of 21.4 s.

### 6.4 What would settle C, and what it costs

The `[pn-refresh]` trace is on the wrong side of the question: it records
what was *asked for*, and C is about what *arrived*. Two ways to close
it, neither offline:

1. **An input-side trace.** `device.lua` already owns the input wiring;
   one unconditional `logger.info` where a page turn is dispatched (the
   `GotoViewRel` handler, or the gesture that reaches it) would make "one
   gesture → two turns" versus "two gestures → two turns" directly
   readable in the same log the refresh traces land in. It must be
   unconditional and unsampled, exactly like `trace()`, or it re-opens
   the sampling doubt issue #14 closed. Cost: a few lines in the wilkbook
   device graft, a `koreader-input` harness test, a rebuild and a
   redeploy — **it changes the shipped reader** — and then another
   multi-day reading window, because the observed rate is about one
   episode per 1.2 days.
2. **Raw evdev capture beside the session log** — `evemu-record` on the
   cyttsp5 node into a ring buffer. No image change, but it needs the
   device, storage, and an operator willing to leave it running for days.

Everything offline that could narrow this has now been done. Four of the
five candidates are out; the survivor is the one this instrument
structurally cannot see.

### 6.5 What this section does not claim

Nothing here was observed on glass — no trace says the panel drew twice,
and the operator's "occasional 2-step page turns" remains the only
optical evidence. Every association is one operator, one image
(`9a08803e…`), 6.19 days. The episodes' trigger is still
**unidentified**.
