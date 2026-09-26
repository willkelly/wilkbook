--[[--
Notebook tunables: the input, panel and storage thresholds, in one place.
The brush geometry (each brush's radii, the S/M/L multipliers and the
eraser's radii) lives in nb_brush.lua, beside the rasterizer that draws
it, because every stroke records it.

Units: px are physical panel pixels (1872x1404 landscape-native, 227 dpi,
the framebuffer's own space); us are microseconds; pressure values are the
w9013 digitizer's raw 0..4095.  Values marked "tune on glass" are guesses
from the 2026-09-26 captures (doc/artifacts/pinenote-du-canvas-feel-20260926/).
Nothing here is read from settings: the plugin keeps the choices a user
made on the panel (brush, size, mode, rubber) in
/data/notebooks/prefs.json, and these defaults are code.
--]]

return {
    -- Physical panel geometry; the plugin overwrites W/H from Screen.bb.w/h.
    W = 1872,
    H = 1404,
    dpi = 227,

    -- Digitizer axis ranges; the plugin overwrites them from EVIOCGABS.
    abs_x_max = 20966,
    abs_y_max = 15725,
    abs_p_max = 4095,

    -- Pressure windows (raw units).  Pen: 9.9 % of contact reports saturate
    -- at 4095 and the median is ~2716; the rubber end reports ~180-880.
    pen_p_lo = 100,
    pen_p_hi = 4095,
    rubber_p_lo = 180,
    rubber_p_hi = 880,

    -- Palm rejection: a touch contact that starts while the pen is in range,
    -- or within this long after it left, is dropped whole (tune on glass).
    palm_grace_us = 500000,
    -- The pen counts as gone only after this long out of range: the
    -- digitizer drops proximity for 22-44 ms at the panel's Y=0 edge and in
    -- hover flicker (the 2026-09-26 captures), and a leave runs the fsync
    -- and releases the rotation hold.  Keep it below palm_grace_us, so no
    -- touch gesture can start before the leave has run (tune on glass).
    prox_leave_us = 150000,

    -- Touch gestures.
    tap_max_us = 400000,
    tap_slop_px = 24,
    longpress_us = 700000,
    longpress_slop_px = 24,
    swipe_max_us = 900000,
    swipe_min_frac = 0.15,     -- of the logical width
    swipe_ratio = 2.0,         -- |along| >= ratio * |across|
    -- Undo/redo swipe: a swipe with at least this many fingers.  The
    -- operator asked for five.  The cyttsp5 as configured reports at most
    -- two contacts at once: in the 2026-09-26 capture (generation 22, five
    -- fingers pressed repeatedly for ~44 s) the peak was 2 over 255 frames,
    -- in slots 0-3, with no "Num touch err" in dmesg; a third contact showed
    -- only for ~20 ms while one of the pair lifted.  So two fingers is the
    -- most the glass can see, and a two-finger swipe left undoes, right
    -- redoes.  Raising the limit is a flash write to the touch controller.
    multi_min_fingers = 2,
    multi_min_frac = 0.12,
    multi_ratio = 1.5,
    multi_max_us = 1500000,

    -- Floating panel.
    flick_min_px_per_s = 1500,
    flick_window_us = 100000,
    panel_button_min_px = 64,  -- touch residual reaches 25 px
    panel_margin_px = 16,
    panel_max_w_px = 1000,

    -- The Refresh button's wash waits this long after the last paint the
    -- notebook published (the page where the panel was, timed from the
    -- publish's end; anything painted after it, timed from when the
    -- controller asked for it).  hrdl's direct driver starts a
    -- GLOBAL_REFRESH without flushing damage still on its way to the panel
    -- (device.lua's publish comment), so the damage worker must have
    -- blitted that paint first, or it lands after the wash as a partial
    -- pass.  The publish is an fsync and the blit a kworker's commit, a
    -- few ms; 150 ms is margin, and still short enough to read as the
    -- tap's answer (tune on glass).
    refresh_settle_us = 150000,

    -- Housekeeping.
    activity_min_interval_us = 1000000,  -- synthetic InputEvent rate limit
    notebooks_root = "/data/notebooks",
}
