--[[--
Host checks for the notebook's brush module (nb_brush.lua).

nb_brush is pure, so everything here runs on the bundle's luajit with no
KOReader modules:

 0. loading: no globals, and no require, ffi, io or os in the source;
 1. styles: the six brushes and the eraser at S/M/L, their recorded
    fields, the 0.01 quantization the journal's integer "st" array needs,
    and the fallbacks for unknown ids;
 2. pressure: radius and density are monotonic, bounded and hit their
    ends at plo/phi;
 3. masks: the 4x4 Bayer levels (exact counts, nesting, period) and the
    checker;
 4. the capsule rasterizer against a per-pixel reference, over seeded
    random segments on the real panel and on a 40x30 panel where most of
    them cross all four edges, zero-length and fully off-panel ones
    included: coverage, clipping, one emit per row, a <-> b symmetry,
    tangents a hair off horizontal on integer rows, exact row counts for
    hand-computed shapes, render()'s order and density argument, and
    bbox() against the rendered ink;
 5. the stroke-erase hit test, on hand cases and against a sampled
    reference;
 6. edges: pixel centres exactly on a boundary, the last row and column,
    huge and sub-floor radii, zero-length flicks with a pressure change,
    the radius floor, masks at negative coordinates, and hits on the
    flank of a taper, where it has to search.

The reference: a pixel is inside when some point c(t) of the segment has
|q - c(t)| <= r(t), r interpolated along it.  That is the union of the
swept discs, i.e. the hull of the end discs.  The literal "distance to
the segment <= radius at the projection" reading is not convex for a
tapered segment and does not even contain the fat end's disc, so it is
checked only on constant-radius segments, where the two agree.

NOT covered here: the glue's fills and per-pixel masking into a
Blitbuffer (test-notebook-render.lua), and how the brushes feel on glass.

Usage: luajit test-notebook-brush.lua <koreader_dir> <plugin_dir> [--bench]
  --bench prints microseconds per segment_spans call to stderr; stdout
  stays byte-deterministic.
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to notebook.koplugin")
local want_bench = arg[3] == "--bench"

package.path = table.concat({
    plugin_dir .. "/?.lua",
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")

local fail = 0
local function report(ok, label, msg)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label,
                        msg or ""))
    if not ok then fail = fail + 1 end
end

local floor, sqrt, abs = math.floor, math.sqrt, math.abs
local min, max = math.min, math.max

-- Park-Miller minimal standard: exact in doubles, the same sequence on
-- every run and every luajit.
local seed = 20260926
local function rnd()
    seed = (seed * 16807) % 2147483647
    return seed / 2147483647
end
local function uniform(lo, hi) return lo + (hi - lo) * rnd() end

------------------------------------------------------------------------
-- 0. Loading: pure, no globals.
------------------------------------------------------------------------

local globals_before = {}
for k in pairs(_G) do globals_before[k] = true end
local cfg = require("nb_config")
local Brush = require("nb_brush")
local leaked = {}
for k in pairs(_G) do
    if not globals_before[k] then leaked[#leaked + 1] = tostring(k) end
end
table.sort(leaked)
report(#leaked == 0, "loading nb_brush defines no globals",
       table.concat(leaked, ","))

local src = assert(io.open(plugin_dir .. "/nb_brush.lua")):read("*a")
local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
report(not code:find("%f[%w_]require%f[^%w_]")
       and not code:find("%f[%w_]ffi%f[^%w_]")
       and not code:find("%f[%w_]io%.") and not code:find("%f[%w_]os%."),
       "nb_brush.lua requires nothing and touches no ffi, io or os", "")

local W, H = cfg.W, cfg.H
local PX_PER_MM = cfg.dpi / 25.4

------------------------------------------------------------------------
-- 1. Styles.
------------------------------------------------------------------------

local ids = table.concat(Brush.IDS, ",")
report(ids == "fine,ballpoint,brushpen,marker,pencil,highlighter",
       "Brush.IDS order", ids)

local STYLE_KEYS = { "brush", "size", "tool", "rmin", "rmax", "gamma",
                     "plo", "phi", "comp", "pat", "dlo", "dhi" }
local function style_shape_ok(st)
    local n = 0
    for _ in pairs(st) do n = n + 1 end
    if n ~= #STYLE_KEYS then return false, "key count " .. n end
    for _, k in ipairs(STYLE_KEYS) do
        local v = st[k]
        if type(v) == "string" then
            if not v:match("^[A-Za-z0-9_.-]+$") then return false, k end
        elseif type(v) == "number" then
            if k == "plo" or k == "phi" then
                if v ~= floor(v) then return false, k .. " not integer" end
            elseif floor(v * 100 + 0.5) / 100 ~= v then
                -- the journal stores v*100 rounded; decoding must give v
                return false, k .. " not a multiple of 0.01"
            end
        else
            return false, k .. " is " .. type(v)
        end
    end
    return true, ""
end

local SIZES = { "S", "M", "L" }
local all_styles = {}
for _, id in ipairs(Brush.IDS) do
    for _, sz in ipairs(SIZES) do
        local st = Brush.style(id, sz, "pen", cfg)
        all_styles[#all_styles + 1] = st
        local ok, why = style_shape_ok(st)
        report(ok and st.brush == id and st.size == sz and st.tool == "pen",
               "style " .. id .. "/" .. sz .. " is flat and journal-exact", why)
    end
end
local eraser = Brush.style("fine", "M", "eraser", cfg)
all_styles[#all_styles + 1] = eraser
do
    local ok, why = style_shape_ok(eraser)
    report(ok, "eraser style is flat and journal-exact", why)
end

-- The M styles as widths, for the reader of this log.
for _, id in ipairs(Brush.IDS) do
    local st = Brush.style(id, "M", "pen", cfg)
    report(true, "style " .. id .. "/M", string.format(
        "r %.2f..%.2f px = %.2f..%.2f mm wide, gamma %.2f, %s/%s, dens %.2f..%.2f",
        st.rmin, st.rmax, 2 * st.rmin / PX_PER_MM, 2 * st.rmax / PX_PER_MM,
        st.gamma, st.comp, st.pat, st.dlo, st.dhi))
end

-- Widths the task asked for, as ranges in mm (size M).
local WANT = {
    fine        = { 0.25, 0.35, 0.25, 0.35, "black", "solid" },
    ballpoint   = { 0.25, 0.35, 0.65, 0.75, "black", "solid" },
    brushpen    = { 0.35, 0.45, 2.9, 3.1, "black", "solid" },
    marker      = { 1.9, 2.1, 1.9, 2.1, "black", "solid" },
    pencil      = { 0.25, 0.35, 0.55, 0.65, "darken", "bayer4" },
    highlighter = { 4.9, 5.1, 4.9, 5.1, "darken", "checker" },
}
for _, id in ipairs(Brush.IDS) do
    local st, w = Brush.style(id, "M", "pen", cfg), WANT[id]
    local lo, hi = 2 * st.rmin / PX_PER_MM, 2 * st.rmax / PX_PER_MM
    report(lo >= w[1] and lo <= w[2] and hi >= w[3] and hi <= w[4]
           and st.comp == w[5] and st.pat == w[6],
           "brush " .. id .. " matches its brief",
           string.format("%.2f..%.2f mm %s/%s", lo, hi, st.comp, st.pat))
end
report(Brush.style("pencil", "M", "pen", cfg).dlo == 0.3
       and Brush.style("pencil", "M", "pen", cfg).dhi == 1,
       "pencil density runs 0.3..1.0", "")
report(eraser.comp == "white" and eraser.pat == "solid"
       and eraser.rmin == 12 and eraser.rmax == 24
       and eraser.plo == cfg.rubber_p_lo and eraser.phi == cfg.rubber_p_hi,
       "eraser: white, solid, 12..24 px over the rubber pressure window",
       string.format("%.2f..%.2f over %d..%d", eraser.rmin, eraser.rmax,
                     eraser.plo, eraser.phi))
do
    local s, l = Brush.style("marker", "S", "eraser", cfg),
                 Brush.style("marker", "L", "eraser", cfg)
    report(s.rmin == l.rmin and s.rmax == l.rmax,
           "eraser radius ignores the size setting", "")
end

for _, id in ipairs(Brush.IDS) do
    local s = Brush.style(id, "S", "pen", cfg)
    local m = Brush.style(id, "M", "pen", cfg)
    local l = Brush.style(id, "L", "pen", cfg)
    report(s.rmax < m.rmax and m.rmax < l.rmax and s.rmin <= m.rmin
           and m.rmin < l.rmin and s.rmin >= 0.75,
           "sizes order S < M < L for " .. id,
           string.format("rmax %.2f %.2f %.2f", s.rmax, m.rmax, l.rmax))
end

do
    local over = setmetatable({ size_mult = { S = 0.5, M = 1, L = 2 } },
                              { __index = cfg })
    local st = Brush.style("marker", "L", "pen", over)
    report(st.rmin == 17.9, "cfg.size_mult overrides the local multipliers",
           string.format("%.2f", st.rmin))
end

do
    local st = Brush.style("crayon", "XL", "quill", cfg)
    report(st.brush == "fine" and st.size == "M" and st.tool == "pen",
           "unknown brush, size and tool fall back to fine/M/pen",
           st.brush .. "/" .. st.size .. "/" .. st.tool)
end

------------------------------------------------------------------------
-- 2. Pressure curves.
------------------------------------------------------------------------

for _, st in ipairs(all_styles) do
    local label = st.brush .. "/" .. st.size .. "/" .. st.tool
    local ok, why = true, ""
    local prev_r, prev_d = -1, -1
    for p = 0, 4200 do
        local r, d = Brush.radius(st, p), Brush.density(st, p)
        if r < prev_r or d < prev_d then
            ok, why = false, "decreases at p=" .. p
            break
        end
        if r < st.rmin or r > st.rmax or d < st.dlo or d > st.dhi then
            ok, why = false, "out of range at p=" .. p
            break
        end
        prev_r, prev_d = r, d
    end
    report(ok, "radius and density monotonic and bounded: " .. label, why)
    report(Brush.radius(st, st.plo) == st.rmin
           and Brush.radius(st, st.phi) == st.rmax
           and Brush.radius(st, -50) == st.rmin
           and Brush.radius(st, 99999) == st.rmax
           and Brush.density(st, st.phi) == st.dhi,
           "radius hits rmin at/below plo and rmax at/above phi: " .. label, "")
end
for _, id in ipairs({ "fine", "marker", "highlighter" }) do
    local st = Brush.style(id, "M", "pen", cfg)
    report(st.rmin == st.rmax and Brush.radius(st, 0) == st.rmin
           and Brush.radius(st, 2716) == st.rmin,
           "constant brush ignores pressure: " .. id, "")
end
do
    -- median contact pressure from the 2026-09-26 captures
    local bp = Brush.style("brushpen", "M", "pen", cfg)
    local w = 2 * Brush.radius(bp, 2716) / PX_PER_MM
    report(w > 1.2 and w < 1.8, "brushpen at median pressure draws ~1.5 mm",
           string.format("%.2f mm", w))
    local pc = Brush.style("pencil", "M", "pen", cfg)
    report(abs(Brush.density(pc, 100) - 0.3) < 1e-12
           and Brush.density(pc, 4095) == 1,
           "pencil density: 0.3 at plo, 1.0 at phi", "")
end
do
    -- Ballpoint M, the default brush, at the median contact pressure: the
    -- operator judged the ink against scribble.lua's radius-2 square
    -- brush, 5 px (~0.56 mm).  Rasterized, not just 2r: a horizontal
    -- segment on a pixel row inks 2 * floor(r) + 1 rows.
    local bp = Brush.style("ballpoint", "M", "pen", cfg)
    local r = Brush.radius(bp, 2716)
    local rows = {}
    Brush.segment_spans(bp, { x = 100, y = 50, p = 2716 }, { x = 200, y = 50, p = 2716 },
                        400, 100, function(y, x0, x1)
                            if x0 <= 150 and x1 >= 150 then rows[#rows + 1] = y end
                        end)
    local mm = #rows / PX_PER_MM
    report(#rows == 5 and mm > 0.5 and mm < 0.6 and abs(2 * r / PX_PER_MM - 0.55) < 0.03,
           "ballpoint M at median pressure (2716) draws 5 px, ~0.56 mm, as the 2026-09-26"
           .. " scribble brush did", string.format("r %.3f px, %d rows = %.2f mm", r,
                                                  #rows, mm))
    -- And the pressure range around it: the lightest contact the pen window
    -- admits (pen_p_lo, 100) draws 3 px, a saturated one (4095) 7 px, so
    -- pressure moves the default line by a pixel either side of the median
    -- on each edge.  Below the window clamps to the lightest.
    local function rows_at(p)
        local n = 0
        Brush.segment_spans(bp, { x = 100, y = 50, p = p }, { x = 200, y = 50, p = p },
                            400, 100, function(_, x0, x1)
                                if x0 <= 150 and x1 >= 150 then n = n + 1 end
                            end)
        return n
    end
    local lo, hi, below = rows_at(100), rows_at(4095), rows_at(20)
    report(lo == 3 and hi == 7 and below == 3,
           "ballpoint M: 3 px at pressure 100, 7 px at 4095, and clamped below the window",
           string.format("%d / %d / %d rows", lo, hi, below))
end

------------------------------------------------------------------------
-- 3. Masks.
------------------------------------------------------------------------

local bayer = Brush.style("pencil", "M", "pen", cfg)
local fine_m = Brush.style("fine", "M", "pen", cfg)
do
    local ok, why = true, ""
    for n = 0, 16 do
        local d = n / 16
        -- every 4x4 tile holds exactly n dots, at several tile offsets
        for _, off in ipairs({ { 0, 0 }, { 4, 8 }, { 1868, 1400 } }) do
            local count = 0
            for y = off[2], off[2] + 3 do
                for x = off[1], off[1] + 3 do
                    if Brush.mask(bayer, d, x, y) then count = count + 1 end
                end
            end
            if count ~= n then
                ok, why = false, string.format("level %d tile %d,%d has %d",
                                               n, off[1], off[2], count)
            end
        end
        -- levels nest: a darker level keeps every dot of a lighter one
        if n < 16 then
            for y = 0, 3 do
                for x = 0, 3 do
                    if Brush.mask(bayer, d, x, y)
                       and not Brush.mask(bayer, (n + 1) / 16, x, y) then
                        ok, why = false, "level " .. n .. " not nested"
                    end
                end
            end
        end
    end
    report(ok, "bayer4: level n/16 inks exactly n of 16, levels nest", why)
end
do
    local rows = {}
    for y = 0, 3 do
        local t = {}
        for x = 0, 3 do
            t[#t + 1] = Brush.mask(bayer, 5 / 16, x, y) and "#" or "."
        end
        rows[#rows + 1] = table.concat(t)
    end
    local got = table.concat(rows, "/")
    report(got == "#.#./.#../#.#./....", "bayer4 at 5/16 is the standard matrix",
           got)
end
do
    local ok = true
    for y = 0, 40 do
        for x = 0, 40 do
            local d = ((x * 7 + y * 3) % 17) / 16
            if Brush.mask(bayer, d, x, y) ~= Brush.mask(bayer, d, x + 4, y)
               or Brush.mask(bayer, d, x, y) ~= Brush.mask(bayer, d, x, y + 8)
            then
                ok = false
            end
        end
    end
    report(ok, "bayer4 is periodic in 4 on both axes", "")
    local none, all = 0, 0
    for y = 0, 3 do
        for x = 0, 3 do
            if Brush.mask(bayer, 0, x, y) then none = none + 1 end
            if Brush.mask(bayer, 0.97, x, y) then all = all + 1 end
        end
    end
    report(none == 0 and all == 16,
           "bayer4: density 0 inks nothing, >= 31/32 inks all 16",
           none .. " " .. all)
end
do
    local hl = Brush.style("highlighter", "M", "pen", cfg)
    local fine = Brush.style("fine", "M", "pen", cfg)
    local ok, count = true, 0
    for y = 0, 31 do
        for x = 0, 31 do
            local m = Brush.mask(hl, 0.5, x, y)
            if m ~= ((x + y) % 2 == 0) then ok = false end
            if m then count = count + 1 end
            if not Brush.mask(fine, nil, x, y) then ok = false end
        end
    end
    report(ok and count == 512,
           "checker is (x+y)%2==0 (half the pixels); solid inks everything",
           tostring(count))
end

------------------------------------------------------------------------
-- 4. The rasterizer against a per-pixel reference.
------------------------------------------------------------------------

-- Signed gap from q to the swept shape, from the stationary point of
-- f(t) = |q - a - t*d| - ra - t*dr on t in [0, 1] (f is convex).
local function ref_gap(qx, qy, ax, ay, ra, bx, by, rb)
    local dx, dy = bx - ax, by - ay
    local L2 = dx * dx + dy * dy
    if L2 == 0 then
        return sqrt((qx - ax) ^ 2 + (qy - ay) ^ 2) - max(ra, rb)
    end
    local L = sqrt(L2)
    local along = ((qx - ax) * dx + (qy - ay) * dy) / L
    local across = abs((qx - ax) * dy - (qy - ay) * dx) / L
    local k = (rb - ra) / L
    local t
    if k >= 1 then
        t = 1
    elseif k <= -1 then
        t = 0
    else
        t = (along + k * across / sqrt(1 - k * k)) / L
        t = min(1, max(0, t))
    end
    local cx, cy = ax + t * dx, ay + t * dy
    return sqrt((qx - cx) ^ 2 + (qy - cy) ^ 2) - (ra + t * (rb - ra))
end

-- The literal reading: radius at the clamped projection.
local function proj_gap(qx, qy, ax, ay, ra, bx, by, rb)
    local dx, dy = bx - ax, by - ay
    local L2 = dx * dx + dy * dy
    local t = L2 > 0 and min(1, max(0, ((qx - ax) * dx + (qy - ay) * dy) / L2))
              or 0
    local cx, cy = ax + t * dx, ay + t * dy
    return sqrt((qx - cx) ^ 2 + (qy - cy) ^ 2) - (ra + t * (rb - ra))
end

-- Check the closed form against a golden-section search of the same
-- convex f, so the reference below does not rest on algebra alone.
do
    local worst = 0
    for _ = 1, 3000 do
        local ax, ay, bx, by = uniform(0, 60), uniform(0, 60),
                               uniform(0, 60), uniform(0, 60)
        if rnd() < 0.1 then bx, by = ax, ay end
        local ra, rb = uniform(0.5, 30), uniform(0.5, 30)
        local qx, qy = uniform(-40, 100), uniform(-40, 100)
        local function f(t)
            local cx, cy = ax + t * (bx - ax), ay + t * (by - ay)
            return sqrt((qx - cx) ^ 2 + (qy - cy) ^ 2) - (ra + t * (rb - ra))
        end
        local lo, hi = 0, 1
        local g = (sqrt(5) - 1) / 2
        for _ = 1, 80 do
            local m1, m2 = hi - g * (hi - lo), lo + g * (hi - lo)
            if f(m1) < f(m2) then hi = m2 else lo = m1 end
        end
        local search = min(f(0), f(1), f((lo + hi) / 2))
        worst = max(worst, abs(search - ref_gap(qx, qy, ax, ay, ra, bx, by, rb)))
    end
    report(worst < 1e-6, "reference closed form agrees with a golden search",
           "3000 random points")
end

-- A style whose radius is its pressure, exactly: over a power-of-two
-- window, r = 1024 * (p / 1024) = p with no rounding.
local geo = { brush = "t", size = "M", tool = "pen", rmin = 0, rmax = 1024,
              gamma = 1, plo = 0, phi = 1024, comp = "black", pat = "solid",
              dlo = 1, dhi = 1 }
local function p_for(r) return r end

-- Rasterize one segment into a table grid, checking the emit contract.
-- Returns rows (y -> {x0, x1}), emit count, contract violations.
local function raster(style, a, b, pw, ph)
    local rows, emits, bad = {}, 0, nil
    local function emit(y, x0, x1)
        emits = emits + 1
        if y ~= floor(y) or x0 ~= floor(x0) or x1 ~= floor(x1) then
            bad = bad or string.format("non-integer span %s %s %s", y, x0, x1)
        elseif y < 0 or y > ph - 1 or x0 < 0 or x1 > pw - 1 or x0 > x1 then
            bad = bad or string.format("span outside panel y=%d %d..%d",
                                       y, x0, x1)
        elseif rows[y] then
            bad = bad or ("row emitted twice: " .. y)
        elseif 1 / y < 0 or 1 / x0 < 0 or 1 / x1 < 0 then
            bad = bad or ("negative zero in span at row " .. y)
        end
        rows[y] = { x0, x1 }
    end
    if b then
        Brush.segment_spans(style, a, b, pw, ph, emit)
    else
        Brush.dot_spans(style, a, pw, ph, emit)
    end
    return rows, emits, bad
end

-- Compare one segment's grid with the reference over the pixels the
-- shape can reach.  Returns counts: checked, beyond tolerance, beyond 1e-6.
local function compare(rows, ax, ay, ra, bx, by, rb, pw, ph, gapf)
    local checked, tol, strict = 0, 0, 0
    local x0 = max(0, floor(min(ax - ra, bx - rb)) - 1)
    local x1 = min(pw - 1, floor(max(ax + ra, bx + rb)) + 2)
    local y0 = max(0, floor(min(ay - ra, by - rb)) - 1)
    local y1 = min(ph - 1, floor(max(ay + ra, by + rb)) + 2)
    for y = y0, y1 do
        local span = rows[y]
        for x = x0, x1 do
            local painted = span and x >= span[1] and x <= span[2] or false
            local g = gapf(x, y, ax, ay, ra, bx, by, rb)
            checked = checked + 1
            if painted ~= (g <= 0) then
                if abs(g) > 1 then tol = tol + 1 end
                if abs(g) > 1e-6 then strict = strict + 1 end
            end
        end
    end
    -- Nothing may be painted outside the window either.
    for y, span in pairs(rows) do
        if y < y0 or y > y1 or span[1] < x0 or span[2] > x1 then
            tol, strict = tol + 1, strict + 1
        end
    end
    return checked, tol, strict
end

local function random_segment(pw, ph, margin, rmax, travel_max)
    local ax, ay = uniform(-margin, pw - 1 + margin),
                   uniform(-margin, ph - 1 + margin)
    local ra, rb = uniform(0.75, rmax), uniform(0.75, rmax)
    local roll = rnd()
    local bx, by
    if roll < 0.12 then
        bx, by = ax, ay                         -- zero length
    else
        local ang, len = uniform(0, 2 * math.pi), uniform(0, travel_max)
        bx, by = ax + len * math.cos(ang), ay + len * math.sin(ang)
    end
    if roll > 0.88 then rb = ra end             -- constant width
    return { x = ax, y = ay, p = p_for(ra) }, { x = bx, y = by, p = p_for(rb) }
end

local function run_random(label, n, pw, ph, margin, rmax, travel_max)
    local checked, tol, strict, emits, bad = 0, 0, 0, 0, nil
    local zero, sym_bad, emit_rows_bad = 0, 0, 0
    for _ = 1, n do
        local a, b = random_segment(pw, ph, margin, rmax, travel_max)
        if a.x == b.x and a.y == b.y then zero = zero + 1 end
        local ra, rb = Brush.radius(geo, a.p), Brush.radius(geo, b.p)
        local rows, e, why = raster(geo, a, b, pw, ph)
        bad = bad or why
        emits = emits + e
        local c, t, s = compare(rows, a.x, a.y, ra, b.x, b.y, rb, pw, ph,
                                ref_gap)
        checked, tol, strict = checked + c, tol + t, strict + s
        -- one emit per row that has ink, never an empty one
        local nrows = 0
        for _ in pairs(rows) do nrows = nrows + 1 end
        if nrows ~= e then emit_rows_bad = emit_rows_bad + 1 end
        -- the hull of (a, b) is the hull of (b, a)
        local back = raster(geo, b, a, pw, ph)
        for y, span in pairs(rows) do
            local o = back[y]
            if not o or o[1] ~= span[1] or o[2] ~= span[2] then
                sym_bad = sym_bad + 1
            end
        end
        for y in pairs(back) do
            if not rows[y] then sym_bad = sym_bad + 1 end
        end
    end
    report(bad == nil, label .. ": every span is integer, clipped to "
           .. (pw - 1) .. "x" .. (ph - 1) .. ", once per row", bad or
           string.format("%d segments, %d zero-length, %d emits", n, zero, emits))
    report(tol == 0, label .. ": coverage matches the reference within +-1 px",
           string.format("%d pixels checked, %d beyond", checked, tol))
    report(strict == 0, label .. ": coverage is exact (beyond 1e-6 px)",
           string.format("%d mismatches", strict))
    report(emit_rows_bad == 0, label .. ": emits equal inked rows",
           tostring(emit_rows_bad))
    report(sym_bad == 0, label .. ": segment a->b inks what b->a inks",
           tostring(sym_bad))
end

-- Real panel, segments near and across the edges; travel up to the
-- measured max per report and beyond.
run_random("panel 1872x1404", 1500, W, H, 40, 30, 60)
-- A 40x30 panel with radii up to 30: most segments cross all four edges.
run_random("panel 40x30", 1500, 40, 30, 20, 30, 70)

-- Constant-width segments against the literal projection reading.
do
    local tol, strict, checked = 0, 0, 0
    for _ = 1, 200 do
        local a, b = random_segment(W, H, 30, 30, 60)
        b.p = a.p
        local r = Brush.radius(geo, a.p)
        local rows = raster(geo, a, b, W, H)
        local c, t, s = compare(rows, a.x, a.y, r, b.x, b.y, r, W, H, proj_gap)
        checked, tol, strict = checked + c, tol + t, strict + s
    end
    report(tol == 0 and strict == 0,
           "constant width: distance-to-segment <= r reference, exact",
           string.format("%d pixels checked", checked))
end

-- Near-degenerate tangents: a segment within 1e-9 px of horizontal (or
-- vertical) whose tangent sits a hair off an integer row.  A slope of
-- ~1e11 must never be extrapolated onto a row outside its extent.
do
    local tol, strict, checked = 0, 0, 0
    local offs = { 0, 1e-12, -1e-12, 1e-10, -1e-10, 3e-10, -3e-10, 1e-9 }
    for i = 1, #offs do
        for j = 1, #offs do
            for _, r in ipairs({ 5, 5 + 2e-10, 4.5 }) do
                for _, dir in ipairs({ "h", "v" }) do
                    local a, b
                    if dir == "h" then
                        a = { x = 100, y = 200 + offs[i], p = r }
                        b = { x = 120, y = 200 + offs[j], p = 5 }
                    else
                        a = { x = 200 + offs[i], y = 100, p = r }
                        b = { x = 200 + offs[j], y = 120, p = 5 }
                    end
                    local rows = raster(geo, a, b, W, H)
                    local c, t, s2 = compare(rows, a.x, a.y, r, b.x, b.y, 5,
                                             W, H, ref_gap)
                    checked, tol, strict = checked + c, tol + t, strict + s2
                end
            end
        end
    end
    report(tol == 0 and strict == 0,
           "near-horizontal/vertical tangents on integer rows stay exact",
           string.format("%d pixels checked, %d beyond 1 px, %d beyond 1e-6",
                         checked, tol, strict))
end

-- Hand-computed shapes: exact rows and emit counts.
local function shape(label, a, b, pw, ph, want_rows, want_first, want_last)
    local rows, e, why = raster(geo, a, b, pw, ph)
    local ys = {}
    for y in pairs(rows) do ys[#ys + 1] = y end
    table.sort(ys)
    local first, last = rows[ys[1] or -1], rows[ys[#ys] or -1]
    local got = string.format("%d emits, rows %s..%s, first %s, last %s", e,
        tostring(ys[1]), tostring(ys[#ys]),
        first and (first[1] .. "-" .. first[2]) or "-",
        last and (last[1] .. "-" .. last[2]) or "-")
    local want = string.format("%d emits, rows %s..%s, first %s, last %s",
        want_rows[3], tostring(want_rows[1]), tostring(want_rows[2]),
        want_first, want_last)
    report(why == nil and got == want, label, got)
end
local function pt(x, y, r) return { x = x, y = y, p = p_for(r) } end
do
    local ok = true
    for r = 0.75, 30, 0.37 do
        if Brush.radius(geo, p_for(r)) ~= r then ok = false end
    end
    report(ok, "the test style's radius equals its pressure exactly", "")
end
shape("horizontal r=5 capsule: 11 rows", pt(100, 100, 5), pt(120, 100, 5),
      W, H, { 95, 105, 11 }, "100-120", "100-120")
shape("vertical r=5 capsule 100..140: 51 rows", pt(300, 100, 5),
      pt(300, 140, 5), W, H, { 95, 145, 51 }, "300-300", "300-300")
shape("r=2 dot at an integer centre: 5 rows", pt(50, 50, 2), nil,
      W, H, { 48, 52, 5 }, "50-50", "50-50")
shape("r=2 zero-length segment equals the dot", pt(50, 50, 2), pt(50, 50, 2),
      W, H, { 48, 52, 5 }, "50-50", "50-50")
shape("corner dot r=5 at (0,0): clipped to 6 rows", pt(0, 0, 5), nil,
      W, H, { 0, 5, 6 }, "0-5", "0-0")
shape("far corner dot r=5 at (W-1,H-1): 6 rows", pt(W - 1, H - 1, 5), nil,
      W, H, { H - 6, H - 1, 6 }, "1871-1871", (W - 6) .. "-1871")
shape("capsule across a 40x30 panel covers every pixel", pt(-10, 15, 20),
      pt(50, 15, 20), 40, 30, { 0, 29, 30 }, "0-39", "0-39")
shape("segment fully left of the panel emits nothing", pt(-80, 500, 20),
      pt(-40, 520, 20), W, H, { nil, nil, 0 }, "-", "-")
shape("segment fully below the panel emits nothing", pt(900, H + 40, 20),
      pt(950, H + 60, 20), W, H, { nil, nil, 0 }, "-", "-")
shape("tapered, fat end swallows the thin one: the fat disc",
      pt(100, 100, 20), pt(105, 100, 2), W, H, { 80, 120, 41 },
      "100-100", "100-100")

-- render(): the dot, then each segment, in stroke order.
do
    local st = Brush.style("pencil", "M", "pen", cfg)
    local pts = { { x = 10, y = 10, p = 400 }, { x = 14, y = 12, p = 2000 },
                  { x = 20, y = 12, p = 4095 } }
    local got, want = {}, {}
    Brush.render(st, pts, W, H, function(y, x0, x1, d)
        got[#got + 1] = string.format("%d:%d-%d@%.4f", y, x0, x1, d)
    end)
    local function rec(y, x0, x1, d)
        want[#want + 1] = string.format("%d:%d-%d@%.4f", y, x0, x1, d)
    end
    Brush.dot_spans(st, pts[1], W, H, rec)
    Brush.segment_spans(st, pts[1], pts[2], W, H, rec)
    Brush.segment_spans(st, pts[2], pts[3], W, H, rec)
    report(table.concat(got, " ") == table.concat(want, " ") and #got > 0,
           "render = dot + segments, in order", #got .. " emits")
    local d_ok = true
    Brush.segment_spans(st, pts[1], pts[2], W, H, function(_, _, _, d)
        if d ~= Brush.density(st, pts[2].p) then d_ok = false end
    end)
    Brush.dot_spans(st, pts[1], W, H, function(_, _, _, d)
        if d ~= Brush.density(st, pts[1].p) then d_ok = false end
    end)
    local solid_nil = true
    Brush.render(Brush.style("marker", "M", "pen", cfg), pts, W, H,
                 function(_, _, _, d) if d ~= nil then solid_nil = false end end)
    report(d_ok and solid_nil,
           "emit density: pattern brushes pass density(end p), solid nil", "")
    local n = 0
    Brush.render(st, {}, W, H, function() n = n + 1 end)
    report(n == 0, "render of an empty stroke emits nothing", "")
end

-- bbox(): bounds every pixel render() inks, tightly.
do
    local ok, tight = true, true
    for _ = 1, 100 do
        local st = all_styles[1 + floor(rnd() * #all_styles)]
        local pts = {}
        local x, y = uniform(-20, W + 20), uniform(-20, H + 20)
        for _ = 1, 1 + floor(rnd() * 6) do
            x, y = x + uniform(-15, 15), y + uniform(-15, 15)
            pts[#pts + 1] = { x = x, y = y, p = uniform(0, 4095) }
        end
        local bx0, by0, bx1, by1 = Brush.bbox(st, pts)
        local ix0, iy0, ix1, iy1 = math.huge, math.huge, -math.huge, -math.huge
        -- render on a huge panel after shifting, so nothing clips
        local big = 1e6
        local shifted = {}
        for i, q in ipairs(pts) do
            shifted[i] = { x = q.x + 1000, y = q.y + 1000, p = q.p }
        end
        Brush.render(st, shifted, big, big, function(yy, x0, x1)
            ix0, ix1 = min(ix0, x0 - 1000), max(ix1, x1 - 1000)
            iy0, iy1 = min(iy0, yy - 1000), max(iy1, yy - 1000)
        end)
        if ix0 < bx0 or ix1 > bx1 or iy0 < by0 or iy1 > by1 then ok = false end
        if bx0 < ix0 - 1 or bx1 > ix1 + 1 or by0 < iy0 - 1 or by1 > iy1 + 1 then
            tight = false
        end
    end
    report(ok, "bbox contains every inked pixel", "100 random strokes")
    report(tight, "bbox is within 1 px of the ink", "")
    report(Brush.bbox(eraser, {}) == nil, "bbox of an empty stroke is nil", "")
    -- x - r lands in (-1, 0]: ceil gives -0, which must not reach a record
    local x0, y0 = Brush.bbox(fine_m, { { x = 1.2, y = 0.9, p = 0 } })
    report(x0 == 0 and y0 == 0 and 1 / x0 > 0 and 1 / y0 > 0,
           "bbox never returns negative zero", string.format("%d %d", x0, y0))
end

------------------------------------------------------------------------
-- 5. Stroke-erase hit tests.
------------------------------------------------------------------------

local fine = Brush.style("fine", "M", "pen", cfg)
local line = { { x = 100, y = 100, p = 2000 }, { x = 150, y = 100, p = 2000 },
               { x = 200, y = 100, p = 2000 } }
local function e(x, y) return { x = x, y = y } end
local R = 12
local reach = R + fine.rmin
report(Brush.hits({ e(150, 100 + reach - 0.05) }, R, line, fine),
       "hit: eraser just inside eraser_r + stroke radius", "")
report(not Brush.hits({ e(150, 100 + reach + 0.05) }, R, line, fine),
       "miss: eraser just outside eraser_r + stroke radius", "")
report(Brush.hits({ e(200 + reach - 0.05, 100) }, R, line, fine),
       "hit: past the stroke's end cap", "")
report(not Brush.hits({ e(200 + reach + 0.05, 100) }, R, line, fine),
       "miss: just past the end cap", "")
report(not Brush.hits({ e(1000, 1000) }, R, line, fine),
       "miss: far away (bbox reject)", "")
report(Brush.hits({ e(150, 40), e(150, 160) }, R, line, fine),
       "hit: eraser path crosses the stroke between two reports", "")
report(not Brush.hits({ e(150, 40), e(150, 80) }, R, line, fine),
       "miss: eraser path stops short", "")
report(not Brush.hits({}, R, line, fine) and not Brush.hits({ e(1, 1) }, R, {}, fine),
       "empty eraser path or empty stroke never hits", "")
do
    local dot = { { x = 500, y = 500, p = 2000 } }
    report(Brush.hits({ e(500 + reach - 0.05, 500) }, R, dot, fine)
           and not Brush.hits({ e(500 + reach + 0.05, 500) }, R, dot, fine),
           "one-sample stroke: a dot of the stroke radius", "")
end
do
    -- brushpen: a thin start (p=100 -> rmin) swelling to rmax at phi
    local bp = Brush.style("brushpen", "M", "pen", cfg)
    local taper = { { x = 300, y = 300, p = 100 }, { x = 330, y = 300, p = 4095 } }
    local at_fat = R + bp.rmax
    report(Brush.hits({ e(330, 300 + at_fat - 0.05) }, R, taper, bp)
           and not Brush.hits({ e(330, 300 + at_fat + 0.05) }, R, taper, bp),
           "tapered stroke: the fat end reaches eraser_r + rmax", "")
    -- behind the thin end the hull is the thin disc; alongside it the
    -- outer tangent already leans out toward the fat end
    local at_thin = R + bp.rmin
    report(Brush.hits({ e(300 - at_thin + 0.05, 300) }, R, taper, bp)
           and not Brush.hits({ e(300 - at_thin - 0.05, 300) }, R, taper, bp),
           "tapered stroke: the thin end cap reaches eraser_r + rmin", "")
end
do
    local bx0, by0, bx1, by1 = Brush.bbox(fine, line)
    local probe = { e(150, 100 + reach - 0.05) }
    report(Brush.hits(probe, R, line, fine, { bx0, by0, bx1, by1 }),
           "recorded bb gives the same hit", "")
    report(not Brush.hits(probe, R, line, fine, { 900, 900, 950, 950 }),
           "a bb elsewhere rejects without scanning the points", "")
end

-- Against a sampled reference: the eraser path's points at 1/2000 steps,
-- each with its exact gap to every stroke segment.
do
    local agree, skipped, total = 0, 0, 0
    local disagree = {}
    for case = 1, 300 do
        local st = all_styles[1 + floor(rnd() * #all_styles)]
        local sp = {}
        local x, y = uniform(100, 200), uniform(100, 200)
        for _ = 1, 1 + floor(rnd() * 5) do
            sp[#sp + 1] = { x = x, y = y, p = uniform(0, 4095) }
            x, y = x + uniform(-12, 12), y + uniform(-12, 12)
        end
        local ep = {}
        x, y = uniform(60, 240), uniform(60, 240)
        for _ = 1, 1 + floor(rnd() * 3) do
            ep[#ep + 1] = { x = x, y = y }
            x, y = x + uniform(-30, 30), y + uniform(-30, 30)
        end
        local er = uniform(2, 24)
        local best = math.huge
        for j = 1, math.max(#ep - 1, 1) do
            local e0, e1 = ep[j], ep[j + 1] or ep[j]
            for k = 0, 2000 do
                local u = k / 2000
                local qx = e0.x + (e1.x - e0.x) * u
                local qy = e0.y + (e1.y - e0.y) * u
                for i = 1, math.max(#sp - 1, 1) do
                    local a, b = sp[i], sp[i + 1] or sp[i]
                    best = min(best, ref_gap(qx, qy, a.x, a.y,
                        Brush.radius(st, a.p), b.x, b.y, Brush.radius(st, b.p)))
                end
            end
        end
        total = total + 1
        local margin = best - er
        if abs(margin) < 0.05 then
            skipped = skipped + 1
        elseif Brush.hits(ep, er, sp, st) == (margin <= 0) then
            agree = agree + 1
        else
            disagree[#disagree + 1] = string.format("case %d margin %.3f",
                                                    case, margin)
        end
    end
    report(#disagree == 0, "hits agrees with a sampled reference",
           string.format("%d of %d agree, %d within 0.05 px skipped%s",
                         agree, total, skipped,
                         #disagree > 0 and (": " .. disagree[1]) or ""))
end

------------------------------------------------------------------------
-- 6. Edges: exact boundaries, the panel's last row and column, huge and
--    sub-floor radii, zero-length flicks, and hits on tapered flanks.
------------------------------------------------------------------------

-- Its own generator, so the sections above keep their samples.
local vseed = 4242
local function vrnd()
    vseed = (vseed * 16807) % 2147483647
    return vseed / 2147483647
end
local function vint(lo, hi) return lo + floor((hi - lo + 1) * vrnd()) end
local function vuni(lo, hi) return lo + (hi - lo) * vrnd() end

-- Boundaries a hair off: coordinates and radii in tenths are inexact in
-- binary, so a pixel centre on an exact-decimal boundary lands 1e-15 px
-- either side of it.  EPS must ink it either way.  The 1e-6 exemption in
-- compare() above cannot see this; here a centre within 1e-12 of the
-- boundary must be inked, and nothing past 1e-7 may be.  Radii from 0
-- cover the sub-floor range a style never produces.
do
    local pw, ph = 48, 40
    local on, miss, extra, bbmiss, bad = 0, 0, 0, 0, nil
    for _ = 1, 6000 do
        local a = { x = vint(-80, 520) / 10, y = vint(-80, 440) / 10,
                    p = vint(0, 120) / 10 }
        local b
        local roll = vrnd()
        if roll < 0.1 then
            b = { x = a.x, y = a.y, p = a.p }
        elseif roll < 0.2 then
            b = { x = a.x, y = a.y, p = vint(0, 120) / 10 }
        else
            b = { x = a.x + vint(-200, 200) / 10,
                  y = a.y + vint(-200, 200) / 10,
                  p = vrnd() < 0.5 and a.p or vint(0, 120) / 10 }
        end
        local rows, _, why = raster(geo, a, b, pw, ph)
        local dots, _, why2 = raster(geo, a, nil, pw, ph)
        bad = bad or why or why2
        local bx0, by0, bx1, by1 = Brush.bbox(geo, { a, b })
        for y = 0, ph - 1 do
            local s, d = rows[y], dots[y]
            for x = 0, pw - 1 do
                local g = ref_gap(x, y, a.x, a.y, a.p, b.x, b.y, b.p)
                local gd = sqrt((x - a.x) ^ 2 + (y - a.y) ^ 2) - a.p
                local ps = s and x >= s[1] and x <= s[2] or false
                local pd = d and x >= d[1] and x <= d[2] or false
                if abs(g) <= 1e-9 then on = on + 1 end
                if (not ps and g <= 1e-12) or (not pd and gd <= 1e-12) then
                    miss = miss + 1
                elseif (ps and g > 1e-7) or (pd and gd > 1e-7) then
                    extra = extra + 1
                end
                if (ps or g <= 1e-12)
                   and (x < bx0 or x > bx1 or y < by0 or y > by1) then
                    bbmiss = bbmiss + 1
                end
            end
        end
    end
    report(bad == nil and on > 100 and miss == 0 and extra == 0,
           "tenths grid: a centre on the boundary is inked, none past it",
           bad or string.format("%d centres on a boundary, %d missed, %d extra",
                                on, miss, extra))
    report(bbmiss == 0, "tenths grid: bbox holds every boundary pixel",
           tostring(bbmiss))
end

-- Exact rows for shapes whose boundaries pass through pixel centres.
local function rows_of(a, b, pw, ph, style)
    local out = {}
    local function emit(y, x0, x1)
        out[#out + 1] = y .. ":" .. x0 .. "-" .. x1
    end
    if b then
        Brush.segment_spans(style or geo, a, b, pw, ph, emit)
    else
        Brush.dot_spans(style or geo, a, pw, ph, emit)
    end
    return table.concat(out, " ")
end
do
    local got = rows_of(pt(100, 100, 5), nil, W, H)
    report(got == "95:100-100 96:97-103 97:96-104 98:96-104 99:96-104"
           .. " 100:95-105 101:96-104 102:96-104 103:96-104 104:97-103"
           .. " 105:100-100",
           "r=5 disc inks the 3-4-5 boundary centres", got)
    -- a=(100,100) r=2, b=(110,103) r=5: the outer tangent runs exactly
    -- along y=98, the tangent branch with no slope on a tapered segment
    local a, b = pt(100, 100, 2), pt(110, 103, 5)
    local rows = raster(geo, a, b, W, H)
    local r98 = rows[98] and (rows[98][1] .. "-" .. rows[98][2]) or "-"
    local _, t, s = compare(rows, 100, 100, 2, 110, 103, 5, W, H, ref_gap)
    report(r98 == "100-110" and t == 0 and s == 0,
           "tapered segment with an exactly horizontal tangent row",
           "row 98 " .. r98)
end

-- The last column is W-1 = 1871 and the last row H-1 = 1403; 1872 and
-- 1404 are off the panel.
do
    local cases = {
        { "disc centred on x=1872 inks only column 1871",
          pt(1872, 10, 1), nil, "10:1871-1871" },
        { "r=0.75 disc on the last pixel inks exactly it",
          pt(1871, 1403, 0.75), nil, "1403:1871-1871" },
        { "disc at x=1872.5 r=0.5 inks nothing",
          pt(1872.5, 10, 0.5), nil, "" },
        { "disc at y=1404 r=1 inks only row 1403",
          pt(700, 1404, 1), nil, "1403:700-700" },
        { "segment down column 1871 into row 1404 stops at 1403",
          pt(1871, 1398, 0.75), pt(1871, 1410, 0.75),
          "1398:1871-1871 1399:1871-1871 1400:1871-1871 1401:1871-1871"
          .. " 1402:1871-1871 1403:1871-1871" },
        { "disc at (-0.5,-0.5) r=sqrt(0.5) touches pixel (0,0)",
          pt(-0.5, -0.5, sqrt(0.5)), nil, "0:0-0" },
    }
    for _, c in ipairs(cases) do
        local got = rows_of(c[2], c[3], W, H)
        report(got == c[4], c[1], got)
    end
end

-- Radii far beyond the panel: bounded work, every row full width.
do
    local big = { brush = "t", size = "M", tool = "pen", rmin = 0,
                  rmax = 2 ^ 40, gamma = 1, plo = 0, phi = 2 ^ 40,
                  comp = "black", pat = "solid", dlo = 1, dhi = 1 }
    local ok, why = true, ""
    for _, r in ipairs({ 5000, 1e6, 1e12 }) do
        for _, shape_b in ipairs({ false, "const", "taper" }) do
            local a = { x = 900, y = 700, p = r }
            local b = shape_b and { x = 910, y = 705,
                                    p = shape_b == "const" and r or r - 3 }
            local rows, e, bad = raster(big, a, b or nil, W, H)
            local full = 0
            for y = 0, H - 1 do
                if rows[y] and rows[y][1] == 0 and rows[y][2] == W - 1 then
                    full = full + 1
                end
            end
            if bad or e ~= H or full ~= H then
                ok, why = false, string.format("r=%g %s: %d emits, %d full%s",
                    r, tostring(shape_b), e, full, bad and (" " .. bad) or "")
            end
        end
    end
    report(ok, "huge radii: exactly one full-width span per panel row", why)
end

-- A zero-length flick whose pressure changes is the fatter end's disc,
-- and it carries the density of the newer sample like any segment.
do
    local ok = true
    for _, id in ipairs({ "brushpen", "pencil", "ballpoint" }) do
        local st = Brush.style(id, "L", "pen", cfg)
        for _, pp in ipairs({ { 100, 4095 }, { 4095, 100 }, { 2716, 2716 } }) do
            local a = { x = 300.3, y = 400.7, p = pp[1] }
            local b = { x = 300.3, y = 400.7, p = pp[2] }
            local fat = pp[1] >= pp[2] and a or b
            local want_d = "nil"
            if st.pat ~= "solid" then
                want_d = tostring(Brush.density(st, b.p))
            end
            local seg, dot = {}, {}
            Brush.segment_spans(st, a, b, W, H, function(y, x0, x1, d)
                seg[#seg + 1] = y .. ":" .. x0 .. "-" .. x1 .. "@"
                    .. tostring(d)
            end)
            Brush.dot_spans(st, fat, W, H, function(y, x0, x1)
                dot[#dot + 1] = y .. ":" .. x0 .. "-" .. x1 .. "@" .. want_d
            end)
            if #seg == 0
               or table.concat(seg, " ") ~= table.concat(dot, " ") then
                ok = false
            end
        end
    end
    report(ok, "zero-length flick: the fatter end's disc, density of b", "")
end

-- The floor only engages under a small cfg.size_mult; the shipped sizes
-- never reach it.
do
    local tiny = setmetatable({ size_mult = { S = 0.1, M = 1, L = 1.6 } },
                              { __index = cfg })
    local ok, got = true, {}
    for _, id in ipairs(Brush.IDS) do
        local st = Brush.style(id, "S", "pen", tiny)
        if st.rmin < 0.75 or st.rmax < 0.75 then ok = false end
        got[#got + 1] = string.format("%.2f", st.rmin)
    end
    report(ok and Brush.style("fine", "S", "pen", tiny).rmin == 0.75,
           "radii are floored at 0.75 px", table.concat(got, " "))
end

-- The controller may adjust a style (e.g. the tip eraser's pressure
-- window) before recording it; that must not leak into the next one.
do
    local s1 = Brush.style("pencil", "M", "pen", cfg)
    s1.plo, s1.rmax = 0, 99
    local s2 = Brush.style("pencil", "M", "pen", cfg)
    report(s2.plo == cfg.pen_p_lo and s2.rmax ~= 99,
           "style() returns a fresh table each call", "")
end

do
    local ok = true
    for y = -9, 3 do
        for x = -9, 3 do
            for n = 0, 16 do
                if Brush.mask(bayer, n / 16, x, y)
                   ~= Brush.mask(bayer, n / 16, x + 8, y + 12) then
                    ok = false
                end
            end
            if Brush.mask(Brush.style("highlighter", "M", "pen", cfg), 0.5,
                          x, y) ~= ((x + y) % 2 == 0) then
                ok = false
            end
        end
    end
    report(ok, "masks stay on one grid across negative coordinates", "")
end

-- hits on a tapered segment's flank.  The flat outer tangent lies on a
-- supporting line of the hull, so a point R + d out along its normal is
-- exactly R + d from the hull, and so is every point of a path parallel
-- to it.  Hit iff d < 0, with no sampling.  Beside a taper the hull is
-- wider than the radius at the projection, so these land in the band
-- where hits() falls back to its search.
do
    local n, wrong, off, first = 0, 0, 0, nil
    for case = 1, 2000 do
        local ax, ay = vuni(200, 400), vuni(200, 400)
        local ang, len = vuni(0, 2 * math.pi), vuni(3, 30)
        local bx, by = ax + len * math.cos(ang), ay + len * math.sin(ang)
        local ra, rb = vuni(0.75, 4), vuni(8, 26)
        if vrnd() < 0.5 then ra, rb = rb, ra end
        local side = vrnd() < 0.5 and 1 or -1
        local R = vuni(0, 24)
        local d = vuni(0.01, 0.3) * (vrnd() < 0.5 and 1 or -1)
        local lam, L1, L2 = vuni(0.1, 0.9), vuni(0, 40), vuni(0, 40)
        local as_path, swap = vrnd() < 0.5, vrnd() < 0.5
        if abs(rb - ra) < len then
            local ux, uy = (bx - ax) / len, (by - ay) / len
            local k = (rb - ra) / len
            local s = sqrt(1 - k * k) * side
            local mx, my = -k * ux - s * uy, -k * uy + s * ux
            local px, py = ax + ra * mx, ay + ra * my
            local qx, qy = bx + rb * mx, by + rb * my
            local fx, fy = px + (qx - px) * lam, py + (qy - py) * lam
            local tl = sqrt((qx - px) ^ 2 + (qy - py) ^ 2)
            local tx, ty = (qx - px) / tl, (qy - py) / tl
            local ex, ey = fx + mx * (R + d), fy + my * (R + d)
            -- the construction, checked against the golden-verified reference
            local g = ref_gap(ex, ey, ax, ay, ra, bx, by, rb)
            if abs(g - (R + d)) > 1e-9 then
                off = off + 1
            end
            local path = { { x = ex, y = ey } }
            if as_path then
                path = { { x = ex + tx * L1, y = ey + ty * L1 },
                         { x = ex - tx * L2, y = ey - ty * L2 } }
                if swap then path[1], path[2] = path[2], path[1] end
            end
            local stroke = { { x = ax, y = ay, p = ra },
                             { x = bx, y = by, p = rb } }
            n = n + 1
            if Brush.hits(path, R, stroke, geo) ~= (d < 0) then
                wrong = wrong + 1
                first = first or string.format("case %d d=%.3f", case, d)
            end
        end
    end
    report(n > 500 and wrong == 0 and off == 0,
           "hits on tapered flanks, points and parallel paths, exact",
           string.format("%d cases, %d wrong, %d constructions off%s", n,
                         wrong, off, first and (": " .. first) or ""))
end

-- Degenerate paths: repeated samples on either side, collinear overlap
-- with no eraser radius, and a path whose only crossing is its second
-- leg.
do
    local R0 = 0
    local dup_line = { { x = 100, y = 100, p = 2000 },
                       { x = 150, y = 100, p = 2000 },
                       { x = 150, y = 100, p = 2000 },
                       { x = 200, y = 100, p = 2000 } }
    report(Brush.hits({ e(150, 40), e(150, 40), e(150, 160) }, R, line, fine),
           "hit: a repeated eraser sample does not end the path", "")
    report(Brush.hits({ e(175, 40), e(175, 160) }, R, dup_line, fine)
           and not Brush.hits({ e(175, 40), e(175, 80) }, R, dup_line, fine),
           "a repeated stroke sample does not break the stroke", "")
    report(Brush.hits({ e(120, 100), e(180, 100) }, R0, line, fine)
           and Brush.hits({ e(160, 100) }, R0, line, fine),
           "R=0: a path along the centre line, or a point on it, hits", "")
    report(not Brush.hits({ e(220, 100), e(260, 100) }, R, line, fine),
           "miss: collinear path beyond the end cap", "")
    report(Brush.hits({ e(0, 40), e(150, 40), e(150, 160) }, 1, line, fine)
           and not Brush.hits({ e(0, 40), e(150, 40), e(300, 40) }, 1, line,
                              fine),
           "a three-sample path: only its second leg crosses", "")
end

------------------------------------------------------------------------
-- Microbenchmark (stderr only; not a gate).
------------------------------------------------------------------------

if want_bench then
    local function bench(label, style, rlo, rhi, travel_max)
        local n, reps = 2000, 200
        local A, B = {}, {}
        for i = 1, n do
            local x, y = uniform(100, W - 100), uniform(100, H - 100)
            local ang, len = uniform(0, 2 * math.pi), uniform(0, travel_max)
            local pa, pb
            if style == geo then
                pa, pb = p_for(uniform(rlo, rhi)), p_for(uniform(rlo, rhi))
            else
                pa, pb = uniform(0, 4095), uniform(0, 4095)
            end
            A[i] = { x = x, y = y, p = pa }
            B[i] = { x = x + len * math.cos(ang), y = y + len * math.sin(ang),
                     p = pb }
        end
        local rows = 0
        local function sink() rows = rows + 1 end
        for i = 1, n do Brush.segment_spans(style, A[i], B[i], W, H, sink) end
        rows = 0
        local t0 = os.clock()
        for _ = 1, reps do
            for i = 1, n do Brush.segment_spans(style, A[i], B[i], W, H, sink) end
        end
        local dt = os.clock() - t0
        io.stderr:write(string.format(
            "BENCH: %-44s %6.3f us/segment  %5.1f rows/segment\n",
            label, dt * 1e6 / (n * reps), rows / (n * reps)))
    end
    bench("r 5 const, travel <= 10 px (p99)", geo, 5, 5, 10)
    bench("r 15 const, travel <= 10 px", geo, 15, 15, 10)
    bench("r 25 const, travel <= 10 px", geo, 25, 25, 10)
    bench("r 5..25 tapered, travel <= 10 px", geo, 5, 25, 10)
    bench("r 5..25 tapered, travel <= 26 px (max)", geo, 5, 25, 26)
    bench("brushpen M (pressure pow), travel <= 10", Brush.style("brushpen",
          "M", "pen", cfg), 0, 0, 10)
    bench("eraser 12..24, travel <= 26", eraser, 0, 0, 26)
    bench("fine M, travel <= 10", Brush.style("fine", "M", "pen", cfg), 0, 0, 10)
end

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
