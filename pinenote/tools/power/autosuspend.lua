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
/* struct input_event: 16-byte timeval then type/code/value = 24 bytes. */
struct as_input_event {
    long tv_sec; long tv_usec;
    unsigned short type; unsigned short code; int value;
};
]]

local EV_KEY, KEY_POWER = 1, 116
local INPUT_EVENT_SIZE = 24

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
    -- Do not sleep while plugged in.  On a charger there is no power to
    -- save, and a device that darkens on your desk while you are using it
    -- is just friction.  Opt in with --suspend-while-charging, or
    -- suspend_while_charging=1 at runtime.
    charging_inhibits = true,
    -- A short press of the power button suspends immediately, without
    -- waiting out the idle timer.  This is the same button that WAKES the
    -- device, so the press that woke it must never be read as a request to
    -- sleep again -- see power_grace below.
    power_key = true,
    -- Longer than this and it is not a tap: the PMIC handles a real
    -- long-press as a hard power-off, and we must not race it by
    -- suspending on the way there.
    power_tap_ms = 1000,
    -- Ignore the power button for this long after a resume.  The wake
    -- press is delivered as an ordinary input event once the device is
    -- back, and without this the device would sleep again instantly.
    power_grace_s = 2,
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
        elseif a == "--suspend-while-charging" then opt.charging_inhibits = false
        elseif a == "--no-power-key" then opt.power_key = false
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
local runtime = { idle = nil, backstop = nil, enabled = true, charging = nil,
                  power_key = nil }
local function reload_config()
    runtime.idle, runtime.backstop, runtime.enabled = nil, nil, true
    runtime.charging = nil
    runtime.power_key = nil
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
        elseif k == "suspend_while_charging" then
            runtime.charging = (v == "1" or v == "true" or v == "yes")
        elseif k == "power_key" then
            runtime.power_key = not (v == "0" or v == "false" or v == "no")
        end
    end
    f:close()
end
local function idle_secs() return runtime.idle or opt.idle end
local function backstop_secs() return runtime.backstop or opt.backstop end
local function power_key_on()
    if runtime.power_key ~= nil then return runtime.power_key end
    return opt.power_key
end

-- Any mains/USB supply reporting online counts as "plugged in".  The
-- candidate list is explicit because this luajit has no io.popen;
-- rk817-charger is the real one on this hardware and the rest are cheap
-- insurance if the supply set ever changes.
local SUPPLIES = { "rk817-charger", "usb", "ac", "usb-c", "rk817-usb" }
local function on_external_power()
    for _, name in ipairs(SUPPLIES) do
        if read_file("/sys/class/power_supply/" .. name .. "/online") == "1" then
            return true, name
        end
    end
    return false
end
local function may_suspend_charging()
    if runtime.charging ~= nil then return runtime.charging end
    return not opt.charging_inhibits
end
local charging_notice = false

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
-- Identify the power key by NAME, never by a fixed event number: the
-- input node order is not stable across boots (observed 2026-08-04, when
-- the accelerometer moved iio:device2 -> iio:device1 and its IRQ 73 -> 71
-- across a power cycle).
local function input_name(n)
    local f = io.open("/sys/class/input/event" .. n .. "/device/name", "r")
    if not f then return nil end
    local name = f:read("*l")
    f:close()
    return name
end

local fds, maxfd = {}, 0
for n = 0, 31 do
    local path = "/dev/input/event" .. n
    local fd = ffi.C.open(path, bit.bor(O_RDONLY, O_NONBLOCK))
    if fd >= 0 then
        local name = input_name(n) or ""
        fds[#fds + 1] = {
            fd = fd, path = path, name = name,
            -- "rk805 pwrkey" on this board; match loosely so a rename or a
            -- different PMIC revision does not silently drop the feature.
            is_power = name:lower():find("pwrkey", 1, true) ~= nil
                    or name:lower():find("power", 1, true) ~= nil,
        }
        if fd > maxfd then maxfd = fd end
    end
end
if #fds == 0 then
    log("no input devices -- refusing to run (would suspend with no way to notice activity)")
    os.exit(1)
end
reload_config()
local power_nodes = {}
for _, d in ipairs(fds) do
    if d.is_power then power_nodes[#power_nodes + 1] = d.path .. " (" .. d.name .. ")" end
end
log("watching %d input devices, idle=%ds backstop=%ds overlay=%s config=%s%s",
    #fds, idle_secs(), backstop_secs(), tostring(opt.overlay), opt.config,
    opt.dry and " [DRY RUN]" or "")
if #power_nodes == 0 then
    log("no power-key node found -- press-to-suspend unavailable (idle timer still works)")
else
    log("press-to-suspend on %s (tap < %dms; %ds grace after resume)",
        table.concat(power_nodes, ", "), opt.power_tap_ms, opt.power_grace_s)
end

-- Must hold a whole number of input_events so a short read never splits a
-- record across reads and desynchronises the parse.
local DRAIN_EVENTS = 64
local drain = ffi.new("uint8_t[?]", DRAIN_EVENTS * INPUT_EVENT_SIZE)

-- Returns true if a short tap of the power button was seen on this fd.
-- A long hold is deliberately ignored: the PMIC turns the device off on
-- its own, and suspending on the way there would race that.
--
-- Press duration comes from the events' own timestamps, not os.time():
-- os.time() has one-second granularity, which cannot tell a tap from a
-- half-second hold, and os.clock() is CPU time in a process that is idle
-- essentially always.
local function scan_power_events(d, nbytes)
    local ev = ffi.cast("struct as_input_event *", drain)
    -- ffi.C.read() returns ssize_t, which reaches Lua as cdata, not a
    -- number: math.floor() rejects it outright ("bad argument #1 to
    -- 'floor' (number expected, got cdata)").  Every value that crosses
    -- from ffi into arithmetic here has to go through tonumber().
    local count = math.floor(tonumber(nbytes) / INPUT_EVENT_SIZE)
    local tapped = false
    for i = 0, count - 1 do
        local e = ev[i]
        if e.type == EV_KEY and e.code == KEY_POWER then
            local t_ms = tonumber(e.tv_sec) * 1000 + tonumber(e.tv_usec) / 1000
            if e.value == 1 then
                d.press_ms = t_ms
            elseif e.value == 0 then
                -- A release with no matching press means the press was
                -- consumed elsewhere (typically the wake). Do not treat a
                -- bare release as a tap.
                if d.press_ms then
                    local held = t_ms - d.press_ms
                    if held >= 0 and held <= opt.power_tap_ms then tapped = true end
                end
                d.press_ms = nil
            end
            -- value == 2 is autorepeat during a hold: not a tap.
        end
    end
    return tapped
end

-- Discard anything queued on every input device.  Called after a resume so
-- the press that woke the device is not then read as a request to sleep.
local function drain_all()
    for _, d in ipairs(fds) do
        while ffi.C.read(d.fd, drain, ffi.sizeof(drain)) > 0 do end
        d.press_ms = nil
    end
end


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
-- Pixels the banner covers, stashed so resume can put them back.  Drawing
-- the banner destroys whatever was underneath, and the post-resume global
-- refresh faithfully repaints the framebuffer -- banner included -- so
-- without this the banner never goes away.  (Observed 2026-08-03.)
local saved_band, saved_rows = nil, 0

local function banner_geometry(scale)
    local ch_h = 8 * scale
    local pad = scale * 3
    return ch_h + pad * 2, ch_h, pad
end

local function draw_banner(text, scale)
    scale = scale or 6
    local bar_h, ch_h, pad = banner_geometry(scale)
    local ch_w = 8 * scale
    local text_w = #text * ch_w
    local x0 = math.max(0, math.floor((FB_W - text_w) / 2))
    local y0 = pad

    local fh = io.open("/dev/fb0", "r+b")
    if not fh then return false, "open /dev/fb0" end

    -- 1. stash the band we are about to destroy
    fh:seek("set", 0)
    saved_band = fh:read(bar_h * FB_STRIDE)
    saved_rows = (saved_band and #saved_band == bar_h * FB_STRIDE) and bar_h or 0
    if saved_rows == 0 then saved_band = nil end

    -- 2. draw
    local row = ffi.new("uint8_t[?]", FB_STRIDE)
    local rule_from = bar_h - math.max(2, math.floor(scale / 2))
    for y = 0, bar_h - 1 do
        local rule = (y >= rule_from)
        ffi.fill(row, FB_STRIDE, rule and 0x00 or 0xFF)
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
        fh:seek("set", y * FB_STRIDE)
        fh:write(ffi.string(row, FB_STRIDE))
    end
    fh:close()

    local fd = ffi.C.open("/dev/fb0", 2)
    if fd >= 0 then ffi.C.fsync(fd); ffi.C.close(fd) end
    return true
end

-- Put back exactly what the banner covered.  Returns false when there is
-- nothing stashed, so the caller can fall back to a full refresh.
local function restore_banner_area()
    if not saved_band or saved_rows == 0 then return false end
    local fh = io.open("/dev/fb0", "r+b")
    if not fh then return false end
    fh:seek("set", 0)
    fh:write(saved_band)
    fh:close()
    local fd = ffi.C.open("/dev/fb0", 2)
    if fd >= 0 then ffi.C.fsync(fd); ffi.C.close(fd) end
    saved_band, saved_rows = nil, 0
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
        -- MUST be a newline, not "".  Lua's io.write with an empty string
        -- issues no write syscall at all, so configfs never sees the
        -- unbind and dwc3 goes on vetoing suspend -- which is exactly how
        -- this daemon "suspended" 10 times with 0 successes on
        -- 2026-08-03.  `echo "" >` works in shell only because echo emits
        -- a newline.
        write_file(udc, "\n")
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
        -- put the covered pixels back BEFORE refreshing, or the refresh
        -- just repaints the banner
        restore_banner_area()
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
-- Suppress press-to-suspend until this time.  Set after every resume, and
-- at startup: the daemon may be starting right after a boot triggered by a
-- power press whose release is still queued.
local power_ignore_until = os.time() + opt.power_grace_s
-- Latched if the power-key parse ever throws, so the failure is reported
-- once and the daemon keeps doing its primary job.
local power_scan_broken = false

while true do
    reload_config()
    if not runtime.enabled then
        -- paused at runtime: stay responsive, just never suspend
        last_activity = os.time()
    end
    local plugged, supply = on_external_power()
    if plugged and not may_suspend_charging() then
        if not charging_notice then
            log("on external power (%s) -- holding off; set suspend_while_charging=1 to override",
                tostring(supply))
            charging_notice = true
        end
        last_activity = os.time()
    elseif charging_notice and not plugged then
        log("external power gone -- auto-suspend active again")
        charging_notice = false
    end
    local remaining = idle_secs() - (os.time() - last_activity)
    if remaining <= 0 and runtime.enabled then
        if opt.dry then
            log("DRY RUN: would suspend now")
            last_activity = os.time()
        else
            suspend_once()
            -- The wake press itself lands as input.  Throw the whole queue
            -- away rather than let it read as either activity or a fresh
            -- suspend request, and hold the button off for the grace period.
            drain_all()
            power_ignore_until = os.time() + opt.power_grace_s
            last_activity = os.time()
        end
    else
        fd_zero()
        for _, d in ipairs(fds) do fd_set(d.fd) end
        tv.tv_sec = remaining
        tv.tv_usec = 0
        local n = ffi.C.select(maxfd + 1, fdset, nil, nil, tv)
        if n and n > 0 then
            local tapped = false
            local saw_input = false
            for _, d in ipairs(fds) do
                if fd_isset(d.fd) then
                    local got = tonumber(ffi.C.read(d.fd, drain, ffi.sizeof(drain)))
                    if got == -1 and ffi.errno() ~= 11 then
                        -- Device vanished (ENODEV after a uinput destroy,
                        -- e.g. an orientation-bridge respawn).  Without
                        -- eviction select() marks the fd readable forever
                        -- and this loop spins at 100% CPU (measured on
                        -- ddr-boost, same pattern, 2026-08-06).  Mark it;
                        -- the eviction pass below closes it and rebuilds
                        -- the list -- closing here and leaving it in fds
                        -- would just trade ENODEV-spin for EBADF-spin.
                        d.dead = true
                    end
                    while got and got > 0 do
                        saw_input = true
                        if d.is_power and power_key_on() then
                            -- Never let a fault in the convenience feature
                            -- take down auto-suspend itself.  A crash here
                            -- once left the device unable to sleep at all,
                            -- which is far worse than losing the button.
                            local ok, res = pcall(scan_power_events, d, got)
                            if ok then
                                if res then tapped = true end
                            elseif not power_scan_broken then
                                power_scan_broken = true
                                log("power-key scan failed (%s) -- disabling press-to-suspend, idle timer continues",
                                    tostring(res))
                            end
                        end
                        got = tonumber(ffi.C.read(d.fd, drain, ffi.sizeof(drain)))
                    end
                end
            end
            local kept = {}
            for _, d in ipairs(fds) do
                if d.dead then
                    ffi.C.close(d.fd)
                    log("input device %s vanished -- evicted", d.path)
                else
                    kept[#kept + 1] = d
                end
            end
            if #kept < #fds then
                fds = kept
                maxfd = 0
                for _, d in ipairs(fds) do
                    if d.fd > maxfd then maxfd = d.fd end
                end
                if #fds == 0 then
                    log("all input devices gone -- refusing to run blind; exiting")
                    os.exit(1)
                end
            end
            if saw_input then last_activity = os.time() end
            if tapped then
                if os.time() < power_ignore_until then
                    -- Almost certainly the press that just woke us.
                    log("power tap within resume grace -- ignoring")
                elseif not runtime.enabled then
                    log("power tap but auto-suspend is paused (enabled=0) -- ignoring")
                elseif opt.dry then
                    log("DRY RUN: power tap would suspend now")
                else
                    log("power tap -- suspending on request")
                    suspend_once()
                    drain_all()
                    power_ignore_until = os.time() + opt.power_grace_s
                    last_activity = os.time()
                end
            end
        end
    end
end
