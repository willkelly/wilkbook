# optics — a portable e-ink optical-defect measurement instrument

The one thing `doc/refresh-policy.md` can never answer from the desk: **what
the panel actually looks like.** The `ebc-replay` workbench computes excellent
*proxies* — "white pixels driven dark," "wash pixel-phases," "staleness" — but
they have never been ground-truthed against real optics, and every open optics
question in that doc ends with "hardware-only, human eyeball."

This tool is the camera-in-a-box answer, built to two design goals:

1. **Deterministic classification, not vibes.** A fixed set of scripts turns a
   captured clip of a page transition into a labelled list of defects (black
   flash, ghosting, slow settle, double-flash, …). Same clip in, same report
   out.
2. **Portable to friends' PineNotes.** Each PineNote carries its *own* waveform
   calibration, so tuning against one panel overfits. The record half is
   low-friction enough that a friend with a PineNote and *any* camera — even a
   phone — can contribute a comparable dataset from *their* display.

## The record / analyze split

- **Record** (runs on the contributor's rig): play a standard test epub on the
  PineNote under its own **frontlight** (a stable, identical-across-units
  illuminant — no external lamp to calibrate), capture video off the panel,
  and produce a self-describing bundle (video + a small session log). The
  contributor needs *no* analysis tooling.
- **Analyze** (this directory, runs on our side): deterministic scripts ingest
  the bundle and classify defects per transition, producing a per-panel optics
  report and a comparable dataset row.

The seam is a **self-calibrating test page**. Every page carries, in fixed
margins: four corner fiducials (→ per-frame homography, so a handheld phone's
shake is corrected), white / black / gray reference patches (→ per-frame
photometric normalization to reflectance, so we measure the *panel*, not the
lamp), and a page-ID marker (→ the analyzer knows which transition it is
seeing). The scenario opens with a distinctive black/white flash sequence to
zero the video clock. Consequence: **even a shaky phone video with no
device-clock sync is fully analyzable**, which is what makes it distributable.

## Defect taxonomy (the deterministic classifiers)

Grounded in the waveform decode in `doc/refresh-policy.md`:

| defect | what it is | measurement |
| --- | --- | --- |
| **black flash** | should-be-white pixels driven dark during a wash (GC16's negative) | min-luminance dip × duration in the white region — temporal |
| **ghost / residue** | prior page still correlated in a should-be-clean region | RMS of the settled residual *and* its correlation with the previous page — spatial |
| **slow / incomplete settle** | panel still changing past the ~447 ms window | luminance-derivative decay time; never-quiescent = incomplete — temporal |
| **double-flash** | one page turn → two washes (the ioctl-races-deferred-io two-pass) | count of distinct dip events per transition — temporal |
| **grayscale corruption** | DU/A2 crushing antialiased grays to binary | settled histogram vs expected levels — spatial *(planned)* |
| **contrast / uniformity** | black not black, white not white, blotchy background | reference-patch reflectance + background σ — photometric *(planned)* |

## Status — what is built now

The **analysis core** (`optics.py`) and its **offline validation** are done and
green: `synth.py` generates clips with *known* injected defects and
`test_optics.py` asserts the classifiers report exactly them — black flash vs
GL16 no-flash, ghosting (with prior-page correlation), slow and never-quiescent
settle, double-flash, and a clean baseline. No hardware, no camera. This is the
project's "prove it offline first" rung for the optics program: the scripts are
correct before real capture exists.

```
guix shell python python-numpy -- make check      # from this directory
# or, from the repo root:
make optics-check
```

Severity thresholds in `optics.py` are deliberate conservative placeholders —
**re-calibrating them against the first real multi-panel captures is the whole
point of collecting friends' data.**

## Next (in build order)

1. **The test epub** — a deterministic generator producing the self-calibrating
   pages above, sequencing the adjacent-page *pairs* that stress the driver
   differently (text→image, image→image graphic-novel halftone, blank↔dense, UX
   overlay open/close, sparse single-column index) — the content taxonomy that
   makes one recording exercise every transition type.
2. **Real-video ingest** — the front of `optics.py`: detect the sync flash,
   solve the per-frame homography from the corner fiducials, normalize to
   reflectance from the in-frame patches, and segment the clip into transitions
   by the page-ID markers. Turns a phone video into the `[T,H,W]` reflectance
   clips the detectors already consume.
3. **The on-device scenario player + bundle format** — a script that drives the
   test epub through KOReader (or raw `/dev/fb0`) on the device over the
   network, flips `rockchip_ebc` params per run, emits the sync pattern, and
   logs timestamps + params + the *waveform-decode summary* (mode/phase counts
   per temp bin from `../wbf` — never the raw per-device `.wbf`, per repo
   policy). Plus the friend-facing recording instructions.
4. **Scoring + optimization** — once multi-panel data lands, feed the per-panel
   defect vectors back to rank waveform/threshold/flash-frac candidates, and
   ground-truth `ebc-replay`'s proxies against measured optics.

## Honest limits

- We lean entirely on **differential / relative** metrics (before/after,
  region-vs-reference). Absolute reflectance is hard and unnecessary for ranking
  candidates.
- Ghosting a human just barely notices can sit near a cheap webcam's noise
  floor. We beat that with differential capture, frame averaging, and the
  frontlight's stable illumination — but **camera quality sets the floor** on
  the subtlest cases, and phone-video contributions will be noisier than a
  locked-down webcam.
- A 30–60 fps camera captures the flash *envelope* (depth, duration), not
  per-phase structure — which is fine, because the per-phase detail already
  comes from the waveform decode in `../wbf`.
