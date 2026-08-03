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
int fsync(int fd);
int select(int nfds, void *r, void *w, void *e, void *timeout);
struct as_tv { long tv_sec; long tv_usec; };
]]

local O_RDONLY, O_NONBLOCK = 0, 2048
local FD_SETSIZE = 1024

-- Build-time defaults; every one is overridable at runtime through the
-- config file below, which is re-read before each idle wait.
local opt = {
    idle = 300,
    backstop = 900,
    dry = false,
    verbose = true,
    overlay = true,
    config = "/var/lib/pinenote/autosuspend.conf",
}
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--idle" then i = i + 1; opt.idle = tonumber(arg[i])
        elseif a == "--backstop" then i = i + 1; opt.backstop = tonumber(arg[i])
        elseif a == "--dry-run" then opt.dry = true
        elseif a == "--quiet" then opt.verbose = false
        elseif a == "--no-overlay" then opt.overlay = false
        elseif a == "--banner-only" then opt.banner_only = true
        elseif a == "--config" then i = i + 1; opt.config = arg[i]
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

-- Runtime tunables.  Written by anyone with root; picked up on the next
-- idle wait without restarting the daemon:
--     idle=120        seconds of no input before suspending
--     backstop=900    RTC safety wake, seconds
--     enabled=0       pause auto-suspend entirely
-- Unknown or malformed keys are ignored rather than fatal: a typo in this
-- file must not leave the device unable to sleep OR unable to wake.
local runtime = { idle = nil, backstop = nil, enabled = true }
local function reload_config()
    runtime.idle, runtime.backstop, runtime.enabled = nil, nil, true
    local f = io.open(opt.config, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)")
        if k == "idle" and tonumber(v) and tonumber(v) >= 5 then
            runtime.idle = math.floor(tonumber(v))
        elseif k == "backstop" and tonumber(v) and tonumber(v) >= 30 then
            runtime.backstop = math.floor(tonumber(v))
        elseif k == "enabled" then
            runtime.enabled = not (v == "0" or v == "false" or v == "no")
        end
    end
    f:close()
end
local function idle_secs() return runtime.idle or opt.idle end
local function backstop_secs() return runtime.backstop or opt.backstop end

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
reload_config()
log("watching %d input devices, idle=%ds backstop=%ds overlay=%s config=%s%s",
    #fds, idle_secs(), backstop_secs(), tostring(opt.overlay), opt.config,
    opt.dry and " [DRY RUN]" or "")

local drain = ffi.new("uint8_t[512]")


--[[ Sleep screen -----------------------------------------------------

The panel is bistable, so whatever is on it when power goes away stays
there for free, for as long as the device sleeps.  We want that to be the
page you were reading plus a small banner, not a white void.

Two halves:
  * rockchip_ebc's `no_off_screen` module parameter stops the driver
    washing the panel to its off-screen buffer at suspend.  Without this
    the driver paints over whatever we drew.  (The off-screen buffer is
    all-white here anyway, because rockchip_ebc_default_screen.bin is
    absent and the driver memsets 0xff as a fallback.)
  * we draw the banner into /dev/fb0 and fsync, which publishes it through
    the same path a page turn uses.

Font is 8x8, uppercase only, scaled by an integer factor -- enough for a
status line and far less machinery than pulling in a real renderer.
--]]

local FB_W, FB_H, FB_STRIDE = 1872, 1404, 7488

local FONT = {
  [" "]="0000000000000000", ["-"]="000000007E000000", ["."]="0000000000181800",
  ["A"]="1818243C42425A00", ["B"]="7C42427C42427C00", ["C"]="3C42404040423C00",
  ["D"]="7844424242447800", ["E"]="7E40407C40407E00", ["F"]="7E40407C40404000",
  ["G"]="3C42404E42423C00", ["H"]="4242427E42424200", ["I"]="3C18181818183C00",
  ["J"]="1E0404040444380C", ["K"]="4244487048444200", ["L"]="4040404040407E00",
  ["M"]="42665A5A42424200", ["N"]="42625A5A46424200", ["O"]="3C42424242423C00",
  ["P"]="7C42427C40404000", ["Q"]="3C424242524A3C02", ["R"]="7C42427C48444200",
  ["S"]="3C42403C02423C00", ["T"]="7E18181818181800", ["U"]="4242424242423C00",
  ["V"]="4242424224241800", ["W"]="42424A5A5A664200", ["X"]="4224241818244200",
  ["Y"]="4224241818181800", ["Z"]="7E020418204070FE",
}

local function fb_open()
    local fd = ffi.C.open("/dev/fb0", 2)  -- O_RDWR
    if fd < 0 then return nil end
    return fd
end

-- Draw the banner directly with pwrite-style seeks: mmap is unnecessary
-- for a few rows and this keeps the failure modes simple.
local function draw_banner(text, scale)
    local fd = fb_open()
    if not fd then return false, "open /dev/fb0" end
    scale = scale or 6
    local ch_w, ch_h = 8 * scale, 8 * scale
    local pad = scale * 3
    local bar_h = ch_h + pad * 2
    local text_w = #text * ch_w
    local x0 = math.floor((FB_W - text_w) / 2)
    if x0 < 0 then x0 = 0 end
    local y0 = pad

    local row = ffi.new("uint8_t[?]", FB_STRIDE)
    for y = 0, bar_h - 1 do
        -- white bar, with a black rule along the bottom edge to delimit it
        local rule = (y >= bar_h - math.max(2, math.floor(scale / 2)))
        local v = rule and 0x00 or 0xFF
        ffi.fill(row, FB_STRIDE, v)
        if not rule then
            local gy = y - y0
            if gy >= 0 and gy < ch_h then
                local fr = math.floor(gy / scale)
                for ci = 1, #text do
                    local glyph = FONT[text:sub(ci, ci)] or FONT[" "]
                    local byte = tonumber(glyph:sub(fr * 2 + 1, fr * 2 + 2), 16) or 0
                    for bx = 0, 7 do
                        if bit.band(byte, bit.lshift(1, 7 - bx)) ~= 0 then
                            local px = x0 + (ci - 1) * ch_w + bx * scale
                            for sx = 0, scale - 1 do
                                local o = (px + sx) * 4
                                if o >= 0 and o + 3 < FB_STRIDE then
                                    row[o] = 0; row[o+1] = 0; row[o+2] = 0; row[o+3] = 0
                                end
                            end
                        end
                    end
                end
            end
        end
        local f = io.open("/dev/fb0", "r+b")
        if not f then ffi.C.close(fd); return false, "reopen" end
        f:seek("set", y * FB_STRIDE)
        f:write(ffi.string(row, FB_STRIDE))
        f:close()
    end
    ffi.C.fsync(fd)
    ffi.C.close(fd)
    return true
end

local SLEEP_TEXT = "SUSPENDED - PRESS POWER TO RESUME"

local function set_no_off_screen(on)
    write_file("/sys/module/rockchip_ebc/parameters/no_off_screen",
               on and "1" or "0")
end

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
    if not arm_backstop(backstop_secs()) then
        log("could not arm RTC backstop -- refusing to suspend")
        restore_gadget(saved)
        return false
    end
    -- Sleep screen: keep the current page and stamp a banner on it.  Order
    -- matters -- no_off_screen must be set BEFORE the refresh thread parks,
    -- or the driver washes over the banner on its way down.
    if opt.overlay then
        set_no_off_screen(true)
        local ok, err = draw_banner(SLEEP_TEXT, 6)
        if not ok then log("banner failed (%s); sleeping without it", tostring(err)) end
        -- let the panel finish painting before power goes away
        os.execute("sleep 1")
    end
    write_file("/dev/kmsg", "<0>WILKBOOK: autosuspend entering deep")
    os.execute("sync")
    local t0 = os.time()
    write_file("/sys/power/state", "mem")
    local slept = os.time() - t0
    write_file("/dev/kmsg", "<0>WILKBOOK: autosuspend resumed")
    restore_gadget(saved)
    if opt.overlay then
        -- hand the panel back to the reader: allow the normal off-screen
        -- behaviour again and force one clean full refresh over the banner.
        set_no_off_screen(false)
        os.execute("pinenote-ebc-refresh >/dev/null 2>&1")
    end
    log("resumed after %ds", slept)
    return true
end

-- Development aid: paint the sleep screen and exit, so the banner can be
-- iterated on without suspending anything.
if opt.banner_only then
    set_no_off_screen(true)
    local ok, err = draw_banner(SLEEP_TEXT, 6)
    log("banner-only: %s", ok and "drawn" or ("failed: " .. tostring(err)))
    os.exit(ok and 0 or 1)
end

local tv = ffi.new("struct as_tv")
local last_activity = os.time()

while true do
    reload_config()
    if not runtime.enabled then
        -- paused at runtime: stay responsive, just never suspend
        last_activity = os.time()
    end
    local remaining = idle_secs() - (os.time() - last_activity)
    if remaining <= 0 and runtime.enabled then
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
