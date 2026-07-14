# Refresh policy — evidence and decisions

The home of the display-quality program: what the panel actually does,
what policy levers exist, what we chose and why. Companion to
`doc/eink-research.md` (domain background) and `doc/testing.md` (the
rungs that validate this offline). Started 2026-07-05 from the phase A
hardware verdict: menus fixed, "full refresh is very flashy — a lot of
black", stylus+touch UX "feels wrong".

## The flash, decoded from our own waveform

All numbers decoded from this device's `ebc.wbf` (never committed) with
`pinenote/tools/wbf` at the 28 °C temperature bin (index 9 of 13), 85 Hz
frame clock. Notation: per-phase drive — `D` darken, `L` lighten,
`.` neutral.

```
GC16  white->white (15,15): DDDDDDDDDDDDDDLLLLLLL........LLLLLLL..
GC16  black->black ( 0, 0): .LLLLLLLLLLLLLLDDDDLLLLDDDDDDDDDDDDDD.
GC16  gray8->gray8 ( 8, 8): ...........LLLLLLLDDDDDDDDDD....LLL...
GL16  white->white (15,15): ......................................
GL16  everything else     : byte-identical to GC16
```

**Why a full refresh "goes black":** the driver's global refresh sets
`EBC_DSP_CTRL_DSP_LUT_MODE` with no diff masking, so *every* pixel runs
the full LUT sequence — and GC16 drives all 256 (from,to) pairs
including the 16 already-at-target diagonals. A white pixel staying
white is driven **toward black for the first 14 of 38 phases
(~165 ms)** while black pixels are simultaneously lightened: the panel
literally displays a negative of the page, then scrubs to target.
That is the flash. It is waveform-driven, not a software double-draw.

**GL16 is the fix the waveform itself offers.** In this .wbf, GL16 is
byte-for-byte GC16 *except* the (15,15) sequence is fully neutral —
the white page background is simply not driven. Same 38 phases, same
447 ms, same scrubbing of text/grays/blacks (gray8→gray8 still gets
its 10D+10L excursion). What GL16 gives up: ghost residue sitting in
pixels the driver *believes* are white→white is never scrubbed — that
is precisely GC16's white wash. GCC16/GLR16/GLD16 in this file are
sha-identical to GL16, so the real menu is: GC16 (deep clean, flashy)
or GL16 (background-preserving wash).

Mode inventory at 28 °C (phases → wall time at 85 Hz; driver clocks
one extra neutral frame, +~12 ms):

| mode | phases | duration | drives | grayscale-safe? |
| --- | --- | --- | --- | --- |
| A2   | 10 | 118 ms | only 0↔15 | no (b/w only) |
| DU   | 19 | 224 ms | any → {0,15} | no (b/w targets only) |
| DU4  | 24 | 282 ms | targets in 4-tone set | 4-tone only |
| GC16 | 38 | 447 ms | all 256 pairs | yes |
| GL16 | 38 | 447 ms | 255 pairs — (15,15) neutral | yes |
| RESET | 87 | 1024 ms | init wash | — |

Temperature matters: GC16/GL16 are 38 phases in every bin ≥ 24 °C but
grow to **131 phases (1.54 s) at 0 °C**. GL16's no-flash property is
verified at the 28 °C bin; re-dump colder bins before relying on it
outdoors (`wbf-info <wbf> <temp>`).

**DU/A2 as global refresh waveforms are unsound for KOReader output**
(antialiased grays get no drive while the driver's prev bookkeeping is
overwritten → persistent desync ghosts). The driver's
`globre_convert_before=1` / `prepare_prev_before_a2=1` params exist
exactly for this; leave DU/A2 to the phase B workbench.

## Decisions so far

1. **Phase A flash policy (2026-07-05, hardware-validated):** KOReader's
   flashui/flashpartial intents wash only when damage ≥ 60% of the
   panel; ui/fast/a2/partial stay on deferred-io partials; `full` always
   washes. Verdict on device: menus stopped blinking, no visible
   ghosting accumulation.
2. **Global refresh waveform = GL16** (`rockchip_ebc.refresh_waveform=6`
   on the cmdline, 2026-07-05 evening): the every-N-pages full wash and
   any auto/ioctl global refresh keep the page background white instead
   of flashing a negative. Awaiting hardware optics judgment.
   Follow-up idea if believed-white residue accumulates: a KOReader
   dispatcher action that flips the param to GC16, fires one global
   refresh, and flips back ("deep clean" gesture) — KOReader runs as
   root and the param is runtime-writable.
3. **Partials stay GC16** (`default_waveform` untouched): partial
   updates are diff-masked (only changed pixels drive), so GL16 ≡ GC16
   there; DU partials would corrupt antialiased text. Page-turn speed
   work belongs to the phase B workbench (waveform choices need the
   replay evidence).
4. **full_refresh_count is the user's knob** (KOReader menu, default 6
   — promotes every 6th page turn to `full`). With no ghosting observed
   and GL16 fulls, raising it is cheap; not seeded, user preference.
5. **Input architecture (2026-07-05 evening):** the touch/stylus
   "feels wrong" verdict root-caused to two frontend wiring bugs, fixed
   on the reMarkable-on-mainline pattern: `handleMixedTouchEv` (the
   cyttsp5's legacy single-touch ABS aliases were being misread as MT
   slot coordinates — two-finger gestures were structurally broken) and
   per-source event conditioning via `src` tagging in our evdev backend
   (pen scaling no longer keys off a proximity boolean that mangled
   touch coordinates whenever the pen hovered; the touchscreen's legacy
   BTN_TOUCH no longer poisons the wacom contact gate — palm-while-pen
   ghost taps; the ws8100 button driver's BTN_TOOL_PEN/RUBBER wrappers
   no longer fight the digitizer's true proximity). Bonus: ws8100 pen
   barrel long-presses now page-turn (KEY_BACK/KEY_FORWARD →
   RPgBack/RPgFwd) — no community project had wired these.

## Context that frames the policy space

- Per-update waveform selection **does not exist** in the driver UAPI
  (one `default_waveform` for partials, one `refresh_waveform` for
  globals, both runtime-writable module params). Adding it is
  community-owned driver work; runtime param flips are the sanctioned
  workaround and the rung-7a harness executes the verbatim driver, so
  flip races are testable offline.
- `refresh_threshold` units (RESOLVED 2026-07-12, pageturn-program
  source audit): the accumulator counts PIXELS of damage and
  `one_screen_area` = 1,314,144 px = HALF the 1872x1404 panel — so
  threshold 60 fires after ~30 full-page turns' worth. (Finding 7's
  earlier "whole screen-areas, ~every 60 turns" correction
  over-corrected; the original ~30-turn figure was right. History
  preserved in finding 7.) hrdl's stack uses 20. Workbench input.
- No community KOReader PineNote target exists — hrdl/PNDeb run stock
  SDL builds under sway with e-ink policy outside KOReader. Our native
  target is novel; upstream issues #14017 (full-refresh) and #14694
  (stylus-as-finger) are the relevant conversations for upstreaming.
- KOReader's canonical e-ink mapping on mxcfb devices: full→GC16-class
  flash, fast/a2→DU/A2, ui/partial→AUTO with waveform per update — the
  shape to emulate if per-update selection ever lands in the driver.

## The phase B workbench (built 2026-07-05, `ebc-replay`)

`pinenote/tools/ebc-logic/ebc-replay` replays `[pn-refresh]` traces
(real ones from `/var/log/reader-session.log`, or `synth`-generated
sessions) through the **verbatim driver's refresh thread** against the
rung-7a fake device, on an 85 Hz frame-clock model.  It re-decides every
intent under a candidate policy (flash fraction, waveforms, driver
params), models the two layers the trace does not record — deferred-io
page-band damage and the driver's own auto-refresh accumulator — and
reports washes by cause, the black-flash census, pixel-phases, settle
latency, and scrub staleness.  Tool details in the ebc-logic README;
runs are deterministic and take seconds at `scale=2`.

### First study: 120-page session, 6 menus, synthetic content (scale 2)

Ship policy unless noted (flash-frac 0.60, GC16 partials, auto_refresh=1
threshold=60, defio bands, flush delay 0, 25 °C).  Traces differ only
where stated.

| run | washes (ioctl+auto) | white px driven dark | wash px-phases | staleness p50/p90 |
| --- | --- | --- | --- | --- |
| GC16 fulls (phase A)   | 26+3 | **12.0 M** | 509 M | 3 / 3 frames |
| GL16 fulls (phase A.2) | 26+3 | **0**      | 222 M | 28 212 / 28 212 (whole session) |
| GL16, full-every 12    | 16+3 | 0          | 145 M | 28 212 / 28 212 |
| GL16, no promoted fulls, thr 60 | 6+4 | 0 | 72 M  | 28 212 / 28 212 |
| GL16, no promoted fulls, thr 20 (hrdl) | 6+12 | 0 | 122 M | 28 212 / 28 212 |
| GL16 + real ~50 ms deferred-io lag | 25+4 | 0 | 187 M | 28 250 / 28 250 |

(Counts at scale 2 = ¼ of native pixel counts.  Settle latency was
38 frames / 447 ms median in every delay-0 run — the GC16 partial page
turn, matching the waveform decode exactly; the scheduler adds zero
frames.)

### First real trace (A.2 first boot, 2026-07-05)

`pinenote/tools/ebc-logic/traces/2026-07-05-a2-first-boot.trace` — 59
events / 153 s harvested post-mortem from the device's
reader-session.log (quickstart navigation, menus, the TOC-tap-bug
reproduction attempts).  The device ran GC16 globals that boot (the
refresh_waveform config bug, fixed same day), so the replay pair is the
policy A/B on real usage:

| refresh waveform | wash px-phases | white px driven dark | staleness p90 |
| --- | --- | --- | --- |
| GC16 (as run)    | 385 M | 9.19 M | 13.3 s |
| GL16 (intended)  | 165 M | 0      | 154 s (whole session) |

The synthetic study's 2.3× wash-cost ratio and the zero-vs-millions
dark-drive split reproduce exactly on real usage, and settle stays
38 frames / 447 ms.  One new observation the synthetic sessions did not
predict: the real session fired **22 ioctl washes in 153 s** (~every
7 s — quickstart page jumps + promoted flashes), so under GC16 the felt
experience was a black flash every few seconds.  That wash *rate* is a
policy lever the workbench should explore next (full_refresh_count and
flash-frac interact with navigation-heavy usage very differently than
with linear reading).

### What the numbers say

1. **The A.2 GL16 decision, quantified.**  Same trace, same washes:
   GC16 fulls drove 12.0 M believed-white pixels dark over the session
   (the black flash the user reported); GL16 drove **zero**, at 2.3×
   fewer wash pixel-phases.  The panel-visible tradeoff is the
   staleness column: under GL16 the white background (~70 % of the
   screen with this content model) is never actively driven after the
   boot wash — 330 s and counting at session end.
2. **Under GL16 fulls, `full_refresh_count` loses its scrub value.**
   The whole point of promoting every Nth page turn to `full` is
   scrubbing accumulated residue — but a GL16 wash does not drive the
   white background either, so staleness is *identical* at full-every
   6, 12, or never.  What frequent fulls still buy is ghost-scrub of
   recently-driven (text) regions; what they cost is a 447 ms
   interruption and ~8 M px-phases each.  Consequence: with GL16
   globals, raising `full_refresh_count` (KOReader menu, default 6) is
   nearly free, and the **only mechanism that re-scrubs whites is a
   GC16 deep clean** — promoting the "dispatcher deep-clean action"
   idea from nice-to-have to the load-bearing residue answer.
3. **Driver quirk (reported, not patched — ebc-logic README finding 7):
   manual washes never reset the auto-refresh accumulator.**
   `ctx->area_count` clears only when the auto threshold itself fires,
   so with `auto_refresh=1` the driver fires its own whole-panel wash
   every `refresh_threshold` half-screens of partial damage *regardless*
   of interleaved user washes — 3 redundant auto washes rode along in
   the full-every-6 run above.  Executed as a `quirk:` test in
   `ebc-replay selftest`.
4. **hrdl's threshold 20 vs our 60**: 12 auto washes per 120 pages vs 4
   (one per ~10 pages vs ~30).  With GL16 autos both are optically
   cheap; with GC16-class washes threshold 20 would flash every ~10
   page turns.
5. **The ioctl races the deferred-io flush — and wins.**  On the device
   the wash ioctl fires at trace time while the painted page travels
   via the fbdev flush timer (~50 ms).  The `defio-delay-ms=50` run
   models that: washes start on the **stale** page, the flush lands
   after, and a follow-up full-band partial draws the new content —
   +22 % partial pixel-phases, median page turn 42 frames/494 ms, and
   under GC16 this is literally the "draws all black and then redraws"
   the hardware verdict described (the wash inverts the *old* page,
   then the new one paints).  GL16 removes the black; the two-pass
   structure remains.  A future policy could delay the ioctl by one
   flush period to wash the new content instead — workbench-testable.
6. **Deferred-io banding** cost ~1.6 % partial pixel-phases on this
   page-turn-dominated session and changed no wash counts (page turns
   are full-screen already; menu rects widen to full-width bands but
   their out-of-rect rows diff-mask to nothing).  It will matter more
   for small frequent UI damage (clock, progress bar) — `defio=bands`
   stays the default for honesty.

### Open questions (updated)

- Replay a **real** harvested trace (next hardware session) and compare
  against the synthetic model; run `verify-decisions=1` as the model
  self-check.
- The deep-clean action: trigger (gesture? every N GL16 washes? on
  A2/DU exit?), and whether it should be GC16-global or a driver-param
  flip around one wash.  The workbench can now cost candidate cadences;
  the optics (how much residue actually accumulates before a clean is
  *visible*) stay hardware-only.
- DU partials with binarized content (`bw_mode`), split_area_limit >0
  (rung-2 scheduler quirk E interacts), and cold-bin cadence (GC16 =
  1.5 s at 0 °C; `temp-c=` is a workbench knob now).
- Harvest next hardware session: `/var/log/reader-session.log` traces,
  evtest captures of a pinch, a palm-while-writing trace, gpio-keys
  contents.

## First measured results (2026-07-11, the calibrated boxed rig)

The full dataset behind this section — bundle catalog, per-claim evidence
audit, and the committed session/trace/report files — is documented for
third-party review in `doc/optics-dataset-2026-07.md`
(+ `doc/datasets/2026-07-optics/`).

The first four-config sweep (GL16/GC16 fulls x full_refresh_count 6/never/1;
bundles + reports under `pinenote/tools/optics/build/bundles/sweep1.*`):

1. **Full refreshes are load-bearing under GL16.** With
   `full_refresh_count=never`, ghost rms on blank-reveal pairs hits **0.309**
   vs ~0.121 for every config with fulls (2.5x the floor) — and after ~40
   fulls-free partial turns the accumulated residue in frequently-toggled
   regions reached 0.2-0.4 reflectance, enough to corrupt the test card's own
   1-bit barcode (cells read 0.63-0.82 instead of ~0/~1; the static reference
   patches stayed clean, so this is real reflectance, not calibration).
   (CORRECTED, 2026-07-12 evidence audit — driver-findings-report.md: this
   run's barcode-corruption reading was a measurement artifact.
   Geometry-verified re-analysis shows sweep1.r02's marks crisp
   (0.007-0.024) with 100% decode through the whole washless pass; the
   0.63-0.82 cells were displaced-geometry samples, and the 0.309 ghost is
   the single corr~0 transition §5.1 of the dataset doc already demoted.
   The washless-regime corruption evidence lives in finding 8's neverx3
   runs, and the cadence recommendation stands on findings 6-7's data.)
   The deep-clean/promotion cadence question is answered: REQUIRED, not
   optional.
2. **Partial page turns are near-flash-free in every config** (depth
   0.00-0.05) — the diff-masked partial regime is clean regardless of the
   global waveform choice. The one partial artifact is the text-CLEAR
   shimmer: whites adjacent to erasing text dip 0.148±0.032 transiently
   (absent when text appears) — quantified on the 10-repeat noise pilot.
3. **full_refresh_count=1 is pure cost**: ghost 0.121 (same as cadence 6)
   for 48 flashes instead of 8.
4. **KOReader pays two washes to leave the menu-style page** (`ux->novel`
   double-flash x2 on every repetition) — a policy fix candidate.
5. **GL16-vs-GC16 full flash depth: NOT yet concluded.** Both measured
   ~0.15-0.19 on n=2 clean samples — suggestive that GL16's advantage
   shrinks once drift exists, but the NaN guard (tiny stays-white masks) and
   the trace->transition join (PLAN task 10) must land before that claim is
   made. It is the first question for the next sweep.

6. **Cadence sweep (6/12/20, GL16 fulls): the accumulation curve is FLAT
   through 18 turns since the last full** (blank-reveal ghost 0.117-0.132
   across all distance buckets vs floor 0.121±0.009, 17 samples pooled across
   the three cadences), while zero-fulls degrades to 0.309 by ~40 turns and
   corrupts toggle-heavy regions. Accumulation is a cliff past ~20, not a
   slope. **Recommendation: full_refresh_count=12** — half the flash events
   of the current default 6 at zero measured ghost cost (20 also measured
   clean but sits closer to the unmapped cliff with thinner data; mapping
   the 20-40 turn cliff onset is the obvious follow-up sweep). Set via the
   KOReader menu per Decision 4 (user's knob); 12 is now the evidence-based
   suggestion. Bundles: `pinenote/tools/optics/build/bundles/cadence.*`.
7. **Cliff mapping (c25/c35/c40) found NO cliff.** (CORRECTED, see 8: the
   original explanation credited the driver's auto-refresh backstop; the
   driver source says threshold units are whole SCREEN-AREAS, so at the
   shipping 60 it fires ~every 60 turns — beyond every tested span. The flat
   curve is real GL16-partial non-accumulation in normal content.) The pooled six-cadence curve is flat 0-33 turns since a
   KOReader full (0.093-0.146, floor 0.121±0.009, 39 samples), and c40
   segmented 47/48 (barcode healthy through 39-turn spans). The resolution of
   the apparent 20->40 cliff: every run carries the SHIPPING driver config
   `auto_refresh=1, refresh_threshold=60` half-screens, so the DRIVER injects
   its own auto-global roughly every ~30 full-page turns — invisible to the
   [pn-refresh] trace. KOReader promotion and the driver threshold are
   overlapping cadence mechanisms; with the backstop present, ANY
   full_refresh_count >= 12 is optically free. The `never` run's 0.309 +
   barcode corruption stands as a single-run outlier pending the soak
   scenario (PLAN task 19: full_refresh_count=never AND auto_refresh=0 —
   exactly the confound its design anticipated), which is where the TRUE
   material accumulation curve gets measured. Bundles: `.../cliff.*`.
8. **`full_refresh_count=never` REFUTED by replication (3/3 corrupt).** Two
   fresh never-runs both showed barcode-region corruption signatures (one
   segmented 0/48; one shattered into 429 pseudo-transitions from decode
   bits flickering on the threshold) — matching the original outlier. With
   the driver threshold at 60 screen-areas, nothing washes within a 48-turn
   pass, and high-frequency-toggle regions accumulate believed-white mud.
   (CORRECTED, 2026-07-12 evidence audit — driver-findings-report.md: the
   0/48 and 429 COUNTS are instrument-dominated — a fixed session
   homography poisoned by the captures' graphic-page openers displaced
   every sample — but the corruption in never-a and never-b is REAL and
   directly on camera: never-a's partials paint whole pages as
   barely-visible ghosts (restored seconds later by an unexplained
   global), and never-b's fine marks sit at 0.22-0.38 (~10x the crisp
   floor) mid-run with a within-run onset. The FORM is corrected too:
   episodic whole-page ghost paints and mark fade, already present at
   never-a's first content pages — not toggle-region mud accumulating
   over the pass. never-c audits clean; the original sweep1.r02 outlier
   is voided (see finding 1) — so the replication tally is 2 corrupt of
   3 fresh never-runs, and the corruption correlates with
   `auto_refresh=1` sessions (finding 10) rather than with washlessness
   itself.) Synthesis: static reading content never accumulates;
   toggle-heavy regions REQUIRE periodic washes; the washes in every
   clean run came from KOReader promotion. The driver-owned architecture
   (never + refresh_threshold≈8, single cadence owner) is under test — it
   is viable iff the driver's auto-global scrubs toggle regions the way
   KOReader's promoted fulls do. Bundles: `.../neverx3.*`,
   `.../driver-owned.*`.
9. **Soak (both mechanisms OFF, 30 same-pair toggles + wash interventions):
   NO accumulation — the simple toggle-count mechanism is refuted.** The
   single toggling barcode cell tracked its never-toggling neighbors within
   ~0.01 across all 30 washless flips (cell-level tracking at half-res;
   parity square likewise ~2% at most); the GL16 and GC16 interventions had
   nothing to scrub. Yet diverse-page never-runs corrupt 3/4. The corrupting
   ingredient is therefore NOT how often a cell toggles but either (a)
   DIVERSE gray-transition sequences per cell (many different pages — what
   the card v2 accumulation block was designed to cycle), or (b) an
   interaction with `auto_refresh=1` itself, which was ON in every corrupting
   run and OFF in the clean soak — i.e. the driver's auto-globals may cause
   the believed-white drift they are meant to prevent. Also noted:
   `refresh_threshold=8` + never still corrupted (6/48), and the
   GLOBAL_REFRESH ioctl works under a live DRM master (deep_clean was always
   real). (CORRECTED, 2026-07-12 evidence audit — driver-findings-report.md:
   the driver-owned "6/48" was a session-homography instrument artifact;
   that run is optically CLEAN on geometry-verified frames through ~11
   camera-confirmed threshold firings, and becomes counter-evidence that
   threshold firings corrupt per-event. The soak's own headline stands on
   100%-valid frames, but its "two unexplained events" anomaly (below) is
   upgraded: both are real static-region drives, and the second (t≈105,
   mid-dwell, autos OFF) permanently grays a framing cell 0.01 -> ~0.10 —
   so auto_refresh=0 was not event-free that boot either.) Next
   experiments: the diverse-page soak (accumulation block) x
   auto_refresh on/off — a 2x2 that isolates the mechanism.
   Bundle: `.../soak1` (+ soak-events.json).
10. **MECHANISM FOUND: the driver's threshold-triggered auto-globals CAUSE
    the corruption (2x2 complete).** Arms: diverse+auto1 corrupts 3/4
    (neverx3); diverse+auto0 CLEAN 2/2 (armB 45/48, armB2 49/48);
    same-pair+auto1 shows 4-5x dark-cell graying (armC); same-pair+auto0
    clean (soak1). A patch-strip wash detector (only globals redraw the
    static strip) caught unexplained globals exactly in the auto=1 runs:
    armC t≈90s, corrupted never-a t≈109s — the culprit on camera — while
    accounting for every manual/ioctl wash in soak1 (plus TWO unexplained
    events there at t≈100/105 with autos off: flagged anomaly, possibly the
    spontaneous-global flakiness family). (CORRECTED, 2026-07-12 evidence
    audit — driver-findings-report.md, per-claim verdicts: the 2x2's
    headline correlation survives — every run with run-level
    corruption/graying was auto=1, both auto=0 runs are free of run-level
    corruption — but four cells are revised. Diverse+auto1 corrupts 2/4,
    not 3/4 (never-c audits clean; the sweep1.r02 outlier is voided, see
    finding 1). armC's graying is real on verified frames (0.08-0.10 vs
    0.001-0.02 same-rig floors, with a per-event step 0.04 -> 0.09 across
    the t≈90 wash) but the "4-5x" figure came through displaced geometry.
    never-a's t≈109 global is real yet its role inverts: it RESTORED a
    ghost-painted page — the corrupting agent on camera is the preceding
    partial paint. And soak1's two auto=0 events are upgraded from anomaly
    to evidence: real static-region drives, the second permanently graying
    a framing cell 0.01 -> ~0.10 — so the damaging-drive phenomenon is not
    exclusive to the threshold path. Finally, driver-owned (threshold=8)
    audits optically CLEAN through ~11 on-camera firings, so "each
    threshold firing does damage" is retracted; per-event damage is rare
    and stochastic. The policy consequence below is unchanged and, if
    anything, reinforced: ioctl washes remain corruption-free across ~30+
    on-camera firings.) ioctl-fired globals (deep_clean,
    KOReader promotions) have never corrupted anything: the wash PATH is
    the variable, not the wash. Stochasticity explained by quirk 3 ("manual
    washes never reset the accumulator"): the damage counter accrues ACROSS
    runs, so auto firings are random-phase — also the likely story behind
    cadence.r01 (c12) quietly under-segmenting 19/48 (the evidence audit
    adds an instrument-first candidate for that count: the session-
    homography opener artifact). **Policy consequence:
    set `auto_refresh=0` and own all washes from userspace via the ioctl
    (KOReader promotion at 12 today; the idle-washer later). Driver finding
    written for upstream (doc/driver-findings-report.md).** Since
    root-caused offline: the threshold path is the driver's only zero-gap
    global launcher and the counting completion handshake lets a straggler
    DSP_END truncate the wash mid-playback — quirk F in `ebc-refresh-test`,
    mechanism + fix sketch in the report's 2026-07-12 entry. Bundles:
    `.../armB*`, `.../armC`.

11. **The idle-washer is validated on glass (acceptance runs, 2026-07-12).**
    The userspace refresh manager (`idlewasher.koplugin`: debt per page turn,
    GL16 full via the ioctl path when debt >= debt_min AND idle >= idle_s,
    bundled full riding the turn at debt_max, GC16 deep clean once per long
    idle span) passed a three-phase on-glass acceptance: idle wash exactly
    idle_s into a pause with debt over min, silence through a below-min
    pause, and — the regression the first run caught — an idle wash after
    reading RESUMES from a below-min span (the timer had been armed on the
    deep-clean horizon; on_input now pulls the deadline back, b82bab1).
    Log lines and the patch-strip detector agreed to ~0.5 s in every run;
    bundled washes additionally proven twice (r0/r1). This completes the
    finding-10 policy: `auto_refresh=0` + KOReader promotion off (`never`)
    + the washer owning cadence is a fully working configuration; promotion
    at 12 remains the belt-and-suspenders default until the washer has
    dogfooding hours. Bundles: `.../idlewasher-accept*`.

12. **GL16 vs GC16 fulls on real content: optically indistinguishable
    flash depth — the pair class dominates, not the waveform (first
    attributed comparison, 2026-07-12).** With the hardened analyzer
    (session-H trust, no-NaN flash, trace->transition join), sweep1
    re-analysis attributes each run's promoted fulls exactly (8 GL16 /
    7 GC16, matching the runs' own [pn-refresh] traces). Per-pair,
    GL16 and GC16 fulls measure the same (~0.06 mean stays-white depth
    both, n=7/6 shared pairs), novel->blank is noisy between runs in
    BOTH directions (0.20/0.12 vs 0.06/0.17), and the waveform-decode
    expectation (GL16 gentler on whites) does not dominate real content
    transitions. One real outlier flagged, not explained: the GL16 run's
    index->ux full flashed 0.35 deep (single 0.2 s event; GC16's same
    pair: 0.04) — n=1, possibly the ux double-flash family. Policy
    consequence: Decision 2 (GL16 for washes) stands — it costs nothing
    optically and preserves the GC16 deep-clean contrast for
    believed-white scrubbing — but the choice is architectural, not a
    measured comfort win. Reports: `sweep1.r0{0,1}-report-v3.json`
    (first generation with per-transition wash attribution).

13. **Relaxation drift measured directly — the physics channel is real
    on this panel (veritas session, 2026-07-13, A.2.8-dbg fixed
    kernel).** A freshly deep-cleaned, freshly painted graphic page left
    with ZERO drives for 300 s under camera: dark structure lightened
    monotonically 0.204 -> 0.223 (+0.019, ~0.004/min) while whites held
    (0.886 -> 0.889). No scheduler, no bookkeeping, no updates — this is
    remnant-voltage/relaxation physics (doc/eink-sota.md's dwell/remnant
    hypothesis), measured. Extrapolated over a 30+ min washless span it
    reaches armC-scale graying with no driver bug required. Same
    session: (a) the corrupting-class diverse walk on the OVERLAP-FIXED
    scheduler ran clean (dark drift +0.004; 22 threshold globals, zero
    stragglers/earlies) — the fixed-kernel B-arm baseline is set, though
    single-run cleanliness never discriminated (pre-fix single runs were
    also clean); (b) a dwell probe (3 s vs 60 s holds, same pair) read
    ghost-spread 0.075 vs 0.098 — direction matches dwell-time physics,
    underpowered at n=6/3 (sd ~0.06); a powered version is queued;
    (c) EXTRACT_FBS belief dumps joined to camera frames end to end for
    the first time — the naive pixelwise join reads correlation 0.386,
    i.e. the instrument works but the join needs proper registration
    (framebuffer space vs camera panel space differ by reflection +
    alignment; PLAN task 23's remaining half). POLICY IMPLICATION: the
    idle-washer's periodic washes are load-bearing against pure physics,
    not just against driver misbehavior — and dark-heavy content wants
    them on a clock, not only on debt. Bundle: `.../veritas`.
    (CORRECTION, same day: the eroded-interior discriminator shows the
    full-mask +0.019 was edge-inflated ~2x by sub-pixel registration
    creep; the registration-immune interior drift is +0.009/300 s
    (~0.002/min), 4.5x the white control (+0.002). The relaxation is
    real; the rate above is halved. Also: the displayed page during V3
    was a near-blank card page, not the graphic page as written — the
    injector's page tracking drifted; dark area was marks/patches only.)

Instrument provenance: 30 fps / exposure 312 / gain 32 / frontlight 255-255;
ghost-rms repeatability sigma 0.003-0.006 between identical transitions.

## Measuring the optics directly (the harness that ends "hardware-only")

Every "stays hardware-only, human eyeball" caveat above — how much residue
accumulates before a GL16 wash needs a GC16 deep clean, whether the flash is
actually gone, how a page turn settles — is what `pinenote/tools/optics` is
being built to *measure*, repeatably, off a webcam-in-a-box (device frontlight
as the illuminant). It is deliberately portable so friends with PineNotes (not
just Fable's) can contribute captures — multi-panel data matters because each
unit has its own waveform calibration. The deterministic defect classifiers
(black flash, ghost, settle, double-flash) are built and validated offline on
synthetic clips (`make optics-check`); the self-calibrating test epub,
real-video ingest, and on-device recorder are the next pieces. Once it lands it
also **ground-truths this workbench's proxies** ("white driven dark", wash
px-phases, staleness) against measured optics. See
`pinenote/tools/optics/README.md`.
