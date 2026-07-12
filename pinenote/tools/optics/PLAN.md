# optics — the experiment plan (v2, from the 2026-07-11 four-critic review)

> Provenance: produced by a 4-critic multi-agent review (card coverage,
> measurement methodology, optimization loop, KOReader realism) of the code and
> docs as of A.2.5; every finding was adversarially verified against the source
> before synthesis (39 confirmed / 1 rejected). This file is the working plan;
> the build-order table at the bottom is the execution queue. README.md stays
> the tool's orientation doc.


**Finding IDs used for traceability** (order as given in the input lists): `CC1–CC10` = card-coverage findings, `ME1–ME10` = methodology findings, `OL1–OL10` = optimization-loop findings, `KR1–KR9` = koreader-realism findings.

---

## 1. Verdict

The instrument is sound — validated detectors, a self-calibrating card, real-video ingest, and a two-tier (camera + ebc-replay) architecture that is the right shape — but the *experiment* around it does not yet exist: transitions are never attributed to a param set (ME1, OL8), the [pn-refresh] trace is never harvested (OL6, KR4), the page-turn injector is unwritten and its device would be ignored by KOReader's input whitelist (OL3, KR2), and the two reader-side knobs that dominate felt behavior are unreachable (OL2). The single biggest weakness is the **missing join**: today's card makes every turn a full global wash (KR1, OL9), so even a perfect capture measures only the regime readers don't live in, and cannot say which config or which KOReader decision produced any number. Fix attribution, the injector, the trace harvest, and the card's regime coverage before adding any optimizer sophistication — the detectors are ready; the plumbing between them and reality is not.

---

## 1a. Single-device stance (2026-07-11, Will's call)

**We are optimizing THIS PineNote, not building a general instrument.** The
portability layer already exists and stays working, but stops receiving
investment. Priority adjustments over the tables below:

- **Demoted**: task 13's phone-VFR robustness (keep the PTS timebase for our
  own webcam's sake, drop the "friend phone" hardening), RECORDING.md
  contributor polish, cross-panel schema care beyond what our own captures
  need. Multi-panel threshold recalibration is dead; **this panel's measured
  noise floor is the reference** (the 10-repeat noise pilot supplies it).
- **Descoped**: cold-bin temperature machinery. Indoors this device lives in
  the 24 °C waveform bin; keep start/end temp logging + the bin-straddle
  guard, skip cold-sweep planning.
- **Fixed-rig simplifications**: one camera, one geometry — calibrate
  homography/photometry once per session and reuse; average repeats harder;
  the subtle-ghost noise floor drops for free. (Self-calibration itself stays:
  it is what makes the webcam quantitative at all.)
- **Camera choice is a device decision**: the panel's waveform runs at 85 Hz
  (A2 ≈ 118 ms, DU ≈ 224 ms). If the boxed webcam does 120 fps at reduced
  resolution, prefer that for fast-mode sessions; 30 fps is fine for
  GC16/GL16-only. Pin the actual webcam model in the bundle metadata.
- **New option unlocked**: a *driver-side* wash trace (what the EBC actually
  drove: wash start/end, waveform used, damage rect — via drm.debug or a
  diagnostic in our own forward-port patch) would be a stronger ground-truth
  join than KOReader's [pn-refresh] intents. Diagnostic-only, so consistent
  with the "report driver bugs, don't fork behavior" policy. SUPERSEDED by §1b:
  the driver already ships `EXTRACT_FBS` — use that instead of adding anything.

## 1b. Community steals (2026-07-11 sweep — full record in doc/eink-research.md §8)

Nobody in the PineNote/reMarkable/Kobo communities has built an optical
measurement rig — this program is novel. But the sweep changed four things:

- **`EXTRACT_FBS` supersedes the "investigate a driver-side trace" idea (§1a)**:
  our driver lineage ALREADY ships an ioctl that dumps the live prev/next
  buffers. That is exact, per-pixel driver-side ground truth (what the EBC
  believes it displayed) to correlate against the camera — no driver patch, no
  policy question. Harness it in the two-tier loop as the third data source:
  camera (optical truth) ↔ EXTRACT_FBS (driver belief) ↔ [pn-refresh] (reader
  intent). Divergence between the three IS the diagnosis.
- **New policy candidate, likely the highest-value one**: hrdl's
  *delayed-quality-redraw* ("fast now, clean later" — his kernel does a GC16
  repaint ~2.4 s after a fast update settles). Implementable in OUR stack as a
  KOReader-side policy (DU/partial during interaction, GL16/GC16 region repaint
  after idle) with zero driver changes. The rig is exactly the instrument to
  judge it: it trades a visible deferred wash for interaction speed.
- **Parameter space additions**: (a) PNDeb's shipped config is a field-tested
  baseline anchor (auto_refresh=1, refresh_threshold=60, split_area_limit=0);
  their user guide's refresh_threshold=20 for redraw-heavy apps is a second
  anchor; (b) `dclk_select=1` (250 MHz) is field-stable per PNDeb dev — cheap
  on-device A/B; (c) `globre_convert_before` (m-weigand's one post-fork
  behavioral param: convert prev buffer into the target waveform's reachable
  space on global refresh — targets post-refresh ghosting under A2/DU4) is a
  small portable patch, then a new bool in the sweep; (d) confirmed extra
  knobs for the fb-backend partials cluster: bw_threshold=7, fourtone=4/7/12,
  bw_dither_invert, delay_a/b/c.
- **A2 may not be worth optimizing**: hrdl's stack dropped A2 entirely
  (DU + early cancellation replaces it), and PNDeb ships an A2 waveform
  *trimmer* accepting gray blacks. Treat A2 as a candidate to eliminate, not
  tune; blue-noise dither tables (hrdl's, constants in his driver source) are
  the portable quality lever for the low-bit modes.

Build-order additions (all non-blocking, after the first capture):

| # | Task | Size |
|---|---|---|
| 23 | EXTRACT_FBS harness: on-device dump helper + host decode + a camera↔driver-belief correlation check in analyze | M |
| 24 | ~~Delayed-quality-redraw prototype~~ **DONE as the idle-washer** (`idlewasher.koplugin`: full-screen debt+idle washes, not region repaint — hardware-validated 2026-07-12, refresh-policy finding 11; thresholds sweepable via the `ko` namespace) | M |
| 25 | Port `globre_convert_before` into the forward-port patch (rung 1–3 offline proof) + add to paramspace | S |
| 26 | Blue-noise dither tables into the bw_mode/low-bit path (or KOReader render) + grayramp rig evaluation | M–L |

## 1c. First-capture session ledger (2026-07-11, night)

Where the rig actually stands after first light:

- **Pilot-calibrated and precise**: 30 fps / exposure 312 / gain 32 /
  frontlight 255-255 (whites 214/255, no clipping); ghost-rms repeatability
  sigma 0.003-0.006 between identical partials; settle verdicts sane after the
  fixed-session-homography change; flash reference is stays-white.
- **First real finding**: GL16 text-CLEAR shimmer — whites adjacent to erasing
  text dip 0.148 +/- 0.032 transiently (absent when text appears). Queue a
  stays-white EROSION knob to separate edge shimmer from background flash.
- **Legacy dark bundle retired**: `build/bundles/first-real` was captured at
  the pre-calibration exposure (whites ~0.55, contrast 0.23 — at the validity
  gate's edge). The corrected pipeline segments only 7/49 transitions on it
  (blank-heavy pages fall below the contrast gate). Do NOT chase this: the
  first calibrated full-card capture supersedes it. If the 7-vs-49 mechanism
  still matters later, instrument the validity gate on that video first.
- **Immediate next**: fresh full-card capture at calibrated settings ->
  should segment ~49 cleanly -> then the GL16-vs-GC16 x full_refresh_count
  sweep is one `--param-sets` file away.

## 2. Test card v2

Ordered by value. All are `testepub.py` + manifest + synth-fixture changes: pure offline-ladder work.

1. **pid-varied content** — pass `pid` into `_draw_content`, deterministic layout variation per kind (line-width phase, panel permutation, row offsets); coarse enough to be human-visible. Makes same-kind STRESS pairs (esp. graphic→graphic ghost) real and fixes the "can't tell pages are turning" live observation. Serves: ghost detector validity, operator feedback. (CC1)
2. **Human-visible page number + parity tile** — ~0.10–0.12-height 7-segment digits bottom-right + alternating-corner black square; record the reserved cell (number cell + BOTH parity corners) in `manifest.json` and **exclude it from white/clean/gray masks at analysis time** (the old footprint turns white next page and would inject digit-shaped ghost). Serves: capture-protocol reliability, dwell verification, video review. (CC2, ME7, OL9)
3. **Stress block ×3 repeats** — append two more copies of the stress sub-sequence with unique pids (PAGEID_BITS=8 gives 256-page headroom); per-pair mean/σ/worst aggregation in `_summarize` keyed on `pair`. Serves: threshold recalibration, all ranking statistics. (CC7, ME2)
4. **Accumulation block** — `accum_00..accum_39` sharing a fixed template with a ~40%-area cycling high-contrast cell; **probe pages = same template with the cell blanked** (not full blanks) after 5/10/20/40 partial turns; end with param-flip GC16 deep clean + recovery probe. Requires `full_refresh_count=never` and `auto_refresh=0` (or GL16 autos counted from the trace) recorded in the manifest. Serves: the load-bearing GL16-residue / deep-clean-cadence question, GL16-vs-GC16 A/B in one ~2-min capture. (CC3, KR5)
5. **checker + grayfield kinds** — 16px checkerboard and uniform 0.5-reflectance content rect; sequence checker→blank and checker→grayfield with STRESS `['ghost']` / `['blotch']`; manifest declares the grayfield content rect as clean/bg region (auto-derivation can't — gray rect is excluded from `after>=0.85`). Serves: worst-case ghost, mid-gray-visible residue, blotch on real captures. (CC5)
6. **grayramp kind** — 16-step wedge matching the waveform's 16 gray levels + continuous ramp + ordered-dither block with **≥4×4-px dither cells** (camera resampling aliases finer); new `'gray'` STRESS tag; manifest marks the calibration strip so `gray_crush_frac` can exclude it. `novel`/`index` already serve as the bitonal A2/DU control. Serves: gray-corruption detector, DU-vs-DU4 discrimination, bw_mode experiments. (CC6)
7. **night kind + dark-flash detector** — inverted novel (black content rect, white margins/markers); `dark_mask = after<=0.15`, `settled_dark` baseline, dark analog of `count_flashes`; synth round-trip must include a night frame through `detect_fiducials` (the 0.15 bright-area gate needs re-keying to bounding extent). Serves: GC16 black→black white-flash direction, asymmetry. (CC10)
8. **Real TTF glyph text** — render novel/textbook with Pillow ImageFont from `pinenote/fonts/local/` (gitignored MB Type files) with graceful DejaVu fallback; amend the determinism docstring. Serves: realistic edge-gray histogram for ghost/dither/DU transfer, populates gray_mask on text pages. (KR9)
9. **coverN family** (cover10/30/50/70/90 black-block pages off a shared template) with `expected_damage_fraction` in the manifest — labeled `['settle']`/`['ghost','settle']` **not** `['flash']`: page turns present full-viewport rects to KOReader, so this samples settle-vs-coverage and the driver's pixel-diff accumulator, **not** the flash_area_fraction boundary (that needs controlled-rect flashui via the fb backend — §5). Serves: ebc-replay wash-px-phase ground-truthing. (CC8)
10. **Four-corner white+black mini-patches** (not a mirrored bottom strip — the barcode owns that span) → 8 constraints for a bilinear gain+offset field in ingest. Serves: blotch/ghost-rms decontamination from the edge-lit frontlight gradient. (ME4)
11. **Duplicated endpoint patches** at both strip ends for mura redundancy. (CC9)
12. Fix the `('index','ux')` STRESS-label rationale comment — it exercises a full-page turn, not flashui policy. (CC8 note)

Regenerate all synthetic-clip/golden fixtures after 1–2 (CC1 note). Card grows to ~60–100 pages ≈ 2.5–5 min/lap at the new 2.5–3 s/page pace.

---

## 3. Methodology fixes

**Protocol (RECORDING.md)**
- Pace 2.5–3 s/page; `--page-period` default 3.0 (ME7). 60 fps **required** when A2/DU/DU4 are candidates; 30 fps acceptable for GC16/GL16-only (ME9). Disable phone auto-FPS/low-light frame-rate reduction (ME8). Frontlight: set warmth so both channels are equal, or record your split (ME5 — do *not* mandate cool-only; the driver convention pins both equal).

**Capture correctness (recorder + ingest)**
- **One video + one bundle per param set** — move `_webcam` inside the param-set loop; each run gets its own sync flashes, so `analyze.py`'s single-`find_sync` assumption holds unchanged. Also fix `recorder.py:276` to pass `params=r["params"]` into `add_run` (schema already supports it), and note pooled ingest also fabricates a spurious cross-run transition per boundary. (ME1, OL8)
- **`--camera-lock`**: probe `v4l2-ctl --list-ctrls`, apply what exists (exposure/focus/WB), persist the **readback** into session.json. (OL8)
- **find_sync on the panel region** (or black-flash-only OR): on real footage sync_end currently lands wrongly early (first black flash ends the loop); add a synthetic two-run split test asserting sync_end. (ME1)
- **Segment truncation**: slice `warped[onset:next_onset]`; `window_s = min(configured ~2.0–2.5s, gap − 2 frames)`; `settled_frame` = last QUIET frame (reuse detect_settle's scan), temporally averaged over the last quiet frames (~√3 noise win). (ME7, ME2)
- **Panel-state reset + counterbalancing**: before candidate params, apply baseline params and issue N≥3 GC16 deep cleans via the transport (`refresh_waveform=4` + `pinenote-ebc-refresh` ×N — works under both backends), logged as a new `'clean'` event; then flip candidate params, then sync. Run candidates in ABBA order; analyze asserts same-session and reports panel-temp delta. (ME3)
- **Timebase**: return per-frame PTS from ffprobe (`best_effort_timestamp_time`, `-fps_mode passthrough` for decode alignment); detect VFR (std(diff)>5% median), record `capture.vfr`/`fps_measured`; convert all `*_s` metrics and `SETTLE_QUIET_FRAMES` to duration-over-dt; jittered-PTS regression test. (ME8)
- **Temperature**: sample panel temp at run **start and end**; compute `expected_settle_s` from `gc16_phases_by_temp` (greatest bin ≤ temp) / `frame_rate_hz`; refuse/downweight comparisons straddling a temp bin. (ME6)

**Photometry**
- **Guarded fit**: endpoint-linear fit first, mid-patch residual check, fallback + `strip_crushed: true` flag; route `decode_pageid`'s per-frame fit through the same guard (crushed strips also break segmentation). The residual test doubles as a free "1-bit mode engaged" detector. (CC9)
- **Bilinear spatial gain field** from the corner patches; synthcam strong-gradient (25%) regression test asserting defect-free ghost_rms/blotch_std stay sub-threshold. (ME4)

**Detectors and report**
- **Wire contrast/blotch on the real path**: build eroded patch masks (p0/p4) at panel resolution in `ingest.ingest`, plus a manifest `bg_region` (an explicit should-be-white rect — the blank page is not uniform); document that per-transition photometry makes detect_contrast a *delta* measure. (CC4)
- **Report v2** (bump REPORT_VERSION): gray/contrast/blotch numeric blocks per transition and in summary; run_id/params on every transition; per-pair mean±σ across repeats; **rank flash by energy, keep depth descriptive**; ghost aggregation respects the corr gate and reports excess-over-measured-noise-floor (plateau frame-pair rms ÷ √2, quadrature-subtracted). (OL5, ME2, ME9)
- **Turn-latency join**: pass run events into analyze; `command_frame = sync_end + round(t·fps)` (t=0 is *end* of sync — fix the misleading comments, no off-by-one "correction"); match events to transitions by `to_pid`; unmatched events flag missed transitions. Select the run whose events belong to this capture explicitly. (OL4)
- **Trace harvest**: after each KOReaderBackend run, `transport.pull` **/var/log/optics-koreader.log** (not reader-session.log — prepare() redirects there) into `trace.<run_id>.log` as a sidecar referenced from session.json; clock-align via the sync flashes; synthesize trace from scenario events for fb-backend runs; extend `validate_session` + tests. (OL6, KR4)
- **Schema v2** (bump bundle VERSION): `camera {model, fps_mode, exposure_locked, shutter_s?}`, `reader {app, version, full_refresh_count, flash_area_fraction}` (scraped via SSH backend; CLI override for manual bundles), `illuminant {cool_level, warm_level, ambient}` (legacy automated bundles are *not* underspecified — split pinned equal), `runs[].panel_temp_c_start/_end`, `runs[].events_source: measured|nominal` (gate when events are first consumed), `device.wbf_sha256` written by both record and package paths as a validation *warning* (not required — keeps the phone-only contributor path alive), and fix the silent `--wbf-sha256` drop in `cmd_package`. (ME10, ME5, ME6)

---

## 4. The optimization loop

**Architecture: two tiers, confirmed** — the division is capability, not just speed: the camera measures per-transition optics and calibrates proxies; ebc-replay measures session-scale accumulation (staleness, wash rate over 30+ min traces) that a 2-minute card physically cannot. (OL6, OL7)

**Parameter space** (document in refresh-policy.md; encode in `pinenote/tools/optics/paramspace.py` emitting typed values — bools as Y/N — consumed by both recorder `--param-sets` and ebc-replay, so both tiers sweep the identical space by construction). (OL1)

| Knob | Type | Sweep values | Mechanism | Constraints |
|---|---|---|---|---|
| refresh_waveform | enum | {4=GC16, 6=GL16} | sysfs runtime | GCC16/GLR16/GLD16 sha-identical to GL16; A2/DU globals unsound for KOReader |
| default_waveform | enum | {4; 2=DU, 3=DU4} | sysfs runtime | 2/3 only jointly with bw_mode + thresholds cluster (fb-backend study) |
| refresh_threshold | int | {10, 20, 40, 60} | sysfs runtime | moot when auto_refresh=0 |
| auto_refresh | bool | {0, 1} | sysfs runtime | manual washes never reset accumulator (quirk 3) |
| full_refresh_count | int | {1, 3, 6, never} | KO settings file, seeded per run | |
| flash_area_fraction | float | {0.4, 0.6, 0.8} | G_reader_settings (after OL2 change) | boundary itself sampled via fb backend, not the card |
| **Held fixed** | | ship values | params one-shot (NOT modprobe.d/cmdline — inert, the A.2 bug) | direct_mode/skip_reset are 0444; panel_reflection=1, dclk_select=0, diff_mode, delays, temp_override (experiment tool only) |

Core camera-facing factorial ≈ **54–72 configs** + a 4–6-config DU/bw_mode partials cluster.

**Objective** — never a bare scalar. `score.py` per-config vector over transitions with STRESS-pair weighting (tags already in the report): {flash energy p95, flash count/page, ghost-RMS-excess p95 on blank-reveal pairs, turn latency p50, wash rate/page (from the harvested trace, not optics), gray_crush max, contrast-delta min, blotch max}. **Hard constraints** (disqualify): gray_crush > ε; settled=false *after verifying the capture window actually covered the settle span*. Compute the **Pareto front over (flash, ghost, latency)**; ship ONE default weight vector documented as a Decision in refresh-policy.md to rank within the front; always publish the front. (OL5)

**Search strategy — no fancy optimizer** (OL7): 
1. Offline full factorial: all valid configs × several long real traces on ebc-replay (minutes, free repeats) → Pareto + default-score ranking. The main-effects/interaction table is itself a deliverable.
2. **Camera anchors**: 6–8 extreme configs (GC16/GL16 × full-every-1/never × threshold 20/off — GC16 configs mandatory for staleness dynamic range) × 3 repeats ≈ 24 runs × ~90 s ≈ **40 min**. Regress proxy→optic per anchor (white-driven-dark ↔ flash energy; wash px-phases ↔ total flash energy; staleness ↔ ghost RMS; replay settle ↔ settle_s/latency).
3. **Camera shortlist**: top 8–12 + Pareto knees, ×3 ≈ **~1 h** → verdict → Decision entry.
4. Documented fallback: camera full factorial (~180–230 runs, 3–6 h overnight) if anchor R² is low or rank order disagrees.
- Wash-rate power: `--laps N` implemented as **prev-key rewind** (rewind window tagged in events and excluded from scoring; no KOReader relaunch between laps — that would reset the full_refresh_count accumulator). (OL7)

**Minimal first experiment once the camera box exists**: one baseline-config run — card v2, KOReaderBackend over SSH, camera locked. It proves in a single ~5-minute session: injector daemon, per-run bundle+attribution, panel-region sync detection, trace harvest + per-turn intent verification (full vs partial — never assume), and the latency join. Immediately follow with the **10-repeat single-stress-pair noise pilot** to measure between-repeat σ and fix N by the paired-design formula (human paging as fallback if the injector's live proof slips). (ME2, OL10, OL9)

---

## 5. KOReader realism

**Add:**
- **The injector, persistent-daemon form** (OL3, KR2): a luajit-ffi process started by `prepare()` *before* the KOReader relaunch that creates the uinput keyboard and **holds the fd** (one-shot create/emit/exit is not viable — the device vanishes and KOReader enumerates input once at init). Device name: add an explicit `'wilkbook-optics'` match to device.lua's whitelist (cleaner than shadowing `ws8100_pen`; device.lua is wilkbook-owned, so this doesn't violate the upstream-bugs policy). Declare keybits 158/159 (+139 KEY_MENU for UI actions), emit EV_SYN per press/release; `/root/optics-inject` becomes a FIFO client; `_ensure_injector`'s `|| :` becomes a hard failure. Offline-prove the 159/158→RPgFwd/RPgBack chain on the koreader-input harness and create-then-enumerate ordering on QEMU rung 4v. Fix the "mechanism pinned" overstatement at driver.py:74.
- **Promotion-regime axis** (KR1): seed `refresh_on_pages_with_images` **explicitly false** (makeFalse semantics — deletion re-enables it) + explicit `full_refresh_count` in a scenario-owned settings file pushed *after* the old KOReader stops and *before* relaunch; run a defaults regime as contrast; **assert which intent fired per turn from the harvested trace** — this is the only way to know the card measured the diff-masked partial path readers actually live in.
- **Dedicated KO_HOME** (`/root/.config/koreader-optics`, KR8): seeded settings + fonts replicating reader-session.scm's dogfooding typography; per-book .sdr/history isolated for free; restart reader-session after the run; record seeded settings in the bundle next to ebc_params; record flash_area_fraction as image/package metadata (hardcoded per image until OL2 lands).
- **ko param namespace** (OL2): param sets become `{"ebc": {...}, "ko": {"full_refresh_count": N, "pinenote_flash_area_fraction": F}}`; device.lua reads `pinenote_flash_area_fraction` from G_reader_settings with a nil-guard, default 0.60; ko.* written in prepare()'s stop→relaunch window (zero extra restarts).
- **Real UI actions** (KR3, KR6): prefer a tiny optics plugin polling a command file via UIManager/Dispatcher (SSH transport) over injection for menu open/close, footer toggle, keyboard; overlay-ghost metric = settled-pre vs settled-post-undo frame diff (a genuinely **new analyzer path** — action events, not manifest page pairs, are the segmentation authority for sub-eps regions); sweep dialog size across the 0.60 boundary using the trace's damage rects.

**Genuinely NOT measurable via the epub path** (route to fb backend / direct driving):
- **A2/DU behavior** — fast/a2 intents are trace-only in device.lua; no per-update waveform UAPI. Study via FramebufferBackend with `default_waveform` flips, which needs a small driver.py extension (fb backend today only writes refresh_waveform and has no partial-damage path). Any reader-side fast-burst prototype flips *only* default_waveform, keeps prepare_prev_before_a2=1, and is gated on ebc-replay evidence first. (KR7)
- **The flash_area_fraction rect boundary** — flash_policy is rect-based and page turns always present full-viewport rects; sample it with controlled-rect flashui refreshes (fb backend partial-rect ioctl at 0.1–0.9, or sized dialogs via the UI-action path). (CC8)
- **Session-scale staleness / deep-clean cadence** — ebc-replay's job on long real traces, plus the soak scenario: `cycle` (N∈{10,50,150} laps GL16-only) and `deep_clean` (waveform-flip + EBC_REFRESH) step types, with auto_refresh=0 or GL16-autos counted from the trace; residue = p4 + page-background whites before/after the clean. (KR5, CC3)
- **crengine-reflowed transfer** — a real reflowed chapter segment indexed by time-from-sync (barcode won't survive reflow), as the transfer check for any card-chosen policy. (KR9, OL9)

**Docs** (OL10): rewrite optics README "Next" as the loop (injector proof → single-panel anchors → offline factorial → shortlist verdict → Decision); demote multi-panel data to threshold recalibration; rename ROADMAP §4 Phase C to the two-tier loop cross-referencing the networking bullet; prune the stale "replay a real harvested trace" item in **both** refresh-policy.md:233 and ROADMAP §4; transport docstrings say "SSH-primary once A.2.5 boots; serial CDC-ACM proven fallback."

---

## 6. Build order

> **STATUS 2026-07-11: blocker tasks 1–8 are DONE** — implemented by four
> parallel workstreams, integrated, and green (200 optics checks +
> koreader-input ALL PASSED, incl. a live host-uinput proof of the injector
> daemon). Two integration seams were wired at merge exactly as the
> workstreams' seam notes prescribed (reserved-key no-op test vs the
> always-reserved card; harvest_trace default moved into the DeviceDriver ABC
> with pull-fallback-on-None). Remaining before the FIRST VALID CAPTURE:
> **(a) flash A.2.6** (the device.lua whitelist + G_reader_settings read ride
> in the koreader-bin graft — the deployed A.2.5 image predates them), and
> **(b) the injector live proof** over SSH (create-before-KOReader-enumerates
> ordering + evdev delivery — the precisely-stated residual gap), then the
> smoke run + 10-repeat noise pilot. Tasks 9+ remain open.

All tasks offline-provable except where noted. **[BLOCKER]** = blocks the first *valid* real capture; everything else can follow it.

| # | Task | Why | Offline-provable | Size | Gate |
|---|---|---|---|---|---|
| 1 | Injector daemon + device.lua `wilkbook-optics` whitelist + keybits/EV_SYN + FIFO client; harness + QEMU proof; fix driver.py:74 wording | Only path to KOReaderBackend captures (OL3, KR2) | Yes (koreader-input harness, QEMU 4v); live proof = step 1 of next SSH session | M | **[BLOCKER]** |
| 2 | Per-param-set video+bundle; `add_run` params fix; `--camera-lock` with readback | Transition→config join; photometric stability (ME1, OL8) | Yes (FakeClock/fake drivers, test_bundle) | M | **[BLOCKER]** |
| 3 | find_sync panel-region fix + two-run split test | sync_end is wrongly early on real footage (ME1) | Yes (synthcam) | S | **[BLOCKER]** |
| 4 | Card v2 core: pid-varied content, page number + parity tile with manifest-reserved cell + mask exclusion, stress ×3, 3 s pace; regen fixtures | Real STRESS pairs, operator feedback, variance data (CC1, CC2, CC7, ME7) | Yes (synth round-trip) | M | **[BLOCKER]** |
| 5 | Scenario settings seeding: dedicated KO_HOME, `refresh_on_pages_with_images=false`, full_refresh_count, ko namespace + device.lua G_reader_settings read | Measure the partial path; reproducibility (KR1, KR8, OL2) | Yes (FakeTransport command assertions) | M | **[BLOCKER]** |
| 6 | Trace harvest: pull optics-koreader.log → `trace.<run_id>.log` sidecar, validation, clock alignment | Verify per-turn intent on capture 1; the ground-truth join (KR4, OL6) | Yes (FakeTransport) | S | **[BLOCKER]** |
| 7 | Panel reset ('clean' event, N≥3 GC16 via EBC_REFRESH under baseline params) + ABBA ordering + temp start/end | Comparable runs (ME3, ME6) | Yes | S | **[BLOCKER]** for multi-config; skippable for the single-run smoke |
| 8 | Ingest windowing: truncate at next onset, quiet-frame settled_frame, window 2.0–2.5 s | Un-confound settle from the next wash (ME7) | Yes | S | **[BLOCKER]** |
| 9 | Report v2: run attribution fields, gray/contrast/blotch mask wiring + numeric blocks, noise floor + excess-over-floor ghost, per-pair aggregation, energy-keyed flash severity | Scoring three dead detectors; statistics (CC4, OL5, ME2, ME9) | Yes | M | after |
| 10 | Turn-latency join + missed-transition flags (fix t=0 comment) | The central feel metric (OL4) | Yes | S–M | after |
| 11 | Schema v2 metadata: camera/reader/illuminant/events_source/wbf_sha256 warning + cmd_package fix; RECORDING.md updates (illuminant, fps, pace) | Cross-panel comparability (ME10, ME5) | Yes | S | after |
| 12 | Guarded photometry fit + strip_crushed + decode_pageid routing; corner patches + bilinear gain field + strong-gradient synthcam test | 1-bit runs analyzable; gradient decontamination (CC9, ME4) | Yes | M | after (before any DU/A2 or blotch-sensitive session) |
| 13 | VFR/PTS timebase + passthrough decode + jitter test; synthcam exposure integration + 30-vs-60 fps bias test; README limits fix | Phone-contributor validity; fast-mode fairness (ME8, ME9) | Yes | M | after (before accepting friend captures) |
| 14 | Temp-compensated expected_settle_s + bin-straddle guard | Kill the cold-panel false positive (ME6) | Yes | S | after |
| 15 | Card v2 extended: accumulation block, checker/grayfield, grayramp, night + dark-flash detector (incl. fiducial gate fix), coverN, glyph text, endpoint duplication | Deep-clean cadence, worst-case ghost, gray corruption, dark asymmetry, transfer realism (CC3, CC5, CC6, CC8, CC10, KR9, KR5) | Yes | L | after (accumulation block is the highest-value piece — do it first within this task) |
| 16 | paramspace.py + refresh-policy.md parameter table (apply-mechanism + bool-type aware) | One space, both tiers (OL1) | Yes | S | after |
| 17 | score.py: vector, hard constraints (window-verified), Pareto front, default weights Decision | Rankable output (OL5) | Yes | M | after |
| 18 | Sweep runner (record→analyze→results table) + `--laps` rewind with tagged/excluded rewind windows | The actual closed loop (OL8, OL7) | Yes | M | after |
| 19 | Soak scenario: `cycle`/`deep_clean` step types + auto_refresh control + residue metric | GL16 residue curve → cadence decision (KR5, CC3) | Yes (fake drivers); verdict needs device | M | after |
| 20 | UI-action plugin + `action` event schema + settled-pre/post-undo analyzer path | Overlay ghost, 0.60 boundary, small-region regime (KR3, KR6) | Yes | L | after |
| 21 | fb-backend extension: default_waveform writes + partial-damage induction + controlled-rect flashui fractions | A2/DU partials and the flash-fraction boundary — unreachable via epub (KR7, CC8) | Yes | M | after |
| 22 | Docs refresh: README Next, ROADMAP §4, refresh-policy.md:233 prune, transport docstrings (SSH-hedged) | Plans match reality (OL10) | Yes | S | anytime |

**Critical path to first valid capture**: 1 → (2,3,4,5,6,8 in parallel) → 7 → smoke run + injector live proof + 10-repeat noise pilot on the A.2.5 SSH session. Everything from task 9 down improves what you *learn* from captures; tasks 1–8 determine whether a capture is worth anything at all.