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

# grayscale corruption: DU/A2 washes crush antialiased mid-grays toward binary
# (0/1). We look at pixels the page *intends* to be mid-gray and measure the
# fraction that settled to an extreme (near black or near white). Placeholders,
# like the rest -- recalibrate against real captures.
GRAY_MID_LO = 0.12           # intended reflectance below this is ink/black, not gray
GRAY_MID_HI = 0.85           # intended reflectance at/above this is white, not gray
GRAY_EXTREME_LO = 0.10       # settled below this = crushed to black
GRAY_EXTREME_HI = 0.90       # settled above this = crushed to white
GRAY_CRUSH_NONE = 0.15       # crushed-fraction below this = grays preserved
GRAY_CRUSH_SEVERE = 0.50     # crushed-fraction at/above this = severe binarization

# contrast / uniformity (photometric; read off the gray-step reference patches
# and a should-be-uniform background region -- present on the test card, so
# these run only when the caller supplies the region masks). Placeholders --
# recalibrate against real captures.
CONTRAST_NONE_ABOVE = 0.80   # white-patch minus black-patch at/above this = healthy
CONTRAST_SEVERE_BELOW = 0.50 # at/below this = severely degraded (grayed-out extremes)
BLOTCH_STD_NONE = 0.020      # background reflectance sigma below this = uniform
BLOTCH_STD_SEVERE = 0.060    # at/above this = severe mottling / blotchy clearing


def _severity(value: float, none_below: float, severe_at: float) -> str:
    if value < none_below:
        return "none"
    if value >= severe_at:
        return "severe"
    return "mild"


def _severity_low(value: float, none_above: float, severe_below: float) -> str:
    """Severity for metrics where a LOWER value is worse (e.g. contrast)."""
    if value >= none_above:
        return "none"
    if value <= severe_below:
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
    gray_mask: np.ndarray = None        # pixels that should be mid-gray in `after`
    # Reference-region masks for the photometric contrast/uniformity detectors.
    # These live on the test card (gray-step patch strip + a uniform background),
    # so they are supplied by ingest from the manifest; left None otherwise and
    # the contrast/blotch detectors simply do not run.
    white_patch_mask: np.ndarray = None  # gray-step white reference patch
    black_patch_mask: np.ndarray = None  # gray-step black reference patch
    bg_mask: np.ndarray = None           # a should-be-uniform background region
    expected_settle_s: float = 0.447    # GC16/GL16 at >=24C decode from refresh-policy.md
    window_s: float = 1.5               # how long after t0 to analyze

    def __post_init__(self):
        if self.white_mask is None:
            self.white_mask = self.after >= 0.85
        if self.clean_mask is None:
            # "clean" = should be uniform background (white here); ghosting shows up
            # as prior-page structure leaking into it.
            self.clean_mask = self.after >= 0.85
        if self.gray_mask is None:
            # intended mid-gray content: neither ink/black nor white. This is the
            # antialiased tonal content that a DU/A2 wash would binarize.
            self.gray_mask = (self.after > GRAY_MID_LO) & (self.after < GRAY_MID_HI)


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
    gray_crush_frac: float = 0.0     # fraction of intended mid-grays crushed to 0/1
    gray_severity: str = "none"
    contrast: float = 1.0            # white-patch minus black-patch reflectance
    contrast_severity: str = "none"
    blotch_std: float = 0.0          # reflectance sigma over a uniform background
    blotch_severity: str = "none"
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
        if self.gray_severity != "none":
            out.append(f"gray-corrupt:{self.gray_severity}")
        if self.contrast_severity != "none":
            out.append(f"contrast:{self.contrast_severity}")
        if self.blotch_severity != "none":
            out.append(f"blotch:{self.blotch_severity}")
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


def detect_gray_corruption(settled_frame, after, gray_mask):
    """Grayscale corruption: a DU/A2 wash crushes antialiased mid-grays to binary.

    We take the pixels the page *intends* to be mid-gray (`gray_mask`, from
    `after`) and measure the fraction whose *settled* reflectance landed at an
    extreme (near black or near white) -- i.e. how much of the intended tonal
    content binarized. This is the settled histogram vs. expected-levels test
    reduced to one scalar: a clean grayscale keeps its mid-tones (fraction ~0),
    a binarized one pushes them all to 0/1 (fraction ~1).
    """
    m = gray_mask
    if m is None or int(m.sum()) < 4:
        return {"crush_frac": 0.0, "severity": "none"}
    vals = settled_frame[m]
    crushed = (vals < GRAY_EXTREME_LO) | (vals > GRAY_EXTREME_HI)
    frac = float(np.count_nonzero(crushed) / crushed.size)
    return {"crush_frac": frac,
            "severity": _severity(frac, GRAY_CRUSH_NONE, GRAY_CRUSH_SEVERE)}


def detect_contrast(settled_frame, white_patch_mask, black_patch_mask):
    """Contrast: settled reflectance of the should-be-white reference patch minus
    the should-be-black one (the extremes of the gray-step strip). Full contrast
    is ~1.0; a tired panel whose white reads dim and whose black washes out reads
    low. LOWER is worse, so severity is graded downward."""
    if white_patch_mask is None or black_patch_mask is None:
        return {"contrast": 1.0, "white": 1.0, "black": 0.0, "severity": "none"}
    if white_patch_mask.sum() < 1 or black_patch_mask.sum() < 1:
        return {"contrast": 1.0, "white": 1.0, "black": 0.0, "severity": "none"}
    white_r = float(settled_frame[white_patch_mask].mean())
    black_r = float(settled_frame[black_patch_mask].mean())
    contrast = white_r - black_r
    return {"contrast": contrast, "white": white_r, "black": black_r,
            "severity": _severity_low(contrast, CONTRAST_NONE_ABOVE,
                                      CONTRAST_SEVERE_BELOW)}


def detect_blotch(settled_frame, bg_mask):
    """Blotchy background: standard deviation of settled reflectance over a
    should-be-uniform region. A clean background sits at the camera noise floor;
    mottled / uneven clearing raises it. HIGHER is worse."""
    if bg_mask is None or int(bg_mask.sum()) < 4:
        return {"std": 0.0, "severity": "none"}
    std = float(settled_frame[bg_mask].std())
    return {"std": std, "severity": _severity(std, BLOTCH_STD_NONE, BLOTCH_STD_SEVERE)}


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

    # grayscale corruption (content defect; mask derived from the intended page)
    gc = detect_gray_corruption(settled_frame, tr.after, tr.gray_mask)
    rep.gray_crush_frac, rep.gray_severity = gc["crush_frac"], gc["severity"]

    # contrast / uniformity (photometric; only when the reference regions of the
    # test card are supplied -- e.g. by ingest from the manifest patch geometry)
    c = detect_contrast(settled_frame, tr.white_patch_mask, tr.black_patch_mask)
    rep.contrast, rep.contrast_severity = c["contrast"], c["severity"]
    b = detect_blotch(settled_frame, tr.bg_mask)
    rep.blotch_std, rep.blotch_severity = b["std"], b["severity"]
    return rep
