--[[--
Host harness for the optics page-turn injector chain (offline ladder).

Proves, against the *verbatim* koreader-bin bundle input stack and the
REPO's device/pinenote/device.lua, the two links the optics harness
depends on (pinenote/tools/optics/PLAN.md task 1):

 1. device.lua's findInputDevices maps an input device NAMED exactly
    'wilkbook-optics' (what optics-inject.lua creates via uinput) to
    found.optics_inject -- exercised on a fake sysfs tree, alongside a
    non-regression sweep of every other whitelisted name;
 2. the event stream optics-inject.lua emits for 'KEY 159' / 'KEY 158'
    (EV_KEY press + SYN_REPORT, EV_KEY release + SYN_REPORT) maps to
    RPgFwd/RPgBack KeyPress/KeyRelease through the bundle's real
    Input:handleKeyBoardEv with device.lua's event_map -- including
    while the pen hovers and a finger taps (mixedrouter installed, as
    on hardware), where the injector's frames must neither perturb slot
    routing nor emit spurious gestures.

NOT covered here (the residual gap, stated precisely): device.lua's
init() glue -- the `self.input:open(devs.optics_inject, ...)` line and
evdev delivery itself (ffi/input_evdev is not run) -- and the live
create-before-enumerate ordering.  Those are QEMU-rung-4v / first-SSH-
session territory; everything decision-bearing between the uinput event
bytes and the RPgFwd gesture is executed verbatim here.

Usage: luajit test-optics-inject.lua /path/to/bundle/lib/koreader \
           /path/to/repo/.../device/pinenote/device.lua \
           /path/to/repo/.../device/pinenote/mixedrouter.lua
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local device_lua_path = assert(arg[2], "arg2: path to pinenote device.lua")
local mixedrouter_path = assert(arg[3], "arg3: path to mixedrouter.lua")

-- The bundle's own module tree (frontend/ first, mirroring setupkoenv),
-- plus its C modules (libs/libkoreader-lfs.so via ffi/util).
package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

------------------------------------------------------------------------
-- Stubs (the same set test-mixedrouter.lua uses, plus ffi/archiver:
-- device/generic/device requires it at module load, but nothing this
-- harness executes touches it -- stubbing keeps libarchive unloaded).
------------------------------------------------------------------------

local noop = function() end

package.preload["logger"] = function()
    return setmetatable({
        dbg = noop, info = noop, warn = noop, err = noop,
        LvDEBUG = noop, setLevel = noop,
    }, { __call = noop })
end

package.preload["dbg"] = function()
    local dbg = { is_on = false, ev_log = noop }
    function dbg:guard() end
    function dbg:dassert(check) return check end
    return setmetatable(dbg, { __call = noop })
end

package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/nonexistent/koreader-settings" end,
        getDataDir = function() return "/nonexistent/koreader-data" end,
    }
end

package.preload["gettext"] = function()
    local identity = function(_, s) return s end
    return setmetatable({
        ngettext = function(_, s) return s end,
        pgettext = function(_, _, s) return s end,
    }, { __call = identity })
end

package.preload["util"] = function()
    local function tableDeepCopy(t)
        if type(t) ~= "table" then return t end
        local copy = {}
        for k, v in pairs(t) do copy[tableDeepCopy(k)] = tableDeepCopy(v) end
        return copy
    end
    return { tableDeepCopy = tableDeepCopy }
end

package.preload["ffi/framebuffer"] = function()
    return {
        DEVICE_ROTATED_UPRIGHT           = 0,
        DEVICE_ROTATED_CLOCKWISE         = 1,
        DEVICE_ROTATED_UPSIDE_DOWN      = 2,
        DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
    }
end

package.preload["ffi/archiver"] = function() return {} end

-- gesturedetector reads G_reader_settings at module load time; the repo
-- device.lua nil-guards its own read of pinenote_flash_area_fraction
-- against exactly this stub shape.
G_reader_settings = {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    isFalse = function() return false end,
    nilOrTrue = function() return true end,
    has = function() return false end,
}

-- The PineNote panel: 1872x1404 @ 227 DPI, upright.
local Screen = {
    DEVICE_ROTATED_UPRIGHT           = 0,
    DEVICE_ROTATED_CLOCKWISE         = 1,
    DEVICE_ROTATED_UPSIDE_DOWN      = 2,
    DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
}
function Screen:getDPI() return 227 end
function Screen:scaleByDPI(dp) return math.ceil(dp * self:getDPI() / 160) end
function Screen:getWidth() return 1872 end
function Screen:getHeight() return 1404 end
function Screen:getRotationMode() return 0 end
function Screen:getTouchRotation() return 0 end

local FakeDevice = { screen = Screen, display_dpi = 227 }
function FakeDevice:isSDL() return false end
function FakeDevice:isAndroid() return false end
function FakeDevice:isPocketBook() return false end
function FakeDevice:isAlwaysFullscreen() return true end
function FakeDevice:hasEinkScreen() return true end
function FakeDevice:isGSensorLocked() return false end

local StubBackend = {}

------------------------------------------------------------------------
-- Systems under test: the REPO device.lua (loads the bundle's real
-- generic device underneath) + the bundle's real Input.
------------------------------------------------------------------------

local PineNote = dofile(device_lua_path)
local Input = require("device/input")
local MixedRouter = dofile(mixedrouter_path)

local fail = 0
local function report(ok, label, msg)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label, msg))
    if not ok then fail = fail + 1 end
end

------------------------------------------------------------------------
-- 1. findInputDevices: 'wilkbook-optics' -> found.optics_inject
--    (real code, fake sysfs tree; tmp path never printed -- the
--    run-tests.sh determinism check diffs two runs' output).
------------------------------------------------------------------------

report(type(PineNote._findInputDevices) == "function",
       "device.lua exports _findInputDevices for this harness",
       tostring(type(PineNote._findInputDevices)))

local base = os.tmpname()
os.remove(base)

local devices = {
    [0] = "wilkbook-optics",
    [7] = "wilkbook-orientation",
    [8] = "wilkbook-orientation", -- spoofed name, wrong/missing virtual ID
    [1] = "cyttsp5",
    [2] = "w9013 2D1F:0095 Stylus",
    [3] = "w9013 2D1F:0095",       -- the pen's 2nd interface: must NOT match
    [4] = "ws8100_pen",
    [5] = "rk805 pwrkey",
    [6] = "gpio-keys",
}
for n, name in pairs(devices) do
    os.execute(string.format("mkdir -p '%s/event%d/device'", base, n))
    local f = assert(io.open(string.format("%s/event%d/device/name", base, n), "w"))
    f:write(name, "\n")
    f:close()
end
os.execute(string.format("mkdir -p '%s/event7/device/id'", base))
for field, value in pairs({ bustype = "0006", vendor = "1209",
                            product = "0002", version = "0001" }) do
    local f = assert(io.open(string.format("%s/event7/device/id/%s", base, field), "w"))
    f:write(value, "\n")
    f:close()
end

local found = PineNote._findInputDevices(base)
os.execute(string.format("rm -rf '%s'", base))

-- fixed order: pairs() iteration is per-process-randomized in LuaJIT
-- and the run-tests.sh determinism check diffs two runs' output
local expected = {
    { "optics_inject", "/dev/input/event0" },
    { "touch",         "/dev/input/event1" },
    { "pen",           "/dev/input/event2" },
    { "penbtn",        "/dev/input/event4" },
    { "pwrkey",        "/dev/input/event5" },
    { "gpiokeys",      "/dev/input/event6" },
    { "gsensor",       "/dev/input/event7" },
}
local expected_set = {}
for _, e in ipairs(expected) do
    local slot, node = e[1], e[2]
    expected_set[slot] = true
    report(found[slot] == node,
           "findInputDevices maps " .. slot,
           string.format("%s (want %s)", tostring(found[slot]), node))
end
local extra = 0
for slot in pairs(found) do
    if not expected_set[slot] then extra = extra + 1 end
end
report(extra == 0, "no spurious slots (pen 2nd interface ignored)",
       extra .. " extra")

local required = {}
PineNote._registerRequiredInputDevices({
    setRequiredDevice = function(path) required[#required + 1] = path end,
}, found)
report(#required == 2 and required[1] == found.optics_inject
       and required[2] == found.gsensor,
       "production init registers optics and orientation as required",
       table.concat(required, ","))

local gyro = { type = 4, code = 3, value = 2, src = "/dev/input/event7" }
report(PineNote._translateGyroEvent(gyro, "/dev/input/event7")
       and gyro.code == 71 and gyro.value == 2 and gyro.wilkbook_gsensor,
       "orientation MSC_RAW translates to private MSC_GYRO", gyro.code)
local invalid = { type = 4, code = 3, value = 4, src = "/dev/input/event7" }
report(not PineNote._translateGyroEvent(invalid, "/dev/input/event7")
       and invalid.code == 0 and invalid.value == 0,
       "invalid orientation MSC_RAW is rejected", invalid.code)
local foreign = { type = 4, code = 3, value = 1, src = "/dev/input/event2" }
report(not PineNote._translateGyroEvent(foreign, "/dev/input/event7")
       and foreign.code == 3,
       "MSC_RAW translation is source-gated", foreign.code)
local absent = { type = 4, code = 3, value = 1, src = nil }
report(not PineNote._translateGyroEvent(absent, nil) and absent.code == 3,
       "MSC_RAW translation requires an enrolled sensor", absent.code)

-- KOReader's verbatim canonical gyro handler owns setting semantics.  The
-- device only reaches it after source-gated translation; test all accepted
-- modes and the upstream input_ignore_gsensor toggle without inventing state.
local gyro_input = Input:new{ device = FakeDevice, input = StubBackend }
gyro_input.handleGyroEv = gyro_input.handleMiscGyroEv
local modes_ok = true
local mode_results = {}
for _, value in ipairs({ 0, 1, 2, 3 }) do
    local event = gyro_input:handleGyroEv({ value = value })
    if value == 0 then
        modes_ok = modes_ok and event == nil
    else
        modes_ok = modes_ok and event and (event.handler == "onSetRotationMode"
            or event.name == "onSetRotationMode") and event.args[1] == value
    end
    mode_results[#mode_results + 1] = string.format("%d:%s", value,
        event and (event.handler or event.name or "event") or "nil")
end
report(modes_ok, "canonical gyro handler accepts all four rotation modes",
       table.concat(mode_results, ","))
gyro_input:toggleGyroEvents(false)
report(gyro_input:handleGyroEv({ value = 2 }) == nil,
       "input_ignore_gsensor toggle suppresses gyro handling", "ignored")
gyro_input:toggleGyroEvents(true)
local reenabled = gyro_input:handleGyroEv({ value = 2 })
report(reenabled and reenabled.handler == "onSetRotationMode"
       and reenabled.args[1] == 2,
       "input_ignore_gsensor toggle restores standard gyro handling", "enabled")
local state_path = os.tmpname()
local state = assert(io.open(state_path, "w"))
state:write("3\n")
state:close()
local replayed = PineNote._syncGyroState(gyro_input, state_path)
os.remove(state_path)
report(replayed and replayed.handler == "onSetRotationMode"
       and replayed.args[1] == 3,
       "re-enable replays the bridge's current committed orientation", "mode 3")

-- A physical rotation must not split a gesture across coordinate spaces.
-- Queue only the latest mode while contact is active, then append it after
-- the lift gesture. Pen hover does not increase contact_count.
local applied = {}
local deferred_input = {
    gesture_detector = { contact_count = 1 },
    handleMiscEv = function() return nil end,
    handleTouchEv = function() return { { handler = "onGesture" } } end,
    handleGyroEv = function(_, ev)
        applied[#applied + 1] = ev.value
        return { handler = "onSetRotationMode", args = { ev.value } }
    end,
}
PineNote._installGyroHandler(deferred_input)
deferred_input:handleMiscEv({ code = 71, value = 1, wilkbook_gsensor = true })
deferred_input:handleMiscEv({ code = 71, value = 3, wilkbook_gsensor = true })
report(#applied == 0, "rotation waits for active contact lift", #applied)
deferred_input.gesture_detector.contact_count = 0
local lifted = deferred_input:handleTouchEv({})
report(#applied == 1 and applied[1] == 3 and #lifted == 2
       and lifted[2].handler == "onSetRotationMode",
       "latest deferred rotation follows the completed gesture",
       table.concat(applied, ","))
deferred_input:handleMiscEv({ code = 71, value = 2, wilkbook_gsensor = true })
report(#applied == 2 and applied[2] == 2,
       "rotation applies immediately without contact", table.concat(applied, ","))

------------------------------------------------------------------------
-- 2. The injector event stream through the bundle's real input stack.
------------------------------------------------------------------------

-- Stable kernel input ABI constants.
local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT = 0
local ABS_X, ABS_Y = 0x00, 0x01
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
local ABS_MT_TRACKING_ID = 0x39
local BTN_TOOL_PEN = 0x140
local KEY_MENU, KEY_BACK, KEY_FORWARD = 139, 158, 159

local PEN = "/dev/input/event3"
local TOUCH = "/dev/input/event2"
local INJECT = "/dev/input/event9"   -- the uinput 'wilkbook-optics' node

local clock_us

local function stamp()
    return { sec = math.floor(clock_us / 1000000), usec = clock_us % 1000000 }
end

local function frame(src, evs)
    local out = {}
    for _, e in ipairs(evs) do
        out[#out + 1] = { type = e[1], code = e[2], value = e[3],
                          src = src, time = stamp() }
    end
    out[#out + 1] = { type = EV_SYN, code = SYN_REPORT, value = 0,
                      src = src, time = stamp() }
    clock_us = clock_us + 20000
    return out
end

-- Exactly what optics-inject.lua writes for one 'KEY <code>' line:
-- press + SYN_REPORT, then release + SYN_REPORT.
local function inject_key(code)
    return {
        frame(INJECT, { { EV_KEY, code, 1 } }),
        frame(INJECT, { { EV_KEY, code, 0 } }),
    }
end

local function makeInput(with_router)
    local input = Input:new{
        device = FakeDevice,
        -- device.lua's event_map, verbatim
        event_map = {
            [116] = "Power",
            [158] = "RPgBack",
            [159] = "RPgFwd",
        },
        wacom_protocol = true,
        disable_double_tap = true,
        input = StubBackend,
    }
    input.gesture_detector.active_contacts = {}
    input.gesture_detector.previous_tap = {}
    input.gesture_detector.contact_count = 0
    input.handleTouchEv = input.handleMixedTouchEv
    if with_router then
        MixedRouter.install(input, PEN, TOUCH)
    end
    return input
end

-- Dispatch exactly like Input:waitEvent: EV_KEY -> handleKeyBoardEv
-- (collect returned key Events), EV_ABS/EV_SYN -> handleTouchEv
-- (collect returned gestures).
local function feed(input, frames)
    local keys, gestures = {}, {}
    for _, fr in ipairs(frames) do
        for _, ev in ipairs(fr) do
            if ev.type == EV_KEY then
                local e = input:handleKeyBoardEv(ev)
                if type(e) == "table" and e.handler then
                    keys[#keys + 1] = e
                end
            elseif ev.type == EV_ABS or ev.type == EV_SYN then
                local evts = input:handleTouchEv(ev)
                if evts then
                    for _, event in ipairs(evts) do
                        gestures[#gestures + 1] = event.args[1]
                    end
                end
            end
        end
    end
    return keys, gestures
end

local function keyToString(e)
    return string.format("%s(%s)", e.handler, tostring(e.args[1].key))
end

local function keysToString(keys)
    if #keys == 0 then return "(none)" end
    local parts = {}
    for _, e in ipairs(keys) do parts[#parts + 1] = keyToString(e) end
    return table.concat(parts, "; ")
end

local function countGes(gestures, ges, x, y)
    local n = 0
    for _, g in ipairs(gestures) do
        if g.ges == ges and (not x or (g.pos.x == x and g.pos.y == y)) then
            n = n + 1
        end
    end
    return n
end

-- 2a. bare KEY_FORWARD / KEY_BACK taps -> RPgFwd/RPgBack press+release,
--     zero gestures (the injector's SYN_REPORTs with no touch slots in
--     flight must be inert through handleTouchEv).
clock_us = 2000000
do
    local input = makeInput(true)
    local frames = {}
    for _, fr in ipairs(inject_key(KEY_FORWARD)) do frames[#frames + 1] = fr end
    for _, fr in ipairs(inject_key(KEY_BACK)) do frames[#frames + 1] = fr end
    local keys, gestures = feed(input, frames)
    local want = "onKeyPress(RPgFwd); onKeyRelease(RPgFwd); "
              .. "onKeyPress(RPgBack); onKeyRelease(RPgBack)"
    report(keysToString(keys) == want,
           "KEY 159 / KEY 158 -> RPgFwd/RPgBack press+release",
           keysToString(keys))
    report(#gestures == 0,
           "injector frames emit no gestures", #gestures .. " gestures")
end

-- 2b. the same taps while the pen hovers and a finger taps (the exact
--     regime the mixedrouter fix exists for): page keys still map, the
--     finger tap survives, nothing is re-classified.
clock_us = 2000000
do
    local input = makeInput(true)
    local frames = {
        frame(PEN, { { EV_KEY, BTN_TOOL_PEN, 1 } }),
        frame(PEN, { { EV_ABS, ABS_X, 1200 }, { EV_ABS, ABS_Y, 300 } }),
        frame(PEN, { { EV_ABS, ABS_X, 1202 }, { EV_ABS, ABS_Y, 301 } }),
    }
    for _, fr in ipairs(inject_key(KEY_FORWARD)) do frames[#frames + 1] = fr end
    -- finger tap at (500,700), slot 0, kernel-deduped (no ABS_MT_SLOT)
    frames[#frames + 1] = frame(TOUCH, { { EV_ABS, ABS_MT_TRACKING_ID, 37 },
                                         { EV_ABS, ABS_MT_POSITION_X, 500 },
                                         { EV_ABS, ABS_MT_POSITION_Y, 700 } })
    frames[#frames + 1] = frame(PEN, { { EV_ABS, ABS_X, 1204 }, { EV_ABS, ABS_Y, 302 } })
    frames[#frames + 1] = frame(TOUCH, { { EV_ABS, ABS_MT_TRACKING_ID, -1 } })
    for _, fr in ipairs(inject_key(KEY_BACK)) do frames[#frames + 1] = fr end
    frames[#frames + 1] = frame(PEN, { { EV_KEY, BTN_TOOL_PEN, 0 } })

    local keys, gestures = feed(input, frames)
    local want = "onKeyPress(RPgFwd); onKeyRelease(RPgFwd); "
              .. "onKeyPress(RPgBack); onKeyRelease(RPgBack)"
    report(keysToString(keys) == want,
           "page keys map amid pen hover + finger interleave",
           keysToString(keys))
    report(countGes(gestures, "tap", 500, 700) == 1
           and countGes(gestures, "tap") == 1,
           "the finger tap survives (mixedrouter regime intact)",
           countGes(gestures, "tap") .. " tap(s)")
    report(countGes(gestures, "pan") + countGes(gestures, "swipe")
           + countGes(gestures, "multiswipe") == 0,
           "no pan/swipe re-classification",
           "pan+swipe count")
end

-- 2c. KEY_MENU (139): DECLARED by the injector daemon (so the device
--     never needs re-creating) but not yet in device.lua's event_map --
--     pin the current drop-it behavior until the UI-action task maps it.
clock_us = 2000000
do
    local input = makeInput(true)
    local keys, gestures = feed(input, inject_key(KEY_MENU))
    report(#keys == 0 and #gestures == 0,
           "KEY 139 (menu) currently unmapped -> dropped (pinned)",
           keysToString(keys))
end

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
