# optics-rig — closed-loop panel measurement

The workstation half of the display-quality loop: a Brio in the
cardboard rig above the panel, a one-time fiducial registration, and a
luma-differential ghost metric. With it an agent can display a route
under test, capture the panel, and get a ghost number — no human eyes
in the loop. First used 2026-08-26 to adjudicate the page-turn route
war (`doc/status.md`); the numbers that killed the wipe hypothesis and
crowned plain GL16 came from this harness.

## Protocol

1. **Fiducials.** `./make-fiducials.sh out.raw` renders the
   registration pattern (white field, 80 px black squares centered at
   fb (80,80), (1792,80), (80,1324), (1792,1324), a 40 px dot at
   (936,702)). Display it on the panel (`ebc-lab/wipe-flip.lua
   --count 1 --page-a out.raw --page-b out.raw` after a wash).
2. **Registration.** Capture a raw frame, find the four square
   centroids (crop ~80 px around each, `-threshold 45% -negate`,
   centroid over white pixels — keep the crop off the bezel, it is
   darker than the ink). Write the four `camX,camY fbX,fbY` pairs, one
   per line, to `calibration` next to `cap.sh` (gitignored — it is
   camera-position-specific and dies whenever the rig moves).
   Validate: warp a capture and check the center dot lands within a
   few px of (936,702). 2026-08-26 achieved 2.6 px.
3. **Capture.** `./cap.sh out.png` grabs a settled 4K MJPEG frame
   (frame 20, past auto-exposure) and warps it into fb space
   (1872x1404 gray) through the calibration.
4. **Measure.** `./measure.sh CAP.png INK_MASK.png PAPER_MASK.png`
   prints the mean capture luma over each mask and
   `ghost = (paper - ink_region) / paper` in percent. Positive =
   residual darkness where the ink mask is; negative = the region is
   *brighter* than paper (large black→white drives overshoot — a
   half-panel rect measured −2% on 2026-08-26; a bright rectangle
   with a visible edge is degradation too).

## Masks and the noise floor

Masks are built from the displayed patterns themselves (ImageMagick,
fb space): ink = `-threshold 50% -negate`; exclude anything within
4 px (`-morphology Dilate Disk:4`) of the *currently displayed*
page's ink so camera blur from live glyphs cannot contaminate the
ghost region; paper = far from every page's ink. CAUTION: an
ImageMagick operator outside parentheses applies to EVERY loaded
image — `a.png b.png -negate -compose Multiply` negates both; write
`a.png \( b.png -negate \)`.

**Always measure the same masks against a washed-panel capture
first.** The lighting gradient between the two mask populations is a
systematic bias (−0.5 % to +1.0 % across 2026-08-26's mask sets, sign
varies with the mask geometry); quote ghost numbers
baseline-corrected. The metric is exposure-invariant (a ratio inside
one frame) but not gradient-invariant.

## Typeset test pages

Real antialiased text pages for the fb, upright in physical portrait:

    convert -density 227 -size 1324x1792 -background white -fill black \
      -font DejaVu-Serif -pointsize 11 -interline-spacing 4 \
      caption:@passage.txt -gravity center -extent 1404x1872 \
      -rotate -90 -depth 8 gray:text-a.raw

(-rotate -90 because physical-portrait top-left is fb bottom-left;
the pen-session perimeter trace pinned that mapping.)

## Traps

- `ffmpeg` needs `-y` — without it the second capture silently
  reuses the first's temp frame and every arm measures the baseline.
- The v4l2 device is the desk Brio moved into the rig; check what the
  camera actually sees before trusting a capture session.
- Thin glyph strokes land ~0.6 camera px per fb px: individual
  strokes blur, but region means over 10⁴–10⁵ px are stable to well
  under the ±0.5 % floor.
