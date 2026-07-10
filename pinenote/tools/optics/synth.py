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


def _hump(p: np.ndarray, center: float, halfwidth: float) -> np.ndarray:
    """Triangular bump in [0,1], peak 1.0 at `center`, zero outside +-halfwidth."""
    d = np.abs(p - center)
    return np.clip(1.0 - d / halfwidth, 0.0, 1.0)


def simulate_transition(before, after, fps=30.0, pre_frames=3, settle_frames=14,
                        wash="gc16", flash_depth=0.6, ghost_strength=0.0,
                        incomplete=False, double=False, noise=0.0, seed=0):
    """Build a [T,H,W] reflectance clip of one page transition.

    wash: 'gc16' -> white pixels driven dark early then recover (black flash);
          'gl16' -> white-staying pixels never driven; 'none' -> no wash motion.
    ghost_strength: residual of the *previous* page left in clean regions.
    incomplete: content pixels never go quiescent within the window.
    double: two flash dips (the ioctl-races-deferred-io two-pass).
    Returns (clip, t0).
    """
    before = before.astype(np.float32)
    after = after.astype(np.float32)
    white = after >= 0.85
    content = ~white
    post_frames = int(round(fps * 1.5))   # tail so the window has room to settle
    T = pre_frames + settle_frames + post_frames
    clip = np.empty((T, H, W), np.float32)

    # pre: steady 'before'
    for t in range(pre_frames):
        clip[t] = before
    t0 = pre_frames

    ghost = ghost_strength * (1.0 - before)   # darker prior pixels leave more residue
    settled = after.copy()
    settled[white] -= ghost[white]            # ghost shows in the clean/white background
    settled = np.clip(settled, 0.0, 1.0)

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
