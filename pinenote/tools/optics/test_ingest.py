#!/usr/bin/env python3
"""Offline round-trip validation of real-video ingest, with no device or
camera: forward-warp a known panel clip through a synthetic camera
(perspective + dark bezel + lighting + nonlinear response + noise), ingest it,
and assert homography, reflectance, page-IDs, and end-to-end defect detection
all recover. Run: python3 test_ingest.py  (needs numpy + scipy + Pillow).
"""
import sys
import numpy as np

# small panel keeps the warp fast; ingest works off fractions so size is free
import testepub as te
te.W, te.H = 300, 400

import optics
import synth
import synthcam
import ingest

_fails = []


def check(name, cond, detail=""):
    print(f"  [{'ok  ' if cond else 'FAIL'}] {name}{('  -- ' + detail) if detail else ''}")
    if not cond:
        _fails.append(name)


def page_refl(kind, pid=0):
    return np.asarray(te.render_page(te.Page(0, kind, pid)), np.float32) / 255.0


def main():
    Wp, Hp = te.W, te.H
    manifest = te.build_manifest(te.build_pages())
    Hc, Wc = int(Hp * 1.3), int(Wp * 1.3)
    H_true = synthcam.make_H_panel_to_cam(Wp, Hp, Wc, Hc)

    # one camera frame of a content page
    novel = page_refl("novel", pid=5)
    cam_clip, _ = synthcam.make_camera_clip(novel[None], H_true, Wp, Hp, (Hc, Wc))
    frame = cam_clip[0]

    print("case: fiducial detection locates the corner markers in camera space")
    true_cam = {f["corner"]: ingest._apply_H(H_true, [(f["cx"] * Wp, f["cy"] * Hp)])[0]
                for f in manifest["markers"]["fiducials"]}
    fids = ingest.detect_fiducials(frame, manifest)
    check("four fiducials found", fids is not None and len(fids or {}) == 4)
    if fids:
        errs = [np.hypot(fids[c][0] - true_cam[c][0], fids[c][1] - true_cam[c][1])
                for c in true_cam]
        check("fiducial centroids within tolerance", max(errs) < 0.03 * Wc,
              f"max err {max(errs):.1f}px (tol {0.03 * Wc:.1f})")

    print("case: rectify + reflectance-normalize recovers panel reflectance")
    Hrec = ingest.homography_from_fiducials(fids, manifest)
    warped = ingest.warp_to_panel(frame, Hrec, (Hp, Wp))
    refl = ingest.apply_photometry(warped, ingest.fit_photometry(warped, manifest))
    # independent probes: a white background pixel and a dark content bar
    wc = refl[int(0.5 * Hp), int(0.5 * Wp)]     # mid content: white bg between lines
    # sample many background pixels for robustness
    bg = refl[int(0.2 * Hp):int(0.9 * Hp), int(0.75 * Wp):int(0.9 * Wp)]
    check("recovered white background ~1.0", abs(np.median(bg) - 1.0) < 0.08,
          f"median={np.median(bg):.3f}")
    darkest = refl[int(0.05 * Hp):int(0.95 * Hp), int(0.03 * Wp):int(0.1 * Wp)].min()
    check("recovered black (fiducial) near 0", darkest < 0.15, f"min={darkest:.3f}")

    print("case: page-ID barcode decodes through the camera")
    ok = []
    for pid in (7, 11, 15):
        pg = page_refl("blank", pid=pid)
        cc, _ = synthcam.make_camera_clip(pg[None], H_true, Wp, Hp, (Hc, Wc))
        fr = cc[0]
        f2 = ingest.detect_fiducials(fr, manifest)
        H2 = ingest.homography_from_fiducials(f2, manifest)
        w2 = ingest.warp_to_panel(fr, H2, (Hp, Wp))
        val, framed = ingest.decode_pageid(w2, manifest)
        ok.append(framed and val == pid)
    check("page ids decode through camera", all(ok), f"{sum(ok)}/3")

    print("case: END-TO-END -- synthetic camera of a page turn -> defect report")
    before = page_refl("novel", pid=10)      # sequence: idx10 novel -> idx11 blank
    after = page_refl("blank", pid=11)
    for wash, expect in (("gc16", "severe"), ("gl16", "none")):
        panel_clip, _ = synth.simulate_transition(
            before, after, fps=20, pre_frames=3, settle_frames=8,
            wash=wash, flash_depth=0.6)
        # prepend sync flashes (markerless -> ingest skips them)
        sync = np.stack([np.zeros((Hp, Wp), np.float32),
                         np.ones((Hp, Wp), np.float32)])
        full = np.concatenate([sync, panel_clip], axis=0)
        cam, _ = synthcam.make_camera_clip(full, H_true, Wp, Hp, (Hc, Wc))
        results, _, _ = ingest.ingest(cam, 20.0, manifest,
                                      lambda kind: page_refl(kind))
        pair = [(tr, seg) for (tr, seg, fr, to) in results if fr == 10 and to == 11]
        check(f"{wash}: novel->blank transition found", len(pair) == 1,
              f"{[(fr, to) for (_, _, fr, to) in results]}")
        if pair:
            tr, seg = pair[0]
            rep = optics.classify_transition(seg, 20.0, tr)
            check(f"{wash}: flash classified '{expect}'", rep.flash_severity == expect,
                  f"depth={rep.flash_depth:.3f} sev={rep.flash_severity}")

    print("case: ffmpeg video decode round-trips (the real-capture entry point)")
    import os
    import shutil
    import subprocess
    import tempfile
    if shutil.which("ffmpeg") and shutil.which("ffprobe"):
        gh, gw = 40, 60
        base = np.linspace(0, 1, gh * gw).reshape(gh, gw).astype(np.float32)
        frames_in = np.stack([base, base * 0.5, np.roll(base, 7, axis=1)])
        raw = (np.clip(frames_in, 0, 1) * 255).astype(np.uint8).tobytes()
        with tempfile.TemporaryDirectory() as d:
            vid = os.path.join(d, "t.mkv")
            subprocess.run(["ffmpeg", "-v", "quiet", "-y", "-f", "rawvideo",
                            "-pix_fmt", "gray", "-s", f"{gw}x{gh}", "-r", "10",
                            "-i", "-", "-c:v", "ffv1", vid], input=raw, check=True)
            dec, fps = ingest.frames_from_video(vid)
            check("frame count round-trips", dec.shape[0] == 3, f"{dec.shape}")
            check("pixels round-trip losslessly",
                  float(np.max(np.abs(dec[:3] - frames_in))) < 0.01,
                  f"maxerr={float(np.max(np.abs(dec[:3] - frames_in))):.4f}")
    else:
        print("  [skip] ffmpeg not on PATH (run inside guix shell ... ffmpeg)")

    print()
    if _fails:
        print(f"ingest: {len(_fails)} FAILED: {', '.join(_fails)}")
        return 1
    print("ingest: ok -- camera -> panel -> reflectance -> defects round-trips")
    return 0


if __name__ == "__main__":
    sys.exit(main())
