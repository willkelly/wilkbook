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
                                  # (segment-relative; ingest slices segments at
                                  # the onset, so it passes t0=0)
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
    window_s: float = 1.5               # how long after t0 to analyze; ingest sets
                                        # min(2.5 s, segment gap - 2 frames) so the
                                        # window never reaches the next page's wash
    onset_frame: int = None             # this transition's wash-onset frame in the
                                        # FULL decoded capture (clip-global index;
                                        # ingest sets it). Lets reports place the
                                        # transition on the capture clock, e.g. for
                                        # the [pn-refresh] trace join. None when the
                                        # caller scores a bare clip.

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


# --- shared quiet-scan (settle detector + settled-state estimate) -------------

def segment_change(seg: np.ndarray, roi_mask: np.ndarray) -> np.ndarray:
    """Per frame-pair mean |Δreflectance| over `roi_mask` -> shape [T-1].
    The one change signal both the settle detector and the settled-state
    estimate read, so 'quiet' means the same thing to both."""
    diffs = np.abs(np.diff(seg, axis=0))
    if roi_mask is not None and roi_mask.sum() > 0:
        return diffs[:, roi_mask].mean(axis=1)
    return diffs.reshape(diffs.shape[0], -1).mean(axis=1)


def first_quiet_run(quiet, min_run: int = SETTLE_QUIET_FRAMES):
    """Index opening the first run of `min_run` consecutive quiet frame-pairs,
    or None if the signal never goes quiet for that long."""
    run = 0
    for i, q in enumerate(quiet):
        run = run + 1 if q else 0
        if run >= min_run:
            return i - min_run + 1
    return None


def trailing_quiet_run(quiet):
    """[a, b) frame-index range of the trailing consecutive-quiet frames of a
    segment whose pairwise quiet flags are `quiet` (len T-1 for T frames).
    Frame i joins the run when pair (i-1, i) is quiet; if the final pair is
    active the run degenerates to the last frame alone, [T-1, T)."""
    T = len(quiet) + 1
    j = T - 1
    while j >= 1 and quiet[j - 1]:
        j -= 1
    return j, T


def settled_state(seg: np.ndarray, roi_mask: np.ndarray,
                  eps: float = SETTLE_EPS) -> np.ndarray:
    """The segment's settled state: the temporal AVERAGE of its last
    consecutive quiet frames (a ~sqrt(n) camera-noise win over any single
    frame). Reading the segment END -- not a fixed frame inside the analysis
    window -- is what un-confounds this page's settled state from the next
    page's wash once ingest truncates segments at the next onset."""
    if seg.shape[0] < 2:
        return seg[-1]
    a, b = trailing_quiet_run(segment_change(seg, roi_mask) < eps)
    return seg[a:b].mean(axis=0)


def _finite_window_means(clip, t0, fps, white_mask, window_s):
    """Per-frame mean reflectance of `white_mask` over the analysis window,
    restricted to photometrically VALID frames. Real segments carry whole-NaN
    frames -- ingest leaves a frame NaN when the camera caught it mid-wash with
    no readable fiducials -- and a single NaN frame inside the window used to
    poison the flash depth into NaN (reported as 'mild(nan)': NaN fails both
    severity comparisons). Invalid frames carry no photometric information, so
    they are excluded from the flash metrics; durations/energies are therefore
    lower bounds when the camera lost frames mid-dip."""
    a, b = _window_frames(clip, t0, fps, window_s)
    means = _region_means(clip[a:b], white_mask)
    return means[np.isfinite(means)]


def detect_flash(clip, t0, fps, white_mask, settled_white, window_s):
    """Black flash: should-be-white pixels driven dark during the wash.

    Returns depth (settled_white - min mean reflectance of white region), the
    time-integrated energy of the dip, its duration, and severity. Depth,
    detection (severity), and the flash count all read the SAME mask and the
    same valid frames -- they cannot disagree. Every value returned is finite.
    """
    means = _finite_window_means(clip, t0, fps, white_mask, window_s)
    if means.size == 0 or not np.isfinite(settled_white):
        return {"depth": 0.0, "energy": 0.0, "duration_s": 0.0,
                "severity": "none"}
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
    ioctl-races-deferred-io two-pass shows up as two). Same mask + same
    valid-frame filtering as detect_flash. Dropping the invalid frames also
    stops a single dip interrupted by unreadable mid-wash frames from being
    counted once per fragment (NaN comparisons read as 'above', so the old
    signal had a false rising edge after every NaN gap)."""
    means = _finite_window_means(clip, t0, fps, white_mask, window_s)
    if means.size == 0 or not np.isfinite(settled_white):
        return 0
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
    prior = before[m]
    ok = np.isfinite(residual)                            # judge only measured pixels
    if ok.sum() < 4:
        return {"rms": 0.0, "corr": 0.0, "severity": "none"}
    residual, prior = residual[ok], prior[ok]
    residual = residual - residual.mean()                 # ignore uniform offset
    rms = float(np.sqrt(np.mean(residual ** 2)))
    prior = prior - prior.mean()
    denom = np.sqrt(np.sum(residual ** 2) * np.sum(prior ** 2))
    corr = float(np.sum(residual * prior) / denom) if denom > 1e-9 else 0.0
    # Ghost only if the residual is both large AND shaped like the prior page.
    sev = _severity(rms, GHOST_RMS_NONE, GHOST_RMS_SEVERE)
    if sev != "none" and abs(corr) < GHOST_CORR_MIN:
        sev = "none"   # large-but-uncorrelated residual is not ghosting
    return {"rms": rms, "corr": corr, "severity": sev}


def detect_settle(clip, t0, fps, roi_mask, expected_settle_s, window_s,
                  change=None):
    """Settle time: when the ROI stops changing after the trigger.

    `change`, if given, is the precomputed segment_change(clip[t0:], roi_mask)
    signal (classify_transition computes it once and shares it with the
    settled-state estimate); its windowed prefix is used here."""
    a, b = _window_frames(clip, t0, fps, window_s)
    n = b - a
    if n < 2:
        return {"settle_s": 0.0, "settled": True, "severity": "none"}
    if change is None:
        per_frame = segment_change(clip[a:b], roi_mask)
    else:
        per_frame = np.asarray(change)[:n - 1]            # window starts at t0
    settle_frame = first_quiet_run(per_frame < SETTLE_EPS)
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
    vals = vals[np.isfinite(vals)]                        # measured pixels only
    if vals.size < 4:
        return {"crush_frac": 0.0, "severity": "none"}
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
    white_r = float(np.nanmean(settled_frame[white_patch_mask]))
    black_r = float(np.nanmean(settled_frame[black_patch_mask]))
    if not (np.isfinite(white_r) and np.isfinite(black_r)):
        return {"contrast": 1.0, "white": 1.0, "black": 0.0, "severity": "none"}
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
    vals = settled_frame[bg_mask]
    vals = vals[np.isfinite(vals)]                        # measured pixels only
    if vals.size < 4:
        return {"std": 0.0, "severity": "none"}
    std = float(vals.std())
    return {"std": std, "severity": _severity(std, BLOTCH_STD_NONE, BLOTCH_STD_SEVERE)}


def classify_transition(clip: np.ndarray, fps: float, tr: Transition) -> DefectReport:
    """Run every detector for one transition and return a structured report.

    `clip` is the transition's SEGMENT (ingest slices [onset:next_onset], so
    the segment end is this page's dwell, uncontaminated by the next wash).
    One quiet-scan of the segment is shared by the settle detector and the
    settled-state estimate: the settled state is the temporal average of the
    segment's last consecutive quiet frames (settled_state), and every
    settled-frame consumer (ghost, gray, contrast, blotch, the flash white
    reference) reads that shared average."""
    rep = DefectReport()
    content = tr.after < 0.85    # settle ROI: changing (content) pixels
    if content.sum() < 4:
        content = np.ones_like(tr.after, dtype=bool)

    seg = clip[tr.t0:]
    # Whole-frame validity: ingest leaves a frame NaN when the camera caught
    # it mid-wash with no readable fiducials, so segments legitimately carry
    # all-NaN frames. Every settled-state consumer must read only valid ones.
    finite = np.isfinite(seg.reshape(seg.shape[0], -1)).all(axis=1)
    if seg.shape[0] >= 2:
        change = segment_change(seg, content)             # computed ONCE
        qa, qb = trailing_quiet_run(change < SETTLE_EPS)
        run_finite = finite[qa:qb]
        if run_finite.all():
            settled_frame = seg[qa:qb].mean(axis=0)
        elif run_finite.any():                            # skip the NaN frames
            settled_frame = seg[qa:qb][run_finite].mean(axis=0)
        elif finite.any():                                # last valid frame at all
            settled_frame = seg[np.nonzero(finite)[0][-1]]
        else:
            settled_frame = seg[-1]
            rep.notes.append("segment has no photometrically valid frames")
    else:
        change = None
        settled_frame = seg[-1]
    # FLASH reference = STAYS-WHITE pixels only (white in `before` AND
    # `after`): pixels that were dark content before legitimately pass
    # through dark states while clearing, and reading them as the white
    # region fabricates flash depth (~0.10 on clean partials, measured on
    # the 2026-07-11 rig noise pilot). Ghost/clean semantics keep the
    # after-white mask -- residue is judged where the AFTER page is white.
    #
    # A transition with NO stays-white area (the before page has no white
    # where the after page is white -- e.g. arriving from a full-black page)
    # has no reference region for the flash metric AT ALL: every after-white
    # pixel is legitimately transiting dark states while clearing, so any
    # dip read there is fabricated. Such a transition is NOT classifiable as
    # flash -- detection and depth stay consistent by both not running (the
    # old fallback to the after-white mask made exactly the fabrication the
    # stays-white change was introduced to kill).
    stays_white = tr.white_mask & (tr.before >= 0.85)
    if stays_white.any():
        sw_vals = settled_frame[stays_white]
        sw_vals = sw_vals[np.isfinite(sw_vals)]
        settled_white = float(sw_vals.mean()) if sw_vals.size else float("nan")
        f = detect_flash(clip, tr.t0, fps, stays_white, settled_white, tr.window_s)
        rep.flash_depth, rep.flash_energy = f["depth"], f["energy"]
        rep.flash_duration_s, rep.flash_severity = f["duration_s"], f["severity"]
        rep.flash_count = count_flashes(clip, tr.t0, fps, stays_white,
                                        settled_white, tr.window_s)
    else:
        rep.notes.append("flash: no stays-white area; not classifiable")

    g = detect_ghost(settled_frame, tr.after, tr.before, tr.clean_mask)
    rep.ghost_rms, rep.ghost_corr, rep.ghost_severity = g["rms"], g["corr"], g["severity"]

    s = detect_settle(clip, tr.t0, fps, content, tr.expected_settle_s, tr.window_s,
                      change=change)
    rep.settle_s, rep.settled, rep.settle_severity = s["settle_s"], s["settled"], s["severity"]

    # grayscale corruption (content defect; mask derived from the intended page)
    gc = detect_gray_corruption(settled_frame, tr.after, tr.gray_mask)
    rep.gray_crush_frac, rep.gray_severity = gc["crush_frac"], gc["severity"]

    # contrast / uniformity (photometric; only when the reference regions of the
    # test card are supplied -- e.g. by ingest from the manifest patch geometry)
    c = detect_contrast(settled_frame, tr.white_patch_mask, tr.black_patch_mask)
    rep.contrast, rep.contrast_severity = c["contrast"], c["severity"]
    bl = detect_blotch(settled_frame, tr.bg_mask)
    rep.blotch_std, rep.blotch_severity = bl["std"], bl["severity"]
    return rep
