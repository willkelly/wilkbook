-- Deterministic host-only tests for the pen tools (D8): the scribbler's
-- geometry/parsing/publish path and ebc-mode's ioctl ABI, extracted
-- VERBATIM from the shipped sources (the test-autosuspend-policy
-- contract: what executes here is the code the device runs, so a rebase
-- or edit that changes behaviour turns this red).
--
-- The ABI pins anchor on the one constant this repo has already proven
-- on hardware: DRM_IOCTL_ROCKCHIP_EBC_GLOBAL_REFRESH = 0xC0016440
-- (glass, 2026-07-04).  The same generator must reproduce it before its
-- MODE/RECT_HINTS outputs are trusted.
--
-- Usage: luajit test-scribble.lua [scribble.lua] [ebc-mode.lua]

local scribble_path = arg[1] or "scribble.lua"
local mode_path = arg[2] or "ebc-mode.lua"

local failures = 0
local function report(ok, label, detail)
    if ok then
        print("PASS: " .. label)
    else
        failures = failures + 1
        print("FAIL: " .. label .. (detail and (" - " .. detail) or ""))
    end
end
local function fatal(msg)
    print("FAIL: " .. msg)
    os.exit(1)
end

local function read_lines(path)
    local f = io.open(path, "r")
    if not f then fatal("cannot open " .. path) end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    return lines
end

-- `local function name()` at column 0, closed by the first `end` at
-- column 0 (the policy suite's extractor).
local function extractor(lines, path)
    return function(name)
        local first
        for i, line in ipairs(lines) do
            if line:match("^local function " .. name .. "%(") then first = i break end
        end
        if not first then fatal("no `local function " .. name .. "` in " .. path) end
        for i = first + 1, #lines do
            if lines[i] == "end" then
                return table.concat(lines, "\n", first, i)
            end
        end
        fatal(name .. " never closes at column 0 in " .. path)
    end
end

local sc_lines = read_lines(scribble_path)
local md_lines = read_lines(mode_path)
local sc_extract = extractor(sc_lines, scribble_path)
local md_extract = extractor(md_lines, mode_path)

-- Build a callable from extracted source + an environment.
local function load_with(src, env, retname)
    local chunk = loadstring(src .. "\nreturn " .. retname, "@extracted:" .. retname)
    if not chunk then fatal("extracted " .. retname .. " does not compile") end
    setfenv(chunk, env)
    return chunk()
end

local base_env = {
    math = math, string = string, table = table, pairs = pairs,
    ipairs = ipairs, tostring = tostring, tonumber = tonumber, io = io,
    EV_SYN = 0, EV_KEY = 1, EV_ABS = 3,
    ABS_X = 0, ABS_Y = 1, ABS_PRESSURE = 24,
    BTN_TOUCH = 330, SYN_REPORT = 0,
    -- the direct driver's real geometry: RGB565, stride 3744.  Assuming
    -- the shipping driver's 32 bpp here is exactly the bug the live
    -- session hit, so the harness pins the 16 bpp arithmetic.
    FB_W = 1872, FB_H = 1404, FB_STRIDE = 3744, FB_BYPP = 2,
}
local function env()
    local e = {}
    for k, v in pairs(base_env) do e[k] = v end
    return e
end

-- ---------------------------------------------------------------- ABI
do
    local e = env()
    local src = md_extract("drm_ioc") .. "\n" .. md_extract("drm_iowr")
        .. "\n" .. md_extract("drm_iow")
    local iowr = load_with(src, e, "drm_iowr")
    local iow = load_with(src, e, "drm_iow")
    report(iowr(0x00, 1) == 0xC0016440,
        "ioctl generator reproduces the hardware-proven GLOBAL_REFRESH 0xC0016440",
        string.format("got 0x%08X", iowr(0x00, 1)))
    report(iowr(0x04, 8) == 0xC0086444,
        "MODE ioctl number is 0xC0086444",
        string.format("got 0x%08X", iowr(0x04, 8)))
    report(iow(0x03, 16) == 0x40106443,
        "RECT_HINTS ioctl number is 0x40106443",
        string.format("got 0x%08X", iow(0x03, 16)))

    local pack_mode = load_with(md_extract("pack_mode"), env(), "pack_mode")
    local unpack_mode = load_with(md_extract("unpack_mode"), env(), "unpack_mode")
    local s = pack_mode(true, 1, true, 0x1234)
    report(#s == 8, "mode struct is exactly 8 bytes", tostring(#s))
    report(s:byte(1) == 1 and s:byte(2) == 1,
        "set_driver_mode and driver_mode land in bytes 1-2")
    report(s:byte(5) == 0x34 and s:byte(6) == 0x12,
        "redraw_delay is little-endian u16 at offset 4")
    report(s:byte(7) == 1, "set_redraw_delay lands in byte 7")
    local m = unpack_mode(s)
    report(m.driver_mode == 1 and m.redraw_delay == 0x1234,
        "pack/unpack roundtrip preserves mode and delay")
    local q = pack_mode(false, 0, false, 0)
    report(q == string.rep("\0", 8),
        "the query form is all-zero (reads without setting)")

    local pack_hint = load_with(md_extract("pack_default_hint"), env(),
                                "pack_default_hint")
    local h = pack_hint(160)
    report(#h == 16, "rect_hints struct is exactly 16 bytes", tostring(#h))
    report(h:byte(1) == 1 and h:byte(2) == 160,
        "set_default_hint=1 and the hint land in bytes 1-2")
    report(h:sub(3) == string.rep("\0", 14),
        "num_rects=0 and a NULL pointer: a default-only repaint")
end

-- ---------------------------------------------------------- geometry
do
    local map = load_with(sc_extract("map_coord"), env(), "map_coord")
    report(map(0, 0, 1000, 99, false) == 0, "axis minimum maps to 0")
    report(map(1000, 0, 1000, 99, false) == 99, "axis maximum maps to out_max")
    report(map(500, 0, 1000, 99, false) == 50, "midpoint rounds to the middle")
    report(map(-50, 0, 1000, 99, false) == 0, "below-range clamps to 0")
    report(map(2000, 0, 1000, 99, false) == 99, "above-range clamps to out_max")
    report(map(0, 0, 1000, 99, true) == 99, "flip mirrors the minimum to out_max")
    report(map(7, 7, 7, 99, false) == 0, "a degenerate range cannot divide by zero")
end

do
    local stamp = load_with(sc_extract("stamp_points"), env(), "stamp_points")
    local function centers(x0, y0, x1, y1)
        local pts = {}
        stamp(x0, y0, x1, y1, 0, function(x, y) pts[#pts + 1] = { x, y } end)
        return pts
    end
    local function contiguous(pts)
        for i = 2, #pts do
            if math.abs(pts[i][1] - pts[i - 1][1]) > 1
               or math.abs(pts[i][2] - pts[i - 1][2]) > 1 then
                return false
            end
        end
        return true
    end
    for _, case in ipairs({
        { 0, 0, 10, 0, "horizontal" },
        { 0, 0, 0, 10, "vertical" },
        { 0, 0, 10, 10, "diagonal" },
        { 0, 0, 3, 11, "steep" },
        { 10, 7, 0, 0, "reversed" },
    }) do
        local pts = centers(case[1], case[2], case[3], case[4])
        report(pts[1][1] == case[1] and pts[1][2] == case[2]
               and pts[#pts][1] == case[3] and pts[#pts][2] == case[4],
            case[5] .. " line covers both endpoints")
        report(contiguous(pts),
            case[5] .. " line has no gaps (every step is a neighbour)")
    end
    local single = centers(5, 5, 5, 5)
    report(#single == 1, "a zero-length stroke is a single dot")
    local n = 0
    stamp(5, 5, 5, 5, 2, function() n = n + 1 end)
    report(n == 25, "radius 2 stamps a 5x5 brush", tostring(n))
end

-- ----------------------------------------------------- event parsing
do
    local e = env()
    local src = sc_extract("map_coord") .. "\n" .. sc_extract("feed_event")
        .. "\n" .. sc_extract("batch_segment")
    local feed = load_with(src, e, "feed_event")
    local segf = load_with(src, e, "batch_segment")
    local geom = { swap_xy = false, flip_x = false, flip_y = false,
                   x_lo = 0, x_hi = 1871, y_lo = 0, y_hi = 1403 }
    local state = {}
    local function ev(t, c, v) return { type = t, code = c, value = v,
                                        tv_sec = 1, tv_usec = 0 } end
    -- moving with the nib UP draws nothing
    feed(state, ev(3, 0, 100)); feed(state, ev(3, 1, 100))
    report(feed(state, ev(0, 0, 0)) == true, "SYN_REPORT ends a batch")
    report(segf(state, geom) == nil, "hovering (no BTN_TOUCH) draws nothing")
    -- touch down: first batch is a dot, not a chord from anywhere
    feed(state, ev(1, 330, 1)); feed(state, ev(3, 0, 200)); feed(state, ev(3, 1, 300))
    feed(state, ev(0, 0, 0))
    local s1 = segf(state, geom)
    report(s1 and s1.x0 == s1.x1 and s1.y0 == s1.y1,
        "the first touched batch is a dot")
    report(s1 and s1.x1 == 200 and s1.y1 == 300,
        "identity ranges map coordinates through unchanged")
    -- next batch draws a segment from the previous point
    feed(state, ev(3, 0, 210)); feed(state, ev(0, 0, 0))
    local s2 = segf(state, geom)
    report(s2 and s2.x0 == 200 and s2.y0 == 300 and s2.x1 == 210 and s2.y1 == 300,
        "the second batch is a segment from the previous point")
    -- lift, move far, touch again: a dot again, never a chord
    feed(state, ev(1, 330, 0)); feed(state, ev(0, 0, 0))
    report(segf(state, geom) == nil, "a lifted nib draws nothing")
    feed(state, ev(3, 0, 900)); feed(state, ev(3, 1, 900))
    feed(state, ev(1, 330, 1)); feed(state, ev(0, 0, 0))
    local s3 = segf(state, geom)
    report(s3 and s3.x0 == 900 and s3.y0 == 900,
        "re-touching starts a fresh stroke, not a chord across the lift")
    -- swap-xy exchanges the axes
    local st2 = { touching = true, rx = 10, ry = 20 }
    local sw = { swap_xy = true, flip_x = false, flip_y = false,
                 x_lo = 0, x_hi = 1871, y_lo = 0, y_hi = 1403 }
    local s4 = segf(st2, sw)
    report(s4 and s4.x1 == 20 and s4.y1 == 10, "--swap-xy exchanges the axes")
end

-- ------------------------------------------------------ ink publish
do
    local e = env()
    local src = sc_extract("plot_into") .. "\n" .. sc_extract("write_ink_rows")
    local plot = load_with(src, e, "plot_into")
    local write = load_with(src, e, "write_ink_rows")

    local rows = {}
    plot(rows, -1, 5); plot(rows, 1872, 5); plot(rows, 5, -1); plot(rows, 5, 1404)
    local n = 0
    for _ in pairs(rows) do n = n + 1 end
    report(n == 0, "out-of-panel plots are dropped at the edge")

    rows = {}
    plot(rows, 3, 5); plot(rows, 4, 5); plot(rows, 5, 5); plot(rows, 9, 5)
    plot(rows, 4, 5)   -- duplicate must not split the run
    local trace, syncs = {}, 0
    local fake = {
        seek = function(_, _, off) trace.off = off end,
        write = function(_, s) trace[#trace + 1] = { off = trace.off, len = #s, s = s } end,
    }
    local runs = write(fake, rows, function() syncs = syncs + 1 end)
    report(runs == 2, "adjacent and duplicate pixels coalesce into runs",
        tostring(runs))
    report(syncs == 1, "exactly one publish (fsync) per batch")
    local seen = {}
    for _, w in ipairs(trace) do seen[w.off] = w.len end
    report(seen[5 * 3744 + 3 * 2] == 6,
        "the 3..5 run lands at y*stride + x*bypp with 3 RGB565 pixels of black")
    report(seen[5 * 3744 + 9 * 2] == 2, "the lone pixel is its own 2-byte run")
    local black = true
    for _, w in ipairs(trace) do
        if w.s ~= string.rep("\0", w.len) then black = false end
    end
    report(black, "ink is black (all-zero XR24)")
end

-- ------------------------------------------------- fb geometry
do
    local e = env()
    local geo = load_with(sc_extract("fb_geometry"), e, "fb_geometry")
    local root = "build/fake-fb"
    os.execute("rm -rf " .. root .. " && mkdir -p " .. root
               .. "/class/graphics/fb0")
    local function put(name, v)
        local f = io.open(root .. "/class/graphics/fb0/" .. name, "w")
        f:write(v)
        f:close()
    end
    put("virtual_size", "1872,1404\n")
    put("stride", "3744\n")
    put("bits_per_pixel", "16\n")
    local w, h, stride, bypp = geo(root)
    report(w == 1872 and h == 1404 and stride == 3744 and bypp == 2,
        "fb geometry is read from sysfs (the direct driver's RGB565)",
        string.format("%s %s %s %s", tostring(w), tostring(h),
                      tostring(stride), tostring(bypp)))
    put("bits_per_pixel", "32\n")
    put("stride", "7488\n")
    local _, _, s32, b32 = geo(root)
    report(s32 == 7488 and b32 == 4,
        "the shipping driver's XR24 geometry reads correctly too")
    os.execute("rm -rf " .. root)
    report(select("#", geo("build/does-not-exist")) == 1
           and geo("build/does-not-exist") == nil,
        "missing sysfs returns nil so the caller keeps its defaults")

    local clear = load_with(sc_extract("clear_white"), env(), "clear_white")
    local offs, lens, white = {}, {}, true
    local fake = {
        seek = function(_, _, off) offs[#offs + 1] = off end,
        write = function(_, s)
            lens[#lens + 1] = #s
            if s ~= string.rep(string.char(255), #s) then white = false end
        end,
    }
    clear(fake)
    report(#offs == 1404 and offs[1] == 0 and offs[2] == 3744,
        "clear_white writes every row at its stride offset")
    report(lens[1] == 1872 * 2 and white,
        "each cleared row is full-width 0xFF (white in RGB565)")
end

-- ------------------------------------------------- device discovery
do
    local root = "build/fake-sys"
    os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
    local function mkdev(kind, n, content)
        os.execute("mkdir -p " .. root .. "/class/" .. kind .. "/"
                   .. (kind == "input" and ("event" .. n) or ("card" .. n))
                   .. "/device")
        local path = kind == "input"
            and (root .. "/class/input/event" .. n .. "/device/name")
            or (root .. "/class/drm/card" .. n .. "/device/uevent")
        local f = io.open(path, "w")
        f:write(content)
        f:close()
    end

    local find_stylus = load_with(sc_extract("find_stylus"), env(), "find_stylus")
    mkdev("input", 0, "rk805 pwrkey\n")
    mkdev("input", 2, "cyttsp5\n")
    mkdev("input", 5, "w9013 2D1F:0095 Stylus\n")
    mkdev("input", 6, "w9013 2D1F:0095\n")
    local n, name = find_stylus(root)
    report(n == 5, "the stylus is found by NAME on whatever node it holds",
        tostring(n))
    report(name and name:find("Stylus") ~= nil, "and it is the Stylus node, not the pad")

    local find_card = load_with(md_extract("find_ebc_card"), env(), "find_ebc_card")
    mkdev("drm", 0, "DRIVER=panfrost\n")
    mkdev("drm", 1, "DRIVER=rockchip-ebc\n")
    report(find_card(root) == 1,
        "the EBC card is resolved behind a panfrost card0")
    os.execute("rm -rf " .. root .. " && mkdir -p " .. root)
    mkdev("drm", 0, "DRIVER=panfrost\n")
    report(find_card(root) == nil, "no EBC driver present resolves to nil, not 0")
end

-- ------------------------------------------------------- structural
do
    local sc_src = table.concat(sc_lines, "\n")
    local md_src = table.concat(md_lines, "\n")
    report(not sc_src:match("/dev/dri/card%d"),
        "scribble.lua carries no DRM card-index literal")
    report(not md_src:match("/dev/dri/card%d"),
        "ebc-mode.lua carries no DRM card-index literal")
    report(md_src:find("DRIVER=rockchip-ebc", 1, true) ~= nil,
        "ebc-mode.lua resolves the card by driver name")
    -- the EVIOCGABS generator, against the arithmetic constant
    local abs = load_with(sc_extract("eviocgabs"), env(), "eviocgabs")
    report(abs(0) == 0x80184540,
        "EVIOCGABS(ABS_X) computes to 0x80184540",
        string.format("got 0x%08X", abs(0)))
end

report(loadfile(scribble_path) ~= nil, "scribble.lua compiles")
report(loadfile(mode_path) ~= nil, "ebc-mode.lua compiles")

print(failures == 0 and "pen tools: all checks passed"
                    or ("pen tools: " .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
