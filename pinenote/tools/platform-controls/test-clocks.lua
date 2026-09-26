local path = arg[1] or "../../packages/platform-controls/pinenote-power-broker.lua"
local ffi = require("ffi")
local C, logs, keys, alarms = {}, {}, {}, {}
local mono, boot, wall = 100, 100, 100000
local elapsed, awake_elapsed, wall_step = 3600, 1, 0
local suspends, clock_failure, input_failure, closes = 0, false, false, 0
local fake_ffi = setmetatable({ C = C }, { __index = ffi })
function C.clock_gettime(id, ts)
    assert(id == 1 or id == 7, "unexpected clock")
    if clock_failure then return -1 end
    local value = id == 1 and mono or boot
    ts[0].tv_sec = math.floor(value)
    ts[0].tv_nsec = math.floor((value - math.floor(value)) * 1e9 + 0.5)
    return 0
end
function C.open(name)
    if name == "/dev/input/event0" then return 73 end
    assert(name == "/dev/fb0"); return -1 -- a missing banner still suspends
end
function C.ioctl(fd, request, value)
    assert(fd == 73 and request == 0x400445a0 and value[0] == 1)
    return input_failure and -1 or 0
end
function C.close(fd) assert(fd == 73); closes = closes + 1; return 0 end
function C.poll() return 0 end
local helpers = dofile("broker-fixture.lua")(path, {
    test_emit = function(_, key) keys[#keys + 1] = key end,
    io = {
        stderr = { write = function(_, s) logs[#logs + 1] = s end, flush = function() end },
        open = function(name, mode)
            if mode == "r" then
                local value = ({ ["/sys/class/rtc/rtc0/since_epoch"] = "100000",
                    ["/sys/class/input/event0/device/name"] = "rk805 pwrkey",
                    ["/sys/power/mem_sleep"] = "[deep]" })[name]
                if not value then return nil end
                return { read = function() return value end, close = function() return true end }
            end
            return { write = function(_, value)
                if name == "/sys/class/rtc/rtc0/wakealarm" then alarms[#alarms + 1] = value end
                if name == "/sys/power/state" then
                    assert(value == "mem"); suspends = suspends + 1
                    mono, boot, wall = mono + awake_elapsed, boot + elapsed, wall + wall_step
                end
                return true
            end, close = function() return true end }
        end,
    },
    os = setmetatable({
        time = function() return wall end,
        execute = function(cmd) return cmd:find(" status ", 1, true) and 1 or 0 end,
    }, { __index = os }),
    require = function(name)
        if name == "ffi" then return fake_ffi end
        if name == "broker_quiesce" then return { new = function() return { wait = function() return true end } end } end
        return require(name)
    end,
}, "{ protocol = protocol, tap = power_tap_allowed, awake = awake_now, inputs = discover_inputs }",
function(source)
    -- Execute the actual production wiring too, so testing a correctly chosen
    -- test clock cannot hide the daemon passing os.time to Protocol.new.
    local inputs = assert(source:match("(local function input_name%(%w+%).-)\n%-%- On PineNote hardware"))
    local setup = assert(source:match("(local grace_until =.-)\nlocal pollfds ="))
    return "local function discover_inputs()\n" .. inputs .. "\nreturn inputs end\n"
        .. "local emit, uinput = test_emit, 42\n" .. setup
end)
local p = helpers.protocol
local function advance(seconds) mono, boot = mono + seconds, boot + seconds end
local function step(seconds) wall = wall + seconds end
local function approx(a, b) return math.abs(a - b) < 1e-6 end

assert(#helpers.inputs() == 1)
input_failure = true
assert(#helpers.inputs() == 0 and closes == 1)
print("PASS: production evdev setup selects MONOTONIC and closes inputs if selection fails")

step(86400); assert(not helpers.tap(100))
advance(1.75); step(-172800); assert(not helpers.tap(100))
advance(0.25); assert(helpers.tap(100))
assert(not helpers.tap(-1) and not helpers.tap(1001))
print("PASS: startup power grace ignores forward/backward wall steps and expires at two awake seconds")

assert(p:physical_request("power"))
step(86400); p:tick(); assert(suspends == 0 and p.state == "WAIT_READY")
advance(9.75); step(-172800); p:tick(); assert(suspends == 0)
advance(0.25); wall_step = -86400
assert(p:tick())
assert(suspends == 1 and p.state == "IDLE" and approx(p.resuspend_at, mono + 20))
assert(keys[1] == 142 and keys[2] == 143)
assert(alarms[1] == "0" and alarms[2] == "103600" and alarms[3] == "0")
print("PASS: production WAIT_READY waits ten awake seconds across wall steps; actual suspend uses BOOTTIME and RTC alarm uses RTC epoch")

step(86400); assert(not helpers.tap(100)); assert(not p:tick())
advance(1.75); step(-172800); assert(not helpers.tap(100))
advance(0.25); assert(helpers.tap(100))
advance(17.75); assert(not p:tick() and p.state == "IDLE")
step(86400); advance(0.25); assert(p:tick() and p.state == "WAIT_READY")
print("PASS: wake grace and RTC settle ignore both wall step directions, measured from wake in awake time")

elapsed, awake_elapsed, wall_step = 3, 0.5, 86400
local ok, detail = p:ready("button-after-clock-step")
assert(ok and detail == "button" and p.resuspend_at == nil)
advance(30); assert(not p:tick())
print("PASS: a short actual suspend plus a large forward wall step is a button wake and clears RTC settle")

elapsed, wall_step = 3600, -86400
ok, detail = p:ready("rtc-after-clock-step")
assert(ok and detail == "rtc" and approx(p.resuspend_at, mono + 20))
assert(not p:tick())
print("PASS: an hour suspended with only half a second awake and a backward wall step is RTC, with a fresh settle window")

elapsed, wall_step = 3594.75, 86400
ok, detail = p:ready("below-threshold")
assert(ok and detail == "button")
elapsed, wall_step = 3595, -86400
ok, detail = p:ready("at-threshold")
assert(ok and detail == "rtc")
clock_failure = true
assert(not pcall(helpers.awake))
print("PASS: suspend classification preserves the backstop-minus-five threshold; clock errors cannot silently use realtime")
