--[[--
frame-clock.lua: time every EBC frame IRQ during a refresh at sub-ms
resolution.  The tool that caught the direct driver stretching
full-panel frames to 18.4 ms against the panel's 12.0 ms scan period
-- the NEON advance is compute-bound at 1.8 GHz, so any clip much
larger than half the panel runs its waveform out of the vendor timing
contract while pen-sized damage stays on it (doc/status.md 2026-08-26
part 11; doc/artifacts/pinenote-optics-turnroutes-20260826/).

Usage: frame-clock.lua --wash                 (GLOBAL_REFRESH, 38 frames)
       frame-clock.lua --block WxH+X+Y        (partial: black rect, fb px;
                                               restores white after)
       [--window-ms N]  observation window (default 2500)
Prints total frames, span, and per-frame deltas in ms.
--]]

package.path = (arg[0] or ""):match("^(.*)/") and
    ((arg[0]):match("^(.*)/") .. "/?.lua;" .. package.path) or package.path
local lib = require("ebclib")
local ffi = require("ffi")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
int fsync(int fd);
int ioctl(int fd, unsigned long req, void *arg);
struct fc_tv { long tv_sec; long tv_usec; };
int gettimeofday(struct fc_tv *tv, void *tz);
]]

local opt = { window_ms = 2500, sys_root = "/sys", proc_root = "/proc" }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--wash" then opt.wash = true
        elseif a == "--block" then
            i = i + 1
            local w, h, x, y = (arg[i] or ""):match("^(%d+)x(%d+)%+(%d+)%+(%d+)$")
            if not w then
                io.stderr:write("bad --block, want WxH+X+Y\n")
                os.exit(2)
            end
            opt.block = { w = tonumber(w), h = tonumber(h),
                          x = tonumber(x), y = tonumber(y) }
        elseif a == "--window-ms" then i = i + 1; opt.window_ms = tonumber(arg[i]) or 2500
        elseif a == "--sys-root" then i = i + 1; opt.sys_root = arg[i]
        elseif a == "--proc-root" then i = i + 1; opt.proc_root = arg[i]
        end
        i = i + 1
    end
end
if not opt.wash and not opt.block then
    io.stderr:write("give --wash or --block WxH+X+Y\n")
    os.exit(2)
end

local function now_us()
    local t = ffi.new("struct fc_tv")
    ffi.C.gettimeofday(t, nil)
    return tonumber(t.tv_sec) * 1000000 + tonumber(t.tv_usec)
end

local fh, fb_fd
local function write_block(val)
    local b = opt.block
    local _, _, stride, bypp = lib.fb_geometry(opt.sys_root)
    stride, bypp = stride or 3744, bypp or 2
    local row = string.rep(string.char(val), b.w * bypp)
    for y = b.y, b.y + b.h - 1 do
        fh:seek("set", y * stride + b.x * bypp)
        fh:write(row)
    end
    fh:flush()
    ffi.C.fsync(fb_fd)
end

local base = lib.ebc_irq_count(opt.proc_root)
if not base then
    io.stderr:write("no EBC line in " .. opt.proc_root .. "/interrupts\n")
    os.exit(1)
end
local t0 = now_us()

if opt.wash then
    local card = lib.find_ebc_card(opt.sys_root)
    if not card then io.stderr:write("no EBC card\n"); os.exit(1) end
    local fd = ffi.C.open("/dev/dri/card" .. card, 2)
    local b = ffi.new("uint8_t[1]", 1)
    ffi.C.ioctl(fd, lib.GLOBAL_REFRESH_IOCTL, b)
    ffi.C.close(fd)
else
    fh = io.open("/dev/fb0", "r+b")
    if not fh then io.stderr:write("cannot open /dev/fb0\n"); os.exit(1) end
    fb_fd = ffi.C.open("/dev/fb0", 2)
    write_block(0)
end

local events, last = {}, base
while now_us() - t0 < opt.window_ms * 1000 do
    local c = lib.ebc_irq_count(opt.proc_root)
    if c ~= last then
        events[#events + 1] = { t = now_us() - t0, n = c - base }
        last = c
    end
end

print(("frames=%d span=%.1fms"):format(
    events[#events] and events[#events].n or 0,
    events[#events] and events[#events].t / 1000 or 0))
for i = 2, #events do
    io.write(("%.1f "):format((events[i].t - events[i - 1].t) / 1000
                              / (events[i].n - events[i - 1].n)))
end
print()

if opt.block then write_block(255) end
