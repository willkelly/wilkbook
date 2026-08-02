--[[--
PineNote auto-suspend: sleep to platform `deep` after a period with no
user input, and come back on a button press.

Why this exists, in one line: awake idle costs ~172 mA and deep costs
~19.3 mA (measured 2026-08-02), so scheduling deep well is worth ~7x --
far more than any other power lever available on this platform.

Design notes, all of them earned on hardware:

  * The reader STAYS RUNNING across the cycle.  Proven 2026-08-02: KOReader
    survives suspend/resume in place with the same processes, and the
    display pipeline works afterwards.  Every earlier deep test stopped
    reader-session first, which is not something an auto-suspend daemon
    can do.
  * The USB gadget MUST be quiesced first.  An attached ACM session
    hard-vetoes suspend through dwc3.
  * Wake is by power button, hardware-proven 2026-08-02 (woke at 35s
    against a 90s RTC backstop, with the alarm still pending).  The button
    press also arrives as an input event, which naturally resets the idle
    timer on resume.
  * An RTC backstop is armed on every cycle.  If a future kernel or DT
    change breaks button wake, the device still returns instead of
    becoming a brick in a bag.  This is cheap insurance and should not be
    removed.

Activity is any readable event on any /dev/input/event*, so touch, pen,
buttons and the cover all count.

Usage: autosuspend.lua [--idle SECONDS] [--backstop SECONDS] [--dry-run]
--]]

local ffi = require("ffi")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
ssize_t read(int fd, void *buf, size_t n);
int select(int nfds, void *r, void *w, void *e, void *timeout);
struct as_tv { long tv_sec; long tv_usec; };
]]

local O_RDONLY, O_NONBLOCK = 0, 2048
local FD_SETSIZE = 1024

local opt = { idle = 300, backstop = 900, dry = false, verbose = true }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--idle" then i = i + 1; opt.idle = tonumber(arg[i])
        elseif a == "--backstop" then i = i + 1; opt.backstop = tonumber(arg[i])
        elseif a == "--dry-run" then opt.dry = true
        elseif a == "--quiet" then opt.verbose = false
        end
        i = i + 1
    end
end

local function log(fmt, ...)
    if not opt.verbose then return end
    io.stderr:write(("[autosuspend] " .. fmt .. "\n"):format(...))
    io.stderr:flush()
end

local function write_file(path, value)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(value)
    local ok = f:close()
    return ok and true or false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

-- fd_set helpers: a bit array of longs, which is what select() wants.
local LONG_BITS = 64
local fdset = ffi.new("long[?]", FD_SETSIZE / LONG_BITS)
local function fd_zero()
    for i = 0, (FD_SETSIZE / LONG_BITS) - 1 do fdset[i] = 0 end
end
local function fd_set(fd)
    local idx = math.floor(fd / LONG_BITS)
    fdset[idx] = bit.bor(fdset[idx], bit.lshift(1ULL, fd % LONG_BITS))
end
local function fd_isset(fd)
    local idx = math.floor(fd / LONG_BITS)
    return bit.band(fdset[idx], bit.lshift(1ULL, fd % LONG_BITS)) ~= 0
end

-- open every input device
-- Enumerate by probing rather than popen: this luajit has no io.popen,
-- and probing avoids depending on a shell at all.
local fds, maxfd = {}, 0
for n = 0, 31 do
    local path = "/dev/input/event" .. n
    local fd = ffi.C.open(path, bit.bor(O_RDONLY, O_NONBLOCK))
    if fd >= 0 then
        fds[#fds + 1] = { fd = fd, path = path }
        if fd > maxfd then maxfd = fd end
    end
end
if #fds == 0 then
    log("no input devices -- refusing to run (would suspend with no way to notice activity)")
    os.exit(1)
end
log("watching %d input devices, idle=%ds backstop=%ds%s",
    #fds, opt.idle, opt.backstop, opt.dry and " [DRY RUN]" or "")

local drain = ffi.new("uint8_t[512]")

local function quiesce_gadget()
    local udc = "/sys/kernel/config/usb_gadget/pinenote-acm/UDC"
    local cur = read_file(udc)
    if cur and cur ~= "" then
        write_file(udc, "")
        return cur
    end
    return nil
end

local function restore_gadget(saved)
    if saved and saved ~= "" then
        write_file("/sys/kernel/config/usb_gadget/pinenote-acm/UDC", saved)
    end
end

local function arm_backstop(seconds)
    write_file("/sys/class/rtc/rtc0/wakealarm", "0")
    local now = tonumber(read_file("/sys/class/rtc/rtc0/since_epoch") or "0")
    if now > 0 then
        write_file("/sys/class/rtc/rtc0/wakealarm", tostring(now + seconds))
        return true
    end
    return false
end

local function suspend_once()
    -- deep is the whole point; refuse rather than silently do s2idle.
    write_file("/sys/power/mem_sleep", "deep")
    local mode = read_file("/sys/power/mem_sleep") or ""
    if not mode:find("%[deep%]") then
        log("deep unavailable (mem_sleep=%s) -- not suspending", mode)
        return false
    end
    local saved = quiesce_gadget()
    if not arm_backstop(opt.backstop) then
        log("could not arm RTC backstop -- refusing to suspend")
        restore_gadget(saved)
        return false
    end
    write_file("/dev/kmsg", "<0>WILKBOOK: autosuspend entering deep")
    os.execute("sync")
    local t0 = os.time()
    write_file("/sys/power/state", "mem")
    local slept = os.time() - t0
    write_file("/dev/kmsg", "<0>WILKBOOK: autosuspend resumed")
    restore_gadget(saved)
    log("resumed after %ds", slept)
    return true
end

local tv = ffi.new("struct as_tv")
local last_activity = os.time()

while true do
    local remaining = opt.idle - (os.time() - last_activity)
    if remaining <= 0 then
        if opt.dry then
            log("DRY RUN: would suspend now")
            last_activity = os.time()
        else
            suspend_once()
            -- the wake press itself lands as input; treat resume as activity
            last_activity = os.time()
        end
    else
        fd_zero()
        for _, d in ipairs(fds) do fd_set(d.fd) end
        tv.tv_sec = remaining
        tv.tv_usec = 0
        local n = ffi.C.select(maxfd + 1, fdset, nil, nil, tv)
        if n and n > 0 then
            for _, d in ipairs(fds) do
                if fd_isset(d.fd) then
                    while ffi.C.read(d.fd, drain, 512) > 0 do end
                end
            end
            last_activity = os.time()
        end
    end
end
