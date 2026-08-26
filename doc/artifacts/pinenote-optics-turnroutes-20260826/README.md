# Optics-rig turn-route measurements — 2026-08-26

First campaign of the closed measurement loop
(`pinenote/tools/optics-rig/`): the Brio in the rig above the panel,
fiducial registration validated at 2.6 px on the center-dot control,
and the differential ghost metric run over five turn routes on the
direct driver (7.1.8, hrdl EBC, identity CLUT unless noted). The
campaign that refuted the wipe hypothesis and settled plain GL16
(hint 32) as the reading route — `doc/status.md` 2026-08-26 part 10.

## The numbers

Ghost = residual darkness in former-ink regions relative to
surrounding paper, in %, exposure-invariant. RAW is as measured;
CORR subtracts the same masks' washed-panel baseline (the lighting
gradient between the mask populations: −0.49 % for the 2-page masks,
−0.55 % for the 4-page masks, +0.97 % for the menu masks).

| arm (all washed first) | capture | raw | corrected |
|---|---|---|---|
| washed panel (noise floor, 2-page masks) | cap-baseline.png | −0.49 | 0 |
| plain GL16 (hint 32), 1 a→b turn | cap-gl16-1turn.png | +1.23 | **+1.72** |
| plain GL16, 8 alternating turns | cap-gl16-8turn.png | +1.70 | **+2.19** |
| DU-wipe then GL16 draw, 1 turn | cap-wipe-1turn.png | +1.95 | +2.44 |
| DU-wipe then GL16 draw, 8 turns | cap-wipe-8turn.png | +2.06 | +2.55 |
| GC16-wipe then GL16 draw, 8 turns | cap-gc16wipe-8turn.png | +2.04 | +2.53 |
| plain GL16, 4 distinct pages, page-1 residual | cap-gl16-4page.png | +0.49 | **+1.04** |
| DU-wipe, 4 distinct pages, page-1 residual | cap-wipe-4page.png | +0.76 | +1.31 |
| half-panel black → white, plain GL16 | cap-menu-residue.png | −1.08 | **−2.05** |

Readings:

- The wipe loses at every horizon. Plain GL16 gives old ink the full
  38-phase drive to white; a wipe replaces that with the wipe
  waveform's shorter drive and the draw then no-ops white-over-white.
- GL16 ghost saturates (~2 %) instead of compounding.
- The last row is the menu lesson: a large black region driven back
  to white lands ~2 % BRIGHTER than surrounding paper (overshoot) —
  a visible bright rectangle, i.e. "degradation" with the opposite
  sign the ghost intuition expects.

## Reproduction

Captures are fb-space warps (1872×1404 gray) from `cap.sh` with the
session calibration (camera→fb: 1521.0,640.3→80,80;
2573.0,599.6→1792,80; 1553.0,1408.3→80,1324; 2606.2,1361.5→1792,1324
— dead on any rig move; re-register per the tool README). Payload
pages: `page-{a,b,c,d}.txt` (committed here) typeset per the
README's convert command (DejaVu-Serif, 227 dpi — a font-version
change shifts glyph geometry, so regenerate masks from your own
raws, never mix eras). Arms driven by `ebc-lab/wipe-flip.lua`;
washes via `GLOBAL_REFRESH`; masks per the tool README (4 px
dilation exclusion, `Disk:12` erosion for the menu rect).

## Part 2 — the frame clock and the temperature U-curve

After the route war, the operator's challenge ("we don't flash on the
shipped driver and don't see this ghosting") turned the instrument on
the driver itself. `ebc-lab/frame-clock.lua` timed every frame IRQ:

- GLOBAL_REFRESH (full panel): 38 frames, **18.4 ms/frame steady**
  (54 Hz) — first frames 18.5, drifting to 17.6 by frame 23.
- 200×200 block partial: 38 frames, **12.0 ms/frame** — the panel's
  true scan period, on the waveform contract.
- 1872×660 half-clip: **12.0 ms/frame** — in contract.

So the frame period is COMPUTE-BOUND: the kernel NEON advance cannot
finish clips much beyond half-panel inside one 12.0 ms scan, and page
turns (~90 % of the panel) run their waveform ~1.5× slow. CPU clocks
are exonerated: 27/40 samples during a wash sat at the 1.8 GHz max
(conservative governor, ramp visible in the first frames).

Then the sign flip: the half-clip arm (IN contract) ghosts MORE, not
less. Same top-region masks throughout (baseline bias −0.55 %):

| arm (contract-rate half-clip unless noted) | capture | raw | corrected |
|---|---|---|---|
| full-page arm (18.4 ms frames), top-region remeasure | cap-gl16-1turn.png | +1.51 | +2.06 |
| half-clip, sensor's 24–27 bin | cap-gl16-tophalf3.png | +2.93 | +3.48 |
| half-clip, 24–27 bin, repeat | (uncommitted) | +2.82 | +3.37 |
| half-clip, forced **21–24** bin | cap-gl16-tophalf-t22b.png | +2.11 | **+2.66** |
| half-clip, forced 18–21 bin | cap-gl16-tophalf-t19.png | +2.81 | +3.36 |

Readings:

- At contract timing GL16 UNDERDRIVES on this driver; the stretched
  frames were partially compensating (and overshooting large areas —
  part 1's −2 % menu rectangle).
- The temperature U-curve bottoms one bin COLDER than the sensor's
  pick: the TPS65185 thermistor read exactly 24.0 °C (the 24–27
  boundary) while the panel's optimum was 21–24. One bin ≈ 0.7–0.8 %
  ghost. `temp_override` applies only on a temperature RE-READ — a
  param write alone changes nothing until rebind/probe (the dmesg
  "override temperature" line is the receipt).
- Even at the optimal bin, contract-rate GL16 (+2.66) trails the
  out-of-contract full-page arm (+2.06): the underdrive exceeds one
  temperature bin. Remaining suspects for the gap to the shipping
  driver: VCOM programming in direct mode, CLUT playback fidelity vs
  the hardware LUT engine, source-driver timing config.
- Repeatability of the whole loop: ±0.1 % on back-to-back identical
  arms.

Two poisoned runs are excluded: one with KOReader running (its own
repaints land mid-arm), one where a shell `&` swallowed the arm
(`A && B & C` backgrounds `A && B`) and the capture measured the
washed book page. Run arms with the reader stopped, and check the
flip log actually printed.

## Part 3 — the parallel advance, and the frame-period model refuted

The banded parallel NORMAL advance
(`pinenote/patches/linux-pinenote-7.1-ebc-parallel-advance.patch`) was
built out-of-Guix against the same source/config, live-swapped as
modules (vermagic + MODVERSIONS CRCs matched first try), and measured
the same night:

- Full-panel wash: **18.4 → 11.9 ms/frame** (the panel scan period);
  small-clip timing unchanged; no band-seam artifacts at 4 bands
  (cap-paced-gl16-1turn.png shows the banded paint — clean text).
- `frame_period_us` pacing holds a steady requested period
  (~16.7 ms for a 15.7 ms request — fsleep overshoot ~1 ms).
- `hskew_override` does NOT change the frame period (64→1000: no
  effect) — it is not a pacing lever on this stack.

Ghost at matched conditions, full-page arms, hint 32:

| arm | capture | raw | corrected |
|---|---|---|---|
| 4 bands, 12.0 ms, bin 21–24 | cap-par-gl16-1turn.png | +2.38 | +2.87 |
| 4 bands, paced ~16.7 ms | cap-paced-gl16-1turn.png | +2.47 | +2.96 |
| 1 band forced, natural ~17.1 ms, bin 22 pinned | cap-iso-single.png | +2.34 | +2.83 |

All three are the same number: **banding costs nothing** (1 vs 4 bands
identical) and **frame period 12–18 ms is ghost-neutral** at matched
temperature — refuting Part 2's "waveform timing contract" reading.
The stretched-era +1.72 was measured hours earlier on a warmer panel:
between-session ghost comparisons are temperature-confounded by
~1 % across an evening, which is the standing reason the
shipping-vs-direct comparison must be run same-session, minutes apart,
on this instrument.

Also caught live: writing a black block over fbcon's black console is
a genuine no-op (frames=0) — the standing zero-IRQ-delta lesson, now
with an optics-rig cameo.
