--[[--
wipe-flip.lua: the turn-route A/B arm driver -- flips pages with a
selectable two-stage "wipe white, then draw" turn (--wipe-hint /
--draw-hint) or a plain single-pass turn (--no-wipe), over synthetic
block pages or real typeset raws (--page-a/--page-b).

Built to test the operator's 2026-08-26 "bounded ghost" hypothesis:
wipe every turn through white so residue cannot accumulate.  The
optics rig REFUTED it the same night (doc/status.md): the wipe
replaces GL16's 38-phase clear of old ink with the wipe waveform's
shorter one and measured DIRTIER at every horizon (single turn,
8-turn alternation, 4-distinct-page chain).  Kept as the arm driver
for replaying those measurements and testing future routes.

A wipe stage wants the IDENTITY table: real DU in the DU slot.  A2
cannot wipe -- it drives only 6 binary transitions and leaves gray
pixels alone.

Usage: wipe-flip.lua [--count N] [--interval-ms N] [--wipe-wait-ms N]
                     [--wipe-hint N] [--draw-hint N] [--no-wipe]
                     [--page-a RAW] [--page-b RAW]
                     [--margin PX] [--line-h PX] [--quiet]
--page-a/--page-b take full-frame 8-bit grayscale raws (fb WxH bytes,
e.g. ImageMagick `gray:` output) -- real typeset text instead of the
synthetic block pages.  --no-wipe skips the white stage (plain-turn
comparison arm).
--]]

package.path = (arg[0] or ""):match("^(.*)/") and
    ((arg[0]):match("^(.*)/") .. "/?.lua;" .. package.path) or package.path
local lib = require("ebclib")
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
int fsync(int fd);
int ioctl(int fd, unsigned long req, void *arg);
struct wf_tv { long tv_sec; long tv_usec; };
int gettimeofday(struct wf_tv *tv, void *tz);
int select(int nfds, void *r, void *w, void *e, struct wf_tv *timeout);
]]

local opt = { count = 8, interval_ms = 2500, wipe_wait_ms = 250,
              wipe_hint = 0, draw_hint = 32, margin = 60, line_h = 28,
              fb = "/dev/fb0", sys_root = "/sys", proc_root = "/proc",
              verbose = true }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--count" then i = i + 1; opt.count = tonumber(arg[i]) or 8
        elseif a == "--interval-ms" then i = i + 1; opt.interval_ms = tonumber(arg[i]) or 2500
        elseif a == "--wipe-wait-ms" then i = i + 1; opt.wipe_wait_ms = tonumber(arg[i]) or 250
        elseif a == "--wipe-hint" then i = i + 1; opt.wipe_hint = tonumber(arg[i]) or 0
        elseif a == "--draw-hint" then i = i + 1; opt.draw_hint = tonumber(arg[i]) or 32
        elseif a == "--margin" then i = i + 1; opt.margin = tonumber(arg[i]) or 60
        elseif a == "--line-h" then i = i + 1; opt.line_h = tonumber(arg[i]) or 28
        elseif a == "--page-a" then i = i + 1; opt.page_a = arg[i]
        elseif a == "--page-b" then i = i + 1; opt.page_b = arg[i]
        elseif a == "--no-wipe" then opt.no_wipe = true
        elseif a == "--quiet" then opt.verbose = false
        end
        i = i + 1
    end
end

local function log(fmt, ...)
    if not opt.verbose then return end
    io.stderr:write(("[wipe-flip] " .. fmt .. "\n"):format(...))
    io.stderr:flush()
end

-- Renderer copied from page-flip.lua (deterministic text-like pages).
local function lcg(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 16807) % 2147483647
        return s
    end
end

local function render_page(page, geom, margin, line_h)
    local rows = {}
    local usable_w = geom.w - 2 * margin
    local y = margin
    local line = 0
    while y + line_h < geom.h - margin do
        local rnd = lcg(page * 1000003 + line * 7919)
        local ink_h = math.floor(line_h * 0.6)
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

local function now_us()
    local t = ffi.new("struct wf_tv")
    ffi.C.gettimeofday(t, nil)
    return tonumber(t.tv_sec) * 1000000 + tonumber(t.tv_usec)
end

local function sleep_ms(ms)
    local t = ffi.new("struct wf_tv")
    t.tv_sec = math.floor(ms / 1000)
    t.tv_usec = (ms % 1000) * 1000
    ffi.C.select(0, nil, nil, nil, t)
end

-- ---------------------------------------------------------------------

local w, h, stride, bypp = lib.fb_geometry(opt.sys_root)
if not w then w, h, stride, bypp = 1872, 1404, 3744, 2 end
local geom = { w = w, h = h, stride = stride, bypp = bypp }
log("fb %dx%d stride=%d %dB/px; %d wipe-flips, wipe=%d draw=%d wait=%dms",
    w, h, stride, bypp, opt.count, opt.wipe_hint, opt.draw_hint,
    opt.wipe_wait_ms)

local card = lib.find_ebc_card(opt.sys_root)
if not card then log("no EBC card"); os.exit(1) end
local card_fd = ffi.C.open("/dev/dri/card" .. card, 2)
if card_fd < 0 then log("cannot open card%d (root?)", card); os.exit(1) end

local function set_hint(hint)
    local hdr = lib.pack_rect_hints_header(true, hint, 0)
    local buf = ffi.new("uint8_t[?]", #hdr)
    ffi.copy(buf, hdr, #hdr)
    local r = ffi.C.ioctl(card_fd, lib.RECT_HINTS_IOCTL, buf)
    if r ~= 0 then log("RECT_HINTS failed (%d) for hint %d", r, hint) end
end

local fh = io.open(opt.fb, "r+b")
if not fh then log("cannot open %s", opt.fb); os.exit(1) end
local fb_fd = ffi.C.open(opt.fb, 2)
local function publish()
    fh:flush()
    if fb_fd >= 0 then ffi.C.fsync(fb_fd) end
end

local white = string.rep(string.char(255), geom.w * geom.bypp)

local function wipe_white()
    for y = 0, geom.h - 1 do
        fh:seek("set", y * geom.stride)
        fh:write(white)
    end
    publish()
end

local function draw_page(rows)
    -- The panel is already white after the wipe; write only the ink.
    for y = 0, geom.h - 1 do
        local rs = rows[y]
        if rs then
            for _, span in ipairs(rs) do
                fh:seek("set", y * geom.stride + span[1] * geom.bypp)
                fh:write(string.rep("\0", (span[2] - span[1]) * geom.bypp))
            end
        end
    end
    publish()
end

-- Load a full-frame 8-bit gray raw and pre-pack it into per-row
-- RGB565 strings (gray g -> (g>>3)<<11 | (g>>2)<<5 | (g>>3), LE).
local g2p
local function load_raw(path)
    if not g2p then
        g2p = {}
        for g = 0, 255 do
            local p = bit.bor(bit.lshift(bit.rshift(g, 3), 11),
                              bit.lshift(bit.rshift(g, 2), 5),
                              bit.rshift(g, 3))
            g2p[g] = string.char(p % 256, math.floor(p / 256))
        end
    end
    local f = io.open(path, "rb")
    if not f then log("cannot open %s", path); os.exit(1) end
    local data = f:read("*a")
    f:close()
    if #data ~= geom.w * geom.h then
        log("%s is %d bytes, want %d", path, #data, geom.w * geom.h)
        os.exit(1)
    end
    local rows = {}
    local t = {}
    for y = 0, geom.h - 1 do
        local base = y * geom.w
        for x = 1, geom.w do
            t[x] = g2p[data:byte(base + x)]
        end
        rows[y] = table.concat(t)
    end
    return rows
end

local function draw_raw(rows)
    for y = 0, geom.h - 1 do
        fh:seek("set", y * geom.stride)
        fh:write(rows[y])
    end
    publish()
end

local pages, raw_mode
if opt.page_a and opt.page_b then
    log("loading raw pages")
    pages = { load_raw(opt.page_a), load_raw(opt.page_b) }
    raw_mode = true
else
    pages = {
        render_page(1, geom, opt.margin, opt.line_h),
        render_page(2, geom, opt.margin, opt.line_h),
    }
end

for flip = 1, opt.count do
    local page = (flip % 2) + 1
    local irq0 = lib.ebc_irq_count(opt.proc_root)
    local t0 = now_us()
    local t1 = t0
    if not opt.no_wipe then
        set_hint(opt.wipe_hint)
        wipe_white()
        t1 = now_us()
        sleep_ms(opt.wipe_wait_ms)
    end
    set_hint(opt.draw_hint)
    if raw_mode then draw_raw(pages[page]) else draw_page(pages[page]) end
    local t2 = now_us()
    sleep_ms(opt.interval_ms)
    local irq1 = lib.ebc_irq_count(opt.proc_root)
    log("flip=%d page=%d wipe_ms=%.1f draw_ms=%.1f irq_delta=%s",
        flip, page, (t1 - t0) / 1000,
        (t2 - t1) / 1000 - (opt.no_wipe and 0 or opt.wipe_wait_ms),
        (irq0 and irq1) and tostring(irq1 - irq0) or "?")
end
set_hint(opt.draw_hint)
log("done (default hint left at %d)", opt.draw_hint)
