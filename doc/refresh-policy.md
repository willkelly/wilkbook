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
- `refresh_threshold` units are ~half-screens of *accumulated* damage
  (threshold × 1,314,144 px), not percent — our cmdline 60 means the
  auto global refresh fires after roughly 30 page-turns' worth. hrdl's
  stack uses 20. Workbench input.
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

The first four-config sweep (GL16/GC16 fulls x full_refresh_count 6/never/1;
bundles + reports under `pinenote/tools/optics/build/bundles/sweep1.*`):

1. **Full refreshes are load-bearing under GL16.** With
   `full_refresh_count=never`, ghost rms on blank-reveal pairs hits **0.309**
   vs ~0.121 for every config with fulls (2.5x the floor) — and after ~40
   fulls-free partial turns the accumulated residue in frequently-toggled
   regions reached 0.2-0.4 reflectance, enough to corrupt the test card's own
   1-bit barcode (cells read 0.63-0.82 instead of ~0/~1; the static reference
   patches stayed clean, so this is real reflectance, not calibration). The
   deep-clean/promotion cadence question is answered: REQUIRED, not optional.
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
