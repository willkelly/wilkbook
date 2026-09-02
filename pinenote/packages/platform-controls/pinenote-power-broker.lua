-- PineNote suspend broker. KOReader owns idle policy; this process
-- owns physical power/cover triggers and is the sole writer to power/state.
local ffi, bit = require("ffi"), require("bit")
local script_dir = (arg[0] or "."):match("^(.*)/[^/]+$") or "."
local bundle_root = script_dir .. "/.."
local koreader_root = os.getenv("WILKBOOK_KOREADER_ROOT")
package.path = script_dir .. "/?.lua;"
    .. bundle_root .. "/overlay/?.lua;"
    .. bundle_root .. "/overlay/frontend/?.lua;"
    .. (koreader_root and koreader_root .. "/frontend/?.lua;" or "")
    .. package.path
local Protocol = require("broker_protocol")
local Quiesce = require("broker_quiesce")

ffi.cdef[[
int open(const char*, int, ...); int close(int); int fsync(int); long read(int, void*, unsigned long);
long write(int, const void*, unsigned long); int ioctl(int, unsigned long, ...);
int mkfifo(const char*, unsigned int); int poll(struct pollfd*, unsigned long, int);
int getpid(void); struct pollfd { int fd; short events, revents; };
struct input_id { unsigned short bustype, vendor, product, version; };
struct uinput_user_dev { char name[80]; struct input_id id; unsigned int ff_effects_max;
 int absmax[64]; int absmin[64]; int absfuzz[64]; int absflat[64]; };
struct input_event { long tv_sec, tv_usec; unsigned short type, code; int value; };
]]
local C = ffi.C
local O_RDONLY, O_WRONLY, O_RDWR, O_NONBLOCK = 0, 1, 2, 0x800
local POLLIN, EV_SYN, EV_KEY, EV_SW, SYN_REPORT = 1, 0, 1, 5, 0
local KEY_POWER, KEY_SLEEP, KEY_WAKEUP, SW_LID = 116, 142, 143, 0
local UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
local UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
local REQUEST = "/run/wilkbook-power/request"
local READY = "/run/wilkbook-power/ready"
local CONFIGS = { "/data/wilkbook/autosuspend.conf", "/var/lib/pinenote/autosuspend.conf",
                  "/run/wilkbook-power/inhibit.conf" }
local WIFI = os.getenv("WILKBOOK_WIFI_CONTROL")
    or "/data/wilkbook/validation/platform-controls-v1/bin/pinenote-wifi-control"
local BACKSTOP, ACK_TIMEOUT, POWER_GRACE = 3600, 10, 2

local function log(fmt, ...)
    io.stderr:write(("[power-broker] " .. fmt .. "\n"):format(...)); io.stderr:flush()
end
local function read_line(path)
    local f = io.open(path, "r"); if not f then return nil end
    local value = f:read("*l"); f:close(); return value
end
local function write_value(path, value)
    local f = io.open(path, "w"); if not f then return false end
    local ok = f:write(value); local closed = f:close(); return ok and closed and true or false
end
local function sleep_ms(ms) C.poll(nil, 0, ms) end
local function run(command) return os.execute(command) == 0 end

local config = { enabled = true, charging = false, backstop = BACKSTOP }
local warned_idle = false
local function reload_config()
    config.enabled, config.charging, config.backstop = true, false, BACKSTOP
    for _, path in ipairs(CONFIGS) do
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                local key, value = line:match("^%s*([%w_]+)%s*=%s*(%S+)")
                if key == "enabled" then config.enabled = not (value == "0" or value == "false" or value == "no")
                elseif key == "backstop" and tonumber(value) and tonumber(value) >= 30 then config.backstop = math.floor(value)
                elseif key == "suspend_while_charging" then config.charging = value == "1" or value == "true" or value == "yes"
                elseif key == "idle" and not warned_idle then
                    warned_idle = true; log("ignoring obsolete idle= setting; KOReader AutoSuspend owns idle timing")
                end
            end
            f:close()
        end
    end
end
local function external_power()
    for _, name in ipairs({ "rk817-charger", "usb", "ac", "usb-c", "rk817-usb" }) do
        if read_line("/sys/class/power_supply/" .. name .. "/online") == "1" then return true, name end
    end
    return false
end
local function suspend_allowed()
    reload_config()
    if not config.enabled then return false, "globally inhibited" end
    local plugged, supply = external_power()
    if plugged and not config.charging then return false, "charging on " .. tostring(supply) end
    return true
end
local function find_ebc_card()
    for n = 0, 63 do
        local f = io.open("/sys/class/drm/card" .. n .. "/device/uevent", "r")
        if f then
            for line in f:lines() do if line == "DRIVER=rockchip-ebc" then f:close(); return "/dev/dri/card" .. n end end
            f:close()
        end
    end
end
local function ebc_barrier()
    local card = find_ebc_card(); if not card then return false, "EBC card unavailable" end
    local ok, adapter = pcall(function()
        return require("device/pinenote/ebc_barrier").new{ card = card, timeout_ms = 10000 }
    end)
    if not ok then return false, adapter end
    return adapter.submit_and_wait()
end
-- The EBC's interrupt line, summed across CPUs (the same row the lab's
-- frame-clock instrument counts); nil when the line is absent.
local function ebc_irq_count()
    local f = io.open("/proc/interrupts", "r"); if not f then return nil end
    local sum
    for line in f:lines() do
        if line:find("fdec0000.ebc", 1, true) then
            sum = 0
            for tok in line:gmatch("%S+") do local n = tonumber(tok); if n then sum = sum + n end end
            break
        end
    end
    f:close(); return sum
end
-- REFRESH_BARRIER is a wilkbook addition to the shipping driver; the
-- shipping-only module parameters are the same driver's fingerprint.
-- hrdl's direct driver registers neither (issue #42).
local function driver_has_barrier()
    return read_line("/sys/module/rockchip_ebc/parameters/no_off_screen") ~= nil
end
local function ebc_quiesce()
    return Quiesce.new{ driver_has_barrier = driver_has_barrier, barrier = ebc_barrier,
                        irq_count = ebc_irq_count, sleep_ms = sleep_ms, log = log }:wait()
end
local function frontlight_off()
    local saved = {}
    for _, name in ipairs({ "backlight_cool", "backlight_warm" }) do
        local path = "/sys/class/backlight/" .. name .. "/brightness"
        local value = read_line(path)
        if value then saved[#saved + 1] = { path, value }; write_value(path, "0") end
    end
    return saved
end
local function frontlight_restore(saved)
    for _, item in ipairs(saved or {}) do
        write_value(item[1], item[2])
        if read_line(item[1]) ~= item[2] then log("frontlight restore verification failed: %s", item[1]) end
    end
end
local function gadget_off()
    local path = "/sys/kernel/config/usb_gadget/pinenote-acm/UDC"
    local saved = read_line(path); if saved and saved ~= "" then write_value(path, "\n") end
    return saved
end
local function gadget_restore(saved)
    if saved and saved ~= "" then write_value("/sys/kernel/config/usb_gadget/pinenote-acm/UDC", saved) end
end
local function arm_rtc()
    local path = "/sys/class/rtc/rtc0/wakealarm"
    write_value(path, "0")
    local now = tonumber(read_line("/sys/class/rtc/rtc0/since_epoch") or "0")
    return now > 0 and write_value(path, tostring(now + config.backstop))
end
local function cleanup_display()
    write_value("/sys/module/rockchip_ebc/parameters/no_off_screen", "0")
    local wf = "/sys/module/rockchip_ebc/parameters/refresh_waveform"
    local saved = read_line(wf); if saved == "4" then saved = "6" end
    local switched = saved and write_value(wf, "4")
    run("/run/current-system/profile/bin/pinenote-ebc-refresh >/dev/null 2>&1")
    if switched then sleep_ms(3000); write_value(wf, saved) end
end
local function fallback_banner()
    -- Deliberately simple and independent of KOReader: a white top band with
    -- large bitmap text. The wake event makes KOReader repaint its prior UI;
    -- cleanup_display's GC16 pass prevents a stale optical remnant.
    write_value("/sys/module/rockchip_ebc/parameters/no_off_screen", "1")
    local glyphs = {
        S={"1111","1000","1000","1111","0001","0001","1111"},
        U={"1001","1001","1001","1001","1001","1001","1111"},
        P={"1110","1001","1001","1110","1000","1000","1000"},
        E={"1111","1000","1000","1110","1000","1000","1111"},
        N={"1001","1101","1101","1011","1011","1001","1001"},
        D={"1110","1001","1001","1001","1001","1001","1110"},
    }
    local text, scale, stride, height = "SUSPEND", 8, 7488, 96
    local row = ffi.new("uint8_t[?]", stride)
    local fb = io.open("/dev/fb0", "r+b")
    if fb then
        for y = 0, height - 1 do
            ffi.fill(row, stride, 0xff)
            local gy = math.floor((y - 16) / scale) + 1
            if gy >= 1 and gy <= 7 then
                local x0 = 32
                for index = 1, #text do
                    local bits = glyphs[text:sub(index, index)][gy]
                    for column = 1, 4 do
                        if bits:sub(column, column) == "1" then
                            local px = x0 + ((index - 1) * 5 + column - 1) * scale
                            for sx = 0, scale - 1 do
                                local off = (px + sx) * 4
                                row[off], row[off+1], row[off+2], row[off+3] = 0, 0, 0, 0
                            end
                        end
                    end
                end
            end
            if y >= height - 4 then ffi.fill(row, stride, 0) end
            fb:seek("set", y * stride); fb:write(ffi.string(row, stride))
        end
        fb:close()
        local fd = C.open("/dev/fb0", O_RDWR); if fd >= 0 then C.fsync(fd); C.close(fd) end
    else
        log("fallback banner could not open framebuffer")
    end
    write_value("/dev/kmsg", "<3>WILKBOOK: KOReader missed suspend preparation deadline; fallback sleep frame")
end
local function wifi_was_on()
    return run(WIFI .. " status >/dev/null 2>&1")
end

local function suspend_transaction(fallback)
    local allowed, reason = suspend_allowed()
    if not allowed then return false, reason end
    if fallback then fallback_banner() else write_value("/sys/module/rockchip_ebc/parameters/no_off_screen", "1") end
    local quiet_ok, quiet_error = ebc_quiesce()
    if not quiet_ok then
        cleanup_display(); return false, "EBC busy: " .. tostring(quiet_error)
    end
    local had_wifi = wifi_was_on()
    if had_wifi and not run(WIFI .. " off") then cleanup_display(); return false, "Wi-Fi quiesce failed" end
    local lights, gadget = frontlight_off(), gadget_off()
    if not arm_rtc() then
        gadget_restore(gadget); frontlight_restore(lights); if had_wifi then run(WIFI .. " on") end
        cleanup_display(); return false, "RTC backstop unavailable"
    end
    write_value("/sys/power/mem_sleep", "deep")
    if not (read_line("/sys/power/mem_sleep") or ""):find("%[deep%]") then
        gadget_restore(gadget); frontlight_restore(lights); if had_wifi then run(WIFI .. " on") end
        cleanup_display(); return false, "deep suspend unavailable"
    end
    run("/run/current-system/profile/bin/sync")
    local started = os.time()
    if not write_value("/sys/power/state", "mem") then
        write_value("/sys/class/rtc/rtc0/wakealarm", "0")
        gadget_restore(gadget); cleanup_display(); frontlight_restore(lights)
        if had_wifi then run(WIFI .. " on") end
        return false, "kernel refused suspend"
    end
    local slept = os.time() - started
    -- A button wake leaves the one-shot backstop armed unless it is cancelled;
    -- otherwise it fires later while the reader is awake.  Clear it for both
    -- button and RTC wakes before performing the remaining resume repairs.
    if not write_value("/sys/class/rtc/rtc0/wakealarm", "0") then
        log("RTC backstop clear failed after resume")
    end
    gadget_restore(gadget); cleanup_display(); frontlight_restore(lights)
    if had_wifi then run(WIFI .. " on") end
    log("resumed after %ds", slept)
    return true, slept >= config.backstop - 5 and "rtc" or "button"
end

local function create_uinput()
    local fd = C.open("/dev/uinput", O_WRONLY); if fd < 0 then return nil end
    if C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_SYN)) ~= 0
       or C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_KEY)) ~= 0
       or C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", KEY_SLEEP)) ~= 0
       or C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", KEY_WAKEUP)) ~= 0 then C.close(fd); return nil end
    local dev = ffi.new("struct uinput_user_dev"); ffi.copy(dev.name, "wilkbook-power-control")
    dev.id.bustype, dev.id.vendor, dev.id.product, dev.id.version = 6, 0x1209, 0x0003, 1
    if C.write(fd, dev, ffi.sizeof(dev)) ~= ffi.sizeof(dev) or C.ioctl(fd, UI_DEV_CREATE) ~= 0 then C.close(fd); return nil end
    return fd
end
local ev = ffi.new("struct input_event")
local function emit(fd, code)
    for _, value in ipairs({ 1, 0 }) do
        ev.type, ev.code, ev.value = EV_KEY, code, value; assert(C.write(fd, ev, ffi.sizeof(ev)) == ffi.sizeof(ev))
        ev.type, ev.code, ev.value = EV_SYN, SYN_REPORT, 0; assert(C.write(fd, ev, ffi.sizeof(ev)) == ffi.sizeof(ev))
    end
end
local function input_name(n) return read_line("/sys/class/input/event" .. n .. "/device/name") end
local inputs = {}
for n = 0, 31 do
    local name = input_name(n)
    if name == "rk805 pwrkey" or name == "gpio-keys" then
        local fd = C.open("/dev/input/event" .. n, bit.bor(O_RDONLY, O_NONBLOCK))
        if fd >= 0 then inputs[#inputs + 1] = { fd = fd, power = name == "rk805 pwrkey" } end
    end
end
-- On PineNote hardware rk805 pwrkey and gpio-keys always exist.  QEMU virt
-- (offline ladder rung 4) has neither -- its power button sits on a PL061
-- the kernel config does not carry -- and physical triggers are severable:
-- KOReader-acknowledged suspend needs only the request FIFO and the uinput
-- device.  Run degraded rather than crash-loop, which would hold
-- reader-session (and so the reader itself) down over a missing button.
if #inputs == 0 then log("no power/cover input devices; physical triggers disabled") end
local uinput = assert(create_uinput(), "cannot create wilkbook-power-control")
C.mkfifo(REQUEST, 384) -- 0600; EEXIST is expected after restart.
local request_fd = C.open(REQUEST, bit.bor(O_RDWR, O_NONBLOCK)); assert(request_fd >= 0, "cannot open request FIFO")
write_value(READY, tostring(C.getpid()) .. "\n")

local grace_until = os.time() + POWER_GRACE
local protocol = Protocol.new{
    now = os.time, ack_timeout = ACK_TIMEOUT,
    can_prepare = function(trigger)
        local allowed, reason = suspend_allowed()
        if not allowed then
            log("preparation inhibited trigger=%s detail=%s", tostring(trigger), tostring(reason))
        end
        return allowed, reason
    end,
    emit_sleep = function()
        log("emitting KEY_SLEEP")
        emit(uinput, KEY_SLEEP)
    end,
    emit_wakeup = function()
        log("emitting KEY_WAKEUP")
        emit(uinput, KEY_WAKEUP)
        grace_until = os.time() + POWER_GRACE
    end,
    suspend = function(fallback, request_id, trigger)
        log("transaction start trigger=%s request=%s fallback=%s",
            tostring(trigger), tostring(request_id), tostring(fallback))
        local ok, detail = suspend_transaction(fallback)
        log("transaction complete ok=%s detail=%s", tostring(ok), tostring(detail))
        return ok, detail
    end,
    log = log,
}
local pollfds = ffi.new("struct pollfd[?]", #inputs + 1)
local buffer, pending, press_ms = ffi.new("uint8_t[4096]"), "", nil
while true do
    reload_config(); protocol:set_enabled(config.enabled)
    pollfds[0].fd, pollfds[0].events = request_fd, POLLIN
    for i, input in ipairs(inputs) do pollfds[i].fd, pollfds[i].events = input.fd, POLLIN end
    C.poll(pollfds, #inputs + 1, 250)
    if bit.band(pollfds[0].revents, POLLIN) ~= 0 then
        local got = tonumber(C.read(request_fd, buffer, ffi.sizeof(buffer)))
        if got and got > 0 then
            pending = pending .. ffi.string(buffer, got)
            while pending:find("\n", 1, true) do
                local line; line, pending = pending:match("^([^\n]*)\n(.*)$")
                local id = line and line:match("^ready%s+([%w_.:-]+)%s*$")
                if id then
                    log("received ready request id=%s", id)
                    protocol:ready(id)
                elseif line ~= "" then log("ignoring malformed request: %s", line) end
            end
        end
    end
    for i, input in ipairs(inputs) do
        if bit.band(pollfds[i].revents, POLLIN) ~= 0 then
            local got = tonumber(C.read(input.fd, buffer, ffi.sizeof(buffer))) or 0
            local events = ffi.cast("struct input_event*", buffer)
            for n = 0, math.floor(got / ffi.sizeof(ev)) - 1 do
                local item = events[n]
                if input.power and item.type == EV_KEY and item.code == KEY_POWER then
                    local ms = tonumber(item.tv_sec) * 1000 + tonumber(item.tv_usec) / 1000
                    log("power event value=%d timestamp_ms=%.3f", item.value, ms)
                    if item.value == 1 then press_ms = ms
                    elseif item.value == 0 and press_ms then
                        local held = ms - press_ms; press_ms = nil
                        if held >= 0 and held <= 1000 and os.time() >= grace_until then
                            local accepted, reason = protocol:physical_request("power")
                            log("power tap held_ms=%.3f accepted=%s detail=%s",
                                held, tostring(accepted), tostring(reason))
                        else
                            log("power release ignored held_ms=%.3f grace_remaining=%d",
                                held, math.max(0, grace_until - os.time()))
                        end
                    end
                elseif not input.power and item.type == EV_SW and item.code == SW_LID and item.value == 1 then
                    protocol:physical_request("cover")
                end
            end
        end
    end
    protocol:tick()
end

C.ioctl(uinput, UI_DEV_DESTROY); C.close(uinput)
