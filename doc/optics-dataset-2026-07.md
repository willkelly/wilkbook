# The 2026-07 optics dataset — third-party review guide

This documents the first measured-optics dataset from the
`pinenote/tools/optics` rig: one capture night (2026-07-11 into the early
UTC hours of 07-12), twenty captures, one panel. It exists so that someone
who was not in the room can audit the claims in
`doc/refresh-policy.md` § "First measured results" (findings 1–9) from the
files alone. Every number in this document was recomputed from the bundle
files at documentation time — not paraphrased from the session notes — and
where the recomputation and the findings text disagree, the disagreement is
stated (§5 and §6).

Where things live:

- **Raw bundles** (gitignored, capture workstation only):
  `pinenote/tools/optics/build/bundles/<bundle>/` — each holds
  `capture.mkv` (the video; 12.28 GB total across the 19 finalized
  captures), `session.json` (schema v2), `manifest.json` (test-card
  geometry), and `trace.rN.log` (the harvested KOReader log with
  `[pn-refresh]` intent lines). Per-transition defect reports sit as
  siblings: `build/bundles/<bundle>-report*.json`.
- **Committed derived dataset**: [`doc/datasets/2026-07-optics/`](datasets/2026-07-optics)
  — one subdirectory per bundle carrying its `session.json`, trace file(s),
  and defect report(s); the single shared card `manifest.json` at the top
  level (byte-identical across all 19 bundles that have one, sha256
  `fe186254…`); and `checksums.txt` with the sha256 + byte size of every
  `capture.mkv` (the videos themselves are not committed). Total ~1.2 MB of
  text/JSON.
- **This document**: the methods, the catalog, the findings audit.

## 1. Instrument & methods

### 1.1 The rig

The PineNote (this project's single unit, running the A.2.6 reader image,
kernel 7.0.11) sits face-up in a closed dark box. The illuminant is the
panel's **own frontlight**, both channels at 255/255 — recorded per bundle
as `illuminant: {cool_level, warm_level, ambient: "dark-box"}`. No external
lamp: the frontlight is stable, spectrum-fixed, and identical across
PineNote units, which is what makes a webcam quantitative here at all.

The camera is a Logitech Brio at MJPG 1080p, 30 fps, stream-copied into
`capture.mkv` (no re-encode, no VFR — `exposure_dynamic_framerate=0` is
locked and recorded). Note the camera *model* is not recorded in the
bundles (`camera.model: null` in every session.json — see §6); it is pinned
here and in `doc/status.md`.

**Exposure calibration and the 30-fps decision.** v4l2's
`exposure_time_absolute` is in **100 µs units**, so at 60 fps the exposure
ceiling is ~156 (15.6 ms, just under the 16.7 ms frame period) —
unavoidably dark on this rig. The 2026-07-11 exposure sweep therefore moved
captures to 30 fps with locked `exposure_time_absolute=312` (31.2 ms) and
`gain=32`, which puts panel whites at 214/255 with zero clipping.
`--camera-lock` *applies* the values (not merely freezing auto-exposure)
and persists the readback: every session.json carries the full v4l2 control
set (white balance locked at 4150, focus 10, `auto_exposure=1` = v4l2
manual mode, `exposure_locked: true`). 30 fps captures the flash *envelope*
(depth, duration), not per-phase structure — per-phase detail comes from
the waveform decode in `pinenote/tools/wbf`, and 30 fps is sufficient for
the GC16/GL16-only regime every bundle here runs (60 fps would be required
for A2/DU work).

**Instrument precision** (the `noise-pilot` bundle: the same
novel↔blank partial transition repeated 10× in each direction under
`full_refresh_count=never`, so every flip is the identical diff-masked
partial): between-repeat ghost-rms sigma recomputed from
`noise-pilot-report2.json` is **0.0026** (novel→blank, n=10) and
**0.0061** (blank→novel, n=11) — the "sigma 0.003–0.006" of the findings
provenance note. Config differences of ~0.01 rms are therefore ≈3-sigma
detectable off this webcam.

### 1.2 The self-calibrating test card

`testepub.py` generates a deterministic fixed-layout epub3,
**landscape-native 1872×1404**, 49 pages: 4 sync pages (black/white
alternating — the clock-zero flash sequence) + 45 content pages arranged as
**three identical 15-page stress blocks** (`rep` 0/1/2 in the manifest, so
every stress pair has 3 repeats). Content kinds: novel ×15, blank ×9,
graphic ×9, index ×6, textbook ×3, ux ×3.

Every page carries, at fixed fractional positions recorded in
`manifest.json`:

- **4 corner fiducials** (pip-coded 1–4) → homography to panel space;
- a **5-patch reflectance strip** (0.0/0.25/0.5/0.75/1.0) along the top →
  per-transition photometric normalization to reflectance;
- an **8-bit page-ID barcode** (10 cells, full width) along the bottom →
  the analyzer knows which transition it is seeing;
- **reserved rects** — the human-visible page number (bottom-right) and two
  alternating-corner parity squares — declared in the manifest and
  *excluded* from analysis masks (the old footprint would otherwise inject
  digit-shaped ghost).

The manifest declares 48 intended transitions, 27 of them stress-tagged
(ghost ×12, settle ×6, flash+settle ×6, flash ×3). One shared manifest
serves all bundles in this dataset (identical sha256 across all 19 copies).

### 1.3 Capture protocol

`recorder.py record` over `SSHTransport` + `KOReaderBackend` — the pages
turn *inside KOReader*, so captures include KOReader's own refresh
decisions. Per param set (each gets its **own video and bundle**):

1. **Panel-state reset**: 3 GC16 global refreshes fired under baseline
   params (`--deep-clean 3`; logged as a `clean` event, `t=0, n=3`);
2. **Param flip**: EBC module params via the runtime sysfs one-shot and
   KOReader settings (`full_refresh_count`) seeded into the dedicated
   KO_HOME before relaunch; logged as a `param` event and recorded in
   `runs[].params` as `{"ebc": {...}, "ko": {...}}`;
3. **Sync flashes**: the card's opening black/white sequence zeroes the
   video clock;
4. **48 injected page turns** via the persistent uinput injector daemon
   (`wilkbook-optics` device) at `--page-period 3.0` s commanded; measured
   event spacing in the sessions is ~3.6–3.8 s;
5. **Trace harvest**: `/var/log/optics-koreader.log` pulled to
   `trace.rN.log` — the `[pn-refresh]` lines are KOReader's per-update
   intent (`full global` vs `partial partial`, plus one `ui partial` launch
   paint), the ground-truth join for "which turns actually washed";
6. **Panel temperature** sampled at run start and end (TPS65185 IIO),
   recorded per run.

### 1.4 Analysis pipeline

`analyze.py BUNDLE_DIR -o report.json` with memory bounds
`--analysis-scale 0.5` (half-resolution panel space) and `--max-fps 30`:
ffmpeg decode → fiducial detection → **one fixed session homography**
(median of 5 frames; the earlier per-frame fit was removed 2026-07-11
because fit jitter at content edges kept the settle ROI "never quiet") →
per-transition photometry fitted from the static reference patches, held
fixed across the transition so the flash survives normalization (the flash
reference uses **stays-white pixels** — text transiting dark while clearing
had previously fabricated ~0.10 flash on clean partials) → page-ID decode →
change-point segmentation (auto-calibrated `change_eps`) → per-transition
detectors: flash (depth/energy/duration/count), ghost (rms + correlation
with the prior page; the corr gate is what separates real ghost from the
render-mismatch bias floor), settle, gray-crush. Output: report JSON
(v1) with per-transition metrics and a summary block.

Severity thresholds in `optics.py` are deliberate conservative placeholders
(e.g. `FLASH_DEPTH_SEVERE = 0.15`, `GHOST_RMS_SEVERE = 0.035`); with the
~0.12+ ghost-rms bias floor (§4), ghost severity is meaningful only through
the correlation gate, and cross-config *differences* are the supported use.

## 2. Bundle catalog

All bundles: schema v2, card v1 geometry (the 3-rep card), fps 30,
exposure 312 / gain 32, frontlight 255/255, dark box — **except
`first-real`** (60 fps, exposure 156, gain 0, frontlight 153/153: the
pre-calibration settings that retired it). All configs run GL16 globals
(`refresh_waveform=6`) unless marked GC16 (`=4`). "ko frc" =
`full_refresh_count` (0 = never). Full sha256s and sizes:
[`datasets/2026-07-optics/checksums.txt`](datasets/2026-07-optics/checksums.txt).

Trace decisions count `[pn-refresh]` lines verbatim: F = `full global`
(includes the one launch wash each run fires before the sync pages),
P = `partial partial`, +1 `ui partial` launch paint in every trace.
"Seg." = transitions segmented by the analyzer (card manifest intends 48).

| bundle | run label | config (ebc / ko) | created UTC | mkv sha256 (12) | bytes | temp °C | trace F/P | seg. | headline (recomputed) | verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| first-real | baseline-gl16 | image defaults (GL16, frc 6) | 07-11 21:25:26 | `7401465419b4` | 663,887,279 | 23→24 | 8/39 | 49 / 7 (see lineage) | whites ~0.55; contrast at validity-gate edge | **retired** (dark exposure) |
| noise-pilot | noise-pilot-10x | params `{}` (frc never; see §6) | 07-11 22:05:58 | `e405538d452d` | 354,511,242 | 23→? | 1/30 | 34 / 26 (see lineage) | repeat sigma 0.0026/0.0061; clear-shimmer 0.1485±0.0316 | precision reference |
| cal-baseline | baseline-gl16 | GL16 / frc 6 (reader block) | 07-11 22:25:51 | `fc67772f9d30` | 663,163,470 | 23→24 | 8/39 | 47 | 6 severe fulls 0.161–0.231; blank-ghost 0.125 (n=8); ux→novel flash ×2,×2,×2 | calibrated GL16 baseline |
| sweep1.r00 | gl16-full6 | rw=6 / frc=6 | 07-11 22:50:04 | `bf2561dc88f5` | 659,348,703 | 23→24 | 9/39 | 48 | blank-ghost 0.1217±0.0086 (n=8); severe fulls 0.161–0.206 (n=5) | clean; the ghost floor |
| sweep1.r01 | gc16-full6 | rw=4 / frc=6 | 07-11 22:50:04 | `630fef7f344e` | 741,339,614 | 24→24 | 8/39 | 48 | blank-ghost 0.126 (n=7, excl. one pre-first-wash 0.298); severe fulls 0.153–0.201 (n=4) | clean; finding 5 unresolved |
| sweep1.r02 | gl16-never | rw=6 / frc=0 | 07-11 22:50:04 | `ed8223b66984` | 689,156,131 | 24→24 | 1/46 | **1** | single segmented transition, ghost 0.3088 (corr 0.006) | corrupt regime (finding 1; caveat §5.1) |
| sweep1.r03 | gc16-full1 | rw=4 / frc=1 | 07-11 22:50:05 | `074ce0f08217` | 661,138,088 | 24→24 | **48**/0 | 55 | blank-ghost 0.1210 (n=8); worst flash 0.478 | full1 = pure cost (finding 3) |
| cadence.r00 | gl16-c6 | rw=6 / frc=6 | 07-11 23:24:47 | `1e221d08e750` | 639,672,735 | 24→24 | 8/39 | 49 | blank-ghost 0.109–0.146 (n=7) | flat (finding 6) |
| cadence.r01 | gl16-c12 | rw=6 / frc=12 | 07-11 23:24:47 | `2fb5d810b743` | 625,943,530 | 24→24 | 4/43 | **19** | blank-ghost 0.125–0.138 (n=3); under-segmented (§6) | flat; basis of the frc=12 recommendation |
| cadence.r02 | gl16-c20 | rw=6 / frc=20 | 07-11 23:24:47 | `6f200541547f` | 629,237,981 | 24→24 | 3/44 | 44 | blank-ghost 0.121–0.143 (n=7) | flat |
| cliff.r00 | gl16-c25 | rw=6 / frc=25 | 07-11 23:50:20 | `eddd62636506` | 633,133,081 | 24→24 | 2/46 | 46 | blank-ghost 0.128–0.143 (n=7) | no cliff (finding 7, corrected) |
| cliff.r01 | gl16-c35 | rw=6 / frc=35 | 07-11 23:50:21 | `80c13022b069` | 648,427,540 | 24→24 | 2/45 | 45 | blank-ghost 0.118–0.144 (n=7) | no cliff |
| cliff.r02 | gl16-c40 | rw=6 / frc=40 | 07-11 23:50:21 | `8b04e09667c6` | 630,908,929 | 24→24 | 2/45 | 47 | blank-ghost 0.093–0.141 (n=8) | no cliff; barcode healthy through 39-turn spans |
| neverx3.r00 | gl16-never-a | rw=6 / frc=0 | 07-12 00:15:26 | `394b7d55f686` | 633,294,311 | 24→24 | 1/46 | **0** | segmentation collapse (0/48) | corrupt (finding 8) |
| neverx3.r01 | gl16-never-b | rw=6 / frc=0 | 07-12 00:15:26 | `02373e4670cf` | 648,723,233 | 24→25 | 1/47 | **429** | pseudo-transition shatter; pseudo-flash to 0.762 | corrupt (finding 8) |
| neverx3.r02 | gl16-never-c | rw=6 / frc=0 | 07-12 00:15:27 | `670b5a38291a` | 670,060,529 | 25→25 | 1/46 | 48 | first blank-reveal ghost 0.3081 **corr 0.330 = severe**; 5 severe ghosts | corrupt (finding 8) |
| driver-owned | drv-thresh8 | rw=6, refresh_threshold=8 / frc=0 | 07-12 00:26:43 | `a2dc7e671e93` | 654,749,843 | 24→25 | 1/46 | **6** | corruption signature (6/48 segmented) | not viable as tested (finding 8) |
| soak1 | (soak-events only) | both mechanisms off (see §3.9) | ~07-12 00:37 (mtime) | `c88eed54ae81` | 754,807,995 | — | no trace | no report | 30 washless flips + GL16/GC16 interventions, 181.5 s of events | toggle-count refuted (finding 9; not recomputable, §6) |
| armB | armB-diverse-auto0 | rw=6, auto_refresh=N / frc=never | 07-12 01:14:53 | `fd85c4948afa` | 677,840,330 | 25→25 | 1/46 | no report yet | one cell of the finding-9 2×2 (diverse pages × auto off) | **pending** |
| armC | — | — | in flight | — | — | — | — | — | capture.mkv still being written at documentation time; no session.json | **pending** |

Report lineage (both generations are committed):

- **noise-pilot**: `noise-pilot-report.json` is the pre-fix analyzer
  (per-frame homography, old flash reference — the run that *exposed* both
  defects; 34 segments, incl. a spurious 0.306 ghost).
  `noise-pilot-report2.json` is the post-fix canonical (26 segments, the
  sigma numbers above).
- **first-real**: `first-real-report.json` is the same-day analyzer that
  first segmented all 49 transitions off the dark capture;
  `first-real-report3.json` is the corrected pipeline, which segments only
  7/49 (blank-heavy pages fall below the contrast validity gate at that
  exposure). The bundle is retired — `cal-baseline` supersedes it
  (PLAN.md §1c).
- All other bundles have exactly one report, produced by the calibrated
  pipeline (analyzer code as of commit `635e516`; report schema v1).

Internal consistency checks that pass across the whole catalog: every
session-recorded capture sha256 matches an independent recomputation of the
video file (19/19); all 19 manifests are byte-identical; every trace's
full-wash count matches its `ko.full_refresh_count` (45 content turns:
frc=6 → 7–8 promoted fulls + launch wash; frc=12 → 3+1; frc=20 → 2+1;
frc=25/35/40 → 1+1; never → 0+1; frc=1 → 47+1).

## 3. Findings 1–9, audited

Each finding below restates the claim from `doc/refresh-policy.md`
§ "First measured results", points at the specific bundles/reports, and
gives the recomputed numbers. Status legend: **verified** = recomputed from
committed artifacts and matches; **caveat** = matches with a nuance a
reviewer should know; **not recomputable** = the claim rests on session
analysis not captured in the committed reports.

### 3.1 Full refreshes are load-bearing under GL16 — verified, with a caveat

Claim: `full_refresh_count=never` drives blank-reveal ghost to **0.309** vs
**~0.121** for every config with fulls; after ~40 fulls-free turns,
toggle-heavy regions accumulate 0.2–0.4 reflectance, enough to corrupt the
card's own barcode.

Evidence: `sweep1.r02-gl16-never-report.json` — the analyzer segmented
**1 of 48** transitions, and that one reads ghost rms **0.3088**. The
floor: `sweep1.r00` blank-reveal ghost **0.1217 ± 0.0086** (n=8),
`sweep1.r03` **0.1210** (n=8), `cal-baseline` **0.125** (n=8). The barcode
cell readings (0.63–0.82 instead of ~0/~1) are a session-analysis claim
not present in any committed report (§6). Caveat on the 0.309 headline in
§5.1: it is a single segmented transition, and its own correlation gate
reads ~0 — the *replication* signatures (finding 8) are the stronger
evidence for the regime being corrupt.

### 3.2 Partial page turns are near-flash-free; the text-CLEAR shimmer — verified

Claim: partials flash 0.00–0.05 in every config; the one partial artifact
is whites adjacent to *erasing* text dipping **0.148 ± 0.032** transiently
(absent when text appears).

Evidence: `noise-pilot-report2.json` (every flip a pure partial):
blank→novel (text *appearing*) flash depth **0.0098 ± 0.0132**
(n=11, max 0.037); novel→blank (text *clearing*) depth
**0.1485 ± 0.0316** (n=10) — the shimmer, exactly as quoted. Across the
full-card runs, non-severe flash depths pool 0.00–0.15; the upper end of
that pool is the clear-shimmer pairs and near-threshold promoted fulls, so
read "0.00–0.05" as the non-shimmer partial population, not the pooled
non-severe maximum.

### 3.3 full_refresh_count=1 is pure cost — verified

Claim: ghost 0.121 (same as cadence 6) for 48 flashes instead of 8.

Evidence: `sweep1.r03-gc16-full1` — trace has **48** `full global` and
**0** `partial partial` page-turn lines (vs 9 fulls in `sweep1.r00`);
blank-reveal ghost **0.1210** (n=8), statistically identical to the
full6 floor. (The doc's "48 vs 8" and the traces' 48 vs 9 differ by
launch-wash accounting; see §5.4.)

### 3.4 The ux→novel double-flash — verified

Claim: KOReader pays two washes to leave the menu-style page, on every
repetition.

Evidence: the `ux->novel` transition (3 per card, one per stress block)
reports **flash count = 2 on all three repetitions** in every
fully-segmented full-cadence bundle: `cal-baseline`, `sweep1.r00`,
`sweep1.r01`, `sweep1.r03`, `cadence.r00/.r02`, `cliff.r00/.r01/.r02`,
`neverx3.r02` — [2,2,2] each. (The retired dark `first-real` read [1,1,1]
— under-detection at the bad exposure; the shattered `neverx3.r01` reads 0
on its 44 pseudo-repetitions.)

### 3.5 GL16-vs-GC16 full flash depth: NOT concluded — verified as open

Claim: both measured ~0.15–0.19 on n=2 clean samples; no separation
claimed pending the NaN guard and the trace→transition join.

Evidence: `sweep1.r00` (GL16) severe-flash depths 0.161–0.206 (n=5 with
non-NaN depth); `sweep1.r01` (GC16) 0.153–0.201 (n=4). The ranges overlap
entirely. Note both runs also carry 14–15 NaN flash depths (§4), which is
exactly why the doc refuses the comparison. One suggestive datum the doc
does not cite: `sweep1.r03`'s worst GC16 full reads **0.478** — the only
committed measurement approaching the GC16-class ~0.6 the waveform decode
predicts.

### 3.6 Cadence sweep: accumulation is flat through 18 turns — verified

Claim: blank-reveal ghost 0.117–0.132 across all distance buckets vs floor
0.121 ± 0.009, 17 samples pooled across c6/c12/c20; recommendation
full_refresh_count=12 (half the flash events of default 6 at zero measured
ghost cost).

Evidence: pooling every blank-reveal ghost in
`cadence.r00/.r01/.r02` reports gives exactly **17 samples**
(7+3+7), raw range 0.109–0.146, pooled mean **0.126**; the floor
0.121 ± 0.009 recomputes from `sweep1.r00` (0.1217 ± 0.0086, n=8). Flash
events: c12's trace has **4** fulls vs c6's **8** — the "half the flashes"
claim, verbatim from the traces. Caveat: c12 itself segmented only 19/48
transitions (§6), so its 3 samples carry the least weight of the three.

### 3.7 Cliff mapping found no cliff — verified, including the correction

Claim (as corrected): the pooled six-cadence blank-reveal curve is flat
0–33 turns since a KOReader full (0.093–0.146, 39 samples); c40 segmented
47/48 with a healthy barcode through 39-turn spans. The *original*
explanation — that the driver's `auto_refresh=1, refresh_threshold=60`
backstop was invisibly washing every ~30 turns — was **wrong** and is
corrected in the doc: the driver source (verbatim in our forward-port
patch) gives `refresh_threshold` units as whole screen-areas, so at 60 it
fires ~every 60 full-page turns — beyond every span tested here. The flat
curve is genuine GL16-partial non-accumulation on normal content.

Evidence: pooling cadence (17) + cliff (7+7+8=22) blank-reveal ghosts =
**39 samples**, raw range **0.093–0.146** — both endpoints land in
`cliff.r02` and `cadence.r00` respectively, matching the doc's quoted range
exactly. `cliff.r02-gl16-c40-report.json` has n_transitions = **47**.

**Corrections history** (deliberately preserved — the reasoning was
audited): commit `c5d1551` ("no cliff to 33 turns — the driver's
auto_refresh backstop found") shipped the backstop explanation; commit
`3610f49` ("correct the backstop claim; never refuted 3/3") retracted it
after re-reading the driver source. Reviewers should note that finding 7's
*body text* in `doc/refresh-policy.md` still carries the superseded
backstop sentences after the corrective parenthetical, and the older
"Context" bullet in the same file still describes threshold units as
~half-screens; the parenthetical in finding 7, finding 8's "60
screen-areas", and commit `3610f49` are authoritative (§5.3).

### 3.8 full_refresh_count=never refuted by replication (3/3) — verified

Claim: two fresh never-runs both corrupt (one segments 0/48; one shatters
into 429 pseudo-transitions), matching the original sweep1.r02 outlier;
`refresh_threshold=8` + never (single driver-owned cadence) also corrupted
(6/48).

Evidence, one report each: `neverx3.r00` n_transitions = **0**;
`neverx3.r01` n_transitions = **429** (flash depths on pseudo-transitions
reach 0.762 — decode bits flickering on the threshold, as described);
`neverx3.r02` segments 48 but its first blank-reveal reads ghost
**0.3081 with corr 0.330 → severity severe** — the one never-run
measurement where the correlation gate itself confirms real, prior-page-
correlated residue — plus 4 more severe ghosts. `driver-owned`
n_transitions = **6**. Traces confirm all four runs washed exactly once
(the launch wash) in 48 turns.

### 3.9 Soak: the simple toggle-count mechanism refuted — not recomputable from committed artifacts

Claim: with both wash mechanisms off, 30 same-pair toggles produced no
accumulation — the toggling barcode cell tracked its never-toggling
neighbors within ~0.01 across all 30 washless flips (parity square ~2% at
most), and the GL16/GC16 interventions had nothing to scrub. Therefore the
corrupting ingredient in diverse-page never-runs is (a) diverse
gray-transition sequences per cell, or (b) an interaction with
`auto_refresh=1` itself — the 2×2 isolating this is the next experiment
(armB is its first arm).

Evidence: `soak1/` carries `capture.mkv` (sha in checksums.txt) and
`soak-events.json` (phase A: 30 flips no washes, t=0–101.0 s;
GL16-global intervention at 101.04 s; phase B: 10 flips;
GC16-global at 140.68 s; phase C: 10 flips; end 181.48 s) — but **no
session.json, no trace, and no standard report**: the cell-level tracking
numbers came from a bespoke half-res analysis of the capture that was not
committed. A third party can verify the protocol timing and re-derive the
cell numbers from the video, but cannot recompute the ~0.01 claim from the
committed JSON alone. This is the weakest-provenance finding in the set;
re-running the soak through a standard reporting path is the fix.

## 4. Known limitations & artifacts

Candid list; several were found during this audit (§5–§6 for the rest).

- **NaN flash depths on tiny stays-white masks.** The flash reference uses
  stays-white pixels; when a transition leaves almost nothing white, depth
  and energy are NaN. Frequency in this dataset: 12–17 of ~48 transitions
  per full-card report (e.g. 12 in cal-baseline, 15 in sweep1.r00). The
  NaN guard is queued (PLAN); until it lands, flash statistics silently
  exclude these transitions. Note also the report files contain **literal
  `NaN` tokens**, which is not strict RFC-8259 JSON — Python's parser
  accepts it; strict parsers will not.
- **Gray-corrupt thresholds are uncalibrated.** `gray-corrupt:mild` flags
  appear on graphic pages in essentially every report — false flags; the
  detector's mask/thresholds have not been calibrated on real captures.
  Ignore gray-corrupt severities in this dataset.
- **Settle-incomplete tail.** `settle:incomplete` verdicts remain common
  (e.g. 30/49 in cadence.r00, 31/47 in cliff.r02) and are partly an
  artifact of SETTLE_EPS vs this rig's noise floor plus window truncation;
  the windowing fix improved but did not eliminate it. Treat settle
  verdicts as indicative, not per-transition truth.
- **Ghost-rms bias floors — differential use only.** The render-vs-reality
  mismatch (real e-ink texture vs the ideal rendered page) sets a floor of
  **~0.12 on blank-after** transitions and **~0.27–0.33 on content-after**
  transitions (recomputed: blank→novel ghost rms 0.284–0.303 in
  noise-pilot; worst_ghost 0.30–0.34 in *every* report including
  the cleanest runs). Absolute ghost rms is not residue; only differences
  between configs at matched pairs, and the correlation gate, carry
  meaning.
- **Sync auto-detection failed (sync_end_frame=0) in the later reports** —
  all of cliff.\*, neverx3.\*, driver-owned, and first-real. Segmentation
  proceeded from page-ID plateaus and change-points, so transition metrics
  stand, but clock alignment against the trace is weaker in those bundles.
  (cal-baseline, noise-pilot, sweep1.\*, cadence.\* detected sync at frames
  589–886.)
- **MJPEG compression** of the source video; photometry rides on 8-bit
  MJPG output.
- **Half-resolution analysis** (`--analysis-scale 0.5`) bounds memory;
  fine-structure (dither cells, 1-px ghost edges) is below the analysis
  grid.
- **Single panel, single temperature.** One PineNote, panel temps 23–27 °C
  across the night (per-run start/end recorded; all within the ≥24 °C
  38-phase waveform bins ±1). Nothing here speaks to cold-bin behavior or
  other units' waveform calibrations.
- **Page-turn latency is not yet joined to the trace** (PLAN task 10):
  reports do not attribute transitions to specific `[pn-refresh]` lines,
  so full-vs-partial attribution of any given transition is inferred from
  cadence arithmetic and flash severity, not measured. This is the single
  biggest analysis gap for finding-5-class questions.
- **Corruption verdicts rest on segmentation coverage.** "Corrupt" for the
  never-runs means the analyzer's own segmentation/decode broke in
  characteristic ways (0/48, 429-shatter, 6/48) plus the one corr-gated
  severe ghost — not a direct residue image. That is strong but indirect
  evidence; the accumulation-block card (PLAN card-v2 task 4) is the
  direct instrument.

## 5. Discrepancies and audit notes (docs vs files)

Found while recomputing; none overturns a finding, but third parties
should know them.

1. **Finding 1's 0.309 headline is a single transition whose own corr gate
   reads ~0.** `sweep1.r02` segmented exactly one transition (labeled
   blank→blank, ghost 0.3088, corr 0.006 → severity "none" under the
   analyzer's correlation gate). Look-alike high first-blank-reveals also
   appear in *clean* runs: sweep1.r01 idx3 = 0.298 (corr 0.173, before
   that run's first promoted full), noise-pilot report1 = 0.306 (an
   artifact the report2 re-analysis removed). The never-regime conclusion
   is carried by the finding-8 replication — where `neverx3.r02`'s 0.3081
   at **corr 0.330** is severity-severe and unambiguous — more than by
   sweep1.r02's lone number.
2. **`reader.full_refresh_count` in session.json is a batch-level scrape,
   not the run's config.** Cadence bundles all record `reader: {…: 20}`,
   cliff bundles 40, sweep1 bundles 1 — the *last* value the sweep left on
   the device — while the authoritative per-run config is
   `runs[].params.ko`. Third parties must read `runs[].params`, not the
   `reader` block. (`cal-baseline`'s reader block happens to be correct at
   6; `noise-pilot`'s is null.)
3. **Superseded text still standing in refresh-policy.md**: finding 7's
   body retains the backstop mechanism sentences ("refresh_threshold=60
   half-screens … injects its own auto-global roughly every ~30 full-page
   turns") after the corrective parenthetical, and the "Context" section's
   threshold bullet still says "~half-screens". Finding 8 and commit
   `3610f49` carry the corrected units (whole screen-areas, ~every 60
   turns). The doc history was preserved rather than rewritten; read the
   correction as authoritative.
4. **Launch-wash accounting.** The doc's flash-event counts ("48 flashes
   instead of 8"; "half the flash events") exclude or include the per-run
   launch wash inconsistently: raw trace counts are 48 vs **9**
   (sweep1.r03 vs r00) and 4 vs 8 (cadence c12 vs c6). Off-by-one only;
   the ratios stand.
5. **cadence.r01 (c12) under-segmented: 19/48 transitions**, not mentioned
   in the findings text. Its blank-reveal sample (n=3) is the thinnest in
   the pooled cadence set. Cause unestablished (same protocol and sync
   detection as its siblings, which segmented 44–49).
6. **Finding 2's "0.00–0.05"** describes the non-shimmer partial
   population; pooled non-severe flash depths in the reports run to ~0.15
   because the text-clear shimmer pairs (0.09–0.20 transient) and
   near-threshold fulls sit in the same severity bucket. The precise,
   recomputable statement is noise-pilot report2's directional split
   (0.0098 ± 0.0132 appearing vs 0.1485 ± 0.0316 clearing).

## 6. Provenance gaps a third party should know

- **Camera model is not in the bundles** (`camera.model: null`,
  `fps_mode: null` everywhere) — the Brio identification lives in
  status.md/this doc only. The schema supports it; `--camera-model` was
  not passed.
- **`device.wbf_sha256` is null** in every bundle (and the key is absent
  entirely in noise-pilot's hand-packaged session), so waveform-file
  identity rides on "same device, same night" rather than a recorded hash.
  Per repo policy the .wbf itself is never bundled.
- **noise-pilot's config is not machine-recorded**: `runs[].params` is
  `{}` and the reader block is null; `full_refresh_count=never` for that
  run is documented in status.md and corroborated by its trace (1 full =
  launch wash only, 30 partials for 20 turns).
- **`testcard.card_version` reads 1 in every session** even though the
  manifest carries the v2-core features (3-rep stress blocks, reserved
  pagenum/parity rects); the constant was not bumped. The shared manifest
  sha256 (`fe186254…`) is the real card identity.
- **Finding 9's numbers and finding 1's barcode-cell readings are not in
  any committed report** (bespoke analyses of the captures); they are
  reproducible from the videos but not from the committed JSON.
- **armB/armC verdicts are pending**: armB is complete and cataloged
  (session + trace + checksummed video; no report yet); armC was still
  being captured when this document was written.

## 7. Reproduction

Pipeline state: analyzer/recorder code last changed in commit `635e516`
("optics: stays-white flash reference; fixed session homography") — all
committed reports except the two pre-fix lineage reports were produced by
it; dataset assembled and audited at repo HEAD `947f656`.

```sh
# 0) Offline self-test of the whole pipeline (no hardware, no camera):
make optics-check
# = guix shell python python-numpy python-scipy python-pillow ffmpeg -- \
#     make -C pinenote/tools/optics check

# 1) Build the test card (deterministic; manifest sha must be fe186254…):
make -C pinenote/tools/optics testcard OUT=build/testcard

# 2) Record (shape of the sweep commands; device-present step —
#    per-run configs are authoritative in each bundle's runs[].params):
python3 recorder.py record \
  --manifest build/testcard/manifest.json --epub build/testcard/card.epub \
  --bundle build/bundles/<name> \
  --transport ssh --host <device> --backend koreader \
  --camera /dev/videoN --camera-lock --fps 30 \
  --deep-clean 3 --page-period 3.0 \
  --param-sets <sets.json>   # [[label, {"ebc": {...}, "ko": {...}}], ...]
# camera controls locked+readback per session.json:
#   MJPG 1080p30, exposure_time_absolute=312 (100 us units), gain=32,
#   white_balance_temperature=4150, focus_absolute=10; frontlight 255/255.

# 3) Analyze (exact flags used for every committed report):
python3 analyze.py build/bundles/<name> \
  --analysis-scale 0.5 --max-fps 30 -o build/bundles/<name>-report.json
```

Raw videos: `pinenote/tools/optics/build/bundles/<bundle>/capture.mkv` on
the capture workstation (gitignored; 12.28 GB for the 19 finalized
captures). Verify against
[`doc/datasets/2026-07-optics/checksums.txt`](datasets/2026-07-optics/checksums.txt);
each session.json independently embeds its own video's sha256.
