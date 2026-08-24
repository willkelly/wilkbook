#!/usr/bin/env python3
"""The 2026-07-12 optics evidence audit, as a re-runnable tool.

`doc/driver-findings-report.md` § "Evidence audit (2026-07-12)" rests its
retractions and confirmations on four offline passes that were run from a
session scratchpad as `audit-validity.py`, `audit2-perframe.py`,
`inspect-window.py`, plus a verbatim rerun of the campaign's patch-strip
detector. Those files were never committed and are not recoverable (no object
in the repo's history, gone from the capture workstation). This module
reconstructs the four passes from their descriptions in the report, built on
`ingest.py`'s primitives rather than on re-pasted copies of them, so the
audit's METHOD is in the tree even though its scripts are not:

    validity   per-frame fiducial-validity accounting        (audit-validity)
    perframe   per-frame-own-fit warp + geometry self-check  (audit2-perframe)
    window     full-fps frame window around a claimed event  (inspect-window)
    strip      patch-strip wash detector                     (campaign rerun)
    dataset    what the COMMITTED dataset can re-check       (new)

READ THIS BEFORE QUOTING ANYTHING THIS TOOL PRINTS
--------------------------------------------------
The first four passes all read camera frames, and **the committed dataset
carries no pixel data** -- `doc/datasets/2026-07-optics/` is session JSON,
KOReader traces and defect reports (~1.2 MB). Their only possible input is a
bundle's `capture.mkv`, 12.28 GB across the 19 finalized captures, gitignored
by policy and represented in the repo only by sha256
(`doc/datasets/2026-07-optics/checksums.txt`). So the frame passes are
re-runnable by a third party who has been handed the videos and has verified
them against those checksums -- NOT from a repo checkout.

`dataset` is the part that runs from a checkout alone. It recomputes every
audit claim the committed files actually support, checks each against the
number published in the report, and prints an explicit register of the claims
that are NOT reproducible from the repo and why. A green `dataset` run does
not mean the audit reproduced; it means the reproducible SUBSET reproduced.
The register is the honest part of the output.

Reconstruction caveat: these are re-derivations from the report's prose, not
the original files. Where the report quotes an intermediate number the pass
should produce, it is quoted in the relevant docstring so a reader can see
what the pass is aimed at. They have not been run against the 2026-07 videos
(this repo has no copy), so the frame passes are validated only against the
synthetic fixtures in `test_audit.py`.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys

# --- the committed dataset -------------------------------------------------

_HERE = os.path.dirname(os.path.abspath(__file__))
DATASET_DIR = os.path.normpath(
    os.path.join(_HERE, "..", "..", "..", "doc", "datasets", "2026-07-optics"))

# The capture night ran on a UTC-6 wall clock; the report's timeline forensics
# quote local times ("driver-owned 18:26"), the sessions record UTC. Pinned as
# a constant rather than read from the host tz so the check is location-free.
CAPTURE_UTC_OFFSET_H = -6


# ===========================================================================
# Pass 5 (new): what the COMMITTED dataset can re-check
# ===========================================================================
#
# Every entry below is a claim the evidence audit (or the dataset doc's
# recomputation of the campaign numbers the audit voided) states in prose,
# paired with the value published for it. `dataset` recomputes each from
# doc/datasets/2026-07-optics/ and reports agreement. Pure stdlib: no numpy,
# no ffmpeg, no video.

# doc/driver-findings-report.md:545,563,571,585,548 -- the "segmentation-symptom
# numbers" the audit declares instrument-dominated. Voiding them is only
# meaningful if a third party can see the numbers being voided; these are the
# analyzer's own n_transitions, straight out of the committed reports.
PUBLISHED_SEGMENTATION = {
    "neverx3.r00-gl16-never-a": 0,     # "segmented 0/48"
    "neverx3.r01-gl16-never-b": 429,   # "429 pseudo-transitions"
    "neverx3.r02-gl16-never-c": 48,    # "stays clean (as the campaign counted it)"
    "driver-owned": 6,                 # "6/48"
    "cadence.r01-gl16-c12": 19,        # "cadence.r01's unexplained 19/48"
    "sweep1.r02-gl16-never": 1,        # dataset doc §5.1 (see SWEEP1_R02_NOTE)
}

# doc/optics-dataset-2026-07.md:159-180, the "trace F/P" column: full-global vs
# partial [pn-refresh] lines per run. This is the audit's workload context --
# which runs were washless -- and it is fully re-derivable from the committed
# traces.
PUBLISHED_TRACE_FP = {
    "first-real": (8, 39),
    "noise-pilot": (1, 30),
    "cal-baseline": (8, 39),
    "sweep1.r00-gl16-full6": (9, 39),
    "sweep1.r01-gc16-full6": (8, 39),
    "sweep1.r02-gl16-never": (1, 46),
    "sweep1.r03-gc16-full1": (48, 0),
    "cadence.r00-gl16-c6": (8, 39),
    "cadence.r01-gl16-c12": (4, 43),
    "cadence.r02-gl16-c20": (3, 44),
    "cliff.r00-gl16-c25": (2, 46),
    "cliff.r01-gl16-c35": (2, 45),
    "cliff.r02-gl16-c40": (2, 45),
    "neverx3.r00-gl16-never-a": (1, 46),
    "neverx3.r01-gl16-never-b": (1, 47),
    "neverx3.r02-gl16-never-c": (1, 46),
    "driver-owned": (1, 46),
    "armB": (1, 46),
}

# doc/driver-findings-report.md:624-627, "Timeline forensics (capture mtimes)".
# session.json records ONE created_utc per session, written when the session
# was finalized -- so a multi-run session (neverx3's three captures) carries
# only the last capture's clock. The two single-capture sessions the report
# names are checkable exactly; neverx3's stamp matches the third of its three
# quoted times and is checked as such.
PUBLISHED_TIMELINE_LOCAL = {
    "driver-owned": "18:26",
    "armB": "19:14",
    "neverx3.r02-gl16-never-c": "18:15",   # report: "neverx3 18:09/18:12/18:15"
}

# doc/optics-dataset-2026-07.md:264-271 -- the ux->novel double flash, [2,2,2]
# in every fully-segmented full-cadence bundle. The audit leans on the clean
# bundles being instrument-sound; this is the sharpest committed check of that.
#
# Two entries name a report EXPLICITLY (`bundle::file`) because the claim is
# about a specific generation of a two-report bundle: first-real's [1,1,1] is
# the same-day analyzer that segmented all 49 transitions off the dark
# capture, NOT the corrected `-report3` (which segments 7 and reports no
# ux->novel at all). Guessing the "canonical" report gets that claim wrong.
PUBLISHED_UX_NOVEL = {
    "cal-baseline": [2, 2, 2],
    "sweep1.r00-gl16-full6": [2, 2, 2],
    "sweep1.r01-gc16-full6": [2, 2, 2],
    "sweep1.r03-gc16-full1": [2, 2, 2],
    "cadence.r00-gl16-c6": [2, 2, 2],
    "cadence.r02-gl16-c20": [2, 2, 2],
    "cliff.r00-gl16-c25": [2, 2, 2],
    "cliff.r01-gl16-c35": [2, 2, 2],
    "cliff.r02-gl16-c40": [2, 2, 2],
    "neverx3.r02-gl16-never-c": [2, 2, 2],
    # retired dark capture: under-detection at the bad exposure
    "first-real::first-real-report.json": [1, 1, 1],
    # the shattered run "reads 0 on its 44 pseudo-repetitions"
    "neverx3.r01-gl16-never-b": [0] * 44,
}

# doc/optics-dataset-2026-07.md:73-79 -- instrument precision, the sigma the
# audit's "~10x the same-rig crisp floor" magnitudes are read against.
PUBLISHED_NOISE_PILOT = {
    # pair: (n, ghost_rms_sigma, flash_depth_mean, flash_depth_sigma)
    "novel->blank": (10, 0.0026, 0.1485, 0.0316),
    "blank->novel": (11, 0.0061, 0.0098, 0.0132),
}

# doc/driver-findings-report.md:616-624 -- soak1's recorded interventions, the
# alignment anchor for its two unexplained events. The EVENT TIMES the audit
# found are pixel-derived (not reproducible); the recorded interventions the
# audit aligned them to are committed.
PUBLISHED_SOAK1_INTERVENTIONS = [("intervention-GL16-global", 101.04),
                                 ("intervention-GC16-global", 140.68)]

# Claims the audit makes that the committed dataset CANNOT check, with the
# reason. Printed on every `dataset` run: the register is the deliverable, not
# a footnote. "no pixels" = needs capture.mkv; "not committed" = the bundle
# itself never reached doc/datasets/.
NOT_REPRODUCIBLE = [
    ("96-97% per-frame fiducial validity in every walk bundle", "no pixels"),
    ("the only >=1 s validity holes are the sync-flash blocks", "no pixels"),
    ("blank-KIND card pages carry fiducials and validate fine", "no pixels"),
    ("the corrupt-run captures open on graphic page 46 (the poisoning "
     "partition into {never-a, never-b, driver-owned, armC} vs "
     "{never-c, armB, armB2, soak1, sweep1.r02})", "no pixels"),
    ("never-a's t~108 whole-page ghost paint and t~109.2 restoring wash",
     "no pixels"),
    ("never-b's framing marks sustained at 0.22-0.38 reflectance mid-run",
     "no pixels"),
    ("driver-owned crisp at framing 0.006-0.018, 51% of frames verified",
     "no pixels"),
    ("sweep1.r02 geometry-verified crisp at framing 0.007-0.024, 100% decode",
     "no pixels"),
    ("armC framing cells/black patch 0.08-0.10 vs 0.001-0.02 floors, and the "
     "per-event 0.04 -> 0.09 step at t~90", "not committed"),
    ("armB/armB2 97% validity, 99%+ aligned decode, zero mid-walk strip events",
     "armB report not committed; armB2 bundle not committed"),
    ("soak1's two unexplained strip events at t~100/105 and the permanent "
     "0.01 -> ~0.10 graying", "soak1 has soak-events.json only, no pixels"),
    ("the verbatim patch-strip detector rerun reproducing every claimed "
     "event time", "no pixels"),
    ("repro v1-v5, idlewasher and the instrumented debug session",
     "not committed"),
]

# A disagreement found while writing this tool; see `dataset` output and
# doc/driver-findings-report.md. Recorded here so the check carries it.
SWEEP1_R02_NOTE = (
    "sweep1.r02 is listed by the audit among the runs that 'opened on crisp "
    "pages and their reports are quantitative', but its committed report "
    "segments 1 of 48 -- the second-worst collapse in the catalog, after "
    "never-a's 0 and ahead of driver-owned's 6, both of which the audit calls "
    "instrument-poisoned. Nothing in the committed dataset supports putting "
    "sweep1.r02 on the sound-instrument side of that partition.")


def _load_json(path):
    with open(path) as f:
        return json.load(f)


def _bundle_dirs(root):
    return sorted(d for d in os.listdir(root)
                  if os.path.isdir(os.path.join(root, d)))


def _report_paths(root, name):
    d = os.path.join(root, name)
    return sorted(os.path.join(d, f) for f in os.listdir(d)
                  if "report" in f and f.endswith(".json"))


def _canonical_report(root, name):
    """The report a claim about this bundle refers to. Two bundles carry a
    pre-fix lineage report alongside the canonical one (dataset doc's "Report
    lineage"): noise-pilot's `-report2` and first-real's `-report3` are the
    corrected pipeline; the unsuffixed file is the superseded generation."""
    paths = _report_paths(root, name)
    if not paths:
        return None
    for suffix in ("report3.json", "report2.json"):
        for p in paths:
            if p.endswith(suffix):
                return p
    return paths[0]


def _resolve(root, spec):
    """A published-table key -> (bundle_name, report_path_or_None).

    `spec` is a bundle directory, or `bundle::report.json` when the claim is
    about one named generation of a multi-report bundle."""
    if "::" in spec:
        name, fname = spec.split("::", 1)
        p = os.path.join(root, name, fname)
        return name, (p if os.path.exists(p) else None)
    if not os.path.isdir(os.path.join(root, spec)):
        return spec, None
    return spec, _canonical_report(root, spec)


def _trace_counts(root, name):
    """(full-global, partial) [pn-refresh] line counts for a bundle's trace.
    `ui partial` (the one launch paint every trace carries) is excluded from
    both -- it is not a page turn."""
    d = os.path.join(root, name)
    traces = sorted(f for f in os.listdir(d)
                    if f.startswith("trace.") and f.endswith(".log"))
    if not traces:
        return None
    full = partial = 0
    with open(os.path.join(d, traces[0]), errors="replace") as f:
        for line in f:
            m = re.search(r"\[pn-refresh\]\s+(\S+)\s+(\S+)", line)
            if not m:
                continue
            if m.group(1) == "full":
                full += 1
            elif m.group(1) == "partial":
                partial += 1
    return full, partial


def _mean_sd(xs):
    n = len(xs)
    if n == 0:
        return 0, float("nan"), float("nan")
    m = sum(xs) / n
    sd = (sum((x - m) ** 2 for x in xs) / (n - 1)) ** 0.5 if n > 1 else 0.0
    return n, m, sd


def _finite(x):
    return x is not None and x == x        # None or NaN -> False


def _local_hhmm(created_utc):
    """'2026-07-12T00:26:43Z' -> '18:26' on the capture night's wall clock."""
    hh = int(created_utc[11:13]) + CAPTURE_UTC_OFFSET_H
    return "%02d:%s" % (hh % 24, created_utc[14:16])


class _Check:
    """One published-vs-recomputed comparison."""

    def __init__(self, claim, published, recomputed, ok):
        self.claim, self.published, self.recomputed, self.ok = \
            claim, published, recomputed, ok

    def line(self):
        tag = "repro " if self.ok else "DIFFER"
        s = "  [%s] %s" % (tag, self.claim)
        if self.ok:
            return s + "  -- %s" % (self.recomputed,)
        return s + "\n           published %s / recomputed %s" % (
            self.published, self.recomputed)


def audit_dataset(root=DATASET_DIR):
    """Recompute every audit claim the committed dataset supports.

    Returns (checks, register). `checks` is the published-vs-recomputed list;
    `register` is NOT_REPRODUCIBLE. Stdlib only -- runs from a bare checkout
    with no numpy, no ffmpeg and no video."""
    checks = []
    have = set(_bundle_dirs(root))

    # 1. segmentation counts (the numbers the audit voids)
    for name, published in sorted(PUBLISHED_SEGMENTATION.items()):
        if name not in have:
            checks.append(_Check("seg %s" % name, published,
                                 "bundle not in dataset", False))
            continue
        rp = _canonical_report(root, name)
        got = _load_json(rp)["summary"]["n_transitions"] if rp else None
        checks.append(_Check("seg %s" % name, published, got, got == published))

    # 2. trace full/partial counts (the workload context)
    for name, published in sorted(PUBLISHED_TRACE_FP.items()):
        got = _trace_counts(root, name) if name in have else None
        checks.append(_Check("trace F/P %s" % name, published, got,
                             got == published))

    # 3. timeline forensics
    for name, published in sorted(PUBLISHED_TIMELINE_LOCAL.items()):
        got = None
        if name in have and os.path.exists(os.path.join(root, name,
                                                        "session.json")):
            got = _local_hhmm(
                _load_json(os.path.join(root, name, "session.json"))["created_utc"])
        checks.append(_Check("timeline %s (local)" % name, published, got,
                             got == published))
    # ... and the claim those times were made to support: one night, no gap
    # big enough to hide a reboot between the corrupting and the clean runs.
    stamps = []
    for name in have:
        p = os.path.join(root, name, "session.json")
        if os.path.exists(p):
            stamps.append(_load_json(p)["created_utc"])
    stamps.sort()
    span_h = None
    if stamps:
        def _mins(s):
            return (int(s[8:10]) * 24 * 60 + int(s[11:13]) * 60 + int(s[14:16]))
        span_h = (_mins(stamps[-1]) - _mins(stamps[0])) / 60.0
    checks.append(_Check("all committed sessions inside one capture night",
                         "<= 12 h", "%.2f h across %d sessions (%s .. %s)"
                         % (span_h, len(stamps), stamps[0][:19], stamps[-1][:19])
                         if stamps else None,
                         span_h is not None and 0 <= span_h <= 12))

    # 4. ux->novel double flash
    for spec, published in sorted(PUBLISHED_UX_NOVEL.items()):
        name, rp = _resolve(root, spec)
        got = None
        if name in have and rp:
            got = [t["flash"]["count"] for t in _load_json(rp)["transitions"]
                   if t.get("pair") == "ux->novel"]
        checks.append(_Check("ux->novel flash counts %s" % spec, published, got,
                             got == published))

    # 5. noise-pilot instrument precision
    rp = _canonical_report(root, "noise-pilot") if "noise-pilot" in have else None
    by_pair = collections.defaultdict(list)
    if rp:
        for t in _load_json(rp)["transitions"]:
            by_pair[t.get("pair")].append(t)
    for pair, (pn, psig, pdep, pdsig) in sorted(PUBLISHED_NOISE_PILOT.items()):
        ts = by_pair.get(pair, [])
        gh = [t["ghost"]["rms"] for t in ts if _finite(t["ghost"]["rms"])]
        dp = [t["flash"]["depth"] for t in ts if _finite(t["flash"]["depth"])]
        n, _gm, gsd = _mean_sd(gh)
        _dn, dm, dsd = _mean_sd(dp)
        got = (n, round(gsd, 4), round(dm, 4), round(dsd, 4))
        checks.append(_Check("noise-pilot %s (n, ghost sigma, depth+-sd)" % pair,
                             (pn, psig, pdep, pdsig), got,
                             got == (pn, psig, pdep, pdsig)))

    # 6. soak1's recorded interventions
    p = os.path.join(root, "soak1", "soak-events.json")
    got = None
    if os.path.exists(p):
        got = [(e["event"], e["t"]) for e in _load_json(p)
               if e["event"].startswith("intervention")]
    checks.append(_Check("soak1 recorded interventions",
                         PUBLISHED_SOAK1_INTERVENTIONS, got,
                         got == PUBLISHED_SOAK1_INTERVENTIONS))

    return checks, list(NOT_REPRODUCIBLE)


def format_dataset_audit(checks, register, root=DATASET_DIR):
    out = ["evidence audit -- claims re-checkable from the COMMITTED dataset",
           "  %s" % root, ""]
    out += [c.line() for c in checks]
    bad = [c for c in checks if not c.ok]
    out += ["", "%d/%d reproduced from committed files." % (
        len(checks) - len(bad), len(checks))]
    out += ["", "NOT reproducible from this repo (%d claims):" % len(register)]
    out += ["  - %s\n      [%s]" % (claim, why) for claim, why in register]
    out += ["",
            "  Those need a bundle's capture.mkv (12.28 GB across 19 captures,",
            "  gitignored; sha256 in checksums.txt) and the frame passes above,",
            "  or a bundle that never reached doc/datasets/ at all.",
            "", "Known disagreement:", "  " + SWEEP1_R02_NOTE]
    return "\n".join(out)


# ===========================================================================
# The frame passes. numpy/scipy/ffmpeg + a bundle WITH its capture.mkv.
# ===========================================================================

def _frame_deps():
    """Import the array stack lazily so `dataset` stays stdlib-only."""
    import numpy as np
    import bundle as bundle_mod
    import ingest
    return np, bundle_mod, ingest


# testepub's fiducial square side, as a fraction of the panel's short side.
# The manifest records each marker's CENTRE but not its size, so the probe
# geometry has to come from the card generator -- read from it when importable
# so the two cannot drift.
def _fid_side_frac():
    try:
        import testepub
        return float(getattr(testepub, "FID", 0.045))
    except Exception:
        return 0.045


FID_CORE_FRAC = 0.35   # sample this fraction of the marker side, centred: the
                       # square's ink core, inside the white registration ring
                       # testepub draws around it


def load_frames(bundle_dir, max_fps=None, analysis_scale=None):
    """(frames, fps, manifest, session) for a bundle that has its capture.

    Raises a plain, explicit error when the capture is absent -- which is what
    a checkout of doc/datasets/ hits, and the message says so rather than
    failing somewhere deep in ffmpeg."""
    _np, bundle_mod, ingest = _frame_deps()
    sess = os.path.join(bundle_dir, "session.json")
    cap_name = "capture.mkv"
    if os.path.exists(sess):
        cap_name = _load_json(sess).get("capture", {}).get("file") or cap_name
    if not os.path.exists(os.path.join(bundle_dir, cap_name)):
        raise SystemExit(
            "no %s in %s -- the frame passes need the video.\n"
            "The committed dataset (doc/datasets/2026-07-optics/) is derived "
            "JSON/logs only;\nthe captures are gitignored (sha256 in "
            "checksums.txt). Use `audit.py dataset` for\nwhat a checkout can "
            "re-check." % (cap_name, bundle_dir))
    b = bundle_mod.load_bundle(bundle_dir)
    manifest = b.load_manifest()
    if analysis_scale:
        Wp, Hp = manifest["resolution"]
        manifest = dict(manifest)
        manifest["resolution"] = [max(2, int(Wp * analysis_scale)),
                                  max(2, int(Hp * analysis_scale))]
    frames, fps = ingest.frames_from_video(b.capture_path, max_fps=max_fps,
                                           scale=analysis_scale)
    return frames, fps, manifest, b.session


def _runs_of(mask):
    """[(start, stop)) index runs where `mask` is True."""
    out, start = [], None
    for i, v in enumerate(mask):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(mask)))
    return out


def _page_at(events, t):
    """The card page in effect at capture-relative time t, from a run's event
    list -- so a validity hole can be attributed to a page KIND. The audit's
    v4 lesson turned on exactly this: the hole was the marker-less sync-white
    page, not the blank-KIND card page."""
    cur = None
    for e in events or []:
        if e.get("event") == "page" and e.get("t", 0) <= t:
            cur = e
    return cur


def audit_validity(bundle_dir, max_fps=10.0, analysis_scale=0.5, run_id=None):
    """Pass 1 -- `audit-validity.py`: per-frame fiducial validity accounting.

    The report ran this "at 10 fps/half-res" and concluded "every walk bundle
    holds 96-97% per-frame fiducial validity, the only >=1 s validity holes
    are the sync-flash blocks, and blank-KIND card pages carry fiducials and
    validate fine". So: the valid fraction, and every invalid run long enough
    to matter, attributed to the card page in effect at that time.

    Validity here is exactly ingest's: `detect_fiducials` found four corner
    markers. It is a geometry-PRESENCE flag, not a geometry-CORRECTNESS flag
    -- the whole point of the audit was that a frame can be 'valid' and still
    be sampled through a displaced homography. That is what `perframe` tests.
    """
    np, _bm, ingest = _frame_deps()
    frames, fps, manifest, session = load_frames(bundle_dir, max_fps,
                                                 analysis_scale)
    Wp, Hp = manifest["resolution"]
    _warped, valid, _H = ingest._warp_all(frames, manifest, (Hp, Wp))
    runs = session.get("runs") or []
    run = next((r for r in runs if r.get("run_id") == run_id), None) or \
        (runs[0] if runs else {})
    events = run.get("events") or []

    holes = []
    for a, b in _runs_of(~valid):
        dur = (b - a) / fps
        page = _page_at(events, a / fps)
        holes.append({"t0": round(a / fps, 3), "t1": round(b / fps, 3),
                      "dur_s": round(dur, 3), "n_frames": int(b - a),
                      "page_kind": (page or {}).get("kind"),
                      "page_pid": (page or {}).get("pid")})
    holes.sort(key=lambda h: -h["dur_s"])
    return {
        "pass": "validity", "bundle": os.path.basename(os.path.abspath(bundle_dir)),
        "fps": fps, "n_frames": int(len(frames)),
        "analysis_scale": analysis_scale,
        "n_valid": int(valid.sum()),
        "valid_frac": round(float(valid.mean()), 4),
        "n_holes": len(holes),
        "holes_ge_1s": [h for h in holes if h["dur_s"] >= 1.0],
        "longest_holes": holes[:10],
    }


def _panel_probes(manifest):
    """Panel-space sample boxes for the audit's three dark references, as
    (name, y0, y1, x0, x1) in panel pixels.

      fid:<corner>  the four fiducial squares -- ink by construction, and the
                    audit's geometry self-check ("fiducial squares must be
                    dark" under the frame's OWN fit)
      framing       the page-id barcode's start+stop cells, always ink: the
                    report's "framing cells 0.012-0.024 / 0.006-0.018" readings
      patch:<name>  the static gray-step strip, incl. the black patch armC's
                    graying was read off
    """
    Wp, Hp = manifest["resolution"]
    out = []
    fid = manifest["markers"]["fiducials"]
    # the marker's ink core, inside the white registration ring, so a
    # sub-pixel warp error cannot drag white paper into the box
    half = max(1, int(FID_CORE_FRAC * _fid_side_frac() * min(Wp, Hp)))
    for f in fid:
        cx, cy = int(f["cx"] * Wp), int(f["cy"] * Hp)
        out.append(("fid:" + f["corner"], max(0, cy - half), cy + half,
                    max(0, cx - half), cx + half))
    g = manifest["markers"]["pageid"]
    span = g["w"] / g["cells"]
    y0 = int((g["y"] + 0.25 * g["h"]) * Hp)
    y1 = max(y0 + 1, int((g["y"] + 0.75 * g["h"]) * Hp))
    for i in (0, g["cells"] - 1):
        fx = g["x"] + i * span + span * 0.4
        x0 = int((fx - 0.15 * span) * Wp)
        x1 = max(x0 + 1, int((fx + 0.15 * span) * Wp))
        out.append(("framing:%d" % i, y0, y1, x0, x1))
    for p in manifest["markers"]["patches"]:
        cx = int((p["x"] + p["w"] / 2) * Wp)
        cy = int((p["y"] + p["h"] / 2) * Hp)
        r = max(2, int(0.01 * min(Wp, Hp)))
        out.append(("patch:%s" % p["name"], max(0, cy - r), cy + r,
                    max(0, cx - r), cx + r))
    return out


DARK_MARGIN = 0.25   # how far above the CARD'S OWN rendered ink a fiducial
                     # probe may read and still count as "dark".
                     #
                     # Not an absolute threshold: the card generator draws the
                     # marker's white registration ring and pips with
                     # absolute-pixel constants, so what a correctly-warped
                     # marker box reads depends on the panel resolution (0.003
                     # -0.023 at the card's native 1872x1404; ~0.5 at a
                     # quarter-size synthetic panel, where the ring swamps the
                     # core). Comparing against the intended render at the SAME
                     # resolution removes that dependence -- and it is the same
                     # discipline analyze.py already uses, re-rendering the
                     # card to define every ghost/flash mask.
                     #
                     # 0.25 is the audit's own separation: same-rig crisp
                     # floors 0.001-0.02 against never-b's worst
                     # geometry-verified marks at 0.22-0.38. A genuinely
                     # grayed panel therefore sits right at this gate, which
                     # is why perframe reports fid_excess and not just the
                     # verdict.


def _probe_values(refl, probes):
    return {name: float(refl[y0:y1, x0:x1].mean())
            for (name, y0, y1, x0, x1) in probes}


_EXPECTED_CACHE = {}


def expected_probes(manifest, probes=None):
    """The probe values the CARD ITSELF renders at this manifest's resolution
    -- the reference a measured frame is compared against.

    The fiducial squares and the gray-step strip are identical on every card
    page, so any content page serves; the page-id cells are not, so only the
    fiducial and patch entries are meaningful here (framing cells are gated by
    `decode_pageid`'s framing bits instead)."""
    _np, _bm, _ing = _frame_deps()
    import testepub
    Wp, Hp = manifest["resolution"]
    # Key on the card geometry too, not just the resolution: two manifests at
    # the same panel size but different marker layouts must not share a cache
    # entry (the shared 2026-07 card would, correctly, hit every time).
    key = (Wp, Hp, tuple(sorted((f["corner"], f["cx"], f["cy"])
                                for f in manifest["markers"]["fiducials"])))
    if key in _EXPECTED_CACHE:
        return _EXPECTED_CACHE[key]
    probes = probes if probes is not None else _panel_probes(manifest)
    page = next((p for p in manifest["pages"]
                 if not p["kind"].startswith("sync")), manifest["pages"][0])
    saved = (testepub.W, testepub.H)
    testepub.W, testepub.H = Wp, Hp
    try:
        try:
            img = testepub.render_page(
                testepub.Page(0, page["kind"], page["pid"]))
        except TypeError:                   # a testepub without the pid slot
            img = testepub.render_page(testepub.Page(0, page["kind"]))
    finally:
        testepub.W, testepub.H = saved
    import numpy as np
    ref = np.asarray(img, np.float32) / 255.0
    vals = _probe_values(ref, probes)
    _EXPECTED_CACHE[key] = vals
    return vals


def geometry_selfcheck(frame, H, manifest, probes=None):
    """The audit's trust rule, as one callable: is THIS homography landing the
    card geometry on THIS frame?

    Verified means both halves, exactly as `audit2-perframe.py` framed it:
    every fiducial square reads dark under the warp (the marker ink is where
    the marker ink should be), AND the page-id barcode decodes with its
    framing bits to a pid the manifest contains. Either half alone is
    forgeable -- a warp displaced onto blank paper reads bright but a warp
    onto the bezel reads uniformly dark and satisfies the framing bits with
    all-ones, which is the failure `ingest._warp_all`'s trust rule was built
    against. Both together are what the audit means by "geometry-verified".

    "Dark" is measured against the card's own render at this resolution (see
    DARK_MARGIN), so `fid_excess` -- how far the marker ink sits ABOVE where
    the card put it -- is the graying magnitude the audit reported, and the
    verdict does not depend on the analysis scale.

    Returns a dict; `verified` is the verdict, the rest is why.
    """
    _np, _bm, ingest = _frame_deps()
    Wp, Hp = manifest["resolution"]
    probes = probes if probes is not None else _panel_probes(manifest)
    pid_set = {p["pid"] for p in manifest.get("pages", [])}
    warped = ingest.warp_to_panel(frame, H, (Hp, Wp))
    try:
        refl = ingest.apply_photometry(
            warped, ingest.fit_photometry(warped, manifest))
        pid, framed = ingest.decode_pageid(warped, manifest)
    except Exception as exc:
        return {"verified": False, "error": repr(exc), "pid": None,
                "framed": False, "fid_max": None, "fid_excess": None,
                "framing_max": None, "vals": {}}
    vals = _probe_values(refl, probes)
    exp = expected_probes(manifest, probes)
    fid_keys = [k for k in vals if k.startswith("fid:")]
    fid_max = max(vals[k] for k in fid_keys)
    excess = max(vals[k] - exp[k] for k in fid_keys)
    framing_max = max(v for k, v in vals.items() if k.startswith("framing:"))
    return {"verified": bool(excess <= DARK_MARGIN and framed
                             and (not pid_set or pid in pid_set)),
            "pid": pid, "framed": bool(framed), "fid_max": fid_max,
            "fid_excess": excess, "framing_max": framing_max, "vals": vals}


def audit_perframe(bundle_dir, max_fps=10.0, analysis_scale=0.5, bins=12):
    """Pass 2 -- `audit2-perframe.py`: warp every frame with its OWN fiducial
    fit and self-check the geometry in panel space before reading any cell.

    The report: "a second pass that warps every frame with its OWN fiducial
    fit and self-checks the geometry in panel space (fiducial squares must be
    dark) before reading any cell". The self-check is the whole point -- a
    frame counts as VERIFIED only if, under its own fit, all four fiducial
    squares read dark AND the page-id framing bits decode to a pid the
    manifest contains. Displaced geometry fails both, so a verified frame's
    cell readings are trustworthy in a way a merely-'valid' frame's are not.

    Reported per time bin, because the audit's sharpest per-claim finding was
    a WITHIN-RUN onset ("never-b: early bins verify crisp at 0.013-0.021, bins
    from ~90 s stop verifying, late bins partially recover").

    Also reports the poisoning diagnostic directly: how far the PRODUCTION
    session homography (ingest's fixed-H path, trust rule and all) displaces
    the fiducial corners relative to each frame's own verified fit. That
    displacement, run-wide, is what fabricated the campaign's mid-gray cell
    readings. A session-H that agrees with the verified per-frame fits to
    within a pixel or two is a session-H that did not poison the run.
    """
    np, _bm, ingest = _frame_deps()
    frames, fps, manifest, _session = load_frames(bundle_dir, max_fps,
                                                  analysis_scale)
    Wp, Hp = manifest["resolution"]
    probes = _panel_probes(manifest)
    pid_set = {p["pid"] for p in manifest.get("pages", [])}

    # production session homography, exactly as a report would get it
    _w_fixed, _v_fixed, H_session = ingest._warp_all(frames, manifest, (Hp, Wp))

    nominal = [(f["cx"] * Wp, f["cy"] * Hp)
               for f in manifest["markers"]["fiducials"]]
    per_frame = []
    for i, fr in enumerate(frames):
        fids = ingest.detect_fiducials(fr, manifest)
        if fids is None:
            per_frame.append(None)
            continue
        H = ingest.homography_from_fiducials(fids, manifest)
        chk = geometry_selfcheck(fr, H, manifest, probes)
        if chk.get("error"):
            per_frame.append(None)
            continue
        per_frame.append({"i": i, "t": i / fps, "H": H, "pid": chk["pid"],
                          "framed": chk["framed"], "fid_max": chk["fid_max"],
                          "fid_excess": chk["fid_excess"],
                          "framing": chk["framing_max"], "vals": chk["vals"],
                          "verified": chk["verified"]})

    ver = [p for p in per_frame if p and p["verified"]]
    disp = None
    if H_session is not None and ver:
        H_med = np.median(np.stack([p["H"] for p in ver]), axis=0)
        a = ingest._apply_H(H_session, nominal)
        b = ingest._apply_H(H_med, nominal)
        disp = float(np.max(np.hypot(a[:, 0] - b[:, 0], a[:, 1] - b[:, 1])))

    n = len(frames)
    edges = [int(round(k * n / bins)) for k in range(bins + 1)]
    binned = []
    for k in range(bins):
        lo, hi = edges[k], edges[k + 1]
        sel = [p for p in per_frame[lo:hi] if p and p["verified"]]
        seen = [p for p in per_frame[lo:hi] if p]
        fr_vals = sorted(p["framing"] for p in sel)
        ex_vals = sorted(p["fid_excess"] for p in sel)
        binned.append({
            "t0": round(lo / fps, 2), "t1": round(hi / fps, 2),
            "n_frames": hi - lo, "n_detected": len(seen), "n_verified": len(sel),
            "framing_min": round(fr_vals[0], 4) if fr_vals else None,
            "framing_med": round(fr_vals[len(fr_vals) // 2], 4) if fr_vals else None,
            "framing_max": round(fr_vals[-1], 4) if fr_vals else None,
            "fid_excess_med": round(ex_vals[len(ex_vals) // 2], 4) if ex_vals else None,
            "fid_excess_max": round(ex_vals[-1], 4) if ex_vals else None,
        })
    all_fr = sorted(p["framing"] for p in ver)
    all_ex = sorted(p["fid_excess"] for p in ver)
    return {
        "pass": "perframe",
        "bundle": os.path.basename(os.path.abspath(bundle_dir)),
        "fps": fps, "n_frames": n, "analysis_scale": analysis_scale,
        "n_detected": sum(1 for p in per_frame if p),
        "n_verified": len(ver),
        "verified_frac": round(len(ver) / n, 4) if n else 0.0,
        "framing_min": round(all_fr[0], 4) if all_fr else None,
        "framing_max": round(all_fr[-1], 4) if all_fr else None,
        "fid_excess_max": round(all_ex[-1], 4) if all_ex else None,
        "decode_frac_of_verified": round(
            sum(1 for p in ver if p["pid"] in pid_set) / len(ver), 4) if ver else None,
        "session_h_displacement_px": (round(disp, 2) if disp is not None else None),
        "bins": binned,
    }


def audit_window(bundle_dir, at_s, span_s=2.0, analysis_scale=None,
                 png_dir=None):
    """Pass 3 -- `inspect-window.py`: full-fps frame window around a claimed
    event, with a per-frame table and optional PNGs.

    The report: "30 fps frame-window extraction with per-frame tables and PNGs
    around every claimed event". No fps decimation by default -- these windows
    are how the audit distinguished a whole-panel wash from a partial paint
    ("the static patch strip cycles dark and repaints" at never-a t~109.2), so
    the per-frame structure IS the evidence. Per frame: validity, decoded pid,
    the dark-probe readings, and the panel mean.
    """
    np, _bm, ingest = _frame_deps()
    frames, fps, manifest, _session = load_frames(bundle_dir, None,
                                                  analysis_scale)
    Wp, Hp = manifest["resolution"]
    probes = _panel_probes(manifest)
    lo = max(0, int((at_s - span_s) * fps))
    hi = min(len(frames), int((at_s + span_s) * fps) + 1)
    # The wash frames are precisely the ones whose own fiducials do not detect,
    # so a window that only reads self-fitted frames goes blind exactly where
    # the event is. Fall back to the session homography (the fixed rig's
    # geometry) so every row in the window carries a panel reading, and say
    # which fit produced it.
    _w, _v, H_session = ingest._warp_all(frames[lo:hi], manifest, (Hp, Wp))
    rows = []
    for i in range(lo, hi):
        fids = ingest.detect_fiducials(frames[i], manifest)
        row = {"i": i, "t": round(i / fps, 3), "valid": fids is not None,
               "fit": "own" if fids is not None else "session",
               "cam_mean": round(float(frames[i].mean()), 4)}
        H = (ingest.homography_from_fiducials(fids, manifest)
             if fids is not None else H_session)
        if H is not None:
            warped = ingest.warp_to_panel(frames[i], H, (Hp, Wp))
            try:
                refl = ingest.apply_photometry(
                    warped, ingest.fit_photometry(warped, manifest))
                pid, framed = ingest.decode_pageid(warped, manifest)
                vals = _probe_values(refl, probes)
                # panel_mean and the strip reading are RAW warped intensity,
                # not reflectance: fit_photometry re-fits the gray-step patches
                # per frame, so a whole-panel drive -- which moves the patches
                # too -- normalizes itself away. Reading the wash out of a
                # photometry-corrected frame would hide exactly the event these
                # windows were extracted to look at.
                strip = [warped[y0:y1, x0:x1].mean()
                         for (n, y0, y1, x0, x1) in probes
                         if n.startswith("patch:")]
                row.update({"pid": pid, "framed": bool(framed),
                            "panel_mean": round(float(np.nanmean(warped)), 4),
                            "panel_refl_mean": round(float(np.nanmean(refl)), 4),
                            "strip_raw": round(float(np.mean(strip)), 4),
                            "probes": {k: round(v, 4) for k, v in vals.items()}})
            except Exception as exc:
                row["error"] = repr(exc)
        rows.append(row)
        if png_dir:
            _write_png(png_dir, "f%06d.png" % i, frames[i])
    return {"pass": "window",
            "bundle": os.path.basename(os.path.abspath(bundle_dir)),
            "fps": fps, "at_s": at_s, "span_s": span_s,
            "frames": [lo, hi], "png_dir": png_dir, "rows": rows}


def _write_png(png_dir, name, frame):
    from PIL import Image
    import numpy as np
    os.makedirs(png_dir, exist_ok=True)
    img = (np.clip(frame, 0, 1) * 255).astype("uint8")
    Image.fromarray(img).save(os.path.join(png_dir, name))


def audit_strip(bundle_dir, max_fps=30.0, analysis_scale=0.5, k=8.0):
    """Pass 4 -- the campaign's patch-strip wash detector, rerun.

    Only a GLOBAL refresh redraws the static gray-step strip: it is identical
    on every card page, so a partial page turn's diff-masked update leaves it
    alone (`doc/refresh-policy.md` finding 10). A frame-to-frame excursion in
    the strip region is therefore a global-class drive, whether or not
    KOReader issued one -- which is how the audit counted driver-owned's "~11
    threshold auto-globals ... every ~14.8 s" and armC's unlogged t~90 event.

    The threshold learns the capture's own quiet floor the same way
    ingest.auto_change_eps does (median + k robust sigmas via MAD), so a
    noisier camera raises it instead of needing a hand-tuned constant.

    Reported against the ISSUED refreshes in the run's trace is the next step
    and is NOT done here -- the audit's "unexplained global" verdicts came
    from that join, and analyze.py already owns the trace-to-onset alignment.
    This pass reports event times; attributing them is a separate judgement.
    """
    np, _bm, ingest = _frame_deps()
    frames, fps, manifest, _session = load_frames(bundle_dir, max_fps,
                                                  analysis_scale)
    Wp, Hp = manifest["resolution"]
    # The strip is watched through the SESSION homography, on every frame,
    # valid or not. A global drive is the very thing that makes a frame's own
    # fiducials undetectable -- gate the series on per-frame validity and the
    # detector goes blind at precisely the events it exists to count. The rig
    # is fixed, so the session geometry is the right instrument here (this is
    # ingest._sync_means' reasoning, applied to the strip).
    _warped, _valid, H_session = ingest._warp_all(frames, manifest, (Hp, Wp))
    if H_session is None:
        raise SystemExit("no frame in %s validated: cannot fit a session "
                         "homography, so the strip cannot be watched"
                         % bundle_dir)
    boxes = [b for b in _panel_probes(manifest) if b[0].startswith("patch:")]
    series = []
    for i in range(len(frames)):
        w = ingest.warp_to_panel(frames[i], H_session, (Hp, Wp))
        series.append(float(np.mean([w[y0:y1, x0:x1].mean()
                                     for (_n, y0, y1, x0, x1) in boxes])))
    s = np.asarray(series, float)
    change = np.abs(np.diff(s))
    eps = ingest.auto_change_eps(change, k=k)
    hot = np.nan_to_num(change, nan=0.0) > eps
    events = [{"t": round((a + 1) / fps, 3),
               "dur_s": round((b - a) / fps, 3),
               "peak_change": round(float(np.nanmax(change[a:b])), 4)}
              for a, b in _runs_of(hot)]
    return {"pass": "strip",
            "bundle": os.path.basename(os.path.abspath(bundle_dir)),
            "fps": fps, "n_frames": int(len(frames)), "change_eps": round(eps, 5),
            "n_events": len(events), "events": events}


# ===========================================================================
# CLI
# ===========================================================================

def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="The frame passes need a bundle WITH its capture.mkv; the "
               "committed dataset has none. Start with `dataset`.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("dataset", help="re-check the audit against the "
                                       "COMMITTED dataset (no video needed)")
    d.add_argument("root", nargs="?", default=DATASET_DIR)

    for name, helptext in (("validity", "per-frame fiducial validity"),
                           ("perframe", "own-fit warp + geometry self-check"),
                           ("strip", "patch-strip wash detector")):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("bundle")
        p.add_argument("--max-fps", type=float,
                       default=30.0 if name == "strip" else 10.0)
        p.add_argument("--analysis-scale", type=float, default=0.5)
        p.add_argument("-o", "--out")
        if name == "validity":
            p.add_argument("--run-id")
        if name == "perframe":
            p.add_argument("--bins", type=int, default=12)
        if name == "strip":
            p.add_argument("-k", type=float, default=8.0)

    p = sub.add_parser("window", help="full-fps window around a claimed event")
    p.add_argument("bundle")
    p.add_argument("--at", type=float, required=True, help="event time (s)")
    p.add_argument("--span", type=float, default=2.0)
    p.add_argument("--analysis-scale", type=float, default=None)
    p.add_argument("--png", dest="png_dir", help="also dump frame PNGs here")
    p.add_argument("-o", "--out")

    args = ap.parse_args(argv)

    if args.cmd == "dataset":
        checks, register = audit_dataset(args.root)
        print(format_dataset_audit(checks, register, args.root))
        return 0 if all(c.ok for c in checks) else 1

    if args.cmd == "validity":
        res = audit_validity(args.bundle, args.max_fps, args.analysis_scale,
                             args.run_id)
    elif args.cmd == "perframe":
        res = audit_perframe(args.bundle, args.max_fps, args.analysis_scale,
                             args.bins)
    elif args.cmd == "strip":
        res = audit_strip(args.bundle, args.max_fps, args.analysis_scale, args.k)
    else:
        res = audit_window(args.bundle, args.at, args.span,
                           args.analysis_scale, args.png_dir)

    text = json.dumps(res, indent=2)
    if getattr(args, "out", None):
        with open(args.out, "w") as f:
            f.write(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
