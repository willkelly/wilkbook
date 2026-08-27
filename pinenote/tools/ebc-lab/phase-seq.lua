--[[--
Userspace phase-sequence driver: submit a raw drive program to the
direct driver's PHASE_SEQUENCE ioctl -- regions, phase bytes, frame
counts, delays -- and the kernel executes it against the glass.  This
is the "user mode driver" iteration seam: custom transitions authored
and revised over SSH in minutes, no image write, no kernel rebuild.

The phase byte is 4 pixels x 2 bits of raw drive: 0x00 idle,
0x55 all-darken, 0xAA all-lighten.  DC balance is the author's problem
-- the wbf-clut --balance-report envelope (DU/DU4 round-trips 0,
GL16/GC16 within +/-48 cold) is the reference for what the vendor
considers safe; stay inside it.

CAUTION, by the driver's own construction: after a phase sequence runs,
the driver parks in ZERO_WAVEFORM mode -- the panel stops responding to
ordinary damage until a MODE ioctl restores NORMAL.  --then-normal does
that automatically; without it, this tool prints the reminder.

DANGER (2026-08-27, doc/status.md part 17): the FIRST live run of this
path -- `--init --then-normal`, on the parallel-advance module --
CRASHED THE KERNEL hard enough to reboot the SoC (no pstore, no UART
listener, cause unattributed: hrdl's phase-sequence executor had never
been exercised by us, and the banded advance was loaded).  Do not run
this tool again except in a UART-attended driver session prepared for
a reboot.

Usage: phase-seq.lua [--init] [--gc16] [--gc-target N] [--temp BIN]
                     [--delay MS] [--elm SPEC] (--elm repeatable)
                     [--then-normal] [--sys-root DIR] [--dev-root DIR]
An elm SPEC is DELAY_MS,FRAMES,REGIONS where REGIONS is one or more
semicolon-separated X+Y+WxH:PHASE entries.
Example -- a crude two-stage turn on the top half of the panel:
  phase-seq.lua --elm 0,6,0+0+1872x702:0x55 --elm 0,6,0+0+1872x702:0xAA \
                --then-normal
--]]

package.path = (arg[0] or ""):match("^(.*)/") and
    ((arg[0]):match("^(.*)/") .. "/?.lua;" .. package.path) or package.path
local lib = require("ebclib")
local ffi = require("ffi")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
int ioctl(int fd, unsigned long req, void *arg);
]]

local O_RDWR = 2

local spec = { elms = {} }
local opt = { then_normal = false, sys_root = "/sys", dev_root = "/dev" }

local function parse_elm(s)
    local delay, frames, rest = s:match("^(%d+),(%d+),(.+)$")
    if not delay then return nil, "want DELAY_MS,FRAMES,REGIONS" end
    local e = { delay_ms = tonumber(delay), num_frames = tonumber(frames),
                regions = {} }
    for part in rest:gmatch("[^;]+") do
        local x, y, w, h, phase =
            part:match("^(%d+)%+(%d+)%+(%d+)x(%d+):(0?[xX]?%x+)$")
        if not x then return nil, "bad region '" .. part .. "'" end
        e.regions[#e.regions + 1] = {
            x = tonumber(x), y = tonumber(y),
            w = tonumber(w), h = tonumber(h),
            phase = tonumber(phase) or tonumber(phase, 16),
        }
    end
    if #e.regions == 0 then return nil, "no regions" end
    return e
end

do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--init" then spec.do_init = true
        elseif a == "--gc16" then spec.do_gc16 = true
        elseif a == "--gc-target" then i = i + 1; spec.gc_target = tonumber(arg[i])
        elseif a == "--temp" then i = i + 1; spec.temperature = tonumber(arg[i])
        elseif a == "--delay" then i = i + 1; spec.delay_ms = tonumber(arg[i])
        elseif a == "--elm" then
            i = i + 1
            local e, err = parse_elm(arg[i] or "")
            if not e then
                io.stderr:write("bad --elm: " .. err .. "\n")
                os.exit(2)
            end
            spec.elms[#spec.elms + 1] = e
        elseif a == "--then-normal" then opt.then_normal = true
        elseif a == "--sys-root" then i = i + 1; opt.sys_root = arg[i]
        elseif a == "--dev-root" then i = i + 1; opt.dev_root = arg[i]
        end
        i = i + 1
    end
end

if #spec.elms == 0 and not spec.do_init and not spec.do_gc16 then
    io.stderr:write("empty program: give --elm, --init, or --gc16\n")
    os.exit(2)
end

local blob, err = lib.pack_phase_sequence(spec)
if not blob then
    io.stderr:write("pack failed: " .. err .. "\n")
    os.exit(2)
end

local card = lib.find_ebc_card(opt.sys_root)
if not card then
    io.stderr:write("no DRM card with DRIVER=rockchip-ebc\n")
    os.exit(1)
end
local fd = ffi.C.open(opt.dev_root .. "/dri/card" .. card, O_RDWR)
if fd < 0 then
    io.stderr:write("cannot open card" .. card .. " (root?)\n")
    os.exit(1)
end

local buf = ffi.new("uint8_t[?]", #blob)
ffi.copy(buf, blob, #blob)
local ret = ffi.C.ioctl(fd, lib.PHASE_SEQUENCE_IOCTL, buf)
if ret ~= 0 then
    ffi.C.close(fd)
    io.stderr:write("PHASE_SEQUENCE ioctl failed (ret=" .. tostring(ret) .. ")\n")
    os.exit(1)
end
print(("phase sequence submitted: %d element(s)%s%s")
    :format(#spec.elms, spec.do_init and " +init" or "",
            spec.do_gc16 and " +gc16" or ""))

if opt.then_normal then
    local mode = ffi.new("uint8_t[8]")
    ffi.copy(mode, lib.pack_mode(true, 0, false, 0), 8)
    local r2 = ffi.C.ioctl(fd, lib.MODE_IOCTL, mode)
    print(r2 == 0 and "mode restored to NORMAL"
                   or "MODE restore FAILED -- panel is parked in ZERO_WAVEFORM")
else
    print("note: driver parks in ZERO_WAVEFORM after the run; restore with"
          .. " ebc-mode --normal (or pass --then-normal)")
end
ffi.C.close(fd)
