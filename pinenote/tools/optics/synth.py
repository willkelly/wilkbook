"""Synthetic e-ink transition clips with *known* injected defects.

Ground truth for the detectors in optics.py. Each helper builds a page (or a
[T, H, W] reflectance clip of a transition) whose defect content we control, so
test_optics.py can assert the classifiers report exactly what was injected --
before any real capture hardware exists. No camera, no device.

Reflectance convention matches optics.py: 0.0 = black, 1.0 = white.
"""

from __future__ import annotations
import numpy as np

H, W = 48, 64


def blank_page() -> np.ndarray:
    return np.ones((H, W), np.float32)


def text_page(seed: int = 0) -> np.ndarray:
    """White page with dark 'text' lines (a few rows of near-black bars)."""
    p = np.ones((H, W), np.float32)
    rng = np.random.default_rng(seed)
    for row in range(6, H - 6, 6):
        cols = rng.integers(4, W - 12)
        p[row:row + 2, 4:4 + cols] = 0.08     # ink
    return p


def image_page(level: float = 0.5) -> np.ndarray:
    """A big mid-gray block on white (graphic-novel / figure content)."""
    p = np.ones((H, W), np.float32)
    p[8:H - 8, 10:W - 10] = level
    return p


def gray_ramp_page(lo: float = 0.15, hi: float = 0.85) -> np.ndarray:
    """White page with a block holding a smooth horizontal gray ramp -- the
    antialiased mid-tone content a DU/A2 wash destroys. Every block column is a
    distinct mid-gray between `lo` and `hi`, so binarization is unambiguous."""
    p = np.ones((H, W), np.float32)
    ramp = np.linspace(lo, hi, W - 20, dtype=np.float32)
    p[8:H - 8, 10:W - 10] = ramp[None, :]
    return p


# --- reference-card synth for the contrast/uniformity detectors ---------------
# Fixed geometry: a white and a black reference patch in the top margin plus a
# large should-be-uniform background block. The masks mirror what ingest would
# derive from the test card's gray-step strip + margin geometry.
_WHITE_PATCH = (np.s_[2:6], np.s_[4:16])
_BLACK_PATCH = (np.s_[2:6], np.s_[20:32])
_BG_BLOCK = (np.s_[16:H - 4], np.s_[4:W - 4])


def _ref_masks():
    """Boolean [H,W] masks for the white patch, black patch, and background."""
    wm = np.zeros((H, W), bool); wm[_WHITE_PATCH] = True
    bm = np.zeros((H, W), bool); bm[_BLACK_PATCH] = True
    bg = np.zeros((H, W), bool); bg[_BG_BLOCK] = True
    return wm, bm, bg


def reference_card(white=1.0, black=0.0, bg=1.0) -> np.ndarray:
    """A page carrying the gray-step reference patches (white + black) and a
    uniform background block. `white`/`black`/`bg` set their intended (or, for a
    degraded panel, actual-settled) reflectance."""
    wm, bm, bgm = _ref_masks()
    p = np.ones((H, W), np.float32)
    p[bgm] = bg
    p[wm] = white
    p[bm] = black
    return p


def _blotch_field(seed: int, dark: float = 0.20, frac: float = 0.4,
                  blocks=(6, 8)) -> np.ndarray:
    """A coarse, spatially-correlated darkening field over [H,W] in [-dark, 0]
    (mottle / uneven clearing, *not* white noise): a Bernoulli mask of coarse
    blocks, nearest-upsampled to panel size. Bimodal so its sigma clears the
    'severe' blotch threshold cleanly."""
    rng = np.random.default_rng(seed)
    rb, cb = blocks
    coarse = -dark * (rng.random((rb, cb)) < frac).astype(np.float32)
    ri = (np.arange(H) * rb) // H
    ci = (np.arange(W) * cb) // W
    return coarse[np.ix_(ri, ci)]


def residue_field(before: np.ndarray, region_mask: np.ndarray,
                  strength: float = 0.6) -> np.ndarray:
    """Additive settled-state field carrying the PRIOR page's ink as residue
    inside `region_mask` only -- e.g. a page-number cell whose old digits
    linger while the rest of the page clears. Darker prior pixels leave more
    residue (same shape as simulate_transition's ghost), zero outside the
    region. Feed to simulate_transition(blotch_field=...)."""
    return (-strength * (1.0 - before) * region_mask).astype(np.float32)


def _hump(p: np.ndarray, center: float, halfwidth: float) -> np.ndarray:
    """Triangular bump in [0,1], peak 1.0 at `center`, zero outside +-halfwidth."""
    d = np.abs(p - center)
    return np.clip(1.0 - d / halfwidth, 0.0, 1.0)


def simulate_transition(before, after, fps=30.0, pre_frames=3, settle_frames=14,
                        wash="gc16", flash_depth=0.6, ghost_strength=0.0,
                        incomplete=False, double=False, binarize=False,
                        blotch_field=None, noise=0.0, seed=0):
    """Build a [T,H,W] reflectance clip of one page transition.

    wash: 'gc16' -> white pixels driven dark early then recover (black flash);
          'gl16' -> white-staying pixels never driven; 'none' -> no wash motion.
    ghost_strength: residual of the *previous* page left in clean regions.
    incomplete: content pixels never go quiescent within the window.
    double: two flash dips (the ioctl-races-deferred-io two-pass).
    binarize: the settled state snaps mid-grays to 0/1 (a DU/A2 1-bit wash),
              so intended tonal content ends up crushed to black or white.
    blotch_field: an additive [H,W] field applied to the settled state (use a
              coarse, spatially-correlated field for a mottled background).
    Returns (clip, t0).
    """
    before = before.astype(np.float32)
    after = after.astype(np.float32)
    hh, ww = before.shape                  # size from the pages, not module dims
    white = after >= 0.85
    content = ~white
    post_frames = int(round(fps * 1.5))   # tail so the window has room to settle
    T = pre_frames + settle_frames + post_frames
    clip = np.empty((T, hh, ww), np.float32)

    # pre: steady 'before'
    for t in range(pre_frames):
        clip[t] = before
    t0 = pre_frames

    ghost = ghost_strength * (1.0 - before)   # darker prior pixels leave more residue
    settled = after.copy()
    settled[white] -= ghost[white]            # ghost shows in the clean/white background
    settled = np.clip(settled, 0.0, 1.0)
    if binarize:
        # DU/A2 renders 1-bit: everything settles to black or white at a 0.5 cut,
        # so intended mid-grays are destroyed while true black/white are unmoved.
        settled = np.where(settled >= 0.5, 1.0, 0.0).astype(np.float32)
    if blotch_field is not None:
        settled = np.clip(settled + blotch_field, 0.0, 1.0).astype(np.float32)

    for k in range(settle_frames):
        p = (k + 1) / settle_frames
        frame = before + p * (after - before)          # linear content settle
        if wash in ("gc16",):
            if double:
                # two well-separated dips (white recovers between them)
                bump = np.maximum(_hump(np.array(p), 0.18, 0.10),
                                  _hump(np.array(p), 0.55, 0.10))
            else:
                bump = _hump(np.array(p), 0.25, 0.22)
            frame = frame.copy()
            frame[white] = 1.0 - flash_depth * float(bump)   # drive white dark, recover
        elif wash == "gl16":
            frame = frame.copy()
            frame[white] = 1.0                                # white never driven
        # content pixels reach `after` at p=1 in every wash
        clip[t0 + k] = frame

    # post: steady 'settled' (with ghost), unless 'incomplete'
    rng = np.random.default_rng(seed + 1)
    for j in range(post_frames):
        t = t0 + settle_frames + j
        if incomplete:
            # never quiescent: content keeps oscillating (e.g. a driver that
            # never stops re-driving), so it never reaches 3 quiet frames.
            f = settled.copy()
            f[content] = np.clip(settled[content] + 0.03 * (1 if j % 2 else -1),
                                 0.0, 1.0)
            clip[t] = f
        else:
            clip[t] = settled

    if noise > 0:
        clip = clip + rng.normal(0.0, noise, clip.shape).astype(np.float32)
    return np.clip(clip, 0.0, 1.0), t0


# --- higher-level scenario builders for the new detectors ---------------------
# Each returns (clip, t0, before, after, tr_kwargs): `after` is the *intended*
# page (what optics.Transition scores against) and tr_kwargs carries any extra
# region masks the detector needs. The clip may settle to something *other* than
# `after` -- that gap is exactly the injected defect.

def grayscale_transition(binarized=False, fps=30.0, seed=0):
    """Gray-ramp page transition. `binarized` -> the ramp settles to 1-bit
    (grayscale corruption); otherwise mid-tones are preserved (clean control).
    The gray_mask is auto-derived from `after`, so tr_kwargs is empty."""
    before = blank_page()
    after = gray_ramp_page()
    clip, t0 = simulate_transition(before, after, fps=fps, wash="none",
                                   binarize=binarized, seed=seed)
    return clip, t0, before, after, {}


def contrast_transition(degraded=False, fps=30.0, seed=0):
    """Reference-card transition read for contrast. Intended `after` is full
    black/white; `degraded` -> the clip settles to a dim white patch and a
    washed-out black patch (low contrast). Clean control settles to full
    contrast."""
    wm, bm, _ = _ref_masks()
    before = blank_page()
    after = reference_card(white=1.0, black=0.0)            # intended: full contrast
    settled = reference_card(white=0.66, black=0.30) if degraded else after
    clip, t0 = simulate_transition(before, settled, fps=fps, wash="none", seed=seed)
    return clip, t0, before, after, {"white_patch_mask": wm, "black_patch_mask": bm}


def blotch_transition(blotchy=False, fps=30.0, seed=0):
    """Reference-card transition read for background uniformity. `blotchy` ->
    the should-be-white background settles mottled (spatially-correlated
    darkening); otherwise it settles uniform (clean control)."""
    _, _, bgm = _ref_masks()
    before = blank_page()
    after = reference_card(white=1.0, black=0.0, bg=1.0)    # intended: uniform white bg
    field = _blotch_field(seed + 3) * bgm if blotchy else None
    clip, t0 = simulate_transition(before, after, fps=fps, wash="none",
                                   blotch_field=field, seed=seed)
    return clip, t0, before, after, {"bg_mask": bgm}
