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

## Open questions for the phase B workbench

- Replay captured `[pn-refresh]` traces under candidate policies:
  flash-threshold values, full_refresh_count, GL16-vs-GC16 cadence,
  refresh_threshold/auto_refresh, split_area_limit (quirk: scheduler
  finding 2 worsens at 0), DU partials with binarized content.
- Metrics per trace: flash count, pixels driven, frames-to-settle,
  est. wall ms per page turn (phases × 1/85 Hz).
- Believed-white residue accumulation rate under GL16-only fulls (the
  one thing GL16 never cleans) — how often does a GC16 deep-clean
  actually need to run?
- Cold-bin behavior (GC16 = 1.5 s at 0 °C): should full_refresh_count
  scale with temperature?
- Harvest next hardware session: evtest captures of a pinch, a
  palm-while-writing trace, gpio-keys contents.
