--[[--
nb_geom -- the notebook's coordinate conversions.

Pure: plain numbers in and out, no KOReader modules, so the notebook's
controller and panel models run on any luajit.  test-notebook-geom.lua
checks every formula here against the bundle's own Blitbuffer
(getPhysicalCoordinates, getPhysicalRect, getBoundedRect) in all four
rotations, so a KOReader change to either side shows up as a host failure.

Two spaces:

  * physical px -- the framebuffer's native landscape space, W x H =
    1872 x 1404 on the PineNote.  Pen and touch events arrive in it, and
    the page buffer and every stored stroke live in it, so ink never
    depends on the rotation it was drawn in.
  * logical px -- KOReader's rotated space, where the panel is laid out
    (upright text) and where swipe directions are judged.

r is a Blitbuffer rotation (0..3), not a KOReader rotation mode; the two
run in opposite directions, and bb_rotation converts.
--]]

local G = {}

local floor, ceil = math.floor, math.ceil

-- KOReader rotation mode m sets Screen.bb's rotation to (4 - m) % 4
-- (ffi/framebuffer.lua setRotationMode rotates by -90 * m degrees): the
-- seeded portrait mode 1 is bb rotation 3.
function G.bb_rotation(mode)
    return (4 - mode) % 4
end

local function bad_rotation(r)
    error("nb_geom: rotation must be 0..3, got " .. tostring(r), 3)
end

function G.logical_size(r, W, H)
    if r == 0 or r == 2 then return W, H end
    if r == 1 or r == 3 then return H, W end
    bad_rotation(r)
end

-- Blitbuffer's getPhysicalCoordinates, restated for a buffer we do not
-- hold: the controller converts with only W, H and r in hand.
function G.to_physical(r, W, H, lx, ly)
    if r == 0 then return lx, ly
    elseif r == 1 then return W - 1 - ly, lx
    elseif r == 2 then return W - 1 - lx, H - 1 - ly
    elseif r == 3 then return ly, H - 1 - lx
    end
    bad_rotation(r)
end

-- The inverse of to_physical.
function G.to_logical(r, W, H, px, py)
    if r == 0 then return px, py
    elseif r == 1 then return py, W - 1 - px
    elseif r == 2 then return W - 1 - px, H - 1 - py
    elseif r == 3 then return H - 1 - py, px
    end
    bad_rotation(r)
end

-- A logical rect to the physical rect covering the same pixels.
-- Normalized: a negative w or h (a drag's corner-to-corner span) moves the
-- origin, and fractional edges round outward so every touched pixel is
-- covered.  Clipped to the panel's pixels, because the result feeds the
-- RECT_HINTS arm and the framebuffer clip, and a dragged floating panel
-- may hang off a screen edge.  A rect with no area (outward rounding
-- would widen a zero extent at a fractional origin to one pixel) or with
-- nothing on screen comes back as 0, 0, 0, 0.
function G.rect_to_physical(r, W, H, x, y, w, h)
    if w < 0 then x, w = x + w, -w end
    if h < 0 then y, h = y + h, -h end
    local lw, lh = G.logical_size(r, W, H)
    local x0, y0 = floor(x), floor(y)
    local x1, y1 = ceil(x + w), ceil(y + h)
    if x0 < 0 then x0 = 0 end
    if y0 < 0 then y0 = 0 end
    if x1 > lw then x1 = lw end
    if y1 > lh then y1 = lh end
    if w == 0 or h == 0 or x1 <= x0 or y1 <= y0 then return 0, 0, 0, 0 end
    w, h = x1 - x0, y1 - y0
    -- Blitbuffer's getPhysicalRect on the clipped rect.
    if r == 0 then return x0, y0, w, h
    elseif r == 1 then return W - (y0 + h), x0, h, w
    elseif r == 2 then return W - (x0 + w), H - (y0 + h), w, h
    elseif r == 3 then return y0, H - (x0 + w), h, w
    end
    bad_rotation(r)
end

-- A physical displacement (a swipe, a drag velocity) as the logical one:
-- the rotation part of to_logical without its offset.  0 - v rather than
-- -v keeps a zero component +0, so it never prints as "-0" in a log.
function G.delta_to_logical(r, dx, dy)
    if r == 0 then return dx, dy
    elseif r == 1 then return dy, 0 - dx
    elseif r == 2 then return 0 - dx, 0 - dy
    elseif r == 3 then return 0 - dy, dx
    end
    bad_rotation(r)
end

-- A digitizer axis value to a physical px float, for rasterizing.  The
-- scale is (n - 1) / raw_max, so the top of the axis lands on the last
-- pixel (20966 -> 1871, not 1872).  Values outside the axis clamp to the
-- panel, and a zero axis (EVIOCGABS failed) maps everything to 0 rather
-- than NaN.
function G.raw_to_px(raw, raw_max, n)
    if raw_max <= 0 then return 0 end
    local v = raw * (n - 1) / raw_max
    if v < 0 then return 0 end
    if v > n - 1 then return n - 1 end
    return v
end

return G
