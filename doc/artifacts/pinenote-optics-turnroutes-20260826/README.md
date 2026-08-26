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
