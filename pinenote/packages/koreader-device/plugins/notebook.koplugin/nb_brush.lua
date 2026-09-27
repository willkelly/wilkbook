--[[--
nb_brush -- brush styles and the span rasterizer for the notebook.

Pure Lua: no KOReader modules, no ffi, no io, so every function here runs
table-driven on any luajit (pinenote/tools/koreader-input/
test-notebook-brush.lua).  The glue turns the spans into C fills.

Ink is binary.  Live ink goes through the armed DU rectangle, which
thresholds any gray to black or white (hint 0x00 is Y1 | THRESHOLD, the
ROCKCHIP_EBC_HINT_* bits in linux-pinenote-7.1-hrdl-direct-mode.patch),
so pressure can only drive width.  The two "shaded" brushes are masks of
black pixels: `darken` paints the mask's black pixels and leaves the
others as they were, so overlapping spans and re-rendered strokes are
idempotent in any order.

A style is a flat table recorded verbatim in each stroke's journal line.
nb_journal's "st" array stores rmin, rmax, gamma, dlo and dhi times 100
as integers, so style() quantizes those to 0.01: a replayed stroke then
rasterizes pixel for pixel as it did live.

Geometry: physical px, pixel centres on integer coordinates, and a pixel
is inked when its centre lies inside the shape.  A segment between two
samples is the convex hull of the discs at its ends, which is the union
of the discs swept with linearly interpolated centre and radius.  One
row of that hull is the union of the two discs' slices and the crossings
of the two outer common tangents, so each row costs two square roots
and two line crossings, and emits one span.
--]]

local Brush = {}

local floor, ceil, sqrt, abs = math.floor, math.ceil, math.sqrt, math.abs
local min, max = math.min, math.max
local HUGE = math.huge

-- Slack on span ends so that a pixel centre exactly on the boundary is
-- inked whichever way the float rounding fell.
local EPS = 1e-9

-- Below ~0.71 px a disc lying between pixel centres covers none of them,
-- and a thin diagonal breaks into dots.
local R_FLOOR = 0.75

Brush.IDS = { "fine", "ballpoint", "brushpen", "marker", "pencil",
              "highlighter" }

-- Size multipliers on both radii.  cfg.size_mult = {S=, M=, L=} overrides
-- them one by one; nb_config sets none, and the host test uses it to
-- reach the R_FLOOR clamp, which the shipped sizes never do.
local SIZE_MULT = { S = 0.7, M = 1.0, L = 1.6 }

-- Radii in physical px at 227 dpi (8.94 px/mm) for size M; the comments
-- give the stroke's width.  Pen pressure in contact has median 2716 raw
-- and saturates at 4095 in 9.9 % of reports (the 2026-09-26 captures),
-- so a linear curve puts ordinary writing at about two thirds of the
-- range.  The brush pen squares it: median pressure draws ~1.5 mm, and
-- only a firm press spreads toward 3 mm.  Ballpoint M, the default brush
-- (nb_controller), has radius 2.53 px at the median, so a line 5 px
-- (~0.56 mm) wide: the 2026-09-26 scribble.lua brush the operator judged
-- the notebook's ink against was a radius-2 square, 5 px (~0.56 mm).
local DEFS = {
    fine        = { rmin = 1.35, rmax = 1.35 },             -- 0.3 mm
    ballpoint   = { rmin = 1.35, rmax = 3.15 },             -- 0.3-0.7 mm
    brushpen    = { rmin = 1.8, rmax = 13.4, gamma = 2 },   -- 0.4-3 mm
    marker      = { rmin = 8.95, rmax = 8.95 },             -- 2 mm
    pencil      = { rmin = 1.35, rmax = 2.7,                -- 0.3-0.6 mm
                    comp = "darken", pat = "bayer4", dlo = 0.3, dhi = 1 },
    highlighter = { rmin = 22.35, rmax = 22.35,             -- 5 mm
                    comp = "darken", pat = "checker", dlo = 0.5, dhi = 0.5 },
}

-- 2.7-5.4 mm wide.  The rubber end reports 180-880 raw (median 776).
-- The eraser ignores the size setting: sizes belong to the brush, and an
-- L marker should not turn the rubber end into an 8.6 mm eraser.
local ERASER = { rmin = 12, rmax = 24, comp = "white" }

local function quant(v)
    return floor(v * 100 + 0.5) / 100
end

--- The recorded style for one stroke.  Unknown ids fall back to the
--- first brush, size M and the pen, and the style names what was used.
function Brush.style(brush_id, size_id, tool, cfg)
    if tool ~= "eraser" then tool = "pen" end
    if not DEFS[brush_id] then brush_id = Brush.IDS[1] end
    if not SIZE_MULT[size_id] then size_id = "M" end
    local def, mult, plo, phi
    if tool == "eraser" then
        def, mult = ERASER, 1
        plo, phi = cfg.rubber_p_lo, cfg.rubber_p_hi
    else
        def = DEFS[brush_id]
        mult = (cfg.size_mult and cfg.size_mult[size_id])
               or SIZE_MULT[size_id]
        plo, phi = cfg.pen_p_lo, cfg.pen_p_hi
    end
    return {
        brush = brush_id, size = size_id, tool = tool,
        rmin = quant(max(R_FLOOR, def.rmin * mult)),
        rmax = quant(max(R_FLOOR, def.rmax * mult)),
        gamma = quant(def.gamma or 1),
        plo = plo, phi = phi,
        comp = def.comp or "black", pat = def.pat or "solid",
        dlo = quant(def.dlo or 1), dhi = quant(def.dhi or 1),
    }
end

-- Pressure normalized over [plo, phi], clamped, then curved by gamma.
local function level(style, p)
    local lo, hi = style.plo, style.phi
    if hi <= lo then return p >= hi and 1 or 0 end
    local u = (p - lo) / (hi - lo)
    if u <= 0 then return 0 end
    if u >= 1 then return 1 end
    local g = style.gamma
    if g ~= 1 then u = u ^ g end
    return u
end

function Brush.radius(style, p)
    local rmin, rmax = style.rmin, style.rmax
    if rmin == rmax then return rmin end
    return rmin + (rmax - rmin) * level(style, p)
end

function Brush.density(style, p)
    local dlo, dhi = style.dlo, style.dhi
    if dlo == dhi then return dlo end
    return dlo + (dhi - dlo) * level(style, p)
end

-- The density passed to emit: nil for solid brushes, so the glue can
-- tell a plain fill from a masked one without looking at the style.
local function emit_density(style, p)
    if style.pat == "solid" then return nil end
    return Brush.density(style, p)
end

-- Standard 4x4 ordered-dither matrix, row-major by (y % 4, x % 4).  Each
-- threshold level adds one pixel per tile, so darker never loses a dot.
local BAYER4 = {  0,  8,  2, 10,
                 12,  4, 14,  6,
                  3, 11,  1,  9,
                 15,  7, 13,  5 }

--- Whether a pattern brush inks physical pixel (x, y).  Tied to panel
--- coordinates, not the stroke, so overlapping strokes share one grid.
function Brush.mask(style, density, x, y)
    local pat = style.pat
    if pat == "bayer4" then
        return BAYER4[(y % 4) * 4 + x % 4 + 1] < floor(density * 16 + 0.5)
    elseif pat == "checker" then
        return (x + y) % 2 == 0
    end
    return true
end

-- Clip a first row or column to the panel.  ceil() of a value in (-1, 0]
-- is -0, which math.max(0, -0) keeps; a comparison turns it into 0 so
-- no "-0" reaches a journal line or a log.
local function clip0(v)
    if v <= 0 then return 0 end
    return v
end

-- Emit the rows of one disc, clipped to the panel.
local function disc_rows(cx, cy, r, W, H, emit, dens)
    local r2 = r * r
    for y = clip0(ceil(cy - r - EPS)), min(H - 1, floor(cy + r + EPS)) do
        local dy = y - cy
        local w = sqrt(max(0, r2 - dy * dy))
        local x0 = clip0(ceil(cx - w - EPS))
        local x1 = min(W - 1, floor(cx + w + EPS))
        if x0 <= x1 then emit(y, x0, x1, dens) end
    end
end

--- emit(y, x0, x1, dens) once per row of the hull of the discs at a and
--- b.  dens is nil for solid brushes, else Brush.density at b.p: the
--- value a live renderer passes for the segment ending at b.
function Brush.segment_spans(style, a, b, W, H, emit)
    local ra, rb = Brush.radius(style, a.p), Brush.radius(style, b.p)
    local ax, ay, bx, by = a.x, a.y, b.x, b.y
    local dens = emit_density(style, b.p)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local dr = rb - ra
    if len2 <= dr * dr then
        -- One disc swallows the other; a zero-length segment lands here.
        if ra >= rb then
            disc_rows(ax, ay, ra, W, H, emit, dens)
        else
            disc_rows(bx, by, rb, W, H, emit, dens)
        end
        return
    end
    local len = sqrt(len2)
    local ux, uy = dx / len, dy / len
    -- The outer tangents' outward normals m satisfy m.(b - a) = ra - rb,
    -- so m = -k*u +/- s*n, with n the left normal of u.
    local k = dr / len
    local s = sqrt(1 - k * k)
    local m1x, m1y = -k * ux - s * uy, -k * uy + s * ux
    local m2x, m2y = -k * ux + s * uy, -k * uy - s * ux
    -- Tangent 1 runs p1 -> q1, tangent 2 runs p2 -> q2.
    local p1x, p1y = ax + ra * m1x, ay + ra * m1y
    local q1x, q1y = bx + rb * m1x, by + rb * m1y
    local p2x, p2y = ax + ra * m2x, ay + ra * m2y
    local q2x, q2y = bx + rb * m2x, by + rb * m2y
    local t1lo, t1hi = min(p1y, q1y), max(p1y, q1y)
    local t2lo, t2hi = min(p2y, q2y), max(p2y, q2y)
    -- A horizontal tangent has no slope; its row takes both ends.
    local t1dx = p1y ~= q1y and (q1x - p1x) / (q1y - p1y)
    local t2dx = p2y ~= q2y and (q2x - p2x) / (q2y - p2y)
    local ra2, rb2 = ra * ra, rb * rb
    local y0 = clip0(ceil(min(ay - ra, by - rb) - EPS))
    local y1 = min(H - 1, floor(max(ay + ra, by + rb) + EPS))
    -- No slack on the tangents' extent: a near-horizontal tangent has a
    -- slope near 1e11, and extrapolating it one hair past its end throws
    -- x tens of px out.  Its ends lie on the discs, whose own slack
    -- already covers those rows.
    for y = y0, y1 do
        local lo, hi = HUGE, -HUGE
        local dya, dyb = abs(y - ay), abs(y - by)
        if dya <= ra + EPS then
            local w = sqrt(max(0, ra2 - dya * dya))
            lo, hi = ax - w, ax + w
        end
        if dyb <= rb + EPS then
            local w = sqrt(max(0, rb2 - dyb * dyb))
            lo, hi = min(lo, bx - w), max(hi, bx + w)
        end
        if y >= t1lo and y <= t1hi then
            if t1dx then
                local x = p1x + (y - p1y) * t1dx
                lo, hi = min(lo, x), max(hi, x)
            else
                lo, hi = min(lo, p1x, q1x), max(hi, p1x, q1x)
            end
        end
        if y >= t2lo and y <= t2hi then
            if t2dx then
                local x = p2x + (y - p2y) * t2dx
                lo, hi = min(lo, x), max(hi, x)
            else
                lo, hi = min(lo, p2x, q2x), max(hi, p2x, q2x)
            end
        end
        local x0 = clip0(ceil(lo - EPS))
        local x1 = min(W - 1, floor(hi + EPS))
        if x0 <= x1 then emit(y, x0, x1, dens) end
    end
end

function Brush.dot_spans(style, a, W, H, emit)
    disc_rows(a.x, a.y, Brush.radius(style, a.p), W, H, emit,
              emit_density(style, a.p))
end

--- A whole stroke in the order live ink draws it: the first sample's
--- dot, then each segment.  Rows repeat across pieces; fills and darken
--- masks are idempotent, so the repeats cost time, not correctness.
function Brush.render(style, points, W, H, emit)
    local n = #points
    if n == 0 then return end
    Brush.dot_spans(style, points[1], W, H, emit)
    for i = 2, n do
        Brush.segment_spans(style, points[i - 1], points[i], W, H, emit)
    end
end

--- The pixel bounds render() can touch, unclipped: x0, y0, x1, y1
--- inclusive, or nil for an empty stroke.  This is the journal's "bb".
function Brush.bbox(style, points)
    local n = #points
    if n == 0 then return nil end
    local x0, y0, x1, y1 = HUGE, HUGE, -HUGE, -HUGE
    for i = 1, n do
        local pt = points[i]
        local r = Brush.radius(style, pt.p)
        x0 = min(x0, ceil(pt.x - r - EPS))
        y0 = min(y0, ceil(pt.y - r - EPS))
        x1 = max(x1, floor(pt.x + r + EPS))
        y1 = max(y1, floor(pt.y + r + EPS))
    end
    -- -0 == 0, and the assignment stores +0
    if x0 == 0 then x0 = 0 end
    if y0 == 0 then y0 = 0 end
    return x0, y0, x1, y1
end

-- Signed gap from point q to the hull of discs (a, ra) and (b, rb):
-- min over t of |q - c(t)| - r(t), negative inside.  With tau the
-- distance along the segment, s and h q's along and across coordinates
-- and k = dr / len, the minimum sits where (tau - s) / |q - c| = k.
local function gap(qx, qy, ax, ay, ra, bx, by, rb)
    local dx, dy = bx - ax, by - ay
    local wx, wy = qx - ax, qy - ay
    local len2 = dx * dx + dy * dy
    if len2 == 0 then
        return sqrt(wx * wx + wy * wy) - max(ra, rb)
    end
    local len = sqrt(len2)
    local s = (wx * dx + wy * dy) / len
    local h = abs(wx * dy - wy * dx) / len
    local k = (rb - ra) / len
    local tau
    if k >= 1 then
        tau = len
    elseif k <= -1 then
        tau = 0
    else
        tau = min(len, max(0, s + k * h / sqrt(1 - k * k)))
    end
    local ds = s - tau
    return sqrt(ds * ds + h * h) - ra - k * tau
end

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- Closest points of segments p1->q1 and p2->q2 (Ericson, Real-Time
-- Collision Detection 5.1.9): parameters s, t and the squared distance.
local function closest(p1x, p1y, q1x, q1y, p2x, p2y, q2x, q2y)
    local d1x, d1y = q1x - p1x, q1y - p1y
    local d2x, d2y = q2x - p2x, q2y - p2y
    local rx, ry = p1x - p2x, p1y - p2y
    local a = d1x * d1x + d1y * d1y
    local e = d2x * d2x + d2y * d2y
    local f = d2x * rx + d2y * ry
    local s, t
    if a == 0 then
        s, t = 0, e > 0 and clamp01(f / e) or 0
    else
        local c = d1x * rx + d1y * ry
        if e == 0 then
            s, t = clamp01(-c / a), 0
        else
            local b = d1x * d2x + d1y * d2y
            local denom = a * e - b * b
            s = denom > 0 and clamp01((b * f - c * e) / denom) or 0
            t = (b * s + f) / e
            if t < 0 then
                s, t = clamp01(-c / a), 0
            elseif t > 1 then
                s, t = clamp01((b - c) / a), 1
            end
        end
    end
    local cx = p1x + d1x * s - p2x - d2x * t
    local cy = p1y + d1y * s - p2y - d2y * t
    return s, t, cx * cx + cy * cy
end

-- Does the eraser capsule e0 -> e1 of radius R touch the stroke hull
-- (a, ra) -> (b, rb)?  The centre lines' closest pair decides every
-- constant-width segment.  A tapered one can leave a band where it does
-- not; there the gap along the eraser segment is convex (a partial
-- minimum of a jointly convex function), so a ternary search settles it.
local function segment_hit(e0x, e0y, e1x, e1y, R, ax, ay, ra, bx, by, rb)
    local _, t, d2 = closest(e0x, e0y, e1x, e1y, ax, ay, bx, by)
    local d = sqrt(d2)
    if d <= R + ra + (rb - ra) * t then return true end
    if d > R + max(ra, rb) then return false end
    local lo, hi = 0, 1
    for _ = 1, 30 do
        local m1 = lo + (hi - lo) / 3
        local m2 = hi - (hi - lo) / 3
        local g1 = gap(e0x + (e1x - e0x) * m1, e0y + (e1y - e0y) * m1,
                       ax, ay, ra, bx, by, rb)
        local g2 = gap(e0x + (e1x - e0x) * m2, e0y + (e1y - e0y) * m2,
                       ax, ay, ra, bx, by, rb)
        if g1 <= R or g2 <= R then return true end
        if g1 < g2 then hi = m2 else lo = m1 end
    end
    return false
end

--- Stroke-erase hit test.  eraser_points is the eraser's path in order,
--- and consecutive points are joined, so a fast eraser that jumps over a
--- thin line between two reports still hits it.  bb, when given, is the
--- stroke's recorded {x0, y0, x1, y1} (Brush.bbox) and saves scanning
--- its points for the reject.
function Brush.hits(eraser_points, eraser_r, stroke_points, stroke_style, bb)
    local ne, ns = #eraser_points, #stroke_points
    if ne == 0 or ns == 0 then return false end
    local ex0, ey0, ex1, ey1 = HUGE, HUGE, -HUGE, -HUGE
    for i = 1, ne do
        local e = eraser_points[i]
        ex0, ey0 = min(ex0, e.x), min(ey0, e.y)
        ex1, ey1 = max(ex1, e.x), max(ey1, e.y)
    end
    local R = eraser_r
    local sx0, sy0, sx1, sy1
    if bb then
        -- bb bounds pixel centres; the hull reaches up to 1 px past them.
        sx0, sy0, sx1, sy1 = bb[1] - 1, bb[2] - 1, bb[3] + 1, bb[4] + 1
    else
        local rmax = stroke_style.rmax
        sx0, sy0, sx1, sy1 = HUGE, HUGE, -HUGE, -HUGE
        for i = 1, ns do
            local pt = stroke_points[i]
            sx0, sy0 = min(sx0, pt.x), min(sy0, pt.y)
            sx1, sy1 = max(sx1, pt.x), max(sy1, pt.y)
        end
        sx0, sy0, sx1, sy1 = sx0 - rmax, sy0 - rmax, sx1 + rmax, sy1 + rmax
    end
    if sx0 > ex1 + R or sx1 < ex0 - R or sy0 > ey1 + R or sy1 < ey0 - R then
        return false
    end
    local a = stroke_points[1]
    local ra = Brush.radius(stroke_style, a.p)
    local i = 1
    repeat
        -- A one-sample stroke is the zero-length segment a -> a.
        local b = stroke_points[i + 1] or a
        local rb = Brush.radius(stroke_style, b.p)
        local reach = max(ra, rb) + R
        if min(a.x, b.x) - reach <= ex1 and max(a.x, b.x) + reach >= ex0
           and min(a.y, b.y) - reach <= ey1 and max(a.y, b.y) + reach >= ey0
        then
            local j = 1
            repeat
                local e0 = eraser_points[j]
                local e1 = eraser_points[j + 1] or e0
                if segment_hit(e0.x, e0.y, e1.x, e1.y, R,
                               a.x, a.y, ra, b.x, b.y, rb) then
                    return true
                end
                j = j + 1
            until j >= ne
        end
        a, ra = b, rb
        i = i + 1
    until i >= ns
    return false
end

return Brush
