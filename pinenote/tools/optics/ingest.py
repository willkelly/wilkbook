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

SYNC_MAX_PREAMBLE_S = 5.0   # the sync block must BEGIN within this of clip start
SYNC_MAX_GAP_S = 0.75       # tolerated non-extreme stretch INSIDE the block
                            # (the camera catches frames mid-refresh between the
                            # black and white sync pages)


def find_sync(frame_means, lo=0.2, hi=0.8, fps=30.0,
              max_preamble_s=SYNC_MAX_PREAMBLE_S, max_gap_s=SYNC_MAX_GAP_S,
              candidate=None):
    """Index one past the opening black/white sync block; 0 if none.

    The sync block is the initial run of ALTERNATING near-black / near-white
    full-frame extremes, requiring >= 2 alternations (i.e. at least three
    alternating extreme runs, B/W/B) -- so a lone dark frame, a bright UI page,
    or a single content-turn flash can never end the search early (the bug the
    old first-extreme-run loop had on real footage). Non-extreme frames are
    tolerated in exactly two places:

      * as a PREAMBLE before the block (UI frames while the scenario starts),
        but only if the block begins within `max_preamble_s` of the clip start;
      * as short mid-refresh gaps INSIDE the block (up to `max_gap_s`), since a
        real camera catches frames mid-wash between the sync pages.

    The scan stops at the end of the FIRST qualifying block, so a concatenated
    multi-run clip yields only the first run's sync (per-run videos are the
    norm; this keeps the function honest standalone).

    `candidate`, if given, is a per-frame bool array: frames marked False are
    never treated as extremes. ingest() passes the marker-detection validity
    inverted (~valid), so a mostly-white CONTENT page -- which carries fiducials
    and therefore validates -- cannot masquerade as a sync white."""
    means = np.asarray(list(frame_means), float)
    n = means.size
    if n == 0:
        return 0
    state = np.zeros(n, int)                      # -1 black, +1 white, 0 neither
    state[means < lo] = -1
    state[means > hi] = 1
    if candidate is not None:
        state[~np.asarray(candidate, bool)] = 0
    max_pre = int(round(max_preamble_s * fps))
    max_gap = max(1, int(round(max_gap_s * fps)))
    start = 0
    while start < n and start <= max_pre:
        if state[start] == 0:
            start += 1
            continue
        # grow a candidate block from this extreme frame
        alternations = 0
        last_state = state[start]
        last_extreme = start
        j = start + 1
        while j < n and (state[j] != 0 or j - last_extreme <= max_gap):
            if state[j] != 0:
                if state[j] != last_state:
                    alternations += 1
                    last_state = state[j]
                last_extreme = j
            j += 1
        if alternations >= 2:
            return last_extreme + 1               # one past the block's last extreme
        start = max(start + 1, last_extreme + 1)  # skip past the failed block
    return 0


def _panel_quad_mask(H_panel_to_cam, cam_shape, panel_hw, shrink=0.03):
    """Boolean camera-space mask of the (slightly shrunken) panel quad. Used to
    read per-frame brightness over the PANEL, not the whole camera frame: the
    dark bezel/box surround otherwise drags a full-white sync flash down to a
    mid-gray mean and the white half of the sync block goes undetected (the
    real-footage failure PLAN.md ME1 calls out). `shrink` pulls the quad edges
    toward its center so bezel pixels never leak in."""
    Hp, Wp = panel_hw
    Hc, Wc = cam_shape
    corners = np.array([[0, 0], [Wp, 0], [Wp, Hp], [0, Hp]], float)
    center = corners.mean(axis=0)
    corners = center + (1.0 - 2.0 * shrink) * (corners - center)
    quad = _apply_H(H_panel_to_cam, corners)
    qc = quad.mean(axis=0)
    yy, xx = np.mgrid[0:Hc, 0:Wc]
    mask = np.ones((Hc, Wc), bool)
    for k in range(4):                            # convex quad: 4 half-planes
        a, b = quad[k], quad[(k + 1) % 4]
        cross = (b[0] - a[0]) * (yy - a[1]) - (b[1] - a[1]) * (xx - a[0])
        side = (b[0] - a[0]) * (qc[1] - a[1]) - (b[1] - a[1]) * (qc[0] - a[0])
        mask &= (cross * np.sign(side)) >= 0
    return mask


def _sync_means(frames, H_panel_to_cam, panel_hw):
    """Per-frame mean brightness over the panel region for find_sync. The rig
    is fixed (one camera, one geometry -- PLAN.md 1a), so one homography from
    any marker-valid frame places the panel for every frame, including the
    marker-less sync flashes themselves. Falls back to whole-frame means when
    no frame validated (find_sync then still returns 0 or a best effort)."""
    if H_panel_to_cam is None:
        return [float(np.mean(f)) for f in frames]
    mask = _panel_quad_mask(H_panel_to_cam, frames[0].shape, panel_hw)
    if not mask.any():
        return [float(np.mean(f)) for f in frames]
    return [float(f[mask].mean()) for f in frames]


def _warp_all(frames, manifest, panel_hw):
    """Detect fiducials + rectify (geometry only) every frame to warped panel
    *intensity*. Frames without clear markers (sync flashes) are left NaN and
    flagged invalid. Photometry is applied later, per transition, from a stable
    frame -- see fit_photometry. Also returns the first valid frame's
    panel->camera homography (None if no frame validates): on the fixed rig it
    stands in for the marker-less sync frames' geometry (_sync_means)."""
    out = np.full((len(frames),) + panel_hw, np.nan, np.float32)
    valid = np.zeros(len(frames), bool)
    H_first = None
    for i, f in enumerate(frames):
        fids = detect_fiducials(f, manifest)
        if fids is None:
            continue
        H = homography_from_fiducials(fids, manifest)
        if H_first is None:
            H_first = H
        out[i] = warp_to_panel(f, H, panel_hw)
        valid[i] = True
    return out, valid, H_first


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
    warped, valid, H_first = _warp_all(frames, manifest, panel_hw)
    # clock-zero: sync detection reads the PANEL region (fixed-rig homography
    # borrowed from the first marker-valid frame) and only marker-less frames
    # may count as extremes -- a bright content page cannot pass as sync white.
    means = _sync_means(frames, H_first, panel_hw)
    sync_end = find_sync(means, fps=fps, candidate=~valid)
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
