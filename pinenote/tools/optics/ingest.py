"""Real-video ingest: a camera clip -> the [T,H,W] panel-space reflectance
clips + labelled transitions the detectors consume.

This is the bridge between the two halves of the harness. Given camera frames
of a run of the test card (see testepub.py) and that card's manifest, it:

  1. finds the opening black/white sync flashes (scenario start / clock zero),
  2. per frame, detects the four corner fiducials and solves a homography that
     rectifies the camera view to panel space,
  3. normalizes to reflectance using the in-frame gray-step reference patches
     (per-frame photometric fit -- corrects camera response + lighting),
  4. decodes the page-ID barcode and segments the clip into transitions,
  5. pairs each transition's frames with the intended before/after pages
     (re-rendered from the manifest) as `optics.Transition`s.

Pure numpy + scipy.ndimage; real video is decoded to frames by ffmpeg
(frames_from_video), but the whole pipeline is validated offline on a
synthetic camera (synthcam.py) with no device -- warp+bezel+lighting+noise a
known panel clip, ingest it, and check panel space, reflectance, page IDs, and
end-to-end defect detection all round-trip.
"""
from __future__ import annotations
import json
import subprocess
import numpy as np
from scipy import ndimage

import optics


# --- real-video frame source (ffmpeg) ---------------------------------------

def frames_from_video(path):
    """Decode a real capture to grayscale frames in [0,1]. Returns (frames, fps).
    The rest of the pipeline is array-based and validated on the synthetic
    camera; this is the only piece that touches a real file. Needs ffmpeg."""
    probe = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json",
         "-show_streams", "-select_streams", "v:0", path],
        capture_output=True, text=True, check=True)
    v = json.loads(probe.stdout)["streams"][0]
    W, H = int(v["width"]), int(v["height"])
    num, den = (v.get("avg_frame_rate") or "0/1").split("/")
    fps = (float(num) / float(den)) if float(den) else 0.0
    raw = subprocess.run(
        ["ffmpeg", "-v", "quiet", "-i", path,
         "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        capture_output=True, check=True).stdout
    buf = np.frombuffer(raw, np.uint8)
    n = buf.size // (W * H)
    frames = buf[:n * W * H].reshape(n, H, W).astype(np.float32) / 255.0
    return frames, fps


# --- homography (DLT) -------------------------------------------------------

def homography_dlt(src, dst):
    """H (3x3) with dst ~ H @ [src;1], from >=4 correspondences. src/dst are
    (N,2) arrays of (x,y)."""
    src = np.asarray(src, float)
    dst = np.asarray(dst, float)
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A.append([-x, -y, -1, 0, 0, 0, u * x, u * y, u])
        A.append([0, 0, 0, -x, -y, -1, v * x, v * y, v])
    A = np.asarray(A)
    _, _, Vt = np.linalg.svd(A)
    H = Vt[-1].reshape(3, 3)
    return H / H[2, 2]


def _apply_H(H, xy):
    """Map (N,2) points through H."""
    xy = np.asarray(xy, float)
    pts = np.concatenate([xy, np.ones((len(xy), 1))], axis=1)
    out = pts @ H.T
    return out[:, :2] / out[:, 2:3]


def warp_to_panel(cam_frame, H_panel_to_cam, panel_hw):
    """Rectify a camera frame to panel space [Hp, Wp] by inverse sampling."""
    Hp, Wp = panel_hw
    vv, uu = np.mgrid[0:Hp, 0:Wp]                      # panel (row=v, col=u)
    grid = np.stack([uu.ravel(), vv.ravel()], axis=1).astype(float)
    cam = _apply_H(H_panel_to_cam, grid)              # -> camera (x, y)
    xc = cam[:, 0].reshape(Hp, Wp)
    yc = cam[:, 1].reshape(Hp, Wp)
    out = ndimage.map_coordinates(cam_frame, [yc, xc], order=1, mode="nearest")
    return out.reshape(Hp, Wp)


# --- fiducial detection -----------------------------------------------------

def _otsu(gray):
    hist, edges = np.histogram(gray, bins=64, range=(gray.min(), gray.max() + 1e-6))
    hist = hist.astype(float)
    tot = hist.sum()
    w0 = np.cumsum(hist)
    w1 = tot - w0
    mids = (edges[:-1] + edges[1:]) / 2
    mu0 = np.cumsum(hist * mids) / np.maximum(w0, 1e-9)
    muT = (hist * mids).sum()
    mu1 = (muT - np.cumsum(hist * mids)) / np.maximum(w1, 1e-9)
    var = w0 * w1 * (mu0 - mu1) ** 2
    return mids[np.argmax(var)]


def detect_fiducials(frame, manifest):
    """{corner:(x,y)} camera-pixel centroids of the four corner markers, or
    None if the frame has no clear panel/markers (a pure sync flash, say).

    The frontlit panel is the big bright region against the dark bezel/box; its
    bounding box gives a rough panel->camera affine, and the manifest's known
    fiducial fractions place a search window *on* each marker (clamped to the
    panel so no bezel leaks in). The corners are otherwise white -- content,
    patches and the barcode live inside the margins, not the corners."""
    if frame.max() - frame.min() < 0.2:          # uniform frame (a sync flash)
        return None
    thr = _otsu(frame)
    lbl, n = ndimage.label(frame > thr)
    if n == 0:
        return None
    sizes = ndimage.sum(np.ones_like(lbl), lbl, index=range(1, n + 1))
    if sizes.max() < 0.15 * frame.size:          # no big panel region
        return None
    ys, xs = np.where(lbl == (np.argmax(sizes) + 1))
    # actual panel quad corners (robust to perspective tilt), not a bbox
    s, d = xs + ys, xs - ys
    quad = {"TL": (xs[s.argmin()], ys[s.argmin()]),
            "BR": (xs[s.argmax()], ys[s.argmax()]),
            "TR": (xs[d.argmax()], ys[d.argmax()]),
            "BL": (xs[d.argmin()], ys[d.argmin()])}
    Wp, Hp = manifest["resolution"]
    roughH = homography_dlt([(0, 0), (Wp, 0), (Wp, Hp), (0, Hp)],
                            [quad["TL"], quad["TR"], quad["BR"], quad["BL"]])
    extent = min(xs.max() - xs.min(), ys.max() - ys.min())
    half = max(5, int(0.05 * extent))
    H, W = frame.shape
    out = {}
    for f in manifest["markers"]["fiducials"]:
        ax, ay = _apply_H(roughH, [(f["cx"] * Wp, f["cy"] * Hp)])[0]
        c = int(max(0, ax - half)); dd = int(min(W, ax + half))
        a = int(max(0, ay - half)); b = int(min(H, ay + half))
        sub = frame[a:b, c:dd]
        if sub.size == 0:
            return None
        dmark = sub < (sub.min() + 0.4 * (sub.max() - sub.min()))
        yy, xx = np.where(dmark)
        if not (0.02 * sub.size < len(xx) < 0.7 * sub.size):   # a real marker
            return None
        out[f["corner"]] = (c + xx.mean(), a + yy.mean())
    return out


PANEL_ORDER = ["TL", "TR", "BR", "BL"]   # consistent point ordering


def homography_from_fiducials(cam_fids, manifest):
    """Solve panel->camera H from detected fiducials + manifest fractions."""
    Wp, Hp = manifest["resolution"]
    nominal = {f["corner"]: (f["cx"] * Wp, f["cy"] * Hp)
               for f in manifest["markers"]["fiducials"]}
    src = [nominal[c] for c in PANEL_ORDER]
    dst = [cam_fids[c] for c in PANEL_ORDER]
    return homography_dlt(src, dst)


# --- reflectance normalization ----------------------------------------------

def fit_photometry(panel_intensity, manifest):
    """Fit observed intensity at the gray-step patches to their known
    reflectance. Fit from a STABLE frame (patches un-driven) and hold it fixed
    across a transition: the camera response + lighting are stable over ~0.5 s,
    while the panel is what changes -- fitting per-frame during a wash would use
    the flashing white patch and erase the very flash we measure."""
    Wp, Hp = manifest["resolution"]
    obs, ref = [], []
    for p in manifest["markers"]["patches"]:
        cx = int((p["x"] + p["w"] / 2) * Wp)
        cy = int((p["y"] + p["h"] / 2) * Hp)
        r = max(2, int(0.01 * min(Wp, Hp)))
        patch = panel_intensity[max(0, cy - r):cy + r, max(0, cx - r):cx + r]
        obs.append(float(patch.mean()))
        ref.append(float(p["reflectance"]))
    obs = np.asarray(obs); ref = np.asarray(ref)
    order = np.argsort(obs)
    deg = 2 if len(obs) >= 3 else 1
    return np.polyfit(obs[order], ref[order], deg)


def apply_photometry(panel_intensity, coeffs):
    return np.clip(np.polyval(coeffs, panel_intensity), 0.0, 1.0).astype(np.float32)


# --- page-ID decode ---------------------------------------------------------

def decode_pageid(panel_intensity, manifest):
    """Decode the bottom-margin barcode from a rectified panel frame (raw warped
    intensity; a per-frame patch fit makes the threshold lighting-robust).
    Returns (value, framed_ok). Fails cleanly on wash frames where the barcode
    is mid-transition."""
    Wp, Hp = manifest["resolution"]
    refl = apply_photometry(panel_intensity,
                            fit_photometry(panel_intensity, manifest))
    g = manifest["markers"]["pageid"]
    span = g["w"] / g["cells"]
    y = g["y"] + g["h"] / 2
    bits = []
    for i in range(g["cells"]):
        fx = g["x"] + i * span + span * 0.4
        px, py = int(fx * Wp), int(y * Hp)
        bits.append(1 if refl[py, px] < 0.5 else 0)
    val = 0
    for b in bits[1:-1]:
        val = (val << 1) | b
    return val, (bits[0] == 1 and bits[-1] == 1)


# --- sync + segmentation ----------------------------------------------------

def find_sync(frame_means, lo=0.2, hi=0.8):
    """Index just past the opening black/white sync run (frames that are all
    near-black or near-white). Returns 0 if none detected."""
    end = 0
    for i, m in enumerate(frame_means):
        if m < lo or m > hi:
            end = i + 1
        elif end > 0:
            break
    return end


def _warp_all(frames, manifest, panel_hw):
    """Detect fiducials + rectify (geometry only) every frame to warped panel
    *intensity*. Frames without clear markers (sync flashes) are left NaN and
    flagged invalid. Photometry is applied later, per transition, from a stable
    frame -- see fit_photometry."""
    out = np.full((len(frames),) + panel_hw, np.nan, np.float32)
    valid = np.zeros(len(frames), bool)
    for i, f in enumerate(frames):
        fids = detect_fiducials(f, manifest)
        if fids is None:
            continue
        H = homography_from_fiducials(fids, manifest)
        out[i] = warp_to_panel(f, H, panel_hw)
        valid[i] = True
    return out, valid


def auto_change_eps(change, k=8.0, floor=0.008):
    """Learn the quiet/active split from the capture's OWN frame-to-frame change
    signal, so a noisier camera raises the threshold automatically instead of
    needing a hand-tuned constant (the parameter the README flagged as most
    likely to need field tuning -- now it tunes itself, no human in the loop).

    Page plateaus dominate the timeline (a page dwells far longer than its
    ~0.5 s wash), so the median and MAD are anchored to the quiet noise floor
    even with many washes present -- MAD ignores the wash minority by design.
    The threshold sits `k` robust-sigmas above that floor, with an absolute
    floor so a perfectly noise-free clip (MAD=0) still separates."""
    v = change[np.isfinite(change)]
    if v.size < 3:
        return floor
    med = float(np.median(v))
    sigma = 1.4826 * float(np.median(np.abs(v - med)))   # robust std via MAD
    return med + max(k * sigma, floor)


def segment_transitions(warped, valid, manifest, change_eps=None):
    """Return transitions as (onset, from_pid, to_pid) via change-point
    detection: stable page plateaus are 'quiet' (low frame-to-frame change),
    separated by 'active' washes. The onset is the last quiet frame of the OLD
    page + 1 -- i.e. the wash start, BEFORE the flash. Onset must precede the
    flash: the barcode still reads as the old page during the early wash, so a
    page-ID-change onset would land mid-wash, past the flash.

    change_eps=None (default) auto-calibrates the quiet/active threshold from
    the clip itself (auto_change_eps); pass a float only to override."""
    T = warped.shape[0]
    ids = []
    for i in range(T):
        if not valid[i]:
            ids.append(-1)
            continue
        v, ok = decode_pageid(warped[i], manifest)
        ids.append(v if ok else -1)
    change = np.full(T, np.inf)
    for i in range(1, T):
        if valid[i] and valid[i - 1]:
            change[i] = float(np.mean(np.abs(warped[i] - warped[i - 1])))
    if change_eps is None:
        change_eps = auto_change_eps(change)
    quiet = change < change_eps
    trans = []
    prev_id, prev_idx = None, None
    for i in range(T):
        if valid[i] and quiet[i] and ids[i] >= 0:
            if prev_id is None:
                prev_id, prev_idx = ids[i], i
            elif ids[i] != prev_id:
                trans.append((prev_idx + 1, int(prev_id), int(ids[i])))
                prev_id, prev_idx = ids[i], i
            else:
                prev_idx = i                          # extend the plateau
    return trans, np.asarray(ids)


def ingest(frames, fps, manifest, render_page):
    """Full pipeline. `frames`: list/array of camera grayscale frames in [0,1].
    `render_page(kind)` returns the intended page reflectance [Hp,Wp] (pass
    testepub.render_page composed with the manifest resolution). Returns a list
    of (optics.Transition, clip_segment) ready for optics.classify_transition."""
    Wp, Hp = manifest["resolution"]
    panel_hw = (Hp, Wp)
    means = [float(np.mean(f)) for f in frames]
    sync_end = find_sync(means)                        # reported for clock-zero
    warped, valid = _warp_all(frames, manifest, panel_hw)
    trans, ids = segment_transitions(warped, valid, manifest)
    pages_by_pid = {p["pid"]: p for p in manifest["pages"]}
    results = []
    for (onset, fr, to) in trans:
        if fr not in pages_by_pid or to not in pages_by_pid:
            continue
        # photometry fixed from the last stable pre-wash frame (patches un-driven)
        ref_idx = onset - 1
        while ref_idx > 0 and not valid[ref_idx]:
            ref_idx -= 1
        if not valid[ref_idx]:
            continue
        coeffs = fit_photometry(warped[ref_idx], manifest)
        seg = apply_photometry(warped[onset:], coeffs)   # wash onset -> settle
        before = render_page(pages_by_pid[fr]["kind"])
        after = render_page(pages_by_pid[to]["kind"])
        tr = optics.Transition(t0=0, before=before, after=after)
        results.append((tr, seg, fr, to))
    return results, warped, sync_end
