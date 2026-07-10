"""Synthetic camera: forward-warp a panel reflectance clip into a realistic
camera view (perspective, dark bezel/box surround, gentle frontlight-like
lighting gradient, a nonlinear photometric response, and noise). Ground truth
for validating ingest.py offline -- no device, no real camera.

The lighting gradient is deliberately mild: the harness uses the PineNote's own
frontlight, which is fairly uniform, and the test card's reference patches are
top-only, so a single global photometric fit corrects it. A strong spatial
gradient would need distributed references (a documented future refinement).
"""
from __future__ import annotations
import numpy as np
from scipy import ndimage

import ingest


def make_H_panel_to_cam(Wp, Hp, Wc, Hc, inset=0.13, tilt=0.03):
    """A known homography placing the panel inside a larger camera frame with a
    slight perspective tilt (so ingest must actually rectify, not just crop)."""
    src = [(0, 0), (Wp, 0), (Wp, Hp), (0, Hp)]          # panel corners
    ix, iy = inset * Wc, inset * Hc
    dst = [(ix + tilt * Wc, iy),
           (Wc - ix, iy + tilt * Hc),
           (Wc - ix - tilt * Wc, Hc - iy),
           (ix, Hc - iy - tilt * Hc)]                   # camera targets
    return ingest.homography_dlt(src, dst)


def precompute_map(H_panel_to_cam, Wp, Hp, cam_hw):
    Hc, Wc = cam_hw
    Hinv = np.linalg.inv(H_panel_to_cam)
    yy, xx = np.mgrid[0:Hc, 0:Wc]
    grid = np.stack([xx.ravel(), yy.ravel()], 1).astype(float)
    pan = ingest._apply_H(Hinv, grid)                   # camera -> panel
    up = pan[:, 0].reshape(Hc, Wc)
    vp = pan[:, 1].reshape(Hc, Wc)
    valid = (up >= 0) & (up < Wp) & (vp >= 0) & (vp < Hp)
    # gentle radial lighting field over the camera frame
    cyc, cxc = Hc / 2, Wc / 2
    r2 = ((xx - cxc) ** 2 + (yy - cyc) ** 2) / (cxc ** 2 + cyc ** 2)
    light = (1.0 - 0.12 * r2).astype(float)
    return up, vp, valid, light


def render_camera_frame(panel_img, cmap, Wp, Hp, bezel=0.06, gamma=1.5,
                        gain=0.85, offset=0.05, noise=0.008, seed=0):
    up, vp, valid, light = cmap
    samp = ndimage.map_coordinates(
        panel_img, [np.clip(vp, 0, Hp - 1), np.clip(up, 0, Wp - 1)],
        order=1, mode="nearest")
    refl = np.where(valid, samp, bezel)                 # bezel outside panel
    cam = gain * light * (refl ** gamma) + offset       # camera response
    rng = np.random.default_rng(seed)
    cam = cam + rng.normal(0.0, noise, cam.shape)
    return np.clip(cam, 0.0, 1.0).astype(np.float32)


def make_camera_clip(panel_clip, H_panel_to_cam, Wp, Hp, cam_hw, seed=0, **kw):
    cmap = precompute_map(H_panel_to_cam, Wp, Hp, cam_hw)
    return np.stack([render_camera_frame(panel_clip[i], cmap, Wp, Hp,
                                         seed=seed + i, **kw)
                     for i in range(len(panel_clip))]), cmap
