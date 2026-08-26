--[[--
PineNote pen scribbler: the D8 latency floor instrument.

Reads the Wacom digitizer (w9013 stylus) directly from evdev, draws ink
into /dev/fb0, and publishes each event batch with one fsync -- the same
publish-on-call seam KOReader's page turns use.  Nothing else sits in
the path: no toolkit, no compositor, no app.  What the 240 fps camera
measures over this tool is the kernel+driver+fbdev floor, and the tool's
own log gives the software half (last-event timestamp to fsync-return)
so the glass half can be attributed by subtraction.

This deliberately draws ONLY black ink.  A latency instrument needs a
mark, not a paint program; black-on-anything is visible on camera and
needs no read-modify-write of the framebuffer.

Companion: ebc-mode.lua switches the direct driver between NORMAL and
FAST and sets the default hint (pen work wants Y1+THRESHOLD, REDRAW
off = hint byte 0).  See README.md for the full D8 session recipe.

Usage: scribble.lua [--radius N] [--swap-xy] [--flip-x] [--flip-y]
                    [--fb PATH] [--device N] [--sys-root DIR]
                    [--dev-root DIR] [--quiet]

Orientation flags exist because the digitizer's axes and the
framebuffer's landscape-native axes may disagree; latency does not care,
so a wrong guess is fixed live with a flag, not debugged in advance.
--]]

local ffi = require("ffi")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
ssize_t read(int fd, void *buf, size_t n);
int fsync(int fd);
int ioctl(int fd, unsigned long req, void *arg);
struct sc_tv { long tv_sec; long tv_usec; };
int gettimeofday(struct sc_tv *tv, void *tz);
struct sc_input_event {
    long tv_sec; long tv_usec;
    unsigned short type; unsigned short code; int value;
};
struct sc_absinfo {
    int value; int minimum; int maximum; int fuzz; int flat; int resolution;
};
]]

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local ABS_X, ABS_Y, ABS_PRESSURE = 0, 1, 24
local BTN_TOUCH = 330
local SYN_REPORT = 0
local INPUT_EVENT_SIZE = 24

local FB_W, FB_H, FB_STRIDE = 1872, 1404, 7488

local O_RDONLY, O_RDWR = 0, 2

local opt = {
    radius = 2,
    swap_xy = false,
    flip_x = false,
    flip_y = false,
    fb = "/dev/fb0",
    device = nil,
    sys_root = "/sys",
    dev_root = "/dev",
    verbose = true,
}
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--radius" then i = i + 1; opt.radius = tonumber(arg[i]) or 2
        elseif a == "--swap-xy" then opt.swap_xy = true
        elseif a == "--flip-x" then opt.flip_x = true
        elseif a == "--flip-y" then opt.flip_y = true
        elseif a == "--fb" then i = i + 1; opt.fb = arg[i]
        elseif a == "--device" then i = i + 1; opt.device = tonumber(arg[i])
        elseif a == "--sys-root" then i = i + 1; opt.sys_root = arg[i]
        elseif a == "--dev-root" then i = i + 1; opt.dev_root = arg[i]
        elseif a == "--quiet" then opt.verbose = false
        end
        i = i + 1
    end
end

local function log(fmt, ...)
    if not opt.verbose then return end
    io.stderr:write(("[scribble] " .. fmt .. "\n"):format(...))
    io.stderr:flush()
end

-- Identify the stylus by NAME, never by a fixed event number: input node
-- order is not stable across boots (the autosuspend daemon learned this
-- on 2026-08-04 when a device moved nodes across a power cycle).  The
-- Wacom digitizer publishes two nodes ("w9013 ... Stylus" and a bare
-- "w9013 ..."); the Stylus one carries the nib coordinates.
local function find_stylus(sys_root)
    for n = 0, 31 do
        local f = io.open(sys_root .. "/class/input/event" .. n
                          .. "/device/name", "r")
        if f then
            local name = f:read("*l") or ""
            f:close()
            if name:lower():find("stylus", 1, true) then
                return n, name
            end
        end
    end
    return nil
end

-- ioctl request for EVIOCGABS(axis): _IOR('E', 0x40+axis, struct
-- input_absinfo).  Computed, not hardcoded, so the harness can pin the
-- generator against the known constant.
local function eviocgabs(axis)
    local IOC_READ = 2
    local size = 24            -- sizeof(struct input_absinfo)
    return IOC_READ * 2^30 + size * 2^16 + 0x45 * 2^8 + (0x40 + axis)
end

-- Map a raw digitizer coordinate into [0, out_max], clamped.  flip
-- mirrors within the axis.  Integer output.
local function map_coord(v, lo, hi, out_max, flip)
    if hi <= lo then return 0 end
    if v < lo then v = lo end
    if v > hi then v = hi end
    local scaled = math.floor((v - lo) * out_max / (hi - lo) + 0.5)
    if flip then scaled = out_max - scaled end
    return scaled
end

-- Walk the line from (x0,y0) to (x1,y1) inclusive, calling plot(x,y)
-- for every pixel of a square brush of the given radius centered on
-- each line point.  Bresenham, so consecutive line points are always
-- neighbours and a fast stroke leaves a solid trail, not dots.
local function stamp_points(x0, y0, x1, y1, radius, plot)
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx - dy
    local x, y = x0, y0
    while true do
        for by = -radius, radius do
            for bx = -radius, radius do
                plot(x + bx, y + by)
            end
        end
        if x == x1 and y == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x = x + sx end
        if e2 < dx then err = err + dx; y = y + sy end
    end
end

-- Fold one decoded event into the pen state.  Returns true when the
-- event ends a batch (SYN_REPORT).  State fields: rx/ry raw coords,
-- touching, ev_sec/ev_usec of the most recent event.
local function feed_event(state, ev)
    state.ev_sec, state.ev_usec = ev.tv_sec, ev.tv_usec
    if ev.type == EV_ABS then
        if ev.code == ABS_X then state.rx = ev.value
        elseif ev.code == ABS_Y then state.ry = ev.value end
    elseif ev.type == EV_KEY and ev.code == BTN_TOUCH then
        state.touching = (ev.value ~= 0)
        if not state.touching then
            -- lifting the nib ends the stroke: the next touch starts
            -- a fresh segment instead of drawing a chord from the old
            -- position
            state.px, state.py = nil, nil
        end
    end
    return ev.type == EV_SYN and ev.code == SYN_REPORT
end

-- One batch boundary: if the nib is down, map the current raw position
-- and return the segment to draw (from the previous mapped point, or a
-- dot if the stroke just started).  Updates the previous point.
local function batch_segment(state, geom)
    if not state.touching or state.rx == nil or state.ry == nil then
        return nil
    end
    local rx, ry = state.rx, state.ry
    if geom.swap_xy then rx, ry = ry, rx end
    local x = map_coord(rx, geom.x_lo, geom.x_hi, FB_W - 1, geom.flip_x)
    local y = map_coord(ry, geom.y_lo, geom.y_hi, FB_H - 1, geom.flip_y)
    local seg = { x0 = state.px or x, y0 = state.py or y, x1 = x, y1 = y }
    state.px, state.py = x, y
    return seg
end

-- Collect plotted pixels into per-row runs, clamped to the panel.
-- rows[y] is a sorted-insertion list of {x0, x1} runs; merging happens
-- at write time after a sort, so plotting stays O(1).
local function plot_into(rows, x, y)
    if x < 0 or x >= FB_W or y < 0 or y >= FB_H then return end
    local r = rows[y]
    if not r then r = {}; rows[y] = r end
    r[#r + 1] = x
end

-- Write the collected ink as black pixel runs: one seek+write per
-- contiguous run, then a single fsync to publish the whole batch
-- through the deferred-io path.  fh is an io file opened "r+b"; sync
-- is called with no arguments after the writes.  Returns the number of
-- runs written (the harness pins coalescing and offsets through a fake
-- fh).
local function write_ink_rows(fh, rows, sync)
    local runs = 0
    for y, xs in pairs(rows) do
        table.sort(xs)
        local i = 1
        while i <= #xs do
            local x0 = xs[i]
            local x1 = x0
            while i + 1 <= #xs and xs[i + 1] <= x1 + 1 do
                i = i + 1
                x1 = xs[i]
            end
            fh:seek("set", y * FB_STRIDE + x0 * 4)
            fh:write(string.rep("\0", (x1 - x0 + 1) * 4))
            runs = runs + 1
            i = i + 1
        end
    end
    sync()
    return runs
end

local function now_us()
    local t = ffi.new("struct sc_tv")
    ffi.C.gettimeofday(t, nil)
    return tonumber(t.tv_sec) * 1000000 + tonumber(t.tv_usec)
end

-- ---------------------------------------------------------------------
-- main

local devn, devname
if opt.device then
    devn, devname = opt.device, "(forced by --device)"
else
    devn, devname = find_stylus(opt.sys_root)
end
if not devn then
    log("no stylus-named input device found -- is the digitizer up?")
    os.exit(1)
end
local devpath = opt.dev_root .. "/input/event" .. devn
local fd = ffi.C.open(devpath, O_RDONLY)
if fd < 0 then
    log("cannot open %s (root?)", devpath)
    os.exit(1)
end
log("stylus: %s (%s)", devpath, tostring(devname))

-- Axis ranges straight from the device; a digitizer is not 0..panel.
local geom = {
    swap_xy = opt.swap_xy, flip_x = opt.flip_x, flip_y = opt.flip_y,
    x_lo = 0, x_hi = FB_W - 1, y_lo = 0, y_hi = FB_H - 1,
}
do
    local ax = ffi.new("struct sc_absinfo")
    local ay = ffi.new("struct sc_absinfo")
    if ffi.C.ioctl(fd, eviocgabs(ABS_X), ax) == 0 then
        geom.x_lo, geom.x_hi = ax.minimum, ax.maximum
    end
    if ffi.C.ioctl(fd, eviocgabs(ABS_Y), ay) == 0 then
        geom.y_lo, geom.y_hi = ay.minimum, ay.maximum
    end
    -- After a swap the X range must clothe the Y axis and vice versa.
    if geom.swap_xy then
        geom.x_lo, geom.y_lo = geom.y_lo, geom.x_lo
        geom.x_hi, geom.y_hi = geom.y_hi, geom.x_hi
    end
end
log("axes: x=[%d..%d] y=[%d..%d] swap=%s flip=%s/%s radius=%d",
    geom.x_lo, geom.x_hi, geom.y_lo, geom.y_hi,
    tostring(opt.swap_xy), tostring(opt.flip_x), tostring(opt.flip_y),
    opt.radius)

local fh = io.open(opt.fb, "r+b")
if not fh then
    log("cannot open %s", opt.fb)
    os.exit(1)
end
local fb_fd = ffi.C.open(opt.fb, O_RDWR)
local function publish()
    fh:flush()
    if fb_fd >= 0 then ffi.C.fsync(fb_fd) end
end

local NEV = 64
local buf = ffi.new("struct sc_input_event[?]", NEV)
local state = {}
local batch = 0

log("scribbling; ctrl-c to stop")
while true do
    local got = tonumber(ffi.C.read(fd, buf, NEV * INPUT_EVENT_SIZE))
    if not got or got <= 0 then break end
    local count = math.floor(got / INPUT_EVENT_SIZE)
    for i = 0, count - 1 do
        local e = buf[i]
        local ev = {
            type = e.type, code = e.code, value = e.value,
            tv_sec = tonumber(e.tv_sec), tv_usec = tonumber(e.tv_usec),
        }
        if feed_event(state, ev) then
            local seg = batch_segment(state, geom)
            if seg then
                local rows = {}
                stamp_points(seg.x0, seg.y0, seg.x1, seg.y1, opt.radius,
                             function(x, y) plot_into(rows, x, y) end)
                write_ink_rows(fh, rows, publish)
                batch = batch + 1
                local ev_us = state.ev_sec * 1000000 + state.ev_usec
                log("batch=%d lag_ms=%.1f seg=(%d,%d)-(%d,%d)",
                    batch, (now_us() - ev_us) / 1000,
                    seg.x0, seg.y0, seg.x1, seg.y1)
            end
        end
    end
end
