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


def adjacent_pair(manifest, a_kind, b_kind):
    """The first adjacent (a_kind, b_kind) pair in the manifest's page sequence
    -> (pid_a, pid_b, next_page_or_None). Dynamic, because the card sequence is
    being restructured concurrently -- no hardcoded pids."""
    pages = manifest["pages"]
    for p, q in zip(pages, pages[1:]):
        if p["kind"] == a_kind and q["kind"] == b_kind:
            nxt = pages[q["index"] + 1] if q["index"] + 1 < len(pages) else None
            return p["pid"], q["pid"], nxt
    raise AssertionError(f"no adjacent {a_kind}->{b_kind} pair in the manifest")


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

    print("case: find_sync -- alternation-block semantics (real-footage bug fix)")
    fps = 30.0
    B, Wt, G = 0.05, 0.95, 0.55                      # black / white / gray mean
    # (a) grayish UI preamble, then 4 sync frames (3 alternations), then content
    means = [G] * 10 + [B, Wt, B, Wt] + [0.6] * 20
    check("preamble + sync block -> sync_end past the block",
          ingest.find_sync(means, fps=fps) == 14,
          f"got {ingest.find_sync(means, fps=fps)} want 14")
    # (b) no sync at all -> 0
    check("no-sync clip -> 0",
          ingest.find_sync([G, 0.6, 0.5, 0.65] * 10, fps=fps) == 0)
    # a single dark flash (no alternation) never qualifies -- the OLD loop
    # returned past it and truncated real pre-sync footage wrongly early
    means = [G] * 5 + [B, B, B] + [0.6] * 20
    check("single flash (0 alternations) -> 0",
          ingest.find_sync(means, fps=fps) == 0)
    # (c) concatenated two-run clip: only the FIRST block is found
    run = [B, Wt, B, Wt]
    means = [G] * 6 + run + [0.6] * 45 + run + [0.6] * 20
    check("two-run clip -> first block only",
          ingest.find_sync(means, fps=fps) == 10,
          f"got {ingest.find_sync(means, fps=fps)} want 10")
    # preamble tolerance: a block starting later than a few seconds is no sync
    means = [G] * 200 + run + [0.6] * 20
    check("block past the preamble window -> 0",
          ingest.find_sync(means, fps=fps) == 0)
    # mid-block gaps: real cameras catch mid-wash grays between the sync pages
    means = [G] * 4 + [B, G, Wt, G, B, G, Wt] + [0.6] * 20
    check("mid-wash gaps inside the block are tolerated",
          ingest.find_sync(means, fps=fps) == 11,
          f"got {ingest.find_sync(means, fps=fps)} want 11")
    # candidate mask: frames marked non-candidate can't count as extremes
    means = [B, Wt, B, Wt] + [0.95] * 3 + [0.6] * 10   # bright CONTENT pages follow
    cand = [True] * 4 + [False] * 13
    check("candidate mask keeps bright content out of the block",
          ingest.find_sync(means, fps=fps, candidate=cand) == 4,
          f"got {ingest.find_sync(means, fps=fps, candidate=cand)} want 4")

    print("case: END-TO-END -- synthetic camera of a page turn -> defect report")
    # dynamic pid lookup: the card sequence is being restructured concurrently,
    # so find the first adjacent novel->blank pair instead of hardcoding pids
    pid_a, pid_b, _ = adjacent_pair(manifest, "novel", "blank")
    before = page_refl("novel", pid=pid_a)
    after = page_refl("blank", pid=pid_b)
    legacy_cam = None
    for wash, expect in (("gc16", "severe"), ("gl16", "none")):
        panel_clip, _ = synth.simulate_transition(
            before, after, fps=20, pre_frames=3, settle_frames=8,
            wash=wash, flash_depth=0.6)
        # prepend sync flashes (markerless -> ingest skips them; 4 flashes = 3
        # alternations, enough for find_sync's block rule)
        sync = np.stack([np.zeros((Hp, Wp), np.float32),
                         np.ones((Hp, Wp), np.float32)] * 2)
        full = np.concatenate([sync, panel_clip], axis=0)
        cam, _ = synthcam.make_camera_clip(full, H_true, Wp, Hp, (Hc, Wc))
        if wash == "gl16":
            legacy_cam = cam
        results, _, sync_end = ingest.ingest(cam, 20.0, manifest,
                                             lambda kind, pid: page_refl(kind, pid))
        check(f"{wash}: sync block found through the camera (panel-region means)",
              sync_end == 4, f"sync_end={sync_end}")
        pair = [(tr, seg) for (tr, seg, fr, to) in results
                if fr == pid_a and to == pid_b]
        check(f"{wash}: novel->blank transition found", len(pair) == 1,
              f"{[(fr, to) for (_, _, fr, to) in results]}")
        if pair:
            tr, seg = pair[0]
            rep = optics.classify_transition(seg, 20.0, tr)
            check(f"{wash}: flash classified '{expect}'", rep.flash_severity == expect,
                  f"depth={rep.flash_depth:.3f} sev={rep.flash_severity}")

    print("case: legacy one-arg render_page(kind) adapters still work (fallback)")
    results, _, _ = ingest.ingest(legacy_cam, 20.0, manifest,
                                  lambda kind: page_refl(kind))
    check("one-arg adapter ingests the same transition",
          [(fr, to) for (_, _, fr, to) in results] == [(pid_a, pid_b)],
          f"{[(fr, to) for (_, _, fr, to) in results]}")

    print("case: reserved cells (page number / parity tile) are excluded from masks")
    import copy
    rect = {"x": 0.25, "y": 0.30, "w": 0.50, "h": 0.35, "what": "pagenum"}
    man_r = copy.deepcopy(manifest)
    man_r["markers"]["reserved"] = [rect]
    rm = ingest.reserved_mask(man_r, (Hp, Wp))
    cy, cx = int((rect["y"] + rect["h"] / 2) * Hp), int((rect["x"] + rect["w"] / 2) * Wp)
    check("reserved mask covers the rect", bool(rm[cy, cx]))
    check("reserved mask stays local",
          not rm[cy, int((rect["x"] + rect["w"] + 0.05) * Wp)])
    check("dilation margin absorbs registration blur",
          bool(rm[cy, int((rect["x"] + rect["w"]) * Wp) + 1]))
    # card v2 always emits reserved rects, so prove the no-op on a stripped
    # copy -- the point is that OLDER manifests (no key) stay behavior-identical
    bare = dict(manifest,
                markers={k: v for k, v in manifest["markers"].items()
                         if k != "reserved"})
    check("no-op when the manifest has no reserved key",
          not ingest.reserved_mask(bare, (Hp, Wp)).any())

    # A region that changes every page (old page-number ink lingering) must
    # not read as ghost when reserved -- and MUST when not (detector intact).
    rect_px = np.zeros((Hp, Wp), bool)
    rect_px[int(rect["y"] * Hp):int((rect["y"] + rect["h"]) * Hp),
            int(rect["x"] * Wp):int((rect["x"] + rect["w"]) * Wp)] = True
    corrupt = synth.residue_field(before, rect_px, strength=0.6)
    clip_r, t0_r = synth.simulate_transition(before, after, fps=20, pre_frames=3,
                                             settle_frames=8, wash="gl16",
                                             blotch_field=corrupt)
    white_excl = (after >= 0.85) & ~rm            # what ingest builds
    tr_excl = optics.Transition(t0=t0_r, before=before, after=after,
                                white_mask=white_excl, clean_mask=white_excl.copy())
    tr_plain = optics.Transition(t0=t0_r, before=before, after=after)
    rep_plain = optics.classify_transition(clip_r, 20.0, tr_plain)
    rep_excl = optics.classify_transition(clip_r, 20.0, tr_excl)
    check("un-reserved: the corrupted cell IS flagged as ghost",
          rep_plain.ghost_severity in ("mild", "severe"),
          f"rms={rep_plain.ghost_rms:.4f} corr={rep_plain.ghost_corr:.2f}")
    check("reserved: the same corruption is NOT ghost",
          rep_excl.ghost_severity == "none", f"rms={rep_excl.ghost_rms:.4f}")

    # and ingest itself applies the exclusion to the masks it builds
    results, _, _ = ingest.ingest(legacy_cam, 20.0, man_r,
                                  lambda kind, pid: page_refl(kind, pid))
    check("reserved-manifest ingest still finds the transition", len(results) == 1)
    if results:
        tr_i = results[0][0]
        check("ingest-built white/clean masks exclude the reserved cell",
              not (tr_i.white_mask & rect_px).any()
              and not (tr_i.clean_mask & rect_px).any())
        check("ingest-built masks keep unreserved white pixels",
              bool(tr_i.white_mask[int(0.5 * Hp), int(0.85 * Wp)]))

    print("case: segment truncation -- a segment ends at the NEXT onset (ME7)")
    # Two back-to-back GC16 turns, 1.2 s apart: A(novel)->B(blank)->C. Without
    # truncation, turn 2's wash lands inside turn 1's old 1.5 s window and the
    # white-region dip double-counts as a second flash; with [onset:next_onset]
    # segments and window = min(2.5, gap - 2 frames) it cannot.
    fps2 = 20.0
    pa, pb, next_pg = adjacent_pair(manifest, "novel", "blank")
    check("manifest has a page after the novel->blank pair", next_pg is not None)
    A = page_refl("novel", pid=pa)
    Bp = page_refl("blank", pid=pb)
    C = page_refl(next_pg["kind"], pid=next_pg["pid"])
    clipAB, _ = synth.simulate_transition(A, Bp, fps=fps2, pre_frames=3,
                                          settle_frames=8, wash="gc16", flash_depth=0.6)
    clipBC, _ = synth.simulate_transition(Bp, C, fps=fps2, pre_frames=3,
                                          settle_frames=8, wash="gc16", flash_depth=0.6)
    dwell = 15                                   # 0.75 s of B before the next turn
    pad = np.repeat(clipBC[-1:], 25, axis=0)     # long final dwell -> window cap case
    sync = np.stack([np.zeros((Hp, Wp), np.float32),
                     np.ones((Hp, Wp), np.float32)] * 2)
    full = np.concatenate([sync, clipAB[:3 + 8 + dwell], clipBC, pad], axis=0)
    # locked-webcam noise: the settle assertion reads the content ROI, whose
    # edge pixels flicker with camera noise -- 0.004 is the locked-rig grade
    # (same level the auto-eps case labels 'a locked webcam')
    cam, _ = synthcam.make_camera_clip(full, H_true, Wp, Hp, (Hc, Wc), noise=0.004)
    results, warped, _ = ingest.ingest(cam, fps2, manifest,
                                       lambda kind, pid: page_refl(kind, pid))
    found = [(fr, to) for (_, _, fr, to) in results]
    check("both turns found", found == [(pa, pb), (pb, next_pg["pid"])], f"{found}")
    if len(results) == 2:
        (tr1, seg1, _, _), (tr2, seg2, _, _) = results
        # segments tile the clip from onset 1: [onset1:onset2] + [onset2:end]
        valid_frames = np.isfinite(warped).all(axis=(1, 2))
        onsets = ingest.segment_transitions(warped, valid_frames, manifest)[0]
        o1, o2 = onsets[0][0], onsets[1][0]
        check("segment 1 truncated at onset 2", seg1.shape[0] == o2 - o1,
              f"len={seg1.shape[0]} gap={o2 - o1}")
        check("segment 2 runs to clip end", seg2.shape[0] == full.shape[0] - o2,
              f"len={seg2.shape[0]}")
        gap1_s = (o2 - o1) / fps2
        check("window 1 = gap - 2 frames (short dwell)",
              np.isclose(tr1.window_s, gap1_s - 2.0 / fps2),
              f"window={tr1.window_s:.3f}s gap={gap1_s:.3f}s")
        check("window 2 capped at 2.5 s (long dwell)", tr2.window_s == 2.5,
              f"window={tr2.window_s:.3f}s seg={seg2.shape[0] / fps2:.2f}s")
        rep1 = optics.classify_transition(seg1, fps2, tr1)
        check("turn 1 sees ONE flash (turn 2's wash is out of its window)",
              rep1.flash_count == 1, f"count={rep1.flash_count}")
        check("turn 1 settles inside its own dwell", rep1.settled,
              f"settle_s={rep1.settle_s:.3f} sev={rep1.settle_severity}")

    print("case: auto change_eps segments across camera noise (no hand-tuning)")
    before = page_refl("novel", pid=pid_a)
    after = page_refl("blank", pid=pid_b)
    panel_clip, _ = synth.simulate_transition(before, after, fps=20, pre_frames=3,
                                              settle_frames=8, wash="gc16", flash_depth=0.6)
    sync = np.stack([np.zeros((Hp, Wp), np.float32), np.ones((Hp, Wp), np.float32)])
    full = np.concatenate([sync, panel_clip], axis=0)
    ok_noise = []
    for nz in (0.004, 0.012, 0.020, 0.030):        # a locked webcam .. a shaky phone
        cam, _ = synthcam.make_camera_clip(full, H_true, Wp, Hp, (Hc, Wc), noise=nz)
        # segmentation must recover the single novel->blank turn with auto eps
        results, _, _ = ingest.ingest(cam, 20.0, manifest,
                                      lambda kind, pid: page_refl(kind, pid))
        found = [(fr, to) for (_, _, fr, to) in results]
        ok_noise.append(found == [(pid_a, pid_b)])
    check("auto-eps recovers the turn at every noise level", all(ok_noise),
          f"{sum(ok_noise)}/4 noise levels")
    # and the learned threshold rises with noise (adapts instead of a fixed 0.04)
    lo_cam, _ = synthcam.make_camera_clip(full, H_true, Wp, Hp, (Hc, Wc), noise=0.004)
    hi_cam, _ = synthcam.make_camera_clip(full, H_true, Wp, Hp, (Hc, Wc), noise=0.030)
    def learned_eps(cam):
        warped, valid, _H = ingest._warp_all(cam, manifest, (Hp, Wp))
        chg = np.full(len(cam), np.inf)
        for i in range(1, len(cam)):
            if valid[i] and valid[i - 1]:
                chg[i] = float(np.mean(np.abs(warped[i] - warped[i - 1])))
        return ingest.auto_change_eps(chg)
    check("learned threshold adapts upward with noise",
          learned_eps(hi_cam) > learned_eps(lo_cam),
          f"lo={learned_eps(lo_cam):.4f} hi={learned_eps(hi_cam):.4f}")

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
