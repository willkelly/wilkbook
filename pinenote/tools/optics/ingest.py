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

def frames_from_video(path, max_fps=None, scale=None):
    """Decode a real capture to grayscale frames in [0,1]. Returns (frames, fps).
    The rest of the pipeline is array-based and validated on the synthetic
    camera; this is the only piece that touches a real file. Needs ffmpeg.

    max_fps / scale bound MEMORY on real captures: a 3-minute 1080p60 clip is
    ~90 GB as float32 (plus a same-order warped panel array) -- the first real
    bundle OOM-killed the analyzer. fps-decimate and downscale at DECODE time;
    all downstream geometry is fraction-based, so a matching manifest-resolution
    scale (analyze --analysis-scale) keeps everything consistent."""
    probe = subprocess.run(
        ["ffprobe", "-v", "quiet", "-print_format", "json",
         "-show_streams", "-select_streams", "v:0", path],
        capture_output=True, text=True, check=True)
    v = json.loads(probe.stdout)["streams"][0]
    W, H = int(v["width"]), int(v["height"])
    num, den = (v.get("avg_frame_rate") or "0/1").split("/")
    fps = (float(num) / float(den)) if float(den) else 0.0
    filters = []
    if max_fps and fps and max_fps < fps:
        filters.append("fps=%g" % max_fps)
        fps = float(max_fps)
    if scale and scale != 1.0:
        W = max(2, int(W * scale) // 2 * 2)
        H = max(2, int(H * scale) // 2 * 2)
        filters.append("scale=%d:%d" % (W, H))
    cmd = ["ffmpeg", "-v", "quiet", "-i", path]
    if filters:
        cmd += ["-vf", ",".join(filters)]
    cmd += ["-f", "rawvideo", "-pix_fmt", "gray", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
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
    # Panel-presence gate: sized for a real dark-box rig, where the panel can
    # sit well back from the camera (10% of frame on the first Brio rig; the
    # old 15% gate rejected every real frame). The quad corners + per-marker
    # checks below are the real validation -- this only screens out frames
    # with no discernible panel at all (sync flashes, lids, hands).
    if sizes.max() < 0.04 * frame.size:
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
        # Contrast gate: a marker window must actually contain dark ink on
        # white. A noise-flat window otherwise "finds" a marker in pure
        # camera noise: the relative dmark threshold sits ~0.6 sigma below
        # the noise mean, so ~25% of pixels qualify and the 2%-70% fraction
        # check passes. This is a hardening, not the whole story -- a window
        # straddling the panel edge sees the dark bezel and passes any
        # contrast gate, which is why marker-less full-white frames can still
        # validate; find_sync therefore no longer trusts validity alone for
        # its candidate mask (see the uniform-panel candidacy in ingest()).
        if float(sub.max()) - float(sub.min()) < MIN_MARKER_CONTRAST:
            return None
        dmark = sub < (sub.min() + 0.4 * (sub.max() - sub.min()))
        yy, xx = np.where(dmark)
        if not (0.02 * sub.size < len(xx) < 0.7 * sub.size):   # a real marker
            return None
        out[f["corner"]] = (c + xx.mean(), a + yy.mean())
    return out


MIN_MARKER_CONTRAST = 0.15   # a real fiducial window spans near-black ink to
                             # white paper (raw range >~0.5 on the rig); a
                             # markerless window is noise-flat. Gate below this
                             # and the window cannot be a marker.


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

SYNC_MAX_PREAMBLE_S = 240.0   # automated captures film the deep-clean +
                              # KOReader relaunch before sync (~30-60 s);
                              # manual captures should start rolling early
                              # anyway. The >=2-alternations rule is the
                              # real discriminator against false blocks.
SYNC_MAX_GAP_S = 0.75       # tolerated non-extreme stretch INSIDE the block
                            # (the camera catches frames mid-refresh between the
                            # black and white sync pages)

SYNC_SPAN_MIN = 0.45        # candidate-pool brightness span below which the
                            # capture has no black<->white swing to adapt to
SYNC_EDGE_FRAC = 0.08       # adaptive extremes sit this fraction inside the
                            # pool's [q02, q98] range: tight enough that a
                            # GC16 wash's brief mid-dip (grazes ~0.28 raw on
                            # the rig) stays out, loose enough that a sync
                            # plateau at 0.207 raw is caught (see below)


def sync_thresholds(frame_means, candidate=None, lo=0.2, hi=0.8):
    """Adapt the black/white extreme thresholds to THIS capture's own panel
    brightness range, so sync detection does not hinge on absolute constants.

    Why: the sync black/white plateaus are raw camera intensity, and where
    they land drifts with exposure, panel temperature, and MJPG photometry.
    On the 2026-07-11 rig the black sync plateau measured 0.207 -- the fixed
    lo=0.2 missed it by 0.007 and every later report printed sync_end_frame=0
    (cliff.*, neverx3.*, driver-owned), while earlier runs the same night sat
    just under 0.2 and detected fine. The sync extremes are by construction
    the extremes OF THE CAPTURE, so anchor the thresholds there.

    The pool is the CANDIDATE frames (the marker-less ones that may count as
    extremes; pass the same mask find_sync gets). Robust [q02, q98] bounds are
    used, and the fixed lo/hi remain the fallback whenever the pool is too
    small or its span too narrow to be a real black<->white swing."""
    pool = np.asarray(list(frame_means), float)
    if candidate is not None:
        pool = pool[np.asarray(candidate, bool)]
    pool = pool[np.isfinite(pool)]
    if pool.size >= 8:
        mn, mx = float(np.quantile(pool, 0.02)), float(np.quantile(pool, 0.98))
        span = mx - mn
        if span >= SYNC_SPAN_MIN:
            return mn + SYNC_EDGE_FRAC * span, mx - SYNC_EDGE_FRAC * span
    return lo, hi


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
    and therefore validates -- cannot masquerade as a sync white.

    `lo`/`hi` are fallback thresholds only: the working extremes adapt to the
    capture's own candidate-frame brightness range (sync_thresholds), so a
    black plateau at 0.207 raw is still black on a warm panel."""
    means = np.asarray(list(frame_means), float)
    n = means.size
    if n == 0:
        return 0
    lo, hi = sync_thresholds(means, candidate=candidate, lo=lo, hi=hi)
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


SYNC_UNIFORM_STD = 0.05   # panel-region std below this = a UNIFORM panel (a
                          # sync black/white fill). Every card page carries
                          # structure (fiducials, patch strip, barcode, marks:
                          # std >~0.1 raw), while a sync fill's std is the
                          # camera noise floor (<~0.03 on the rig).


def _sync_stats(frames, H_panel_to_cam, panel_hw):
    """Per-frame (mean, std) of brightness over the panel region for
    find_sync. The rig is fixed (one camera, one geometry -- PLAN.md 1a), so
    one homography from any marker-valid frame places the panel for every
    frame, including the marker-less sync flashes themselves. Falls back to
    whole-frame stats when no frame validated (find_sync then still returns 0
    or a best effort; stds are then reported as None -- a whole-frame std
    always includes the bezel and can never read 'uniform')."""
    if H_panel_to_cam is not None:
        mask = _panel_quad_mask(H_panel_to_cam, frames[0].shape, panel_hw)
        if mask.any():
            vals = [f[mask] for f in frames]
            return ([float(v.mean()) for v in vals],
                    [float(v.std()) for v in vals])
    return [float(np.mean(f)) for f in frames], None


def _sync_means(frames, H_panel_to_cam, panel_hw):
    """Back-compat shim: the per-frame panel means only (see _sync_stats)."""
    return _sync_stats(frames, H_panel_to_cam, panel_hw)[0]


def _warp_all(frames, manifest, panel_hw, fixed_h=True):
    """Detect fiducials + rectify (geometry only) every frame to warped panel
    *intensity*. Frames without clear markers (sync flashes) are left NaN and
    flagged invalid. Photometry is applied later, per transition, from a stable
    frame -- see fit_photometry. Also returns the SESSION homography (None if
    no frame validates): on the fixed rig it stands in for the marker-less
    sync frames' geometry (_sync_means).

    fixed_h=True (the default -- PLAN §1a fixed-rig stance): fit ONE session
    homography as the median of the first few valid frames' fits and warp
    every frame with it. Per-frame fits jitter by sub-pixel amounts, which at
    high-contrast content edges (page-number digits, markers) fabricates
    frame-to-frame change that keeps the settle detector's edge-dominated ROI
    "never quiet" (measured live on the 2026-07-11 noise pilot: 22/26 clean
    dwells read settle:incomplete). Fiducial detection still runs per frame
    for the validity flags (sync/wash frames must stay excluded)."""
    out = np.full((len(frames),) + panel_hw, np.nan, np.float32)
    valid = np.zeros(len(frames), bool)
    all_fids = [detect_fiducials(f, manifest) for f in frames]
    H_session = None
    if fixed_h:
        # median-of-fits over the first few valid frames: robust to one bad fit
        Hs = []
        for fids in all_fids:
            if fids is not None:
                Hs.append(homography_from_fiducials(fids, manifest))
            if len(Hs) >= 5:
                break
        if Hs:
            H_session = np.median(np.stack(Hs), axis=0)
    for i, f in enumerate(frames):
        if all_fids[i] is None:
            continue
        H = H_session if H_session is not None else \
            homography_from_fiducials(all_fids[i], manifest)
        out[i] = warp_to_panel(f, H, panel_hw)
        valid[i] = True
    return out, valid, H_session


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


MAX_WINDOW_S = 2.5    # analysis-window cap; below it the window is the segment
                      # gap minus 2 frames, so it can never reach the next wash

RESERVED_DILATE_FRAC = 0.005   # dilation margin around reserved rects (fraction
                               # of each panel dimension), absorbing registration
                               # blur so rect-edge pixels can't leak into masks


def reserved_mask(manifest, panel_hw, margin=RESERVED_DILATE_FRAC):
    """Boolean [Hp,Wp] mask of the card's reserved marker cells.

    manifest['markers']['reserved'] (card v2) lists fractional
    {'x','y','w','h','what'} rects for per-page bookkeeping regions -- the
    human-visible page number and the parity tile -- whose pixels change on
    EVERY page by design. They must be excluded from the should-be-white /
    clean masks, or a page number that turns white on the next page reads as
    digit-shaped ghost. Each rect is dilated by `margin` on every side.
    All-False when the key is absent (older manifests): a no-op consumer."""
    Hp, Wp = panel_hw
    mask = np.zeros((Hp, Wp), bool)
    for r in manifest.get("markers", {}).get("reserved", []) or []:
        x0 = int(np.floor((r["x"] - margin) * Wp))
        x1 = int(np.ceil((r["x"] + r["w"] + margin) * Wp))
        y0 = int(np.floor((r["y"] - margin) * Hp))
        y1 = int(np.ceil((r["y"] + r["h"] + margin) * Hp))
        mask[max(0, y0):min(Hp, y1), max(0, x0):min(Wp, x1)] = True
    return mask


def _render(render_page, kind, pid):
    """Call the caller's page renderer with the (kind, pid) contract, falling
    back to the legacy one-arg (kind) form on TypeError so old adapters keep
    working during integration. pid matters once the card carries pid-varied
    content and per-page markers (PLAN.md card v2): the intended before/after
    must be THAT page's pixels, not a pid-0 stand-in."""
    try:
        return render_page(kind, pid)
    except TypeError:
        return render_page(kind)


def ingest(frames, fps, manifest, render_page):
    """Full pipeline. `frames`: list/array of camera grayscale frames in [0,1].
    `render_page(kind, pid)` returns the intended page reflectance [Hp,Wp]
    (pass testepub.render_page composed with the manifest resolution; a legacy
    one-arg render_page(kind) still works -- see _render). Returns a list of
    (optics.Transition, clip_segment) ready for optics.classify_transition.

    Windowing semantics: each transition's segment is warped[onset:next_onset]
    (the last runs to clip end), so a segment's tail is THIS page's dwell and
    the settled state (optics reads the temporal average of the segment's last
    quiet frames) is never contaminated by the next page's wash. The
    classification window is min(MAX_WINDOW_S, gap - 2 frames), floored at 2
    frames -- the 2-frame guard keeps the window strictly inside the segment
    even when onset detection lands a frame late."""
    Wp, Hp = manifest["resolution"]
    panel_hw = (Hp, Wp)
    warped, valid, H_first = _warp_all(frames, manifest, panel_hw)
    # clock-zero: sync detection reads the PANEL region (fixed-rig session
    # homography) and a frame may count as an extreme when it is marker-less
    # OR its panel region is uniform. ~valid alone proved insufficient on the
    # 2026-07-11 cliff-era captures (sync_end_frame=0 in every later report):
    # the full-white sync pages "validated" -- their corner windows straddle
    # the bezel, and dark bezel pixels satisfy the marker checks -- so exactly
    # the white half of the sync block was excluded and the >=2-alternations
    # rule could never fire. A uniform panel (std at the noise floor) is the
    # structural signature of a sync fill: every real card page carries
    # fiducials/patches/barcode, so this cannot re-admit a bright CONTENT
    # page (the false positive ~valid was introduced to prevent).
    means, stds = _sync_stats(frames, H_first, panel_hw)
    candidate = ~valid
    if stds is not None:
        candidate = candidate | (np.asarray(stds) < SYNC_UNIFORM_STD)
    sync_end = find_sync(means, fps=fps, candidate=candidate)
    trans, ids = segment_transitions(warped, valid, manifest)
    pages_by_pid = {p["pid"]: p for p in manifest["pages"]}
    onsets = [o for (o, _, _) in trans] + [warped.shape[0]]
    rmask = reserved_mask(manifest, panel_hw)     # all-False on older manifests
    results = []
    for k, (onset, fr, to) in enumerate(trans):
        next_onset = onsets[k + 1]
        if fr not in pages_by_pid or to not in pages_by_pid:
            continue
        # photometry fixed from the last stable pre-wash frame (patches un-driven)
        ref_idx = onset - 1
        while ref_idx > 0 and not valid[ref_idx]:
            ref_idx -= 1
        if not valid[ref_idx]:
            continue
        coeffs = fit_photometry(warped[ref_idx], manifest)
        seg = apply_photometry(warped[onset:next_onset], coeffs)  # onset -> dwell end
        gap_s = (next_onset - onset) / fps
        window_s = max(2.0 / fps, min(MAX_WINDOW_S, gap_s - 2.0 / fps))
        before = _render(render_page, pages_by_pid[fr]["kind"], fr)
        after = np.asarray(_render(render_page, pages_by_pid[to]["kind"], to),
                           np.float32)
        # white/clean masks: intended-white pixels MINUS the reserved cells
        # (page number, parity tile) -- those change every page by design and
        # would otherwise read as ghost. Identical to the auto-derived masks
        # when the manifest has no reserved rects.
        white = (after >= 0.85) & ~rmask
        tr = optics.Transition(t0=0, before=before, after=after,
                               white_mask=white, clean_mask=white.copy(),
                               window_s=window_s, onset_frame=int(onset))
        results.append((tr, seg, fr, to))
    return results, warped, sync_end
