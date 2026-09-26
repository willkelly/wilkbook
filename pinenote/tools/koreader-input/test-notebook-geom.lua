--[[--
Host harness for the notebook's coordinate conversions (nb_geom.lua).

nb_geom restates Blitbuffer's rotation arithmetic so the pure notebook
modules can convert without holding a buffer.  This suite checks every
restated formula against the bundle's real ffi/blitbuffer and
ffi/framebuffer in all four rotations:

  * bb_rotation and logical_size against framebuffer:setRotationMode;
  * to_physical against getPhysicalCoordinates, to_logical as its exact
    inverse, and both against pixel memory (a logical paintRect read back
    with the physical getPixelP);
  * rect_to_physical against getPhysicalRect (in-bounds rects) and
    getBoundedRect + getPhysicalRect (rects hanging off an edge), plus
    its own normalizing, outward rounding and empty result;
  * delta_to_logical against differences of converted points;
  * raw_to_px at the digitizer's axis ends and outside them;
  * edges: the last pixel and one past it, zero extents at fractional
    origins, rotation 1 against rotation 3, and a rotation outside 0..3
    reaching any conversion.

Points come from a fixed-seed generator, so the output is identical run
to run.

Usage: luajit test-notebook-geom.lua <koreader_dir> <plugin_dir>
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to notebook.koplugin")

package.path = table.concat({
    plugin_dir .. "/?.lua",
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
-- ffi/util (pulled in by blitbuffer) needs libs/libkoreader-lfs.so.
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

-- Purity: loading nb_geom must pull in nothing but itself (checked
-- before Blitbuffer loads, and reported once report() exists).
local before = {}
for k in pairs(package.loaded) do before[k] = true end
local G = require("nb_geom")
local extra = {}
for k in pairs(package.loaded) do
    if not before[k] and k ~= "nb_geom" then extra[#extra + 1] = k end
end
table.sort(extra)

-- ffi/loadlib captures print for its logging when it loads, and without
-- it blitbuffer falls back to pure Lua; silence it for the load only.
local real_print = print
print = function() end
local loaded, BB, Framebuffer = pcall(function()
    require("ffi/loadlib")
    return require("ffi/blitbuffer"), require("ffi/framebuffer")
end)
print = real_print
assert(loaded, BB)

local fail = 0
local function report(ok, label, msg)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label,
                        msg or ""))
    if not ok then fail = fail + 1 end
end

report(#extra == 0, "nb_geom loads no other module",
       #extra == 0 and "" or table.concat(extra, ","))

local W, H = 1872, 1404

-- Park-Miller: every product stays below 2^53, so the sequence is exact
-- on doubles and identical on every run.
local seed = 20260926
local function rnd(n)
    seed = (seed * 16807) % 2147483647
    return seed % n
end

local function tuple(...)
    local t = { ... }
    for i = 1, select("#", ...) do t[i] = tostring(t[i]) end
    return "(" .. table.concat(t, ",") .. ")"
end

local function new_bb(r)
    local bb = BB.new(W, H, BB.TYPE_BB8)
    bb:fill(BB.COLOR_WHITE)
    bb:setRotation(r)
    return bb
end

------------------------------------------------------------------------
-- 1. Rotation mode and logical size, against the framebuffer.
------------------------------------------------------------------------

do
    local expect = { [0] = 0, 3, 2, 1 }
    local fb = Framebuffer:new{ bb = BB.new(W, H, BB.TYPE_BB8) }
    for m = 0, 3 do
        fb:setRotationMode(m)
        local r = G.bb_rotation(m)
        report(r == expect[m] and r == fb.bb:getRotation(),
               "bb_rotation(" .. m .. ")",
               "nb_geom " .. r .. ", framebuffer " .. fb.bb:getRotation())
        local lw, lh = G.logical_size(r, W, H)
        report(lw == fb:getWidth() and lh == fb:getHeight(),
               "logical_size(r=" .. r .. ")",
               lw .. "x" .. lh .. " vs framebuffer "
               .. fb:getWidth() .. "x" .. fb:getHeight())
    end
    fb.bb:free()
end

------------------------------------------------------------------------
-- 2. Points: to_physical == getPhysicalCoordinates, to_logical inverts.
------------------------------------------------------------------------

local N_POINTS = 4000

for r = 0, 3 do
    local bb = new_bb(r)
    local lw, lh = G.logical_size(r, W, H)
    local pts = {
        { 0, 0 }, { lw - 1, 0 }, { 0, lh - 1 }, { lw - 1, lh - 1 },
        { math.floor(lw / 2), math.floor(lh / 2) },
    }
    for _ = 1, N_POINTS do pts[#pts + 1] = { rnd(lw), rnd(lh) } end

    local bad_fwd, bad_inv, bad_range
    for _, p in ipairs(pts) do
        local lx, ly = p[1], p[2]
        local px, py = G.to_physical(r, W, H, lx, ly)
        local bx, by = bb:getPhysicalCoordinates(lx, ly)
        if not bad_fwd and (px ~= bx or py ~= by) then
            bad_fwd = tuple(lx, ly) .. " -> " .. tuple(px, py)
                      .. " bb " .. tuple(bx, by)
        end
        if not bad_range and (px < 0 or px >= W or py < 0 or py >= H) then
            bad_range = tuple(lx, ly) .. " -> " .. tuple(px, py)
        end
        local qx, qy = G.to_logical(r, W, H, px, py)
        if not bad_inv and (qx ~= lx or qy ~= ly) then
            bad_inv = tuple(lx, ly) .. " -> " .. tuple(qx, qy)
        end
    end
    local n = #pts .. " points"
    report(not bad_fwd, "r=" .. r .. ": to_physical == getPhysicalCoordinates",
           bad_fwd or n)
    report(not bad_range, "r=" .. r .. ": to_physical lands on the panel",
           bad_range or n)
    report(not bad_inv, "r=" .. r .. ": to_logical inverts to_physical",
           bad_inv or n)

    -- The other direction over physical points, fractional ones included:
    -- the pen hands the controller float px.
    local bad_phys
    for _ = 1, N_POINTS do
        local px, py = rnd(W * 4) / 4, rnd(H * 4) / 4
        local lx, ly = G.to_logical(r, W, H, px, py)
        local qx, qy = G.to_physical(r, W, H, lx, ly)
        if not bad_phys and (qx ~= px or qy ~= py) then
            bad_phys = tuple(px, py) .. " -> " .. tuple(qx, qy)
        end
    end
    report(not bad_phys, "r=" .. r .. ": to_physical inverts to_logical",
           bad_phys or (N_POINTS .. " quarter-px points"))

    -- Pixel memory: a 1x1 logical paintRect must land on the physical
    -- pixel to_physical names.  getPixelP reads physical memory directly,
    -- so this does not lean on getPhysicalCoordinates agreeing with itself.
    local bad_px
    for i = 1, 24 do
        local lx, ly = pts[i][1], pts[i][2]
        local px, py = G.to_physical(r, W, H, lx, ly)
        bb:paintRect(lx, ly, 1, 1, BB.COLOR_BLACK)
        local v = bb:getPixelP(px, py)[0].a
        bb:paintRect(lx, ly, 1, 1, BB.COLOR_WHITE)
        if not bad_px and v ~= 0 then
            bad_px = tuple(lx, ly) .. " -> " .. tuple(px, py) .. " reads " .. v
        end
    end
    report(not bad_px, "r=" .. r .. ": logical paint lands at to_physical",
           bad_px or "24 pixels")
    bb:free()
end

do
    local ok, err = pcall(G.to_physical, 4, W, H, 0, 0)
    report(not ok and tostring(err):find("rotation must be 0..3", 1, true) ~= nil,
           "a rotation outside 0..3 is an error", ok and "no error" or "")
end

------------------------------------------------------------------------
-- 3. Rects.
------------------------------------------------------------------------

local N_RECTS = 1500

for r = 0, 3 do
    local bb = new_bb(r)
    local lw, lh = G.logical_size(r, W, H)

    -- In bounds: exactly getPhysicalRect.
    local bad_in
    for _ = 1, N_RECTS do
        local x, y = rnd(lw), rnd(lh)
        local w, h = 1 + rnd(lw - x), 1 + rnd(lh - y)
        local a = tuple(G.rect_to_physical(r, W, H, x, y, w, h))
        local b = tuple(bb:getPhysicalRect(x, y, w, h))
        if not bad_in and a ~= b then
            bad_in = tuple(x, y, w, h) .. " -> " .. a .. " bb " .. b
        end
    end
    report(not bad_in, "r=" .. r .. ": rect_to_physical == getPhysicalRect",
           bad_in or (N_RECTS .. " rects"))

    -- Hanging off an edge but overlapping the screen: the clip must agree
    -- with KOReader's own getBoundedRect before conversion.
    local bad_edge, n_edge = nil, 0
    for _ = 1, N_RECTS do
        local x = rnd(lw + 600) - 300
        local y = rnd(lh + 600) - 300
        local w, h = 1 + rnd(700), 1 + rnd(700)
        if x < lw and y < lh and x + w > 0 and y + h > 0 then
            n_edge = n_edge + 1
            local a = tuple(G.rect_to_physical(r, W, H, x, y, w, h))
            local b = tuple(bb:getPhysicalRect(bb:getBoundedRect(x, y, w, h)))
            if not bad_edge and a ~= b then
                bad_edge = tuple(x, y, w, h) .. " -> " .. a .. " bb " .. b
            end
        end
    end
    report(not bad_edge,
           "r=" .. r .. ": off-edge rects clip like getBoundedRect",
           bad_edge or (n_edge .. " partly visible rects"))

    -- Nothing on screen: the empty rect.
    local empty = {
        { -50, 10, 50, 10 }, { lw, 10, 5, 5 }, { 10, -20, 5, 20 },
        { 10, lh, 5, 5 }, { 10, 10, 0, 5 }, { 10, 10, 5, 0 },
    }
    local bad_empty
    for _, c in ipairs(empty) do
        local a = tuple(G.rect_to_physical(r, W, H, c[1], c[2], c[3], c[4]))
        if not bad_empty and a ~= "(0,0,0,0)" then
            bad_empty = tuple(c[1], c[2], c[3], c[4]) .. " -> " .. a
        end
    end
    report(not bad_empty, "r=" .. r .. ": off-screen rects are 0,0,0,0",
           bad_empty or (#empty .. " rects"))

    -- Negative extents describe the same rect from its far corner.
    local a = tuple(G.rect_to_physical(r, W, H, 300, 400, -120, -80))
    local b = tuple(G.rect_to_physical(r, W, H, 180, 320, 120, 80))
    report(a == b, "r=" .. r .. ": negative w/h normalize", a .. " vs " .. b)

    -- Fractional edges round outward: 10.5..12.5 covers pixels 10..12.
    a = tuple(G.rect_to_physical(r, W, H, 10.5, 20.25, 2, 3))
    b = tuple(bb:getPhysicalRect(10, 20, 3, 4))
    report(a == b, "r=" .. r .. ": fractional edges round outward",
           a .. " vs " .. b)

    a = tuple(G.rect_to_physical(r, W, H, -5, -5, lw + 10, lh + 10))
    report(a == tuple(0, 0, W, H),
           "r=" .. r .. ": an oversized rect clips to the whole panel", a)

    -- Pixel memory: paint a logical rect, then read its physical corners
    -- (inside) and the pixels one step outside each edge.
    local x, y, w, h = 200, 300, 37, 53
    bb:paintRect(x, y, w, h, BB.COLOR_BLACK)
    local px, py, pw, ph = G.rect_to_physical(r, W, H, x, y, w, h)
    local function at(qx, qy) return bb:getPixelP(qx, qy)[0].a end
    local inside = at(px, py) == 0 and at(px + pw - 1, py) == 0
        and at(px, py + ph - 1) == 0 and at(px + pw - 1, py + ph - 1) == 0
    local outside = at(px - 1, py) == 255 and at(px + pw, py) == 255
        and at(px, py - 1) == 255 and at(px, py + ph) == 255
    report(inside and outside,
           "r=" .. r .. ": logical paintRect fills exactly the physical rect",
           tuple(px, py, pw, ph))
    bb:free()
end

------------------------------------------------------------------------
-- 4. Deltas.
------------------------------------------------------------------------

for r = 0, 3 do
    local bb = new_bb(r)
    local lw, lh = G.logical_size(r, W, H)
    local bad
    for _ = 1, N_POINTS do
        local l1x, l1y, l2x, l2y = rnd(lw), rnd(lh), rnd(lw), rnd(lh)
        local p1x, p1y = bb:getPhysicalCoordinates(l1x, l1y)
        local p2x, p2y = bb:getPhysicalCoordinates(l2x, l2y)
        local dx, dy = G.delta_to_logical(r, p2x - p1x, p2y - p1y)
        if not bad and (dx ~= l2x - l1x or dy ~= l2y - l1y) then
            bad = tuple(l1x, l1y, l2x, l2y) .. " -> " .. tuple(dx, dy)
        end
    end
    report(not bad, "r=" .. r .. ": delta_to_logical matches point differences",
           bad or (N_POINTS .. " pairs"))
    bb:free()
end

do
    -- The seeded portrait mode 1: moving toward physical +y is moving
    -- toward logical -x, i.e. a leftward (next-page) swipe.
    local r = G.bb_rotation(1)
    local dx, dy = G.delta_to_logical(r, 0, 300)
    report(dx == -300 and dy == 0,
           "portrait mode 1: physical +y is a logical left swipe",
           tuple(dx, dy))
    local zeros = true
    for q = 0, 3 do
        local zx, zy = G.delta_to_logical(q, 0, 0)
        zeros = zeros and tostring(zx) == "0" and tostring(zy) == "0"
    end
    report(zeros, "delta_to_logical never yields -0", "")
end

------------------------------------------------------------------------
-- 5. Digitizer to px.
------------------------------------------------------------------------

do
    local cases = {
        { "x axis start", 0, 20966, 1872, 0 },
        { "x axis end is the last pixel", 20966, 20966, 1872, 1871 },
        { "y axis end is the last pixel", 15725, 15725, 1404, 1403 },
        { "x below the axis clamps", -40, 20966, 1872, 0 },
        { "x past the axis clamps", 21500, 20966, 1872, 1871 },
        { "x midpoint stays fractional", 10483, 20966, 1872, 935.5 },
        { "y quarter", 3931.25, 15725, 1404, 350.75 },
        { "zero axis maps to 0", 500, 0, 1872, 0 },
    }
    for _, c in ipairs(cases) do
        local v = G.raw_to_px(c[2], c[3], c[4])
        report(v == c[5], "raw_to_px: " .. c[1],
               tuple(c[2], c[3], c[4]) .. " -> " .. tostring(v))
    end
    local mono, prev = true, -1
    for raw = 0, 20966, 7 do
        local v = G.raw_to_px(raw, 20966, 1872)
        if v < prev then mono = false end
        prev = v
    end
    report(mono, "raw_to_px is monotonic over the x axis", "")

    -- Every integer on both axes lands on a pixel, and only the axis end
    -- reaches the last one.
    local inside = true
    for raw = 0, 20966 do
        local v = G.raw_to_px(raw, 20966, 1872)
        if v < 0 or v > 1871 or (raw < 20966 and v >= 1871) then inside = false end
    end
    for raw = 0, 15725 do
        local v = G.raw_to_px(raw, 15725, 1404)
        if v < 0 or v > 1403 or (raw < 15725 and v >= 1403) then inside = false end
    end
    report(inside, "raw_to_px: every axis value lands on the panel, the end alone on the last pixel", "")
    report(G.raw_to_px(500, -1, 1872) == 0, "raw_to_px: a negative axis maps to 0", "")
end

------------------------------------------------------------------------
-- 6. Edges: the far pixel, zero extents, rotation 1 against 3, bad r.
------------------------------------------------------------------------

for r = 0, 3 do
    local bb = new_bb(r)
    local lw, lh = G.logical_size(r, W, H)

    -- The last logical pixel is inside and one past it is not.
    local cases = {
        { lw - 1, lh - 1, 1, 1 }, { lw - 1, 0, 5, 1 }, { 0, lh - 1, 1, 5 },
        { lw - 2, lh - 2, 2, 2 }, { lw - 1, lh - 1, 300, 300 },
        { 5, 5, -10, 3 },
    }
    local bad
    for _, c in ipairs(cases) do
        local x, y, w, h = c[1], c[2], c[3], c[4]
        if w < 0 then x, w = x + w, -w end
        local a = tuple(G.rect_to_physical(r, W, H, c[1], c[2], c[3], c[4]))
        local b = tuple(bb:getPhysicalRect(bb:getBoundedRect(x, y, w, h)))
        if not bad and a ~= b then
            bad = tuple(c[1], c[2], c[3], c[4]) .. " -> " .. a .. " bb " .. b
        end
    end
    report(not bad, "r=" .. r .. ": far-edge rects match getBoundedRect",
           bad or (#cases .. " rects"))

    -- A 1x1 logical rect is the pixel to_physical names.
    local bad_pt
    for _ = 1, 500 do
        local lx, ly = rnd(lw), rnd(lh)
        local px, py = G.to_physical(r, W, H, lx, ly)
        local a = tuple(G.rect_to_physical(r, W, H, lx, ly, 1, 1))
        if not bad_pt and a ~= tuple(px, py, 1, 1) then
            bad_pt = tuple(lx, ly) .. " -> " .. a .. " vs " .. tuple(px, py)
        end
    end
    report(not bad_pt, "r=" .. r .. ": a 1x1 rect is the to_physical pixel",
           bad_pt or "500 pixels")

    -- A zero extent has no area, even at a fractional origin where
    -- outward rounding would otherwise widen it to a pixel.  KOReader's
    -- getBoundedRect agrees.
    local z = tuple(G.rect_to_physical(r, W, H, 10.5, 10, 0, 5))
        .. tuple(G.rect_to_physical(r, W, H, 10, 10.5, 5, 0))
        .. tuple(G.rect_to_physical(r, W, H, 10.5, 10.5, -0, 3))
    local _, _, bw = bb:getBoundedRect(10.5, 10, 0, 5)
    report(z == string.rep("(0,0,0,0)", 3) and bw == 0,
           "r=" .. r .. ": zero extents at fractional origins are empty", z)

    local a = tuple(G.rect_to_physical(r, W, H, -0.5, -0.5, 1, 1))
    report(a == tuple(bb:getPhysicalRect(0, 0, 1, 1)),
           "r=" .. r .. ": a fractional rect over the corner covers its pixel", a)

    -- Float deltas: quarter px are exact in binary, so the rotated delta
    -- must equal the difference of the converted points exactly.
    local bad_d
    for _ = 1, 500 do
        local p1x, p1y = rnd(W * 4) / 4, rnd(H * 4) / 4
        local p2x, p2y = rnd(W * 4) / 4, rnd(H * 4) / 4
        local l1x, l1y = G.to_logical(r, W, H, p1x, p1y)
        local l2x, l2y = G.to_logical(r, W, H, p2x, p2y)
        local dx, dy = G.delta_to_logical(r, p2x - p1x, p2y - p1y)
        if not bad_d and (dx ~= l2x - l1x or dy ~= l2y - l1y) then
            bad_d = tuple(p1x, p1y, p2x, p2y) .. " -> " .. tuple(dx, dy)
        end
    end
    report(not bad_d, "r=" .. r .. ": delta_to_logical is exact on float points",
           bad_d or "500 pairs")
    bb:free()
end

do
    -- Rotation 1 and rotation 3 are opposite quarter turns: the same
    -- logical point and the same physical swipe land differently.
    local a = tuple(G.to_physical(1, W, H, 100, 200))
    local b = tuple(G.to_physical(3, W, H, 100, 200))
    report(a == "(1671,100)" and b == "(200,1303)",
           "r=1 and r=3 put a logical point in different places", a .. " vs " .. b)
    local m1 = tuple(G.delta_to_logical(G.bb_rotation(1), 0, 300))
    local m3 = tuple(G.delta_to_logical(G.bb_rotation(3), 0, 300))
    report(m1 == "(-300,0)" and m3 == "(300,0)",
           "modes 1 and 3 read one physical swipe as opposite page turns",
           m1 .. " vs " .. m3)

    -- A rotation outside 0..3 is a caller bug wherever it arrives, even
    -- for a rect that would clip to nothing.
    local calls = {
        { "logical_size", function(q) return G.logical_size(q, W, H) end },
        { "to_physical", function(q) return G.to_physical(q, W, H, 0, 0) end },
        { "to_logical", function(q) return G.to_logical(q, W, H, 0, 0) end },
        { "rect_to_physical", function(q) return G.rect_to_physical(q, W, H, 5, 5, 5, 5) end },
        { "rect_to_physical off screen",
          function(q) return G.rect_to_physical(q, W, H, -50, 10, 50, 10) end },
        { "delta_to_logical", function(q) return G.delta_to_logical(q, 1, 1) end },
    }
    local missed
    for _, c in ipairs(calls) do
        for _, q in ipairs({ 4, -1, 1.5 }) do
            local ok, err = pcall(c[2], q)
            if not missed and (ok or not tostring(err):find("rotation must be 0..3", 1, true)) then
                missed = c[1] .. "(" .. q .. ")"
            end
        end
    end
    report(not missed, "every conversion rejects a rotation outside 0..3",
           missed or (#calls .. " functions x 3 rotations"))
end

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
