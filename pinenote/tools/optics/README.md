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
| **grayscale corruption** | DU/A2 crushing antialiased grays to binary | fraction of intended mid-grays that settled at the extremes (0/1) — spatial |
| **contrast / uniformity** | black not black, white not white, blotchy background | white-patch minus black-patch reflectance + background σ — photometric |

## Status — what is built now

The first real dataset (2026-07-11, 20 captures off the calibrated boxed
rig) is cataloged for third-party review in `doc/optics-dataset-2026-07.md`,
with the derived session/trace/report files committed under
`doc/datasets/2026-07-optics/`.

The **entire offline pipeline round-trips**, all green (`make optics-check`):
test card → synthetic camera → ingest → panel reflectance → defect report,
with no hardware and no camera.

- **Analysis core** (`optics.py`): `synth.py` generates clips with *known*
  injected defects and `test_optics.py` asserts the classifiers report exactly
  them — black flash vs GL16 no-flash, ghosting (with prior-page correlation),
  slow and never-quiescent settle, double-flash, grayscale corruption (a gray
  ramp binarized to 1-bit vs. a clean control), contrast (dim-white/washed-black
  reference patches vs. full contrast) and background blotchiness (mottled vs.
  uniform clearing), and a clean baseline. Grayscale corruption runs on every
  transition (its mask is the intended mid-gray content); contrast/uniformity
  read the gray-step reference patches + a uniform background region, so they
  run when those region masks are supplied (ingest wiring is the next step).
- **Self-calibrating test epub** (`testepub.py`): a deterministic generator for
  the fixed-layout epub3 KOReader pages through — content per the taxonomy
  (novel / graphic / textbook / blank / ux / index) plus baked-in corner
  fiducials, a black→white gray-step reference strip, a page-ID barcode, and an
  opening black/white sync sequence; `manifest.json` records marker geometry (as
  page fractions, so ingest is resolution-independent) and the labelled page +
  transition-pair sequence. `test_epub.py` verifies it round-trips. Build one:
  `make testcard OUT=build/testcard`.
- **Real-video ingest** (`ingest.py`): decode (ffmpeg) → per-frame fiducial
  detection + homography rectification to panel space → reflectance (a
  photometric fit held fixed across a transition, from a stable pre-wash frame,
  so the flash survives) → page-ID decode → change-point segmentation into
  transitions paired with their intended before/after pages. `synthcam.py`
  forward-warps a known panel clip into a realistic camera view (perspective,
  dark bezel, lighting, nonlinear response, noise) and `test_ingest.py` asserts
  homography, reflectance, page-IDs, and **end-to-end defect detection**
  (synthetic camera of a GC16 page turn → flash *severe*; GL16 → *none*) all
  recover — plus a lossless ffmpeg decode round-trip.

Severity thresholds in `optics.py` are deliberate conservative placeholders —
**re-calibrating them against the first real multi-panel captures is the whole
point of collecting friends' data.** A few robustness notes are in "Honest
limits" below (top-only reference patches; change-point `change_eps`).

## Recording & bundles

The record/analyze seam is a **bundle**: a self-describing folder a contributor
sends back, holding one capture and just enough metadata to analyze it without
their hardware. This is the sendable-to-friends layer, and it is built and
offline-tested (`test_bundle.py`, wired into `make check`):

- **`bundle.py`** — the bundle format + `session.json` schema and the
  create/write/load/validate helpers. A bundle is `capture.<ext>` +
  `manifest.json` + `session.json`, where the session log records device
  model/revision, the frontlight level (the standardized illuminant), panel
  temperature if known, the `rockchip_ebc` params, the timestamped page/param
  sequence (clock-zeroed on the opening sync flash), and the device's
  **waveform-decode summary**. That summary is the *decoded* mode/phase-per-temp
  counts parsed from `../wbf`'s `wbf-info` **text** output
  (`waveform_summary_from_wbf_info`) — never the raw per-device `.wbf`, which the
  format actively refuses to carry (`assert_no_raw_waveform`), per repo policy.
- **`analyze.py`** — the real end-to-end analyze path: `analyze_bundle(dir)`
  loads + validates a bundle, decodes its video (`ingest.frames_from_video`),
  runs the full `ingest` → `optics.classify_transition` pipeline, and emits a
  per-panel defect report (JSON + a human-readable table). CLI:
  `python3 analyze.py BUNDLE_DIR [-o report.json]`.
- **`recorder.py`** — the record-side CLI. `package` (real) wraps a pre-recorded
  video + metadata into a bundle; `analyze` (real) runs the path above; `record`
  is the **on-device scenario player**. Its device-driving is real, factored in
  `driver.py` into a **Transport × RenderBackend** matrix:
  - *Transport* — `SerialTransport` over the USB CDC-ACM console (`/dev/ttyGS0`
    on device ↔ `/dev/ttyACM*` on host, wired by `pinenote/services/usb-gadget.scm`)
    works **tethered today, no Wi-Fi** — the device sat in the camera box is
    reachable over the same USB-C cable that powers it. `SSHTransport` (over the
    network) is the friends'/untethered path and needs only the
    `doc/networking.md` story — no new code.
  - *RenderBackend* — `KOReaderBackend` (**default**: turns pages *in KOReader*,
    so the capture includes KOReader's own refresh choices) or
    `FramebufferBackend` (writes raw frames to `/dev/fb0` and fires
    `pinenote-ebc-refresh` under a chosen waveform, bypassing KOReader — the
    control). Diffing a KOReader run against a framebuffer run of the same card
    isolates how much KOReader shapes the optics.

  `test_driver.py` proves the whole command layer (param/frontlight/temp sysfs,
  serial byte push, both backends' page-turn sequences) against a fake transport
  — no device. Five device-specific values (the KOReader input-injection
  mechanism, the fb pixel format, the backlight/hwmon nodes, the koreader store
  path) are the `HARDWARE_CHECKLIST` in `driver.py`: isolated constants a
  hardware session pins with no structural change.
- **`RECORDING.md`** — the friend-facing rig + capture instructions (device in a
  dark box under its own frontlight, camera placement, locking exposure/focus/WB,
  keeping all four fiducials in frame, what to run, and exactly which files to
  send — never the `.wbf`).

## Trace → transition join (wash attribution)

Each run's harvested `[pn-refresh]` trace (device-epoch timestamps of every
refresh KOReader *issued*) is now JOINED to the camera transitions, so a
report can attribute each visible wash: `src=ko-full` / `ko-partial` (the
reader asked for it) vs `src=none` — a panel change with **no** issuing line,
i.e. a driver-initiated global (or a trace gap), itself a finding. The report
carries a per-transition `trace` block (matched lines with `dt_s`), a `src`
column in the text table, and a `trace_join` summary.

**Alignment anchor (a deliberate decision):** the k-th page turn's
`[pn-refresh]` line vs that turn's camera wash onset, fitted as one rigid
offset by a mode-of-pairwise-differences vote and refined as the median over
the consistent pairs (`analyze.align_trace`). The bundle format's *sync*
anchor (`events` t=0 = clock-zero, capture side = `find_sync`'s block end)
was measured to be unusable for a sub-second join: `sync_end_frame` lands at
the end of the settled sync-white *dwell*, up to a full page period after
clock-zero, so `sync_end + t*fps` carries seconds of systematic error. The
onset fit instead *measures* the offset and reports its own accuracy
(`median_abs_residual_s` / `max_abs_residual_s` per bundle — the residuals
are the per-turn issue-to-visible-wash latency jitter plus ±1–2 frames of
onset granularity; expect ~0.1–0.3 s on the rig against a 1.0 s match window
and ≥3 s page periods). Fewer than 3 mode-consistent pairs → the join
declines explicitly rather than guessing.

## Analyzer robustness notes (2026-07 regressions, fixed)

- **`sync ends frame 0`** (every report after the cadence captures):
  `find_sync`'s fixed thresholds missed the warm panel's plateaus (black read
  0.207 raw vs `lo=0.2`; the "validating" full-white sync pages were excluded
  by `candidate=~valid` — their corner windows straddle the bezel and the
  dark bezel pixels satisfy the marker checks). Fixed three ways: thresholds
  now adapt to the capture's own candidate range (`sync_thresholds`), a
  uniform-panel-region frame is a sync candidate regardless of marker
  validity (`SYNC_UNIFORM_STD`), and noise-flat marker windows are rejected
  (`MIN_MARKER_CONTRAST`).
- **`flash mild(nan)`**: whole-NaN frames (unreadable mid-wash) inside the
  analysis window poisoned the flash depth into NaN, which graded "mild"
  (NaN fails both severity comparisons) and fabricated extra flash counts
  (false rising edges around each NaN gap). The flash metrics now read only
  photometrically valid frames; detection, depth and count share the same
  stays-white mask; a transition with *no* stays-white area is explicitly
  not classifiable as flash (`notes`), instead of silently falling back to
  the after-white mask (which fabricates depth from clearing pixels).
  Reports can no longer carry NaN (strict-JSON guard).

> **The current execution queue lives in [PLAN.md](PLAN.md)** — the 2026-07-11
> four-critic review's verified findings and dependency-ordered build list. The
> section below is the pre-review summary, kept until PLAN.md tasks land.

## Next (in build order)

1. **Confirm the driver against a real device (tethered, no Wi-Fi).** The driver
   command layer is built and tested; a hardware session pins the five
   `HARDWARE_CHECKLIST` values in `driver.py` — chiefly the KOReader
   headless-page-turn injection and the `/dev/fb0` pixel format — then
   `recorder.py record --transport serial --backend {koreader,fb}` drives a real
   capture over the USB cable. This is the first "your own baseline device" run.
2. **Scoring + optimization** — once multi-panel data lands, feed the per-panel
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
- **Reference patches are top-only**, so the photometric fit is a single global
  curve — fine under the frontlight (fairly uniform), but a strong *spatial*
  lighting gradient would need distributed references (patches at the bottom /
  corners, or a per-region fit). The synthetic camera's gradient is kept mild to
  match the frontlight assumption.
- **Segmentation uses a change-point threshold** (`change_eps`) to find washes
  between quiet page plateaus. It now **auto-calibrates from each capture's own
  change signal** (`ingest.auto_change_eps`: a robust noise floor + margin, so a
  noisier camera raises it automatically — no hand-tuning, validated across a
  synthetic-camera noise sweep in `test_ingest.py`). The residual limit is
  inherent: a genuinely static page turn with no visible change has no signal to
  segment on — the sync flashes and page-ID plateaus bound that case.
