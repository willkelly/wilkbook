#!/usr/bin/env python3
"""Validate the reconstructed 2026-07-12 evidence-audit passes (audit.py).

Two halves:

  1. `dataset` -- run the committed-data re-audit against the real
     `doc/datasets/2026-07-optics/` and require every published number back.
     No video, no numpy: this is the part a third party gets from a checkout.

  2. the frame passes -- build a synthetic bundle (panel clip -> synthetic
     camera -> ffv1 mkv -> a real v2 bundle dir) with defects we injected, and
     require validity/perframe/window/strip to report exactly what went in.
     This is the only validation the frame passes have: the 2026-07 captures
     are not in this repo, so they have never been run against the footage the
     audit actually analyzed.

The graphic-page-opener case is the one the issue asked to close, and it does
NOT reproduce the audit's stated mechanism -- see its `note:` lines. Read them
before quoting this suite as confirming the audit.

Run: python3 test_audit.py  (needs numpy + scipy + Pillow; ffmpeg for the
video round-trip, which skips with a message when it is missing).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

import testepub as te
te.W, te.H = 748, 560            # the card's aspect at a fraction of its
                                 # native size: every geometry here is
                                 # fraction-based, so size is free

import audit                                                    # noqa: E402
import bundle as B                                              # noqa: E402
import ingest                                                   # noqa: E402
import synthcam                                                 # noqa: E402

_fails = []

FPS = 30.0
CAM_HW = (1080, 1920)            # camera frame; panel sits small inside it,
INSET = 0.33                     # like the real dark-box rig


def check(name, cond, detail=""):
    print(f"  [{'ok  ' if cond else 'FAIL'}] {name}{('  -- ' + detail) if detail else ''}")
    if not cond:
        _fails.append(name)


def note(text):
    print(f"  [note] {text}")


def page_refl(manifest, kind, pid=0):
    Wp, Hp = manifest["resolution"]
    te.W, te.H = Wp, Hp
    return np.asarray(te.render_page(te.Page(0, kind, pid)), np.float32) / 255.0


# ===========================================================================
# 1. the committed-data re-audit
# ===========================================================================

def case_dataset():
    print("case: `audit.py dataset` reproduces every published number it claims to")
    root = audit.DATASET_DIR
    check("the committed dataset is where audit.py looks for it",
          os.path.isdir(root), root)
    if not os.path.isdir(root):
        return
    checks, register = audit.audit_dataset(root)
    bad = [c for c in checks if not c.ok]
    check("every published-vs-recomputed check reproduces",
          not bad, "%d checks, %d differ%s" % (
              len(checks), len(bad),
              (": " + "; ".join(c.claim for c in bad)) if bad else ""))
    check("the check set is not vacuous", len(checks) >= 40, f"{len(checks)}")

    # The register is the honest half of the output; an empty one would mean
    # the tool was quietly claiming the whole audit reproduces.
    check("the not-reproducible register is populated and reasoned",
          len(register) >= 10 and all(claim and why for claim, why in register),
          f"{len(register)} claims")
    reasons = {why for _c, why in register}
    check("every register reason names a concrete blocker",
          all(("pixel" in r) or ("committed" in r) for r in reasons),
          "; ".join(sorted(reasons)))

    print("case: `dataset` fails loudly when a published number stops reproducing")
    # Mutation: a check that cannot silently pass. Point the tool at a copy of
    # the dataset with one report's n_transitions edited, and require a red.
    with tempfile.TemporaryDirectory() as tmp:
        alt = os.path.join(tmp, "ds")
        shutil.copytree(root, alt)
        rp = os.path.join(alt, "driver-owned", "driver-owned-report.json")
        rep = json.load(open(rp))
        rep["summary"]["n_transitions"] = 41
        with open(rp, "w") as f:
            json.dump(rep, f)
        mchecks, _r = audit.audit_dataset(alt)
        differ = [c for c in mchecks if not c.ok]
        check("a tampered n_transitions is caught, and only that check",
              len(differ) == 1 and differ[0].claim == "seg driver-owned",
              "%d differ: %s" % (len(differ), [c.claim for c in differ]))
        check("the failing line prints published AND recomputed",
              "6" in differ[0].line() and "41" in differ[0].line(),
              differ[0].line().replace("\n", " | ") if differ else "")

    print("case: the register names the audit's load-bearing pixel claims")
    text = "\n".join(c for c, _w in register)
    for needle in ("96-97%", "graphic page 46", "patch-strip"):
        check(f"register mentions {needle!r}", needle in text)


# ===========================================================================
# 2. the frame passes, on synthetic footage with injected defects
# ===========================================================================

def build_panel_clip(manifest):
    """A capture-shaped panel clip with everything the passes must find:

      [0:24)   sync block -- four marker-less black/white fills, 6 frames each
               (0.8 s at 30 fps: a validity hole no content page can produce)
      [24:...) three content pages, one wash frame each
      mid-run  ONE injected global-class drive: every panel pixel, the STATIC
               patch strip included, driven dark and repainted. Only a global
               redraws that strip, which is exactly why the campaign's
               detector watched it.

    Returns (clip, sync_frames, wash_t, page_events)."""
    sync_dwell = 6
    clip = []
    for kind, pid in (("sync_black", 0), ("sync_white", 1),
                      ("sync_black", 2), ("sync_white", 3)):
        clip += [page_refl(manifest, kind, pid)] * sync_dwell
    sync_frames = len(clip)

    events, prev = [], page_refl(manifest, "blank", 4)
    for kind, pid in (("blank", 4), ("novel", 5), ("blank", 11)):
        cur = page_refl(manifest, kind, pid)
        events.append({"t": len(clip) / FPS, "event": "page",
                       "page_index": pid, "pid": pid, "kind": kind})
        clip += [(prev + cur) / 2] + [cur] * 9
        prev = cur

    # the injected global: 3 dark frames then back to the page
    wash_frame = len(clip)
    clip += [prev * 0.15] * 3 + [prev] * 30
    return np.stack(clip), sync_frames, wash_frame / FPS, events


def make_bundle(tmpdir, manifest, clip, events, name="synthbundle"):
    Wp, Hp = manifest["resolution"]
    H_true = synthcam.make_H_panel_to_cam(Wp, Hp, CAM_HW[1], CAM_HW[0],
                                          inset=INSET)
    cam, _ = synthcam.make_camera_clip(clip, H_true, Wp, Hp, CAM_HW)

    video = os.path.join(tmpdir, f"{name}.mkv")
    raw = (np.clip(cam, 0, 1) * 255).astype(np.uint8).tobytes()
    subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "rawvideo",
                    "-pix_fmt", "gray", "-s", f"{CAM_HW[1]}x{CAM_HW[0]}",
                    "-r", str(FPS), "-i", "-", "-c:v", "ffv1", video],
                   input=raw, check=True)
    mpath = os.path.join(tmpdir, f"{name}-manifest.json")
    with open(mpath, "w") as f:
        json.dump(manifest, f)

    session = B.new_session(
        device={"model": "PineNote", "revision": "1.2", "os": "wilkbook",
                "kernel": "7.0.14-pinenote"},
        illuminant_level=255, panel_temp_c=24.0,
        ebc_params={"ebc": {"refresh_waveform": 6}})
    session["capture"]["fps"] = FPS
    B.add_run(session, "r0", events, label="synth", params={"ebc": {}})
    bdir = os.path.join(tmpdir, name)
    B.write_bundle(bdir, session, video, mpath)
    return bdir, H_true, cam


def case_frame_passes(manifest, tmpdir):
    clip, sync_frames, wash_t, events = build_panel_clip(manifest)
    bdir, H_true, cam = make_bundle(tmpdir, manifest, clip, events)

    print("case: `validity` accounts for every frame and lands the hole on sync")
    v = audit.audit_validity(bdir, max_fps=None, analysis_scale=None)
    check("every frame is accounted for as valid or in a hole",
          v["n_valid"] + sum(h["n_frames"] for h in v["longest_holes"]
                             ) <= v["n_frames"]
          and v["n_valid"] <= v["n_frames"], f"{v['n_valid']}/{v['n_frames']}")
    check("content frames validate (the instrument works at all)",
          v["valid_frac"] > 0.5, f"valid_frac={v['valid_frac']}")
    holes = v["longest_holes"]
    sync_end_s = sync_frames / FPS
    # NOT "the sync block is one hole": the white sync fills VALIDATE on this
    # rig -- their corner windows straddle the dark bezel and satisfy the
    # marker checks (the premise test_ingest.py's real-footage fixture pins).
    # So the block reads as alternating short holes, one per BLACK fill. The
    # audit's claim shape: every hole is a marker-less full-panel state --
    # here the sync fills and the injected global -- and never a page turn.
    def _in_sync(h):
        return h["t1"] <= sync_end_s + 1.5 / FPS

    def _at_global(h):
        return abs(h["t0"] - wash_t) < 0.2

    stray = [h for h in holes if not (_in_sync(h) or _at_global(h))]
    check("every validity hole is a sync fill or the injected global drive",
          holes and not stray,
          f"holes {[(h['t0'], h['t1']) for h in holes]} "
          f"(sync ends {sync_end_s:.2f}s, global at {wash_t:.2f}s); "
          f"stray {[(h['t0'], h['t1']) for h in stray]}")
    check("the first hole opens at the start of the sync block",
          holes and min(h["t0"] for h in holes) < 0.1,
          f"earliest hole t0={min((h['t0'] for h in holes), default=None)}")
    turn_ts_all = [e["t"] for e in events if e["t"] > sync_end_s + 0.1]
    check("no validity hole coincides with an ordinary page turn",
          not [h for h in holes
               if any(abs(h["t0"] - t) < 0.2 for t in turn_ts_all)],
          f"turns at {turn_ts_all}")
    # the audit's v4 lesson, restated: blank CARD pages are not the hole
    blank_holes = [h for h in holes if h["page_kind"] == "blank"
                   and h["dur_s"] >= 0.2]
    check("no long hole is attributed to a blank-KIND card page "
          "(the v4 lesson: the hole is the marker-less sync fill)",
          not blank_holes, f"{blank_holes}")

    print("case: `perframe` verifies geometry in panel space before reading cells")
    p = audit.audit_perframe(bdir, max_fps=None, analysis_scale=None, bins=6)
    check("most content frames verify under their own fit",
          p["verified_frac"] > 0.5, f"verified_frac={p['verified_frac']}")
    check("verified frames read the framing cells at the ink floor",
          p["framing_max"] is not None and p["framing_max"] < 0.5,
          f"framing {p['framing_min']}..{p['framing_max']}")
    check("verified frames sit at the card's own marker ink, not above it",
          p["fid_excess_max"] is not None
          and p["fid_excess_max"] <= audit.DARK_MARGIN,
          f"fid_excess_max={p['fid_excess_max']} (margin {audit.DARK_MARGIN})")
    check("every verified frame decodes a manifest pid",
          p["decode_frac_of_verified"] == 1.0,
          f"{p['decode_frac_of_verified']}")
    check("the production session-H agrees with the verified per-frame fits "
          "(this run is NOT poisoned)",
          p["session_h_displacement_px"] is not None
          and p["session_h_displacement_px"] < 3.0,
          f"{p['session_h_displacement_px']} px")
    check("bins cover the clip and carry their own verified counts",
          len(p["bins"]) == 6
          and sum(b["n_frames"] for b in p["bins"]) == p["n_frames"],
          f"{len(p['bins'])} bins, {sum(b['n_frames'] for b in p['bins'])} frames")

    print("case: the geometry self-check REJECTS a displaced homography")
    # The promoted audit2 rule, tested where it matters: a fit that is merely
    # plausible must not be trusted. Displace a good fit by a few percent of
    # the panel and require the self-check to notice -- if it passed, every
    # downstream cell reading would be fabricated, which is the exact defect
    # the audit found in the campaign's reports.
    Wp, Hp = manifest["resolution"]
    good = None
    for i in range(sync_frames, len(cam)):
        f = ingest.detect_fiducials(cam[i], manifest)
        if f is not None:
            good = (i, ingest.homography_from_fiducials(f, manifest))
            break
    check("a content frame yields a fit to displace", good is not None)
    if good:
        i, H_good = good
        ok = audit.geometry_selfcheck(cam[i], H_good, manifest)
        check("the honest fit verifies", ok["verified"],
              f"pid={ok['pid']} fid_excess={ok['fid_excess']:.3f}")
        rejected = []
        for frac in (0.05, 0.10, 0.20):
            shift = np.eye(3)
            shift[0, 2] = frac * Wp          # slide the panel sideways
            bad = audit.geometry_selfcheck(cam[i], H_good @ shift, manifest)
            rejected.append((frac, bad["verified"], bad["pid"],
                             round(bad["fid_excess"], 3)
                             if bad["fid_excess"] is not None else None))
        check("every displaced fit is rejected",
              all(not r[1] for r in rejected), f"{rejected}")

    print("case: `window` extracts a full-fps table around a claimed event")
    w = audit.audit_window(bdir, at_s=wash_t, span_s=0.5)
    n_expect = int(round(2 * 0.5 * FPS)) + 1
    check("the window spans the requested seconds at capture fps",
          abs(len(w["rows"]) - n_expect) <= 2,
          f"{len(w['rows'])} rows (want ~{n_expect}) at {w['fps']} fps")
    check("rows are frame-indexed and time-ordered",
          [r["i"] for r in w["rows"]] == sorted(r["i"] for r in w["rows"])
          and all(w["rows"][k]["t"] < w["rows"][k + 1]["t"]
                  for k in range(len(w["rows"]) - 1)))
    darkest = min((r.get("panel_mean", 1.0) for r in w["rows"]
                   if "panel_mean" in r), default=1.0)
    check("the injected global shows in the window as a panel-wide dip",
          darkest < 0.6, f"min panel_mean={darkest:.3f}")
    strip_rows = [r for r in w["rows"] if "probes" in r]
    check("the per-frame table carries the dark probes the audit read",
          strip_rows and all(any(k.startswith("patch:") for k in r["probes"])
                             and any(k.startswith("framing:") for k in r["probes"])
                             for r in strip_rows),
          f"{len(strip_rows)} rows with probes")

    print("case: `window --png` writes the frames the audit inspected by eye")
    pdir = os.path.join(tmpdir, "pngs")
    audit.audit_window(bdir, at_s=wash_t, span_s=0.1, png_dir=pdir)
    pngs = sorted(os.listdir(pdir)) if os.path.isdir(pdir) else []
    check("PNGs land one per frame in the window", len(pngs) >= 5,
          f"{len(pngs)} files")

    print("case: `strip` fires on the global drive and not on partial turns")
    s = audit.audit_strip(bdir, max_fps=None, analysis_scale=None)
    hits = [e for e in s["events"] if abs(e["t"] - wash_t) < 0.4]
    check("the injected global is detected at its injected time",
          len(hits) >= 1,
          f"events at {[e['t'] for e in s['events']]}, injected {wash_t:.2f}s")
    # Page turns AFTER the sync block: the opening black/white fills are
    # themselves full-panel drives and SHOULD show, and the first page turn
    # sits on the sync boundary, so only the later turns test the claim.
    sync_end_s = sync_frames / FPS
    turn_ts = [e["t"] for e in events if e["t"] > sync_end_s + 0.1]
    check("the fixture leaves later page turns to test against",
          len(turn_ts) >= 2, f"{turn_ts}")
    spurious = [e for e in s["events"]
                if abs(e["t"] - wash_t) >= 0.4 and e["t"] > sync_end_s + 0.1
                and any(abs(e["t"] - t) < 0.4 for t in turn_ts)]
    check("ordinary page turns do NOT move the static patch strip",
          not spurious, f"page turns at {turn_ts}, spurious {spurious}")
    check("the opening sync fills DO move it (they are full-panel drives)",
          any(e["t"] <= sync_end_s for e in s["events"]),
          f"events at {[e['t'] for e in s['events']]}")


def case_graphic_opener(manifest, tmpdir):
    """The coverage gap the issue names: a capture whose OPENING frames are a
    `graphic` card page -- the audit's second, worse poisoning mode.

    The audit's mechanism: "when that page is a `graphic` card page (large
    mid-gray panels), the Otsu panel-quad detection distorts, the session
    homography lands displaced, and every downstream sample ... reads
    fabricated mid-grays for the WHOLE run while the per-frame validity flags
    stay green."

    What this fixture actually shows is the FIRST half only, and the honest
    result is in the `note:` lines below."""
    print("case: a capture that OPENS on a graphic card page (the audit's "
          "second poisoning mode)")
    Wp, Hp = manifest["resolution"]
    graphic = page_refl(manifest, "graphic", 46)
    base, sync_frames, _wash_t, events = build_panel_clip(manifest)
    n_open = 8
    clip = np.concatenate([np.stack([graphic] * n_open), base], axis=0)
    shifted = [dict(e, t=e["t"] + n_open / FPS) for e in events]

    H_true = synthcam.make_H_panel_to_cam(Wp, Hp, CAM_HW[1], CAM_HW[0],
                                          inset=INSET)
    cam, _ = synthcam.make_camera_clip(clip, H_true, Wp, Hp, CAM_HW)

    # Premise: the opener really is the pathological content, not just a page.
    check("fixture premise: the graphic page is majority non-white "
          "(the mid-gray panels the audit blamed)",
          (graphic < 0.6).mean() > 0.5, f"{(graphic < 0.6).mean():.3f} below 0.6")

    # The mechanism the audit named, measured: Otsu thresholds a mid-gray
    # graphic page THROUGH the panel, so the bright region that
    # detect_fiducials takes for "the panel" shatters. These two numbers are
    # the ones quoted in doc/driver-findings-report.md.
    from scipy import ndimage
    thr = ingest._otsu(cam[0])
    lbl, ncomp = ndimage.label(cam[0] > thr)
    sizes = ndimage.sum(np.ones_like(lbl), lbl, index=range(1, ncomp + 1))
    largest = float(sizes.max()) / cam[0].size
    clean = cam[-1]
    tclean = ingest._otsu(clean)
    lblc, ncompc = ndimage.label(clean > tclean)
    sizesc = ndimage.sum(np.ones_like(lblc), lblc, index=range(1, ncompc + 1))
    largestc = float(sizesc.max()) / clean.size
    check("the graphic opener shatters the Otsu panel region, a clean page "
          "does not",
          ncomp >= 3 * ncompc and largest < largestc,
          f"graphic: {ncomp} components, largest {largest:.4f} of frame; "
          f"clean page: {ncompc} components, largest {largestc:.4f}")
    check("the shattered largest component falls under the panel-presence gate",
          largest < 0.04 <= largestc,
          f"{largest:.4f} vs gate 0.04 (clean {largestc:.4f})")

    pid_set = {p["pid"] for p in manifest["pages"]}
    opener = []
    for i in range(n_open):
        f = ingest.detect_fiducials(cam[i], manifest)
        if f is None:
            opener.append(("rejected", None))
            continue
        H = ingest.homography_from_fiducials(f, manifest)
        chk = audit.geometry_selfcheck(cam[i], H, manifest)
        opener.append(("verified" if chk["verified"] else "untrusted",
                       chk["pid"]))
    verdicts = {v for v, _p in opener}
    check("no opening frame produces a DISPLACED-but-trusted fit "
          "(the mode that poisoned the campaign is not reachable here)",
          all(v != "verified" or p == 46 for v, p in opener), f"{opener}")

    # The check above is an implication, and an implication over a set with no
    # "verified" member is VACUOUSLY true -- it would keep passing if this
    # fixture silently stopped producing fits at all.  Pin the regime itself so
    # a change in outcome is a test failure rather than a silent no-op.
    check("the opener fixture stays in the regime this case was written for "
          "(at least one opening frame reaches a verdict, and the assertion "
          "above is therefore not vacuous by accident)",
          len(opener) == n_open and bool(verdicts), f"{opener}")

    note("the opener frames come back %s. That is the ONLY geometry this "
         "fixture exercises (INSET is a module constant, there is no size "
         "sweep), and at it the graphic page is rejected outright by the "
         "panel-presence gate. The correct-decode branch is NOT exercised "
         "here -- do not read this fixture as evidence for it. What it does "
         "establish is that the audit's displaced-but-valid fit was never "
         "produced." % sorted(verdicts))
    note("so this fixture pins the fail-closed half of the mechanism and the "
         "trust rule's protection. The audit's displaced-geometry half is NOT "
         "reproduced offline and rests on the 2026-07 videos alone.")

    print("case: the run still ingests correctly despite the graphic opener")
    _bdir, _H, _cam = None, None, None
    bdir, _Ht, _c = make_bundle(tmpdir, manifest, clip, shifted, "graphic-open")
    p = audit.audit_perframe(bdir, max_fps=None, analysis_scale=None, bins=4)
    check("the session homography still agrees with the verified per-frame fits",
          p["session_h_displacement_px"] is not None
          and p["session_h_displacement_px"] < 3.0,
          f"{p['session_h_displacement_px']} px")
    check("verified frames still read the framing cells at the ink floor",
          p["framing_max"] is not None and p["framing_max"] < 0.5,
          f"framing_max={p['framing_max']}")

    print("case: the frame passes refuse a bundle with no capture (the "
          "committed dataset's shape)")
    nocap = os.path.join(tmpdir, "nocap")
    os.makedirs(nocap, exist_ok=True)
    shutil.copyfile(os.path.join(bdir, "session.json"),
                    os.path.join(nocap, "session.json"))
    try:
        audit.load_frames(nocap)
        check("a capture-less bundle raises", False, "no exception")
    except SystemExit as exc:
        msg = str(exc)
        check("a capture-less bundle raises with an actionable message",
              "audit.py dataset" in msg and "gitignored" in msg, msg[:90])


def main():
    case_dataset()

    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        print("  [skip] ffmpeg not on PATH (run inside guix shell ... ffmpeg)")
        print("\naudit: dataset re-audit ok; frame passes skipped (no ffmpeg)")
        return 1 if _fails else 0

    manifest = te.build_manifest(te.build_pages())
    with tempfile.TemporaryDirectory() as tmp:
        case_frame_passes(manifest, tmp)
        case_graphic_opener(manifest, tmp)

    if _fails:
        print(f"\naudit: {len(_fails)} FAILURES: {_fails}")
        return 1
    print("\naudit: ok -- the committed-data re-audit reproduces, and the "
          "reconstructed frame passes find what was injected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
