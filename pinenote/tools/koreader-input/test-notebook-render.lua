--[[--
Host checks for the notebook's pixels (notebook.koplugin nb_surface.lua)
on the bundle's own Blitbuffer, headless.

 0. loading: nb_surface pulls in nb_brush and nothing else (ffi/blitbuffer
    is loaded first, and ffi/png only by write_png);
 1. new_page: BB8, physical, rotation 0, every pixel white;
 2. ink spans land on exactly the right physical pixels, on BB8 and on
    RGB16 (0x0000 black, 0xFFFF white), against a per-pixel setPixel
    reference: panel edges, one-pixel spans, whole rows;
 3. the exclude rect (the open panel on the framebuffer) is untouched,
    spans crossing, inside and touching its edges;
 4. darken: never writes white, keeps existing black, leaves every
    other pixel as it was; the bayer4 masks at all 17 levels and the
    checker are exact against Brush.mask, and switching pattern or
    density between commands resamples the tile; the white eraser
    clears; a buffer type without a pointer path (RGB32) goes through
    setPixel and agrees; darken clips a span past the buffer's edge
    as paintRect clips a fill, rather than writing past it;
 5. render_page equals live ink pixel for pixel: synthetic w9013 pen
    streams (every brush and size, the rubber and the tip as erasers,
    strokes on the panel edges, a single-sample dot) go through
    nb_controller, its ink commands are applied to one page and to an
    RGB16 framebuffer through the alias, and J.replay of its appends is
    rendered into another page; a second session adds the stroke
    eraser, whose region render the glue runs too;
 5b. the page buffer equals a full render of the page file at every
    pen-up and touch action of one session run as main.lua runs it, on
    the seeded portrait screen: brush choices from the panel, 3-finger
    undo and redo over overlapping black and darken strokes, the
    stroke eraser, ink going dead, SYN_DROPPED, a tool switch and
    suspend mid-stroke, a page turn and back, ink under the open panel
    (the panel's screen pixels untouched) and an undo from it, and a
    failed append, at pen-up and mid-stroke, handled by the glue's
    failure rule; the screen outside the panel always shows the page;
 6. region renders write nothing outside the region and equal the full
    render inside it, including regions that only touch a stroke's box
    (the box skip must not drop an edge row or column); Brush.bbox
    bounds every span Brush.render emits over random strokes, which is
    what makes that skip sound;
 7. blit_page maps physical to physical in all four rotations, BB8 and
    RGB16 targets, for all four combinations of page and target
    inverse flags, at offsets, and restores the page's flags; RGB32
    (the SDL emulator's screen) blits too; live ink through the alias
    equals a blit of the inked page on BB8 and RGB16, night mode
    included; with the C blitter off (KOReader's dev_no_c_blitter)
    new_page, ink and blit_page give the same bytes as with it on;
 8. fb_alias: a Screen-style RGB16 buffer with padded stride and a
    rotation; an alias write lands at the right memory and the right
    logical pixel in every rotation, inverse flag included;
 9. write_png exports rotation 0 whatever the flag (a decode round
    trip, not a golden), and reports a failed write, or an encoder
    that cannot load, as nil and a message.

Comparisons are pixel counts and buffer-to-buffer diffs, never PNG
goldens.  When the operator's 2026-09-26 captures are on disk
(gitignored; absent in CI, where that part prints one fixed SKIP-style
PASS), pen-1.bin's 156 strokes also go through the controller and the
render is compared with the live ink.

Timings go to stderr ("BENCH:"), which the determinism check ignores:
per-segment ink cost for a ballpoint, an L highlighter and a pencil on
RGB16 and BB8, and a full render_page of pen-1.bin.

Usage: luajit test-notebook-render.lua <koreader_dir> <plugin_dir> [capture_dir]
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to notebook.koplugin")
local script_dir = arg[0]:match("^(.*)/[^/]*$") or "."
local capture_dir = arg[3] or (script_dir .. "/../pen/build/captures-20260926")

package.path = table.concat({
    plugin_dir .. "/?.lua",
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
-- ffi/util needs libs/libkoreader-lfs.so
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

local format, concat = string.format, table.concat
local floor, sqrt, sin, cos = math.floor, math.sqrt, math.sin, math.cos

local fail = 0
local function report(ok, label, msg)
    if msg and msg ~= "" then
        print(format("%s: %s: %s", ok and "PASS" or "FAIL", label, msg))
    else
        print(format("%s: %s", ok and "PASS" or "FAIL", label))
    end
    if not ok then fail = fail + 1 end
end

-- ffi/loadlib logs through the print it captures when it loads.
local real_print = print
print = function() end
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
print = real_print
local ffi = require("ffi")

------------------------------------------------------------------------
-- 0. Loading
------------------------------------------------------------------------

local before = {}
for k in pairs(package.loaded) do before[k] = true end
local Surface = require("nb_surface")
local extra = {}
for k in pairs(package.loaded) do
    if not before[k] then extra[#extra + 1] = k end
end
table.sort(extra)
report(concat(extra, ",") == "nb_brush,nb_surface",
       "nb_surface loads nb_brush and nothing else", concat(extra, ","))

local Brush = require("nb_brush")
local Ctl = require("nb_controller")
local J = require("nb_journal")
local G = require("nb_geom")
local cfg = dofile(plugin_dir .. "/nb_config.lua")

local W, H = cfg.W, cfg.H
local XMAX, YMAX = cfg.abs_x_max, cfg.abs_y_max
local TYPE_BB8, TYPE_RGB16 = BB.TYPE_BB8, BB.TYPE_BBRGB16
local BLACK, WHITE = BB.COLOR_BLACK, BB.COLOR_WHITE
local U8P = ffi.typeof("uint8_t *")
local U16P = ffi.typeof("uint16_t *")

------------------------------------------------------------------------
-- Raw memory helpers: physical coordinates, whatever the rotation flag
------------------------------------------------------------------------

local function row8(bb, y) return ffi.cast(U8P, bb.data) + bb.stride * y end
local function row16(bb, y)
    return ffi.cast(U16P, ffi.cast(U8P, bb.data) + bb.stride * y)
end

local function mem(bb, x, y)
    if bb:getType() == TYPE_RGB16 then return row16(bb, y)[x] end
    return row8(bb, y)[x]
end

-- The memory values of black and white for a buffer's type (no flag).
local function levels(bb)
    if bb:getType() == TYPE_RGB16 then return 0x0000, 0xFFFF end
    return 0x00, 0xFF
end

-- Every physical pixel set to v (a raw memory value).
local function set_all(bb, v)
    for y = 0, bb.h - 1 do
        if bb:getType() == TYPE_RGB16 then
            local p = row16(bb, y)
            for x = 0, bb.w - 1 do p[x] = v end
        else
            ffi.fill(row8(bb, y), bb.w, v)
        end
    end
end

local function count(bb, v)
    local n = 0
    for y = 0, bb.h - 1 do
        if bb:getType() == TYPE_RGB16 then
            local p = row16(bb, y)
            for x = 0, bb.w - 1 do if p[x] == v then n = n + 1 end end
        else
            local p = row8(bb, y)
            for x = 0, bb.w - 1 do if p[x] == v then n = n + 1 end end
        end
    end
    return n
end

-- Pixels whose memory differs; a and b of the same type and size.
local function diff(a, b)
    local n = 0
    local rgb = a:getType() == TYPE_RGB16
    for y = 0, a.h - 1 do
        local p = rgb and row16(a, y) or row8(a, y)
        local q = rgb and row16(b, y) or row8(b, y)
        for x = 0, a.w - 1 do if p[x] ~= q[x] then n = n + 1 end end
    end
    return n
end

-- Pixels where a BB8 page and an RGB16 buffer disagree on black/white.
local function diff_page_fb(page, fb)
    local n = 0
    for y = 0, page.h - 1 do
        local p, q = row8(page, y), row16(fb, y)
        for x = 0, page.w - 1 do
            local want = p[x] == 0 and 0x0000 or 0xFFFF
            if q[x] ~= want then n = n + 1 end
        end
    end
    return n
end

------------------------------------------------------------------------
-- The reference painter: the contract restated per pixel, through
-- setPixel (a different code path from nb_surface's fills and pointers)
------------------------------------------------------------------------

local function ref_ink(bb, cmd, ex)
    local sp, comp, mstyle = cmd.spans, cmd.comp, { pat = cmd.pat }
    for i = 1, #sp, 3 do
        local y = sp[i]
        for x = sp[i + 1], sp[i + 2] do
            local inside = ex and x >= ex.x and x < ex.x + ex.w
                           and y >= ex.y and y < ex.y + ex.h
            if not inside then
                if comp == "black" then
                    bb:setPixel(x, y, BLACK)
                elseif comp == "white" then
                    bb:setPixel(x, y, WHITE)
                elseif comp == "darken" and Brush.mask(mstyle, cmd.dens, x, y) then
                    bb:setPixel(x, y, BLACK)
                end
            end
        end
    end
end

-- Spans of a whole stroke, as the controller would send them.
local function stroke_cmd(style, points)
    local spans, dens = {}, nil
    Brush.render(style, points, W, H, function(y, x0, x1, d)
        spans[#spans + 1], spans[#spans + 2], spans[#spans + 3] = y, x0, x1
        dens = d
    end)
    return { op = "ink", spans = spans, comp = style.comp, pat = style.pat,
             dens = dens }
end

local function nspans(cmd)
    local n = 0
    for i = 1, #cmd.spans, 3 do n = n + cmd.spans[i + 2] - cmd.spans[i + 1] + 1 end
    return n
end

------------------------------------------------------------------------
-- 1. new_page
------------------------------------------------------------------------

do
    local pg = Surface.new_page(W, H)
    report(pg:getType() == TYPE_BB8 and pg.w == W and pg.h == H
           and pg:getRotation() == 0 and pg:getInverse() == 0,
           "new_page: BB8, physical W x H, rotation 0, not inverted",
           format("type %d, %dx%d, rot %d", pg:getType(), pg.w, pg.h, pg:getRotation()))
    local white = count(pg, 0xFF)
    report(white == W * H, "new_page: every pixel white (calloc is black)",
           format("%d of %d", white, W * H))
end

------------------------------------------------------------------------
-- 2. Solid spans at exact physical pixels, BB8 and RGB16
------------------------------------------------------------------------

-- Edges, single pixels, whole rows, adjacent and overlapping spans.
local SPANS = {
    0, 0, 0,                  -- top-left pixel
    0, W - 1, W - 1,          -- top-right pixel
    H - 1, 0, W - 1,          -- the whole last row
    H - 1 - 1, W - 1, W - 1,  -- last column, second-last row
    5, 10, 19,
    5, 20, 20,                -- adjacent to the previous
    6, 15, 40,
    6, 30, 60,                -- overlapping the previous
    700, 931, 931,
    701, 0, 1871,
    1000, 1800, 1871,
}

for _, t in ipairs({ TYPE_BB8, TYPE_RGB16 }) do
    local name = t == TYPE_BB8 and "BB8" or "RGB16"
    local bb = BB.new(W, H, t)
    bb:fill(WHITE)
    local ref = BB.new(W, H, t)
    ref:fill(WHITE)
    local cmd = { op = "ink", spans = SPANS, comp = "black", pat = "solid" }
    Surface.ink(bb, cmd)
    ref_ink(ref, cmd)
    local black, white = levels(bb)
    -- 1 + 1 + W + 1 + 10 + 1 + 26 + 31 (6: 15..60 is 46, counted once) ...
    local want = 0
    local seen = {}
    for i = 1, #SPANS, 3 do
        for x = SPANS[i + 1], SPANS[i + 2] do
            local k = SPANS[i] * W + x
            if not seen[k] then seen[k] = true; want = want + 1 end
        end
    end
    local nb, nw = count(bb, black), count(bb, white)
    report(diff(bb, ref) == 0 and nb == want and nw == W * H - want,
           name .. ": black spans land on exactly their physical pixels",
           format("%d black (%s), %d white (%s), %d differ from the per-pixel reference",
                  nb, format(t == TYPE_BB8 and "0x%02x" or "0x%04x", black), nw,
                  format(t == TYPE_BB8 and "0x%02x" or "0x%04x", white), diff(bb, ref)))
    report(mem(bb, 0, 0) == black and mem(bb, W - 1, 0) == black
           and mem(bb, 1, 0) == white and mem(bb, 20, 5) == black
           and mem(bb, 21, 5) == white and mem(bb, 9, 5) == white
           and mem(bb, W - 1, H - 2) == black and mem(bb, W - 2, H - 2) == white,
           name .. ": span ends are inclusive, neighbours untouched")
    -- The white eraser: clear part of what was drawn.
    local er = { op = "ink", comp = "white", pat = "solid",
                 spans = { H - 1, 100, 199, 701, 0, 1871, 6, 15, 60 } }
    Surface.ink(bb, er)
    ref_ink(ref, er)
    report(diff(bb, ref) == 0 and mem(bb, 100, H - 1) == white
           and mem(bb, 99, H - 1) == black and mem(bb, 200, H - 1) == black
           and count(bb, black) == nb - 100 - W - 46,
           name .. ": the white eraser clears exactly its spans",
           format("%d black left", count(bb, black)))
end

------------------------------------------------------------------------
-- 3. The exclude rect
------------------------------------------------------------------------

do
    local EX = { x = 400, y = 300, w = 200, h = 100 }   -- x 400..599, y 300..399
    local spans = {
        299, 350, 650,   -- the row above: whole
        300, 350, 650,   -- crosses both edges
        301, 399, 600,   -- touches both edges from outside
        302, 400, 599,   -- exactly the rect's row
        303, 450, 500,   -- inside
        304, 350, 450,   -- enters from the left
        305, 550, 650,   -- leaves on the right
        306, 350, 400,   -- ends on the rect's first column
        307, 599, 650,   -- starts on its last column
        399, 0, W - 1,   -- the rect's last row, whole panel
        400, 350, 650,   -- the row below: whole
    }
    for _, t in ipairs({ TYPE_BB8, TYPE_RGB16 }) do
        local name = t == TYPE_BB8 and "BB8" or "RGB16"
        for _, cm in ipairs({ { "black", "solid" }, { "white", "solid" },
                              { "darken", "checker" }, { "darken", "bayer4" } }) do
            local SENT = t == TYPE_BB8 and 0x55 or 0x5555
            local bb, ref = BB.new(W, H, t), BB.new(W, H, t)
            set_all(bb, SENT)
            set_all(ref, SENT)
            local cmd = { op = "ink", spans = spans, comp = cm[1], pat = cm[2],
                          dens = cm[2] ~= "solid" and 0.5 or nil }
            Surface.ink(bb, cmd, EX)
            ref_ink(ref, cmd, EX)
            local touched = 0
            for y = EX.y, EX.y + EX.h - 1 do
                for x = EX.x, EX.x + EX.w - 1 do
                    if mem(bb, x, y) ~= SENT then touched = touched + 1 end
                end
            end
            local d = diff(bb, ref)
            -- a fill must also reach the pixels touching the rect
            local edges = cm[1] == "darken"
                          or (mem(bb, 399, 301) ~= SENT and mem(bb, 600, 300) ~= SENT)
            report(touched == 0 and d == 0 and edges,
                   format("%s %s/%s: the exclude rect is untouched, the rest as the reference",
                          name, cm[1], cm[2]),
                   format("%d px inside changed, %d differ", touched, d))
        end
    end
    -- A zero-size exclude excludes nothing.
    local bb = BB.new(64, 8, TYPE_BB8)
    bb:fill(WHITE)
    Surface.ink(bb, { spans = { 2, 0, 63 }, comp = "black", pat = "solid" },
                { x = 10, y = 0, w = 0, h = 8 })
    report(count(bb, 0) == 64, "an empty exclude rect excludes nothing")
end

------------------------------------------------------------------------
-- 4. Darken and the masks
------------------------------------------------------------------------

do
    -- Stripes of black, white and a gray neither ink writes, so a write
    -- of either value to the wrong pixel shows.
    local function striped(t)
        local bb = BB.new(W, H, t)
        local b, w = levels(bb)
        local g = t == TYPE_BB8 and 0x80 or 0x8410
        for y = 0, H - 1 do
            for x = 0, W - 1 do
                local k = (x + 3 * y) % 7
                local v = k < 2 and b or (k < 5 and w or g)
                if t == TYPE_RGB16 then row16(bb, y)[x] = v else row8(bb, y)[x] = v end
            end
        end
        return bb, b, w
    end
    local spans = {}
    for y = 100, 163 do spans[#spans + 1] = y; spans[#spans + 1] = 3; spans[#spans + 1] = W - 1 end
    for _, t in ipairs({ TYPE_BB8, TYPE_RGB16 }) do
        local name = t == TYPE_BB8 and "BB8" or "RGB16"
        for _, pd in ipairs({ { "bayer4", 0.3 }, { "bayer4", 1 }, { "checker", 0.5 } }) do
            local bb, b, w = striped(t)
            local before_ = BB.new(W, H, t)
            before_:blitFrom(bb)
            local cmd = { spans = spans, comp = "darken", pat = pd[1], dens = pd[2] }
            Surface.ink(bb, cmd)
            local whitened, unblacked, wrong = 0, 0, 0
            local ms = { pat = pd[1] }
            for y = 0, H - 1 do
                for x = 0, W - 1 do
                    local was, now = mem(before_, x, y), mem(bb, x, y)
                    if now == w and was ~= w then whitened = whitened + 1 end
                    if was == b and now ~= b then unblacked = unblacked + 1 end
                    local inked = y >= 100 and y <= 163 and x >= 3
                                  and Brush.mask(ms, pd[2], x, y)
                    local want = inked and b or was
                    if now ~= want then wrong = wrong + 1 end
                end
            end
            report(whitened == 0 and unblacked == 0 and wrong == 0,
                   format("%s darken %s/%s: never writes white, keeps black, "
                          .. "leaves the rest; black exactly where the mask is",
                          name, pd[1], tostring(pd[2])),
                   format("%d whitened, %d black lost, %d wrong", whitened, unblacked, wrong))
        end
    end

    -- Every bayer level exact, in a 16x16 block at an odd offset, one
    -- command per level on one buffer after another pattern: the tile
    -- is resampled whenever the pattern or the density changes.
    for _, t in ipairs({ TYPE_BB8, TYPE_RGB16 }) do
        local name = t == TYPE_BB8 and "BB8" or "RGB16"
        local bad, counts = 0, {}
        local bb = BB.new(64, 40, t)
        for level = 0, 16 do
            for _, pat in ipairs({ "checker", "bayer4" }) do
                bb:fill(WHITE)
                local dens = level / 16
                local sp = {}
                for y = 7, 22 do sp[#sp + 1] = y; sp[#sp + 1] = 13; sp[#sp + 1] = 28 end
                Surface.ink(bb, { spans = sp, comp = "darken", pat = pat, dens = dens })
                local b = levels(bb)
                local n = 0
                for y = 0, 39 do
                    for x = 0, 63 do
                        local want = y >= 7 and y <= 22 and x >= 13 and x <= 28
                                     and Brush.mask({ pat = pat }, dens, x, y)
                        local got = mem(bb, x, y) == b
                        if got ~= (want and true or false) then bad = bad + 1 end
                        if got then n = n + 1 end
                    end
                end
                if pat == "bayer4" then
                    counts[#counts + 1] = tostring(n)
                    if n ~= 16 * level then bad = bad + 1 end
                elseif n ~= 128 then
                    bad = bad + 1
                end
            end
        end
        report(bad == 0, name .. ": bayer4 at all 17 levels and the checker match "
               .. "Brush.mask pixel for pixel",
               "bayer4 black per 16x16: " .. concat(counts, ","))
    end

    -- darken over solid is a black fill.
    local bb = BB.new(32, 4, TYPE_BB8)
    bb:fill(WHITE)
    Surface.ink(bb, { spans = { 1, 0, 31 }, comp = "darken", pat = "solid" })
    report(count(bb, 0) == 32, "darken with the solid pattern fills black")

    -- An unknown comp (a damaged or newer journal line) draws nothing.
    bb:fill(WHITE)
    Surface.ink(bb, { spans = { 1, 0, 31 }, comp = "sparkle", pat = "solid" })
    report(count(bb, 0xFF) == 128, "an unknown comp draws nothing")

    -- No pointer path for RGB32 (the SDL emulator's default): setPixel.
    local r32, ref = BB.new(97, 31, BB.TYPE_BBRGB32), BB.new(97, 31, BB.TYPE_BBRGB32)
    r32:fill(WHITE)
    ref:fill(WHITE)
    local cmds = {
        { spans = { 3, 0, 96, 4, 10, 80, 30, 50, 96 }, comp = "black", pat = "solid" },
        { spans = { 4, 20, 60 }, comp = "white", pat = "solid" },
        { spans = { 10, 0, 96, 11, 5, 90, 12, 1, 2 }, comp = "darken", pat = "bayer4", dens = 0.4 },
        { spans = { 20, 0, 96, 21, 3, 93 }, comp = "darken", pat = "checker", dens = 0.5 },
    }
    local EX = { x = 40, y = 10, w = 9, h = 12 }
    for _, c in ipairs(cmds) do
        Surface.ink(r32, c, EX)
        ref_ink(ref, c, EX)
    end
    local d = 0
    for y = 0, 30 do
        for x = 0, 96 do
            if r32:getPixel(x, y):getColor8().a ~= ref:getPixel(x, y):getColor8().a then
                d = d + 1
            end
        end
    end
    report(d == 0, "RGB32 (no pointer path): fills, darken and exclude as the reference",
           format("%d differ", d))

    -- Spans past the buffer: paintRect clips a fill, and darken's
    -- pointer and setPixel writes must clip the same way rather than
    -- land in another row or outside the buffer.  The target is a view
    -- of rows 2..5 of a 10-row buffer, so every stray write, the row
    -- above included, lands in memory this test owns and can see.
    local bad_clip = {}
    for _, t in ipairs({ TYPE_BB8, TYPE_RGB16, BB.TYPE_BBRGB32 }) do
        local spans = { 4, 0, 15,     -- the first row past the bottom
                        5, 0, 15,
                        -1, 0, 15,    -- a row above the top
                        1, 6, 20,     -- past the right edge
                        0, 10, 16,    -- ending one past it, where both masks ink x 16
                        2, -9, 1 }    -- from left of column 0
        for _, cm in ipairs({ { "black", "solid" }, { "darken", "checker" },
                              { "darken", "bayer4" } }) do
            local big = BB.new(16, 10, t)
            big:fill(WHITE)
            local view = BB.new(16, 4, t, ffi.cast(U8P, big.data) + 2 * big.stride,
                                big.stride)
            local ref = BB.new(16, 4, t)
            ref:fill(WHITE)
            local cmd = { spans = spans, comp = cm[1], pat = cm[2], dens = 0.5 }
            Surface.ink(view, cmd)
            -- the reference: the same command on in-range spans only
            ref_ink(ref, { spans = { 1, 6, 15, 0, 10, 15, 2, 0, 1 }, comp = cm[1], pat = cm[2],
                           dens = 0.5 })
            local wrong = 0
            for y = 0, 9 do
                for x = 0, 15 do
                    local got = big:getPixel(x, y):getColor8().a
                    local inview = y >= 2 and y <= 5
                    local want = inview and ref:getPixel(x, y - 2):getColor8().a or 0xFF
                    if got ~= want then wrong = wrong + 1 end
                end
            end
            if wrong > 0 then
                bad_clip[#bad_clip + 1] = format("type %d %s/%s: %d wrong", t, cm[1], cm[2], wrong)
            end
        end
    end
    report(#bad_clip == 0, "spans past the buffer's edges are clipped, fills and darken alike "
           .. "(BB8, RGB16, RGB32)", concat(bad_clip, "; "))
end

------------------------------------------------------------------------
-- Synthetic pen streams through the controller
------------------------------------------------------------------------

local ID = "20260926T120000Z-00c0de"
local NB = { id = ID, title = "Render" }
local T0 = 1758844800 * 1000000
local clock = T0
local NOW = T0
local function now() return NOW end

local function RX(px) return floor(px * XMAX / (W - 1) + 0.5) end
local function RY(py) return floor(py * YMAX / (H - 1) + 0.5) end

local function pen(list, ty, code, v, raw)
    list[#list + 1] = { src = "pen", type = ty, code = code, value = v,
                        t = clock, raw = raw }
end
-- device.lua passes the rounded px as value and the digitizer unit as raw.
local function xy(list, px, py)
    local rx, ry = RX(px), RY(py)
    pen(list, 3, 0, floor(rx * W / XMAX + 0.5), rx)
    pen(list, 3, 1, floor(ry * H / YMAX + 0.5), ry)
end
local function syn(list) pen(list, 0, 0, 0) end

-- One pen-down in kernel order: proximity over the first point, contact
-- with BTN_TOUCH:1 ahead of its X/Y, a report per point at 360 Hz, the
-- lift, proximity out.  pts = { {x, y, p}... } in physical px.
local function stroke_events(list, tool, pts)
    local key = tool == "rubber" and 321 or 320
    local p1 = pts[1]
    pen(list, 1, key, 1); xy(list, p1[1], p1[2]); syn(list)
    clock = clock + 2770
    pen(list, 1, 330, 1); xy(list, p1[1], p1[2]); pen(list, 3, 24, p1[3]); syn(list)
    for i = 2, #pts do
        clock = clock + 2770
        local q = pts[i]
        xy(list, q[1], q[2]); pen(list, 3, 24, q[3]); syn(list)
    end
    clock = clock + 2770
    pen(list, 1, 330, 0); pen(list, 3, 24, 0); syn(list)
    clock = clock + 2770
    pen(list, 1, key, 0); syn(list)
    clock = clock + 200000
end

-- n samples from a to b, pressure p0..p1, bent by a sine of amplitude amp.
local function line(ax, ay, bx, by, n, p0, p1, amp)
    local pts = {}
    local dx, dy = bx - ax, by - ay
    local len = sqrt(dx * dx + dy * dy)
    local nx, ny = -dy / len, dx / len
    for i = 0, n - 1 do
        local u = i / (n - 1)
        local s = (amp or 0) * sin(u * 6.283)
        pts[#pts + 1] = { ax + dx * u + nx * s, ay + dy * u + ny * s,
                          floor(p0 + (p1 - p0) * u + 0.5) }
    end
    return pts
end

local function circle(cx, cy, r, n, p)
    local pts = {}
    for i = 0, n do
        local a = i / n * 6.283
        pts[#pts + 1] = { cx + r * cos(a), cy + r * sin(a), p + (i % 7) * 300 }
    end
    return pts
end

-- The plan: one controller per brush change, as a reopen would; each
-- continues the same page's journal.
local PLAN = {
    { brush = "fine", size = "M", strokes = {
        line(100, 100, 700, 400, 60, 2000, 2000),
        line(120, 380, 690, 110, 45, 800, 4095, 20) } },
    { brush = "ballpoint", size = "S", strokes = {
        line(80, 500, 1700, 520, 200, 150, 4095, 40),
        circle(900, 300, 120, 90, 900) } },
    { brush = "brushpen", size = "L", strokes = {
        line(300, 700, 1500, 650, 150, 100, 4095, 60),
        { { 1600, 200, 3500 } } } },                       -- a single-sample dot
    { brush = "marker", size = "M", strokes = {
        line(200, 250, 1400, 260, 100, 2716, 2716),
        line(0, 0, W - 1, 0, 120, 3000, 3000),              -- along the top edge
        line(0, H - 1, 0, 0, 90, 3000, 3000),               -- the left edge
        line(W - 1, 5, W - 1, H - 1, 90, 3000, 3000),       -- the right edge
        line(W - 1, H - 1, 10, H - 1, 150, 3000, 3000) } }, -- the bottom edge
    { brush = "pencil", size = "M", strokes = {
        line(150, 150, 1300, 600, 250, 100, 4095, 90),
        line(400, 800, 1200, 1100, 150, 3000, 600, 30) } },
    { brush = "highlighter", size = "L", strokes = {
        line(100, 260, 1500, 280, 180, 2500, 2500, 10),
        line(600, 100, 700, 1300, 150, 2500, 2500, 25) } },
    { brush = "pencil", size = "L", strokes = {                -- darken over darken
        line(500, 240, 1300, 300, 120, 400, 4000, 15) } },
    { brush = "fine", size = "M", rubber = "area", tool = "rubber", strokes = {
        line(250, 180, 1300, 560, 120, 200, 880, 30) } },
    { brush = "marker", size = "S", mode = "erase", strokes = {  -- the tip as eraser
        line(1000, 600, 1100, 1000, 80, 1000, 4095, 10) } },
    { brush = "ballpoint", size = "L", strokes = {
        circle(1500, 1000, 200, 150, 1200),
        line(1400, 900, 1700, 1300, 90, 4095, 100) } },
}

-- Run a plan through fresh controllers.  Ink goes to page and, when
-- given, the framebuffer alias; appends are collected; with regions,
-- render_page commands limited to a region run too (the stroke eraser's
-- pen-up rebuild).  Full renders (open) are not run: the page must stay
-- live ink only, and a full render is what it is compared against.
local function run_plan(plan, page, fb, lines, regions)
    local st = { ink = 0, darken = 0, white = 0, spans = 0, renders = 0 }
    local function run(cmds)
        for _, cmd in ipairs(cmds) do
            if cmd.op == "ink" then
                Surface.ink(page, cmd)
                if fb then Surface.ink(fb, cmd) end
                st.ink = st.ink + 1
                st.spans = st.spans + #cmd.spans / 3
                if cmd.comp == "darken" then st.darken = st.darken + 1 end
                if cmd.comp == "white" then st.white = st.white + 1 end
            elseif cmd.op == "append" then
                lines[#lines + 1] = cmd.line
            elseif cmd.op == "render_page" and cmd.region and regions then
                Surface.render_page(page, cmd.page, cmd.strokes, cfg, cmd.region)
                st.renders = st.renders + 1
            end
        end
    end
    for _, seg in ipairs(plan) do
        local c = Ctl.new{ cfg = cfg, now_rt_us = now,
                           prefs = { brush = seg.brush, size = seg.size,
                                     mode = seg.mode or "write",
                                     rubber = seg.rubber or "area" } }
        run(c:open(NB, 0, J.replay(lines, cfg)))
        run(c:set_ink_live(true))
        local evs = {}
        for _, pts in ipairs(seg.strokes) do stroke_events(evs, seg.tool or "pen", pts) end
        for _, e in ipairs(evs) do
            NOW = e.t + 500
            run(c:feed(e))
        end
        run(c:close())
    end
    return st
end

------------------------------------------------------------------------
-- 5. render_page equals live ink
------------------------------------------------------------------------

-- Section 5's replay, kept for the region and blit checks.
local replay_page, replay_strokes

do
    local page = Surface.new_page(W, H)
    local fbmem = BB.new(W, H, TYPE_RGB16)
    fbmem:fill(WHITE)
    local fb = Surface.fb_alias(fbmem)
    local lines = {}
    local st = run_plan(PLAN, page, fb, lines)
    local rp = J.replay(lines, cfg)
    local out = Surface.new_page(W, H)
    Surface.render_page(out, 0, rp.strokes, cfg)
    local d = diff(page, out)
    local black = count(page, 0)
    report(d == 0 and #rp.strokes == #lines and rp.bad_lines == 0 and black > 0,
           "render_page of the replayed journal equals the live ink, pixel for pixel",
           format("%d strokes, %d ink commands (%d darken, %d white), %d spans, "
                  .. "%d black px, %d differ", #rp.strokes, st.ink, st.darken, st.white,
                  st.spans, black, d))
    report(st.darken > 0 and st.white > 0, "the session exercised darken and white ink",
           format("%d darken, %d white", st.darken, st.white))
    local e = 0
    for _, s in ipairs(rp.strokes) do if s.style.tool == "eraser" then e = e + 1 end end
    report(e == 2, "the session recorded the rubber and the tip as eraser strokes",
           format("%d eraser strokes", e))
    local dfb = diff_page_fb(page, fbmem)
    report(dfb == 0, "the RGB16 framebuffer through the alias holds the same ink as the page",
           format("%d differ", dfb))
    -- The edges: the marker strokes reach row 0, row H-1, column 0 and W-1.
    report(mem(page, 900, 0) == 0 and mem(page, 900, H - 1) == 0
           and mem(page, 0, 700) == 0 and mem(page, W - 1, 700) == 0,
           "edge strokes ink the panel's first and last rows and columns")
    replay_page, replay_strokes = out, rp.strokes

    -- The stroke eraser: whiteouts live, then the controller's region
    -- render at pen-up, as the glue runs it.
    local plan2 = {}
    for i, seg in ipairs(PLAN) do plan2[i] = seg end
    plan2[#plan2 + 1] = { brush = "fine", size = "M", mode = "stroke_erase", strokes = {
        line(650, 50, 650, 900, 120, 2000, 2000) } }
    plan2[#plan2 + 1] = { brush = "fine", size = "M", rubber = "stroke", tool = "rubber",
                          strokes = { line(1450, 1250, 1750, 1250, 60, 500, 500) } }
    plan2[#plan2 + 1] = { brush = "pencil", size = "S", strokes = {
        line(600, 400, 900, 450, 60, 3000, 3000) } }
    local page2 = Surface.new_page(W, H)
    local lines2 = {}
    local st2 = run_plan(plan2, page2, nil, lines2, true)
    local rp2 = J.replay(lines2, cfg)
    local out2 = Surface.new_page(W, H)
    Surface.render_page(out2, 0, rp2.strokes, cfg)
    local xs, erased = 0, 0
    for _, l in ipairs(lines2) do
        local rec = J.decode(l)
        if rec.k == "x" then xs, erased = xs + 1, erased + #rec.ids end
    end
    local d2 = diff(page2, out2)
    -- Both erasers hit, and what they took is gone from the replay (the
    -- second cannot pick what the first already hid).
    report(d2 == 0 and xs == 2 and st2.renders == 2 and erased > 0
           and #rp2.strokes == #rp.strokes + 1 - erased,
           "with the stroke eraser: whiteouts plus its region renders equal the replay",
           format("%d x records erasing %d strokes, %d region renders, %d strokes left, "
                  .. "%d differ", xs, erased, st2.renders, #rp2.strokes, d2))
end

------------------------------------------------------------------------
-- 5b. The page buffer equals the journal through every rebuild
------------------------------------------------------------------------

-- One session run as main.lua runs it, on the seeded portrait screen
-- (RGB16, rotation 3): ink into the page and, through the alias, the
-- screen less the open panel's physical rect; every render_page, full
-- and region; load_page answered at once; a repaint or panel command
-- blits the page and paints the panel over it (a sentinel here); a
-- failed append handled by the glue's rule (the rest of the list runs
-- without its appends, arms, ink and publishes, then io_error gets the
-- failed command); schedule answered by on_timer once the clock passes
-- it (one timer, as main.lua keeps), which runs the pen's leave and the
-- stroke eraser's render that waits for it.  At every pen-up (after the
-- leave) and touch action the page must be
-- a full render of the page file's replay: the screen never keeps ink
-- the journal lacks, and a reread page is the page on screen.
do
    local PANEL = 0x5555
    local SKIP = { append = true, arm = true, ink = true, publish_ink = true }
    local scr = BB.new(W, H, TYPE_RGB16)
    scr:fill(WHITE)
    scr:setRotation(3)
    local S = { lines = {}, page = Surface.new_page(W, H), cur = 0,
                fb = Surface.fb_alias(scr) }

    local function paint()
        Surface.blit_page(scr, S.page, 0, 0)
        local P = S.panel
        if P then
            for y = P.y, P.y + P.h - 1 do
                local q = row16(scr, y)
                for x = P.x, P.x + P.w - 1 do q[x] = PANEL end
            end
        end
    end

    local exec
    exec = function(cmds)
        local err, err_cmd
        for _, cmd in ipairs(cmds) do
            local op = cmd.op
            if err and SKIP[op] then
                -- skipped, as the glue skips them after a failed write
            elseif op == "ink" then
                Surface.ink(S.page, cmd)
                Surface.ink(S.fb, cmd, S.panel)
            elseif op == "render_page" then
                Surface.render_page(S.page, cmd.page, cmd.strokes, cfg, cmd.region)
            elseif op == "append" then
                if S.fail_append then
                    S.fail_append = nil
                    err, err_cmd = "ENOSPC page", cmd
                else
                    local l = S.lines[cmd.page] or {}
                    S.lines[cmd.page] = l
                    l[#l + 1] = cmd.line
                end
            elseif op == "load_page" then
                exec(S.c:page_loaded(cmd.page, J.replay(S.lines[cmd.page] or {}, cfg)))
            elseif op == "panel" then
                local L = cmd.layout
                S.layout, S.panel = L, nil
                if L then
                    local px, py, pw, ph = G.rect_to_physical(3, W, H, L.x, L.y, L.w, L.h)
                    if pw > 0 and ph > 0 then S.panel = { x = px, y = py, w = pw, h = ph } end
                end
                paint()
            elseif op == "repaint" then
                paint()
            elseif op == "schedule" then
                S.timer_at = NOW + cmd.delay_us
            end
        end
        if err then exec(S.c:io_error(err, err_cmd)) end
    end
    -- The UI loop's timer, when the clock has passed it.
    local function fire()
        while S.timer_at and S.timer_at <= clock do
            local at = S.timer_at
            S.timer_at = nil
            NOW = at
            exec(S.c:on_timer(at))
        end
    end

    local function open_session()
        S.c = Ctl.new{ cfg = cfg, now_rt_us = now, rotation_mode = 1,
                       prefs = { brush = "marker", size = "M", mode = "write",
                                 rubber = "area" } }
        exec(S.c:open(NB, 0, J.replay(S.lines[0] or {}, cfg)))
        exec(S.c:resync({ prox = false, touching = false }, NOW))
        exec(S.c:set_ink_live(true))
    end

    local function feed_all(list)
        for _, e in ipairs(list) do
            NOW = e.t + 300
            exec(S.c:feed(e))
        end
    end
    -- One pen-down, report by report; hooks[i]() runs after point i's.
    local function pen_down(tool, pts, hooks)
        local key = tool == "rubber" and 321 or 320
        local l = {}
        pen(l, 1, key, 1); xy(l, pts[1][1], pts[1][2]); syn(l)
        clock = clock + 2770
        pen(l, 1, 330, 1); xy(l, pts[1][1], pts[1][2]); pen(l, 3, 24, pts[1][3]); syn(l)
        feed_all(l)
        for i = 2, #pts do
            clock = clock + 2770
            l = {}
            xy(l, pts[i][1], pts[i][2]); pen(l, 3, 24, pts[i][3]); syn(l)
            feed_all(l)
            if hooks and hooks[i] then hooks[i]() end
        end
        clock = clock + 2770
        l = {}
        pen(l, 1, 330, 0); pen(l, 3, 24, 0); syn(l)
        clock = clock + 2770
        pen(l, 1, key, 0); syn(l)
        feed_all(l)
        clock = clock + 200000
        fire()
    end
    -- Touch intents through the controller's dispatcher (nb_input's
    -- recognizers have their own suite); x, y and dx, dy are physical.
    local function touch(it)
        clock = clock + 1000
        fire()
        NOW = clock
        it.t = clock
        local out = {}
        S.c:_run({ it }, out)
        exec(out)
    end
    local function tap(id)
        for _, it in ipairs(S.layout.items) do
            if it.id == id then
                local px, py = G.to_physical(3, W, H, it.x + floor(it.w / 2),
                                             it.y + floor(it.h / 2))
                touch({ k = "tap", x = px, y = py, target = "panel" })
                return
            end
        end
        error("no panel item " .. id)
    end
    -- A panel choice as the operator makes it: long press, tap, Close.
    local function choose(...)
        touch({ k = "long_press", x = 1800, y = 1350 })
        for _, id in ipairs({ ... }) do tap(id) end
        tap("close")
    end
    -- Portrait (bb rotation 3): a physical +dy is a logical leftward swipe.
    local function undo() touch({ k = "multi_swipe", dx = 0, dy = 600, fingers = 3 }) end
    local function redo() touch({ k = "multi_swipe", dx = 0, dy = -600, fingers = 3 }) end

    local function check(label)
        local want = Surface.new_page(W, H)
        local rp = J.replay(S.lines[S.cur] or {}, cfg)
        Surface.render_page(want, S.cur, rp.strokes, cfg)
        local d = diff(S.page, want)
        want:free()
        local ds, dp = 0, 0
        local P = S.panel
        for y = 0, H - 1 do
            local p, q = row8(S.page, y), row16(scr, y)
            for x = 0, W - 1 do
                if P and x >= P.x and x < P.x + P.w and y >= P.y and y < P.y + P.h then
                    if q[x] ~= PANEL then dp = dp + 1 end
                elseif q[x] ~= (p[x] == 0 and 0x0000 or 0xFFFF) then
                    ds = ds + 1
                end
            end
        end
        report(d == 0 and ds == 0 and dp == 0 and rp.bad_lines == 0,
               "journal: " .. label,
               format("page %d, %d strokes, %d black px; %d page px differ from the "
                      .. "replay, %d screen px from the page, %d panel px inked",
                      S.cur, #rp.strokes, count(S.page, 0), d, ds, dp))
    end

    open_session()
    pen_down("pen", line(200, 300, 1500, 700, 80, 3000, 3000, 30))
    choose("brush:pencil")
    pen_down("pen", line(250, 700, 1500, 250, 90, 500, 4095, 40))
    choose("brush:highlighter", "size:L")
    pen_down("pen", line(150, 500, 1600, 520, 100, 2500, 2500, 20))
    choose("brush:ballpoint", "size:M")
    pen_down("pen", line(700, 100, 800, 1300, 100, 200, 4095, 60))
    pen_down("rubber", line(600, 400, 1100, 600, 60, 300, 880, 10))
    choose("brush:brushpen")
    pen_down("pen", line(900, 200, 1000, 1200, 70, 4095, 100, 25))
    check("six overlapping strokes, black, darken and the rubber, brushes from the panel")
    undo()
    check("3-finger undo")
    undo()
    check("undo of the rubber's stroke brings back what it erased")
    undo()
    check("a third undo")
    redo()
    check("3-finger redo")
    choose("brush:fine")
    pen_down("pen", line(100, 1000, 1700, 900, 50, 2000, 2000, 5))
    redo()
    check("new ink after an undo; the redo it cleared does nothing")

    choose("mode:stroke_erase")
    pen_down("pen", line(1450, 400, 1450, 700, 30, 2000, 2000))
    choose("mode:write")
    check("the stroke eraser through overlapping black and darken strokes")

    choose("brush:marker")
    pen_down("pen", line(300, 1100, 1300, 1150, 60, 3000, 3000, 20),
             { [30] = function() exec(S.c:set_ink_live(false)) end })
    exec(S.c:set_ink_live(true))
    check("ink going dead mid-stroke keeps what was drawn, recorded")

    choose("brush:pencil")
    pen_down("pen", line(300, 200, 1300, 260, 60, 3000, 3000, 20),
             { [25] = function()
                   local l = {}
                   clock = clock + 100
                   pen(l, 0, 3, 0)
                   clock = clock + 100
                   xy(l, 700, 240); syn(l)
                   feed_all(l)
                   exec(S.c:resync({ prox = true, tool = "pen", touching = true }, NOW))
               end })
    check("SYN_DROPPED mid-stroke")

    choose("brush:ballpoint")
    pen_down("pen", line(1200, 1000, 400, 1200, 60, 3000, 3000, 20),
             { [30] = function()
                   local l = {}
                   clock = clock + 2770
                   pen(l, 1, 320, 0); pen(l, 1, 321, 1); xy(l, 800, 1100)
                   pen(l, 3, 24, 700); syn(l)
                   feed_all(l)
               end })
    check("a tool switch mid-stroke")

    pen_down("pen", line(1500, 100, 1600, 1300, 60, 3000, 3000, 20),
             { [20] = function()
                   exec(S.c:suspend())
                   exec(S.c:resume({ prox = true, tool = "pen", touching = true }))
               end })
    check("suspend and resume mid-stroke")

    touch({ k = "swipe", dx = 0, dy = 600 })
    S.cur = 1
    check("a swipe to the blank next page")
    pen_down("pen", line(100, 100, 1700, 1300, 60, 3000, 3000, 20))
    check("ink on page 1")
    touch({ k = "swipe", dx = 0, dy = -600 })
    S.cur = 0
    check("back on page 0")

    choose("brush:marker")
    touch({ k = "long_press", x = 900, y = 700 })
    local P = S.panel
    pen_down("pen", line(P.x - 100, P.y + P.h / 2, P.x + P.w + 100, P.y + P.h / 2, 80,
                         3000, 3000))
    local under = 0
    for y = P.y, P.y + P.h - 1 do
        local p = row8(S.page, y)
        for x = P.x, P.x + P.w - 1 do if p[x] == 0 then under = under + 1 end end
    end
    report(under > 0, "journal: the stroke crossed the open panel's rect",
           format("%d black px under the panel", under))
    check("ink across the open panel: the page holds it, the panel's screen pixels do not")
    tap("undo")
    check("undo from the open panel")
    tap("close")
    check("the panel closed")

    -- Each failure scenario proves its own premise: the stroke inked
    -- before its append failed, and nothing reached the page file.
    local function failing(label, draw)
        local nlines = #(S.lines[S.cur] or {})
        local base = count(S.page, 0)
        S.fail_append, S.peak = true, base
        draw()
        report(S.fail_append == nil and #(S.lines[S.cur] or {}) == nlines
               and S.peak > base, "journal: " .. label .. " (premise)",
               format("inked %d px before the failure, %d lines kept", S.peak - base,
                      #(S.lines[S.cur] or {})))
        check(label)
    end
    failing("a failed append at pen-up: the stroke is rendered away", function()
        pen_down("pen", line(200, 600, 1600, 650, 80, 3000, 3000, 40),
                 { [79] = function() S.peak = count(S.page, 0) end })
    end)
    pen_down("pen", line(200, 900, 1600, 950, 80, 3000, 3000, 40))
    check("after io_error nothing inks")

    -- A reopen, and a failed append in the middle of a pen-down: the
    -- SYN_DROPPED gap record's.
    exec(S.c:close())
    open_session()
    check("reopened")
    failing("a failed append mid-stroke: the cut-off stroke is rendered away", function()
        pen_down("pen", line(250, 150, 1550, 1250, 80, 3000, 3000, 30),
                 { [40] = function()
                       S.peak = count(S.page, 0)
                       local l = {}
                       clock = clock + 100
                       pen(l, 0, 3, 0)
                       clock = clock + 100
                       xy(l, 900, 700); syn(l)
                       feed_all(l)
                   end })
    end)
end

------------------------------------------------------------------------
-- 6. Region renders
------------------------------------------------------------------------

do
    local strokes = replay_strokes
    local REGIONS = {
        { x = 300, y = 200, w = 400, h = 300 },
        { x = 0, y = 0, w = 1, h = 1 },
        { x = W - 50, y = H - 40, w = 50, h = 40 },
        { x = 0, y = 700, w = W, h = 1 },
        { x = 1750, y = 40, w = 60, h = 60 },      -- no strokes there
        { x = 0, y = 0, w = W, h = H },
    }
    for _, R in ipairs(REGIONS) do
        local bb = BB.new(W, H, TYPE_BB8)
        set_all(bb, 0x55)
        Surface.render_page(bb, 0, strokes, cfg, R)
        local outside, inside = 0, 0
        for y = 0, H - 1 do
            local p, q = row8(bb, y), row8(replay_page, y)
            local iny = y >= R.y and y < R.y + R.h
            for x = 0, W - 1 do
                if iny and x >= R.x and x < R.x + R.w then
                    if p[x] ~= q[x] then inside = inside + 1 end
                elseif p[x] ~= 0x55 then
                    outside = outside + 1
                end
            end
        end
        report(outside == 0 and inside == 0,
               format("region %d,%d %dx%d: nothing written outside, the full render inside",
                      R.x, R.y, R.w, R.h),
               format("%d outside written, %d inside differ", outside, inside))
    end
    -- Regions whose edge is a stroke's box edge: a dot at an integer
    -- centre inks its box's extreme rows and columns, so a region that
    -- only touches the box must still draw it.
    do
        local style = Brush.style("fine", "M", "pen", cfg)   -- r 1.35: box 499..501
        local dot = { { style = style, points = { { x = 500, y = 500, p = 2000 } } } }
        local full = Surface.new_page(W, H)
        Surface.render_page(full, 0, dot, cfg)
        local bad = {}
        for _, R in ipairs({ { x = 501, y = 490, w = 20, h = 20 },    -- from the right
                             { x = 480, y = 490, w = 20, h = 20 },    -- ends at x 499
                             { x = 490, y = 501, w = 20, h = 20 },    -- from below
                             { x = 490, y = 480, w = 20, h = 20 } }) do -- ends at y 499
            local bb = Surface.new_page(W, H)
            Surface.render_page(bb, 0, dot, cfg, R)
            local d, inked = 0, 0
            for y = R.y, R.y + R.h - 1 do
                for x = R.x, R.x + R.w - 1 do
                    if mem(bb, x, y) ~= mem(full, x, y) then d = d + 1 end
                    if mem(full, x, y) == 0 then inked = inked + 1 end
                end
            end
            if d > 0 or inked == 0 then
                bad[#bad + 1] = format("%d,%d: %d differ, %d inked", R.x, R.y, d, inked)
            end
        end
        report(#bad == 0, "regions touching a stroke's box at one edge still draw it",
               concat(bad, "; "))
    end

    -- render_page skips a stroke whose Brush.bbox misses the region, so
    -- that box must bound every span Brush.render emits.  Random strokes
    -- over every brush and size and the eraser, with near-horizontal and
    -- near-vertical legs (tangent slopes near 1e11), half-integer
    -- centres and panel edges.
    do
        local seed = 20260926
        local function rnd()
            seed = (seed * 16807) % 2147483647
            return seed / 2147483647
        end
        local styles = {}
        for _, id in ipairs(Brush.IDS) do
            for _, sz in ipairs({ "S", "M", "L" }) do
                styles[#styles + 1] = Brush.style(id, sz, "pen", cfg)
            end
        end
        styles[#styles + 1] = Brush.style("fine", "M", "eraser", cfg)
        local nstrokes, nspans_, outside = 0, 0, 0
        local x0, y0, x1, y1
        local function emit(y, a, b)
            nspans_ = nspans_ + 1
            if y < y0 or y > y1 or a < x0 or b > x1 then outside = outside + 1 end
        end
        for trial = 1, 4000 do
            local style = styles[1 + trial % #styles]
            local pts = {}
            local x, y = rnd() * (W - 1), rnd() * (H - 1)
            for i = 1, 1 + floor(rnd() * 6) do
                local m = rnd()
                if m < 0.2 then
                    x, y = x + (rnd() - 0.5) * 60, y + (rnd() - 0.5) * 1e-7
                elseif m < 0.3 then
                    x, y = x + (rnd() - 0.5) * 1e-7, y + (rnd() - 0.5) * 60
                elseif m < 0.4 then
                    x, y = floor(x) + 0.5, floor(y) + 0.5
                elseif m < 0.5 then
                    x = rnd() < 0.5 and 0 or W - 1
                else
                    x, y = x + (rnd() - 0.5) * 40, y + (rnd() - 0.5) * 40
                end
                x = math.max(0, math.min(W - 1, x))
                y = math.max(0, math.min(H - 1, y))
                pts[i] = { x = x, y = y, p = floor(rnd() * 4096) }
            end
            x0, y0, x1, y1 = Brush.bbox(style, pts)
            nstrokes = nstrokes + 1
            Brush.render(style, pts, W, H, emit)
        end
        report(outside == 0, "Brush.bbox bounds every span Brush.render emits, so the "
               .. "region skip drops nothing",
               format("%d random strokes, %d spans, %d outside their box", nstrokes,
                      nspans_, outside))
    end

    -- An empty region writes nothing.
    local bb = BB.new(64, 64, TYPE_BB8)
    set_all(bb, 0x55)
    Surface.render_page(bb, 0, strokes, { W = 64, H = 64 }, { x = 10, y = 10, w = 0, h = 5 })
    report(count(bb, 0x55) == 64 * 64, "an empty region writes nothing")

    -- The skip's box is computed once per entry: a region render walked
    -- every sample on the page to reject strokes, on every undo and
    -- stroke erase.  Fresh entries, so no earlier render has cached them.
    do
        local fresh = {}
        for i, e in ipairs(strokes) do
            fresh[i] = { a = e.a, rec = e.rec, style = e.style, bb = e.bb,
                         points = e.points }
        end
        local real, calls = Brush.bbox, 0
        Brush.bbox = function(...)
            calls = calls + 1
            return real(...)
        end
        local page = Surface.new_page(W, H)
        local R = { x = 300, y = 200, w = 40, h = 30 }
        Surface.render_page(page, 0, fresh, cfg, R)
        local first = calls
        Surface.render_page(page, 0, fresh, cfg, R)
        Surface.render_page(page, 0, fresh, cfg, { x = 900, y = 700, w = 40, h = 30 })
        Brush.bbox = real
        page:free()
        report(first == #fresh and calls == #fresh,
               "region renders compute each stroke's box once, then reuse it",
               format("%d strokes: %d calls after one render, %d after three",
                      #fresh, first, calls))
    end
end

------------------------------------------------------------------------
-- 7. blit_page: physical to physical, inverse flags, offsets
------------------------------------------------------------------------

do
    local PW, PH = 61, 37
    local page = BB.new(PW, PH, TYPE_BB8)
    for y = 0, PH - 1 do
        for x = 0, PW - 1 do
            -- asymmetric: a left column, a top row, and a sparse lattice
            local blk = x == 0 or (y == 0 and x < 20) or (x * 7 + y * 13) % 5 == 0
            row8(page, y)[x] = blk and 0x00 or 0xFF
        end
    end
    local bad_cases, cases = {}, 0
    for _, t in ipairs({ TYPE_BB8, TYPE_RGB16 }) do
        for r = 0, 3 do
            for pinv = 0, 1 do
                for tinv = 0, 1 do
                    cases = cases + 1
                    local tgt = BB.new(PW, PH, t)
                    set_all(tgt, t == TYPE_BB8 and 0x55 or 0x5555)
                    tgt:setRotation(r)
                    tgt:setInverse(tinv)
                    page:setInverse(pinv)
                    Surface.blit_page(tgt, page, 0, 0)
                    local b, w = levels(tgt)
                    local wrong = 0
                    for y = 0, PH - 1 do
                        for x = 0, PW - 1 do
                            -- the page's colour as its flag reads it, then
                            -- stored as the target's flag stores it
                            local black = (row8(page, y)[x] == 0) ~= (pinv == 1)
                            local stored = black ~= (tinv == 1)
                            if mem(tgt, x, y) ~= (stored and b or w) then wrong = wrong + 1 end
                        end
                    end
                    local restored = page:getRotation() == 0 and page:getInverse() == pinv
                                     and tgt:getInverse() == tinv and tgt:getRotation() == r
                    if wrong > 0 or not restored then
                        bad_cases[#bad_cases + 1] = format("%s r%d p%d t%d: %d wrong%s",
                            t == TYPE_BB8 and "BB8" or "RGB16", r, pinv, tinv, wrong,
                            restored and "" or " flags not restored")
                    end
                end
            end
        end
    end
    page:setInverse(0)
    report(#bad_cases == 0, "blit_page maps physical to physical in all 4 rotations, "
           .. "BB8 and RGB16, matching and mismatching inverse flags, flags restored",
           #bad_cases == 0 and format("%d cases", cases) or concat(bad_cases, "; "))

    -- RGB32, the SDL emulator's screen unless EMULATE_BB_TYPE is set: the
    -- C blit and the C invert both take it (an unsupported pair aborts
    -- the process in blitbuffer.c).  Read back through getPixel, which
    -- honours the flag.
    local bad32 = 0
    for r = 0, 3 do
        for tinv = 0, 1 do
            local tgt = BB.new(PW, PH, BB.TYPE_BBRGB32)
            tgt:setRotation(r)
            tgt:setInverse(tinv)
            Surface.blit_page(tgt, page, 0, 0)
            tgt:setRotation(0)
            for y = 0, PH - 1 do
                for x = 0, PW - 1 do
                    local want = row8(page, y)[x]
                    if tgt:getPixel(x, y):getColor8().a ~= want then bad32 = bad32 + 1 end
                end
            end
        end
    end
    report(bad32 == 0, "blit_page onto RGB32, all rotations, inverse 0 and 1",
           format("%d wrong", bad32))

    -- Offsets: the page's logical (u, v) lands at the target's logical
    -- (u + dx, v + dy), and nothing outside the blitted rect is written,
    -- the in-place inversion included.
    local bad = {}
    for _, r in ipairs({ 1, 3 }) do
        for tinv = 0, 1 do
            for _, off in ipairs({ { 5, 3 }, { -4, -2 } }) do
                local dx, dy = off[1], off[2]
                local tgt = BB.new(PW, PH, TYPE_RGB16)
                set_all(tgt, 0x5555)
                tgt:setRotation(r)
                tgt:setInverse(tinv)
                Surface.blit_page(tgt, page, dx, dy)
                page:setRotation(r)
                local lw, lh = tgt:getWidth(), tgt:getHeight()
                local wrong = 0
                for ly = 0, lh - 1 do
                    for lx = 0, lw - 1 do
                        local tx, ty = tgt:getPhysicalCoordinates(lx, ly)
                        local u, v = lx - dx, ly - dy
                        local want = 0x5555
                        if u >= 0 and v >= 0 and u < lw and v < lh then
                            local px, py = page:getPhysicalCoordinates(u, v)
                            local black = row8(page, py)[px] == 0
                            want = (black ~= (tinv == 1)) and 0x0000 or 0xFFFF
                        end
                        if row16(tgt, ty)[tx] ~= want then wrong = wrong + 1 end
                    end
                end
                page:setRotation(0)
                if wrong > 0 then
                    bad[#bad + 1] = format("r%d t%d off %d,%d: %d wrong", r, tinv, dx, dy, wrong)
                end
            end
        end
    end
    report(#bad == 0, "blit_page at offsets: logical placement, nothing written outside "
           .. "the blitted rect", concat(bad, "; "))

    -- Full size, the seeded portrait (bb rotation 3), the session's page.
    for tinv = 0, 1 do
        local scr = BB.new(W, H, TYPE_RGB16)
        scr:setRotation(3)
        scr:setInverse(tinv)
        Surface.blit_page(scr, replay_page, 0, 0)
        local wrong = 0
        for y = 0, H - 1 do
            local p, q = row8(replay_page, y), row16(scr, y)
            for x = 0, W - 1 do
                local stored = (p[x] == 0) ~= (tinv == 1)
                if q[x] ~= (stored and 0x0000 or 0xFFFF) then wrong = wrong + 1 end
            end
        end
        report(wrong == 0, format("blit_page full panel, rotation 3, inverse %d", tinv),
               format("%d wrong", wrong))
    end

    -- Live ink through the alias equals a later blit of the inked page:
    -- what the pen drew is what the next repaint shows, night mode too.
    local SW, SH = 211, 157
    local ink = {
        { spans = { 10, 5, 200, 11, 5, 200, 12, 0, 210 }, comp = "black", pat = "solid" },
        { spans = { 11, 50, 60 }, comp = "white", pat = "solid" },
        { spans = { 40, 0, 210, 41, 3, 150, 42, 7, 9 }, comp = "darken", pat = "bayer4", dens = 0.55 },
        { spans = { 80, 20, 190, 81, 21, 191, 150, 0, 210 }, comp = "darken", pat = "checker", dens = 0.5 },
        { spans = { 156, 100, 210, 0, 0, 0 }, comp = "black", pat = "solid" },
    }
    local bad2 = {}
    for _, t in ipairs({ TYPE_BB8, TYPE_RGB16 }) do
        for r = 0, 3 do
            for tinv = 0, 1 do
                local pg = Surface.new_page(SW, SH)
                local scr = BB.new(SW, SH, t)
                scr:setRotation(r)
                scr:setInverse(tinv)
                Surface.blit_page(scr, pg, 0, 0)
                local alias = Surface.fb_alias(scr)
                for _, c in ipairs(ink) do
                    Surface.ink(pg, c)
                    Surface.ink(alias, c)
                end
                local scr2 = BB.new(SW, SH, t)
                scr2:setRotation(r)
                scr2:setInverse(tinv)
                Surface.blit_page(scr2, pg, 0, 0)
                local d = diff(scr, scr2)
                if d > 0 then
                    bad2[#bad2 + 1] = format("%s r%d t%d: %d differ",
                                             t == TYPE_BB8 and "BB8" or "RGB16", r, tinv, d)
                end
            end
        end
    end
    report(#bad2 == 0, "live ink through the alias equals a blit of the inked page, "
           .. "BB8 and RGB16, all rotations, inverse 0 and 1", concat(bad2, "; "))

    -- KOReader's dev_no_c_blitter setting sends paintRect, fill, blitFrom
    -- and invertRect down their Lua paths.  The bytes must not change,
    -- and blit_page must not reach invertRect's Lua fallback, whose
    -- full-width BB8 and RGB24 loop raises an error (a 64-bit stride as
    -- its loop limit).
    local function shot(cbb, t, r, tinv, dx, dy)
        BB:enableCBB(cbb)
        local pg = Surface.new_page(SW, SH)
        for _, c in ipairs(ink) do Surface.ink(pg, c) end
        local s = BB.new(SW, SH, t)
        s:fill(WHITE)
        s:setRotation(r)
        s:setInverse(tinv)
        local ok, err = pcall(Surface.blit_page, s, pg, dx, dy)
        local alias = Surface.fb_alias(s)
        Surface.ink(alias, { spans = { 100, 0, 210, 101, 30, 40 }, comp = "black",
                             pat = "solid" }, { x = 20, y = 95, w = 10, h = 10 })
        Surface.ink(alias, { spans = { 120, 0, 210 }, comp = "darken", pat = "bayer4",
                             dens = 0.3 })
        BB:enableCBB(true)
        return ok and BB.tostring(s) or ("error: " .. tostring(err))
    end
    local bad3, n3 = {}, 0
    for _, t in ipairs({ TYPE_BB8, TYPE_RGB16, BB.TYPE_BBRGB24, BB.TYPE_BBRGB32 }) do
        for r = 0, 3 do
            for tinv = 0, 1 do
                for _, off in ipairs({ { 0, 0 }, { 7, -3 } }) do
                    n3 = n3 + 1
                    local on = shot(true, t, r, tinv, off[1], off[2])
                    local off_ = shot(false, t, r, tinv, off[1], off[2])
                    if on ~= off_ then
                        bad3[#bad3 + 1] = format("type %d r%d inv%d off %d,%d%s", t, r, tinv,
                                                 off[1], off[2], off_:match("^error: ")
                                                 and " (raised)" or "")
                    end
                end
            end
        end
    end
    report(#bad3 == 0 and BB:getUseCBB(), "C blitter off: new_page, ink and blit_page give "
           .. "the same bytes as with it on (BB8, RGB16, RGB24, RGB32 screens)",
           #bad3 == 0 and format("%d cases", n3) or concat(bad3, "; "))
end

------------------------------------------------------------------------
-- 8. fb_alias on a Screen-style buffer
------------------------------------------------------------------------

do
    -- Padded like a real fbdev line: pixel_stride past the visible width.
    local PADW = W + 16
    local scr = BB.new(W, H, TYPE_RGB16, nil, PADW * 2, PADW)
    scr:fill(WHITE)
    local bad = {}
    for r = 0, 3 do
        for inv = 0, 1 do
            scr:setRotation(r)
            scr:setInverse(inv)
            set_all(scr, inv == 1 and 0x0000 or 0xFFFF)   -- white as the flag stores it
            local a = Surface.fb_alias(scr)
            local shape = a.w == W and a.h == H and a:getRotation() == 0
                          and a:getType() == TYPE_RGB16 and a.stride == scr.stride
                          and a.pixel_stride == scr.pixel_stride and a:getInverse() == inv
                          and a:getAllocated() == 0
                          and ffi.cast(U8P, a.data) == ffi.cast(U8P, scr.data)
            Surface.ink(a, { spans = { 200, 100, 100 }, comp = "black", pat = "solid" })
            Surface.ink(a, { spans = { 201, 0, 7 }, comp = "darken", pat = "checker", dens = 0.5 })
            local blackmem = inv == 1 and 0xFFFF or 0x0000
            local lx, ly = G.to_logical(r, W, H, 100, 200)
            local seen = scr:getPixel(lx, ly):getColor8().a
            local n = count(scr, blackmem)
            local ok = shape and row16(scr, 200)[100] == blackmem and seen == 0
                       and n == 1 + 4 and row16(scr, 201)[1] == blackmem
                       and row16(scr, 201)[0] ~= blackmem
            if not ok then
                bad[#bad + 1] = format("r%d inv%d: shape %s, mem %04x, logical %d,%d reads %d, %d black",
                                       r, inv, tostring(shape), row16(scr, 200)[100], lx, ly, seen, n)
            end
        end
    end
    report(#bad == 0, "fb_alias: physical (100,200) through the alias is Screen.bb's "
           .. "physical (100,200) and its logical pixel, all rotations, inverse 0 and 1, "
           .. "padded stride", concat(bad, "; "))
    scr:setRotation(3)
    scr:setInverse(0)
    local lx, ly = G.to_logical(3, W, H, 100, 200)
    report(lx == 1203 and ly == 100, "the seeded portrait shows physical (100,200) at "
           .. "logical (1203,100)", format("%d,%d", lx, ly))
end

------------------------------------------------------------------------
-- 9. write_png
------------------------------------------------------------------------

do
    local Png = require("ffi/png")
    -- os.tmpname creates the file; write_png overwrites it.  No path is
    -- printed: stdout must not change between runs.
    local path, path2 = os.tmpname(), os.tmpname()
    local page = Surface.new_page(97, 31)
    page:paintRect(3, 2, 5, 1, BLACK)   -- rotation 0 while painting
    page:paintRect(96, 30, 1, 1, BLACK)
    page:setRotation(3)
    local ok, err = Surface.write_png(page, path)
    local dec_ok, img = Png.decodeFromFile(path, 1)
    local wrong = 0
    if dec_ok then
        local d = ffi.cast(U8P, img.data)
        for y = 0, 30 do
            for x = 0, 96 do
                if d[y * 97 + x] ~= row8(page, y)[x] then wrong = wrong + 1 end
            end
        end
    end
    report(ok == true and err == nil and dec_ok and img.width == 97
           and img.height == 31 and img.ncomp == 1 and wrong == 0
           and page:getRotation() == 3,
           "write_png: a BB8 page exports gray at rotation 0 whatever its flag, flag kept",
           format("%s, %s, %d wrong", tostring(ok), dec_ok and format("%dx%d/%d", img.width,
                  img.height, img.ncomp) or "no decode", wrong))
    local fb = BB.new(8, 4, TYPE_RGB16)
    fb:fill(WHITE)
    Surface.ink(fb, { spans = { 1, 2, 2 }, comp = "black", pat = "solid" })
    fb:setRotation(1)
    local ok2 = Surface.write_png(fb, path2)
    local dec2, img2 = Png.decodeFromFile(path2, 3)
    local d2 = dec2 and ffi.cast(U8P, img2.data)
    report(ok2 == true and dec2 and img2.width == 8 and img2.height == 4
           and d2[(1 * 8 + 2) * 3] == 0 and d2[(1 * 8 + 3) * 3] == 255,
           "write_png: RGB16 exports RGB at rotation 0")
    -- A regular file cannot be a directory.
    local okf, errf = Surface.write_png(page, path .. "/page.png")
    report(okf == nil and type(errf) == "string" and #errf > 0,
           "write_png: a failed write returns nil and a message")
    -- An encoder that cannot load (no ffi/loadlib, no lodepng) is a
    -- failed write as well, not an error raised at the caller.
    local saved = package.loaded["ffi/png"]
    package.loaded["ffi/png"] = nil
    package.preload["ffi/png"] = function() error("lodepng missing", 0) end
    local okn, errn = Surface.write_png(page, path .. ".none")
    package.preload["ffi/png"] = nil
    package.loaded["ffi/png"] = saved
    report(okn == nil and errn == "lodepng missing",
           "write_png: an encoder that cannot load returns nil and its message")
    os.remove(path)
    os.remove(path2)
end

------------------------------------------------------------------------
-- The real captures (optional), and the benchmarks (stderr)
------------------------------------------------------------------------

ffi.cdef [[
typedef struct {
    int64_t sec; int64_t usec; uint16_t type; uint16_t code; int32_t value;
} nbrender_input_event;
]]

-- 24-byte aarch64 input_event records; the capture holds digitizer
-- units, which device.lua would pass as raw with the rounded px as value.
local function load_capture(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    local recs = ffi.cast("const nbrender_input_event *", data)
    local evs = {}
    for i = 0, floor(#data / 24) - 1 do
        local e = recs[i]
        local ty, code, v = e.type, e.code, e.value
        local ev = { src = "pen", type = ty, code = code, value = v,
                     t = tonumber(e.sec) * 1000000 + tonumber(e.usec) }
        if ty == 3 and code <= 1 then
            ev.raw = v
            local n, max = W, XMAX
            if code == 1 then n, max = H, YMAX end
            ev.value = floor(v * n / max + 0.5)
        end
        evs[#evs + 1] = ev
    end
    return evs
end

local capture_strokes
do
    local evs = load_capture(capture_dir .. "/pen-1.bin")
    if not evs then
        print("PASS: pen-1.bin render vs live skipped (absent)")
    else
        local page = Surface.new_page(W, H)
        local lines = {}
        local c = Ctl.new{ cfg = cfg, now_rt_us = now, prefs = { brush = "ballpoint" } }
        c:open(NB, 0, J.replay({}, cfg))
        c:set_ink_live(true)
        local inks = 0
        for _, e in ipairs(evs) do
            NOW = e.t + 1000
            for _, cmd in ipairs(c:feed(e)) do
                if cmd.op == "ink" then
                    Surface.ink(page, cmd)
                    inks = inks + 1
                elseif cmd.op == "append" then
                    lines[#lines + 1] = cmd.line
                end
            end
        end
        for _, cmd in ipairs(c:close()) do
            if cmd.op == "append" then lines[#lines + 1] = cmd.line end
        end
        local rp = J.replay(lines, cfg)
        local out = Surface.new_page(W, H)
        Surface.render_page(out, 0, rp.strokes, cfg)
        local d = diff(page, out)
        report(d == 0 and #rp.strokes == 156,
               "pen-1.bin: the render of its 156 strokes equals the live ink",
               format("%d strokes, %d ink commands, %d black px, %d differ",
                      #rp.strokes, inks, count(page, 0), d))
        capture_strokes = rp.strokes
    end
end

-- Per-segment ink: typical pen travel (~10 px a report) at median
-- pressure, on the RGB16 framebuffer (through an alias, as the glue
-- draws) and on the BB8 page.
do
    local function segments(style, n)
        local cmds, seed = {}, 20260926
        local function rnd()
            seed = (seed * 16807) % 2147483647
            return seed / 2147483647
        end
        for i = 1, n do
            local ax, ay = 100 + rnd() * 1600, 100 + rnd() * 1200
            local a = rnd() * 6.283
            local b = { x = ax + 10 * cos(a), y = ay + 10 * sin(a), p = 2716 }
            local spans, dens = {}, nil
            Brush.segment_spans(style, { x = ax, y = ay, p = 2716 }, b, W, H,
                                function(y, x0, x1, d)
                                    spans[#spans + 1] = y
                                    spans[#spans + 1] = x0
                                    spans[#spans + 1] = x1
                                    dens = d
                                end)
            cmds[i] = { op = "ink", spans = spans, comp = style.comp, pat = style.pat,
                        dens = dens }
        end
        return cmds
    end
    local fbmem = BB.new(W, H, TYPE_RGB16)
    fbmem:fill(WHITE)
    local fb = Surface.fb_alias(fbmem)
    local page = Surface.new_page(W, H)
    for _, b in ipairs({ { "ballpoint", "M" }, { "highlighter", "L" }, { "pencil", "M" } }) do
        local style = Brush.style(b[1], b[2], "pen", cfg)
        local cmds = segments(style, 4000)
        local rows = 0
        for _, c in ipairs(cmds) do rows = rows + #c.spans / 3 end
        for _, target in ipairs({ { "RGB16 fb", fb }, { "BB8 page", page } }) do
            for _, c in ipairs(cmds) do Surface.ink(target[2], c) end   -- warm the JIT
            local t0 = os.clock()
            for _ = 1, 3 do
                for _, c in ipairs(cmds) do Surface.ink(target[2], c) end
            end
            local dt = (os.clock() - t0) / (3 * #cmds)
            io.stderr:write(format("BENCH: ink %s %s (%s/%s) on %s: %.2f us/segment, "
                                   .. "%.1f rows/segment\n", b[1], b[2], style.comp,
                                   style.pat, target[1], dt * 1e6, rows / #cmds))
        end
    end
    if capture_strokes then
        local out = Surface.new_page(W, H)
        Surface.render_page(out, 0, capture_strokes, cfg)
        local t0 = os.clock()
        for _ = 1, 5 do Surface.render_page(out, 0, capture_strokes, cfg) end
        io.stderr:write(format("BENCH: render_page pen-1.bin (%d strokes, ballpoint): "
                               .. "%.1f ms full page\n", #capture_strokes,
                               (os.clock() - t0) / 5 * 1e3))
    end
end

if fail == 0 then
    print("RESULT: ok")
else
    print(format("RESULT: failed (%d)", fail))
    os.exit(1)
end
