--[[--
Synthetic page turner: the turn-quality experiment rig that needs no
KOReader.  Renders two text-like pages into /dev/fb0 and flips between
them on an interval, logging the EBC IRQ delta and wall time per flip.
Pair it with rect-hints.lua (routing under test) or a CLUT swap, watch
on the Brio or with eyes, and judge -- one SSH loop per hypothesis.

"Text-like" is deliberate: rows of black runs with ragged right edges
and different line phases per page, so a flip's damage pattern
resembles a real page turn (mutual overwrite of glyph-shaped ink), not
a block fill.

Usage: page-flip.lua [--count N] [--interval-ms N] [--fb PATH]
                     [--margin PX] [--line-h PX] [--sys-root DIR]
                     [--proc-root DIR] [--quiet]
--]]

package.path = (arg[0] or ""):match("^(.*)/") and
    ((arg[0]):match("^(.*)/") .. "/?.lua;" .. package.path) or package.path
local lib = require("ebclib")
local ffi = require("ffi")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
int fsync(int fd);
struct pf_tv { long tv_sec; long tv_usec; };
int gettimeofday(struct pf_tv *tv, void *tz);
int select(int nfds, void *r, void *w, void *e, struct pf_tv *timeout);
]]

local opt = {
    count = 10, interval_ms = 3000, fb = "/dev/fb0",
    margin = 60, line_h = 28,
    sys_root = "/sys", proc_root = "/proc", verbose = true,
}
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--count" then i = i + 1; opt.count = tonumber(arg[i]) or 10
        elseif a == "--interval-ms" then i = i + 1; opt.interval_ms = tonumber(arg[i]) or 3000
        elseif a == "--fb" then i = i + 1; opt.fb = arg[i]
        elseif a == "--margin" then i = i + 1; opt.margin = tonumber(arg[i]) or 60
        elseif a == "--line-h" then i = i + 1; opt.line_h = tonumber(arg[i]) or 28
        elseif a == "--sys-root" then i = i + 1; opt.sys_root = arg[i]
        elseif a == "--proc-root" then i = i + 1; opt.proc_root = arg[i]
        elseif a == "--quiet" then opt.verbose = false
        end
        i = i + 1
    end
end

local function log(fmt, ...)
    if not opt.verbose then return end
    io.stderr:write(("[page-flip] " .. fmt .. "\n"):format(...))
    io.stderr:flush()
end

-- Deterministic pseudo-random word lengths: a tiny LCG, seeded per
-- (page, line), so page A and page B are stable across runs (an A/B
-- capture is comparable to yesterday's) yet differ from each other.
local function lcg(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 16807) % 2147483647
        return s
    end
end

-- Render one page's ink runs.  Returns rows = { [y] = { {x0,x1}... } }
-- in PIXELS; the writer below turns them into framebuffer bytes.  Line
-- text occupies the upper 60% of each line box (the "x-height"), like
-- type on a page.
local function render_page(page, geom, margin, line_h)
    local rows = {}
    local usable_w = geom.w - 2 * margin
    local y = margin
    local line = 0
    while y + line_h < geom.h - margin do
        local rnd = lcg(page * 1000003 + line * 7919)
        local ink_h = math.floor(line_h * 0.6)
        -- paragraph breaks in different places per page
        local skip = (line % 13 == (page == 1 and 5 or 9))
        if not skip then
            local spans = {}
            local x = margin + (rnd() % 3) * 8
            while x < margin + usable_w - 40 do
                local word = 24 + (rnd() % 120)
                local gap = 10 + (rnd() % 18)
                if x + word > margin + usable_w then
                    word = margin + usable_w - x
                end
                spans[#spans + 1] = { x, x + word }
                x = x + word + gap
            end
            for dy = 0, ink_h - 1 do
                local ry = y + dy
                rows[ry] = rows[ry] or {}
                for _, s in ipairs(spans) do
                    rows[ry][#rows[ry] + 1] = { s[1], s[2] }
                end
            end
        end
        y = y + line_h
        line = line + 1
    end
    return rows
end

-- Write a full page: white background, then the ink runs, one seek+
-- write per contiguous byte span, single fsync at the end (the same
-- publish-on-call seam a real turn uses).
local function write_page(fh, rows, geom, sync)
    local white = string.rep(string.char(255), geom.w * geom.bypp)
    for y = 0, geom.h - 1 do
        fh:seek("set", y * geom.stride)
        fh:write(white)
        local rs = rows[y]
        if rs then
            for _, span in ipairs(rs) do
                fh:seek("set", y * geom.stride + span[1] * geom.bypp)
                fh:write(string.rep("\0", (span[2] - span[1]) * geom.bypp))
            end
        end
    end
    sync()
end

local function now_us()
    local t = ffi.new("struct pf_tv")
    ffi.C.gettimeofday(t, nil)
    return tonumber(t.tv_sec) * 1000000 + tonumber(t.tv_usec)
end

local function sleep_ms(ms)
    local t = ffi.new("struct pf_tv")
    t.tv_sec = math.floor(ms / 1000)
    t.tv_usec = (ms % 1000) * 1000
    ffi.C.select(0, nil, nil, nil, t)
end

-- ---------------------------------------------------------------------
-- main

local w, h, stride, bypp = lib.fb_geometry(opt.sys_root)
if not w then
    log("fb geometry unreadable; assuming direct-driver RGB565")
    w, h, stride, bypp = 1872, 1404, 3744, 2
end
local geom = { w = w, h = h, stride = stride, bypp = bypp }
log("fb %dx%d stride=%d %dB/px; %d flips at %d ms",
    w, h, stride, bypp, opt.count, opt.interval_ms)

local fh = io.open(opt.fb, "r+b")
if not fh then
    log("cannot open %s", opt.fb)
    os.exit(1)
end
local fb_fd = ffi.C.open(opt.fb, 2)
local function publish()
    fh:flush()
    if fb_fd >= 0 then ffi.C.fsync(fb_fd) end
end

local pages = {
    render_page(1, geom, opt.margin, opt.line_h),
    render_page(2, geom, opt.margin, opt.line_h),
}

for flip = 1, opt.count do
    local page = (flip % 2) + 1
    local irq0 = lib.ebc_irq_count(opt.proc_root)
    local t0 = now_us()
    write_page(fh, pages[page], geom, publish)
    local t1 = now_us()
    sleep_ms(opt.interval_ms)
    local irq1 = lib.ebc_irq_count(opt.proc_root)
    log("flip=%d page=%d draw_ms=%.1f irq_delta=%s",
        flip, page, (t1 - t0) / 1000,
        (irq0 and irq1) and tostring(irq1 - irq0) or "?")
end
log("done")
