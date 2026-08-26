# D8: nib-to-ink latency, measured — FAST vs NORMAL

2026-08-26, the direct-mode ladder's D8 rung closed. Instrument:
`pinenote/tools/pen/` (scribble.lua drawing black ink into /dev/fb0
with one fsync per event batch; ebc-mode.lua switching driver mode and
hints). Camera: Samsung Galaxy slow motion, 240 fps effective inside
the edit-list slow section (4.17 ms/frame). Operator drew and tapped;
analysis counted frames between nib contact and ink visibility on
filmstrip extractions, then confirmed with per-frame ROI luminance
curves at tap-dot locations.

## Results

| | FAST (table-free engine) | NORMAL (CLUT engine) |
|---|---|---|
| software path (pen event → fsync returned) | 0.3 ms median | 0.3 ms median |
| nib contact → first visible ink | **~20 ms** (17–25 ms, two strikes, ±2 frames) | **~40–60 ms** (cleanest strike; second event compatible) |
| first ink → fully dark | ~100 ms | **~250–290 ms** (plateau at luma 138 from white 175) |
| grayscale capability | none (binary by construction) | full CLUT (16-level) |

The felt verdicts these numbers sit under: FAST — "absolutely insane
… WAY faster than I expected"; NORMAL — "feels pretty much the same
to write on." Both true: both modes land at or below the ~50–70 ms
threshold where a hand notices drawing lag, and FAST is 2× faster to
first ink and ~3× faster to solid. The margins where FAST earns its
keep: fast flicks and small print (one NORMAL strike showed ink-free
glass 90 ms after the nib left; another light tap left no ink at all).

Physics cross-check: FAST first-visibility at 1–2 phases of the
~36 ms table-free drive ✓; NORMAL development plateau at ~250–290 ms
matches GL16's ~22 active phases ≈ 260 ms at the cold bin ✓.

## Files

- `fast-strike-1-frames1240-1256.jpg`, `fast-strike-2-…` — 240 fps
  filmstrips (step 2) of two FAST colon-dot strikes: nib lowest at
  ~1246/~1210, first ink at ~1250–1252/~1214–1216.
- `normal-strike-frames2450-2486.jpg` — a NORMAL strike window: nib
  down at ~2464, no visible ink by 2486 (90 ms) — first-visibility in
  NORMAL exceeds the whole FAST budget.
- `normal-dot-geometry-audit.png` — the grid-overlaid patch that
  pinned dot coordinates after two mis-aimed ROI passes.
- `normal-dot445-yavg-curve.csv` — the decisive aligned luminance
  curve (frames 2480–2640): strike complex, nib clearing with
  recovery arrested at 158 (ink already present), monotone descent to
  the 138 plateau by ~2600.

## The methodology trap, for the next analyst

Samsung slow-motion files carry an edit list, and ffmpeg's two input
paths honor it differently: `ffmpeg -i file` (and its `select=`
filter) decodes the retimed timeline; the lavfi `movie=` source used
by `ffprobe -f lavfi` reads a DIFFERENT frame sequence at the same
nominal frame numbers. Cross-pipeline frame indices silently
disagree — a frame-3100 patch was inked in one pipeline and blank in
the other. Every number above comes from the self-consistent `-i`
pipeline (`signalstats,metadata=print` for curves, `select=` for
frames). The muxer's non-monotonic-dts warnings mark the edit-list
splice points (here 986/2765) — outside them the 4.17 ms/frame
arithmetic is wrong. Second trap: a 36×36 ROI buries an 8 px dot in
~2 luma units; match the ROI to the mark (12×12 dead-center gives a
~35-unit signal).

## Interpretation for the campaign

The embrace threshold ("FAST reaches pen-class latency, tens of ms")
is met with margin — and NORMAL alone is inside pen-class too, which
reframes the product: NORMAL (the CLUT path, the same waveform
lineage the shipping driver renders with) can carry BOTH reading and
writing, with FAST as an opt-in sketch mode rather than a required
posture. What direct mode still owes the reader is page-turn
transition quality, not rendering fidelity — the standing optics +
PHASE_SEQUENCE workstreams.
