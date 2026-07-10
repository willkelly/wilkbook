"""Deterministic e-ink optical-defect detectors (offline analysis core).

This is the *analyze* half of the optics harness (see README.md). It takes a
registered, photometrically-normalized clip of a page transition and classifies
the defects that matter for refresh-policy tuning: black flash, ghosting, slow
settle, and double-flash. It is pure and deterministic -- same clip in, same
report out -- so it can be validated offline on synthetic clips with known
injected defects (test_optics.py) before any real capture exists.

Conventions
-----------
A *clip* is a float32 array of shape [T, H, W] holding panel **reflectance** in
[0, 1], where 0.0 = black and 1.0 = white, already registered to panel space and
normalized against the in-frame white/black reference patches. (The record half
and the ingest step -- homography from the corner fiducials, reflectance
normalization from the patches -- produce this; this module never touches a
camera.)

A *transition* is one page-change event to score, described by `Transition`:
its trigger frame, the intended before/after pages, and the region masks derived
from them (what should be white, what should be a clean/uniform background).

Severity thresholds are module-level constants, deliberately conservative
placeholders to be re-calibrated against the first real multi-panel captures
(that calibration is the whole point of collecting friends' data).
"""

from __future__ import annotations

from dataclasses import dataclass, field
import numpy as np

# --- severity thresholds (reflectance units unless noted); calibrate on real data ---
FLASH_DEPTH_NONE = 0.03      # dip below settled white smaller than this = no flash
FLASH_DEPTH_SEVERE = 0.15    # dip at/above this = severe (GC16-class negative)
GHOST_RMS_NONE = 0.010       # residual RMS in a clean region below this = clean
GHOST_RMS_SEVERE = 0.035
GHOST_CORR_MIN = 0.30        # residual must correlate with the prior page to be "ghost"
SETTLE_EPS = 0.008           # per-frame mean |Δreflectance| below this = quiescent
SETTLE_QUIET_FRAMES = 3      # consecutive quiet frames required to call it settled
SETTLE_ONTIME_FACTOR = 1.3   # settle within expected*factor = on-time


def _severity(value: float, none_below: float, severe_at: float) -> str:
    if value < none_below:
        return "none"
    if value >= severe_at:
        return "severe"
    return "mild"


@dataclass
class Transition:
    """One page-change event to score within a clip."""
    t0: int                       # frame index at which the refresh was triggered
    before: np.ndarray            # intended page BEFORE, reflectance [H, W]
    after: np.ndarray             # intended page AFTER, reflectance [H, W]
    white_mask: np.ndarray = None       # pixels that should be white in `after`
    clean_mask: np.ndarray = None       # pixels that should be a uniform background
    expected_settle_s: float = 0.447    # GC16/GL16 at >=24C decode from refresh-policy.md
    window_s: float = 1.5               # how long after t0 to analyze

    def __post_init__(self):
        if self.white_mask is None:
            self.white_mask = self.after >= 0.85
        if self.clean_mask is None:
            # "clean" = should be uniform background (white here); ghosting shows up
            # as prior-page structure leaking into it.
            self.clean_mask = self.after >= 0.85


@dataclass
class DefectReport:
    flash_depth: float = 0.0
    flash_energy: float = 0.0        # reflectance-seconds
    flash_duration_s: float = 0.0
    flash_severity: str = "none"
    flash_count: int = 0
    ghost_rms: float = 0.0
    ghost_corr: float = 0.0
    ghost_severity: str = "none"
    settle_s: float = 0.0
    settled: bool = True
    settle_severity: str = "none"
    notes: list = field(default_factory=list)

    @property
    def defects(self) -> list:
        out = []
        if self.flash_severity != "none":
            out.append(f"flash:{self.flash_severity}")
        if self.flash_count >= 2:
            out.append(f"double-flash:{self.flash_count}")
        if self.ghost_severity != "none":
            out.append(f"ghost:{self.ghost_severity}")
        if self.settle_severity != "none":
            out.append(f"settle:{self.settle_severity}")
        return out


def _window_frames(clip: np.ndarray, t0: int, fps: float, window_s: float):
    t1 = min(clip.shape[0], t0 + max(1, int(round(window_s * fps))))
    return t0, t1


def _region_means(clip: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """Mean reflectance inside `mask` for every frame -> shape [T]."""
    if mask.sum() == 0:
        return clip.reshape(clip.shape[0], -1).mean(axis=1)
    flat = clip[:, mask]
    return flat.mean(axis=1)


def detect_flash(clip, t0, fps, white_mask, settled_white, window_s):
    """Black flash: should-be-white pixels driven dark during the wash.

    Returns depth (settled_white - min mean reflectance of white region), the
    time-integrated energy of the dip, its duration, and severity.
    """
    a, b = _window_frames(clip, t0, fps, window_s)
    means = _region_means(clip[a:b], white_mask)          # [win]
    dip = np.maximum(0.0, settled_white - means)          # how far below white
    depth = float(dip.max()) if dip.size else 0.0
    energy = float(dip.sum() / fps)                        # reflectance-seconds
    duration = float(np.count_nonzero(dip > FLASH_DEPTH_NONE) / fps)
    return {
        "depth": depth,
        "energy": energy,
        "duration_s": duration,
        "severity": _severity(depth, FLASH_DEPTH_NONE, FLASH_DEPTH_SEVERE),
    }


def count_flashes(clip, t0, fps, white_mask, settled_white, window_s):
    """Count distinct dip events (a page turn should wash once; the
    ioctl-races-deferred-io two-pass shows up as two)."""
    a, b = _window_frames(clip, t0, fps, window_s)
    means = _region_means(clip[a:b], white_mask)
    below = (settled_white - means) > FLASH_DEPTH_SEVERE * 0.5
    # count rising edges of the "below" signal
    count = int(np.count_nonzero(below[1:] & ~below[:-1]))
    if below.size and below[0]:
        count += 1
    return count


def detect_ghost(settled_frame, after, before, clean_mask):
    """Ghosting: prior-page structure remaining in a should-be-uniform region.

    residual = settled - intended, restricted to clean_mask. We report its RMS
    and how strongly it correlates with the previous page's content there -- a
    high RMS that *correlates with `before`* is ghosting (vs. random noise or a
    uniform brightness offset).
    """
    m = clean_mask
    if m.sum() < 4:
        return {"rms": 0.0, "corr": 0.0, "severity": "none"}
    residual = (settled_frame - after)[m]
    residual = residual - residual.mean()                 # ignore uniform offset
    rms = float(np.sqrt(np.mean(residual ** 2)))
    prior = before[m]
    prior = prior - prior.mean()
    denom = np.sqrt(np.sum(residual ** 2) * np.sum(prior ** 2))
    corr = float(np.sum(residual * prior) / denom) if denom > 1e-9 else 0.0
    # Ghost only if the residual is both large AND shaped like the prior page.
    sev = _severity(rms, GHOST_RMS_NONE, GHOST_RMS_SEVERE)
    if sev != "none" and abs(corr) < GHOST_CORR_MIN:
        sev = "none"   # large-but-uncorrelated residual is not ghosting
    return {"rms": rms, "corr": corr, "severity": sev}


def detect_settle(clip, t0, fps, roi_mask, expected_settle_s, window_s):
    """Settle time: when the ROI stops changing after the trigger."""
    a, b = _window_frames(clip, t0, fps, window_s)
    seg = clip[a:b]
    if seg.shape[0] < 2:
        return {"settle_s": 0.0, "settled": True, "severity": "none"}
    diffs = np.abs(np.diff(seg, axis=0))                  # [win-1, H, W]
    if roi_mask.sum() > 0:
        per_frame = diffs[:, roi_mask].mean(axis=1)
    else:
        per_frame = diffs.reshape(diffs.shape[0], -1).mean(axis=1)
    quiet = per_frame < SETTLE_EPS
    settle_frame = None
    run = 0
    for i, q in enumerate(quiet):
        run = run + 1 if q else 0
        if run >= SETTLE_QUIET_FRAMES:
            settle_frame = i - SETTLE_QUIET_FRAMES + 1
            break
    if settle_frame is None:
        return {"settle_s": float(window_s), "settled": False, "severity": "incomplete"}
    settle_s = float(settle_frame / fps)
    if settle_s <= expected_settle_s * SETTLE_ONTIME_FACTOR:
        sev = "none"
    else:
        sev = "slow"
    return {"settle_s": settle_s, "settled": True, "severity": sev}


def classify_transition(clip: np.ndarray, fps: float, tr: Transition) -> DefectReport:
    """Run every detector for one transition and return a structured report."""
    rep = DefectReport()
    # settled white reference: mean of the white region in the last analyzed frame
    a, b = _window_frames(clip, tr.t0, fps, tr.window_s)
    settled_frame = clip[b - 1]
    settled_white = float(settled_frame[tr.white_mask].mean()) if tr.white_mask.sum() else 1.0

    f = detect_flash(clip, tr.t0, fps, tr.white_mask, settled_white, tr.window_s)
    rep.flash_depth, rep.flash_energy = f["depth"], f["energy"]
    rep.flash_duration_s, rep.flash_severity = f["duration_s"], f["severity"]
    rep.flash_count = count_flashes(clip, tr.t0, fps, tr.white_mask, settled_white, tr.window_s)

    g = detect_ghost(settled_frame, tr.after, tr.before, tr.clean_mask)
    rep.ghost_rms, rep.ghost_corr, rep.ghost_severity = g["rms"], g["corr"], g["severity"]

    content = tr.after < 0.85    # analyze settle over changing (content) pixels
    if content.sum() < 4:
        content = np.ones_like(tr.after, dtype=bool)
    s = detect_settle(clip, tr.t0, fps, content, tr.expected_settle_s, tr.window_s)
    rep.settle_s, rep.settled, rep.settle_severity = s["settle_s"], s["settled"], s["severity"]
    return rep
