--[[
Scripted orientation injector -- drive KOReader rotations without hands.

Sibling of pinenote/tools/optics/optics-inject.lua, which does the same
job for page turns. Measuring a refresh cost per rotation otherwise needs
a human to physically tilt the device inside the sampling window, and a
missed window costs a whole measurement cycle (three were lost on
2026-08-04 that way).

It impersonates the real bridge deliberately and completely:

  name     wilkbook-orientation
  identity bustype 0x06, vendor 0x1209, product 0x0002, version 1
  protocol EV_MSC / MSC_RAW / <mode>, then EV_SYN / SYN_REPORT

device.lua accepts the gsensor ONLY on that full identity (a name alone
is spoofable -- see its "defense in depth" comment), so anything less
than the exact tuple is ignored and the rotation silently never arrives.

Modes are the calibrated physical-edge contract from orientation_core.lua
-- do NOT renumber:
    0 = RIGHT edge up      2 = LEFT edge up
    1 = TOP edge up        3 = BOTTOM edge up

The real bridge must be STOPPED first: two devices of the same name race
for the gsensor slot and which one KOReader binds is enumeration order,
i.e. luck. And because the gsensor is a required device, dropping the
bridge makes reader-session restart -- that is expected, and it is what
makes KOReader enumerate this device instead.

Usage:
    orientation-inject.lua                  # interactive: modes on stdin
    orientation-inject.lua --fifo PATH      # read modes from a fifo
    orientation-inject.lua --seq 1,3,1 --gap 8   # scripted, then exit
--]]

local ffi = require("ffi")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
long write(int fd, const void *buf, unsigned long n);
int ioctl(int fd, unsigned long request, ...);
struct input_id { unsigned short bustype, vendor, product, version; };
struct uinput_user_dev { char name[80]; struct input_id id; unsigned int ff_effects_max;
  int absmax[64]; int absmin[64]; int absfuzz[64]; int absflat[64]; };
struct input_event { long tv_sec, tv_usec; unsigned short type, code; int value; };
unsigned int sleep(unsigned int seconds);
]]
local C = ffi.C

local O_WRONLY = 1
local EV_SYN, EV_MSC, SYN_REPORT, MSC_RAW = 0, 4, 0, 3
local BUS_VIRTUAL = 0x06
local UI_SET_EVBIT, UI_SET_MSCBIT = 0x40045564, 0x40045568
local UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
local DEVICE_NAME = "wilkbook-orientation"
local READY = "/run/wilkbook-orientation.ready"

local opt = { gap = 6 }
do
    local i = 1
    while i <= #arg do
        if arg[i] == "--fifo" then i = i + 1; opt.fifo = arg[i]
        elseif arg[i] == "--seq" then i = i + 1; opt.seq = arg[i]
        elseif arg[i] == "--gap" then i = i + 1; opt.gap = tonumber(arg[i]) or 6
        end
        i = i + 1
    end
end

local function log(fmt, ...)
    io.stderr:write("[orientation-inject] " .. string.format(fmt, ...) .. "\n")
    io.stderr:flush()
end

local fd = C.open("/dev/uinput", O_WRONLY)
assert(fd >= 0, "cannot open /dev/uinput (root?)")
assert(C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_SYN)) == 0, "UI_SET_EVBIT EV_SYN")
assert(C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_MSC)) == 0, "UI_SET_EVBIT EV_MSC")
assert(C.ioctl(fd, UI_SET_MSCBIT, ffi.cast("int", MSC_RAW)) == 0, "UI_SET_MSCBIT MSC_RAW")

local dev = ffi.new("struct uinput_user_dev")
ffi.copy(dev.name, DEVICE_NAME)
dev.id.bustype, dev.id.vendor, dev.id.product, dev.id.version =
    BUS_VIRTUAL, 0x1209, 0x0002, 1
assert(C.write(fd, dev, ffi.sizeof(dev)) == ffi.sizeof(dev), "write uinput_user_dev")
assert(C.ioctl(fd, UI_DEV_CREATE) == 0, "UI_DEV_CREATE")

-- The bridge publishes this; anything waiting on the bridge waits on it.
local rf = io.open(READY, "w")
if rf then rf:write("inject\n"); rf:close() end

log("created %s (bus 0x%02x vid 0x%04x pid 0x%04x ver %d)",
    DEVICE_NAME, BUS_VIRTUAL, 0x1209, 0x0002, 1)

local ev = ffi.new("struct input_event")
local function emit(mode)
    ev.type, ev.code, ev.value = EV_MSC, MSC_RAW, mode
    assert(C.write(fd, ev, ffi.sizeof(ev)) == ffi.sizeof(ev))
    ev.type, ev.code, ev.value = EV_SYN, SYN_REPORT, 0
    assert(C.write(fd, ev, ffi.sizeof(ev)) == ffi.sizeof(ev))
    log("emitted mode %d", mode)
end

local function cleanup()
    C.ioctl(fd, UI_DEV_DESTROY)
    C.close(fd)
    os.remove(READY)
    log("destroyed %s", DEVICE_NAME)
end

if opt.seq then
    local first = true
    for m in opt.seq:gmatch("[^,]+") do
        local mode = tonumber(m)
        if mode and mode >= 0 and mode <= 3 then
            if not first then C.sleep(opt.gap) end
            first = false
            emit(mode)
        else
            log("skipping bad mode %q (want 0-3)", tostring(m))
        end
    end
    C.sleep(opt.gap)
    cleanup()
    return
end

local src = opt.fifo and io.open(opt.fifo, "r") or io.stdin
if not src then cleanup(); error("cannot open " .. tostring(opt.fifo)) end
log("reading modes (0-3), one per line%s", opt.fifo and (" from " .. opt.fifo) or "")
while true do
    local line = src:read("*l")
    if not line then
        if opt.fifo then src = io.open(opt.fifo, "r"); if src then goto continue end end
        break
    end
    local mode = tonumber((line:gsub("%s", "")))
    if line:match("quit") then break end
    if mode and mode >= 0 and mode <= 3 then emit(mode)
    elseif #line > 0 then log("ignored %q", line) end
    ::continue::
end
cleanup()
