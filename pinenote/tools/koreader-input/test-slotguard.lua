--[[--
Slot identity guard: the 2026-09-02 glass crash, reproduced and pinned.

Runs the bundle's *verbatim* frontend/device/input.lua +
gesturedetector.lua the way pinenote/device.lua does (handleMixedTouchEv
+ the repo's mixedrouter), and drives the exact field sequence that
killed KOReader on the PineNote during pinch-to-font-size:

    pinch -> one finger lifts (pinch emitted) -> ReaderRolling re-renders:
    Input:inhibitInput(true) (the still-down finger's frames are dropped)
    -> inhibitInput(false) -> Input:resetState() wipes every slot table
    -> the still-down finger's next DELTA-ONLY frame lands in an empty
    table (no id, no x) -> the next finger pairs with that ghost ->
    the two-finger pan calls Contact:getPath() on it ->
    gesturedetector.lua:325 "attempt to perform arithmetic on field 'x'".

Each scenario runs WITHOUT the repo's slotguard (upstream behaviour:
the quirk: cases must THROW exactly that error -- that is the pin) and
WITH it (must not throw, and must emit no "initial_tev out of order"
warning).  Two controls prove the guard is neutral on well-formed
frames: the mixedrouter suite's own two-finger spread must classify
identically with and without it, and a lift that arrives before any
position must be harmless either way.

Usage: luajit test-slotguard.lua KOREADER_DIR MIXEDROUTER_LUA SLOTGUARD_LUA
Output: PASS/FAIL lines and a final "RESULT: ok" / "RESULT: failed".
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local mixedrouter_path = assert(arg[2], "arg2: path to mixedrouter.lua")
local slotguard_path = assert(arg[3], "arg3: path to slotguard.lua")

-- Record warnings instead of silencing them: the "initial_tev out of
-- order" safety-net warnings are part of what the guard must eliminate.
local warnings = {}
-- The bundle's own module tree (frontend/ first, mirroring setupkoenv).
package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")

------------------------------------------------------------------------
-- Stubs.  package.preload beats package.path, so these shadow the
-- bundle's heavier modules.  Everything the exercised code *computes
-- with* (ui/time, ui/geometry, optmath, device/key, ui/event, the ffi
-- cdefs) is the bundle's real code; the stubs only cut off I/O, logging
-- and the framebuffer.
------------------------------------------------------------------------

local noop = function() end

package.preload["logger"] = function()
    -- Silent: keeps the output deterministic and assertion-only.
    local function warn(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        warnings[#warnings + 1] = table.concat(parts, " ")
    end
    return setmetatable({
        dbg = noop, info = noop, warn = warn, err = noop,
        LvDEBUG = noop, setLevel = noop,
    }, { __call = noop })
end

package.preload["dbg"] = function()
    -- input.lua reads DEBUG.is_on; optmath calls dbg:guard().
    local dbg = { is_on = false, ev_log = noop }
    function dbg:guard() end
    function dbg:dassert(check) return check end
    return setmetatable(dbg, { __call = noop })
end

package.preload["datastorage"] = function()
    -- Input:init() only wants a settings dir to pcall(dofile) a custom
    -- event map from; a non-existent path means "none".
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
    -- gesturedetector only uses util.tableDeepCopy (multiswipe + rotation).
    local function tableDeepCopy(t)
        if type(t) ~= "table" then return t end
        local copy = {}
        for k, v in pairs(t) do copy[tableDeepCopy(k)] = tableDeepCopy(v) end
        return copy
    end
    return { tableDeepCopy = tableDeepCopy }
end

package.preload["ffi/framebuffer"] = function()
    -- input.lua only reads the rotation constants off this module.
    return {
        DEVICE_ROTATED_UPRIGHT           = 0,
        DEVICE_ROTATED_CLOCKWISE         = 1,
        DEVICE_ROTATED_UPSIDE_DOWN      = 2,
        DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
    }
end

-- gesturedetector reads G_reader_settings at module load time.
G_reader_settings = {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    isFalse = function() return false end,
    nilOrTrue = function() return true end,
    has = function() return false end,
}

-- The PineNote panel: 1872x1404 @ 227 DPI, upright.
-- PAN_THRESHOLD = scaleByDPI(35) = ceil(35 * 227/160) = 50 px.
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

-- Backend stub: Input:init() skips its default backend require when
-- self.input is preset (same trick as device.lua's input_evdev).  No
-- setTimer => Input:setTimeout takes the poll-deadline path; no timers
-- are ever pumped by this harness, so hold/double-tap timers stay inert
-- (double-tap is disabled anyway, and taps then emit synchronously at
-- contact lift -- upstream Input.disable_double_tap defaults to true).
local StubBackend = {}

------------------------------------------------------------------------
-- The system under test.
------------------------------------------------------------------------

package.preload["ui/uimanager"] = function()
    return { unschedule = noop, scheduleIn = noop, nextTick = noop, broadcastEvent = noop }
end

local Input = require("device/input")
local MixedRouter = dofile(mixedrouter_path)

local PEN = "/dev/input/event3"
local TOUCH = "/dev/input/event2"

local function makeInput(with_router)
    local input = Input:new{
        device = FakeDevice,
        wacom_protocol = true,
        disable_double_tap = true,
        input = StubBackend,
    }
    -- Upstream treats GestureDetector's contact/tap tables as
    -- process-global (class-level) state.  Give each case its own,
    -- exactly as a fresh process would have.
    input.gesture_detector.active_contacts = {}
    input.gesture_detector.previous_tap = {}
    input.gesture_detector.contact_count = 0
    -- Mirror pinenote/device.lua: mixed handler first, then the router.
    input.handleTouchEv = input.handleMixedTouchEv
    if with_router then
        MixedRouter.install(input, PEN, TOUCH)
    end
    return input
end

------------------------------------------------------------------------
-- Event plumbing.
------------------------------------------------------------------------

-- Stable kernel input ABI constants (mirrors mixedrouter.lua's own).
local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT = 0
local ABS_X, ABS_Y = 0x00, 0x01
local ABS_MT_SLOT = 0x2f
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
local ABS_MT_TRACKING_ID = 0x39
local BTN_TOOL_PEN, BTN_TOUCH = 0x140, 0x14a

-- Deterministic fake clock (values chosen so GestureDetector's clock
-- source probe is deterministically inconclusive on any sane host: a
-- ~2s timestamp is +/-2.5s from neither REALTIME nor an uptime clock).
local clock_us

local function stamp()
    return { sec = math.floor(clock_us / 1000000), usec = clock_us % 1000000 }
end

-- One input frame: every event gets the same timestamp, then the clock
-- advances.  Events are {type, code, value, src}; a trailing SYN_REPORT
-- is appended (src'd to the frame's device).
local function frame(src, evs)
    local out = {}
    for _, e in ipairs(evs) do
        out[#out + 1] = { type = e[1], code = e[2], value = e[3],
                          src = src, time = stamp() }
    end
    out[#out + 1] = { type = EV_SYN, code = SYN_REPORT, value = 0,
                      src = src, time = stamp() }
    clock_us = clock_us + 20000 -- 20 ms between frames
    return out
end

-- Dispatch exactly like Input:waitEvent does, collecting gestures.
local function feed(input, frames)
    local gestures = {}
    for _, fr in ipairs(frames) do
        for _, ev in ipairs(fr) do
            if ev.type == EV_KEY then
                input:handleKeyBoardEv(ev)
            elseif ev.type == EV_ABS or ev.type == EV_SYN then
                local evts = input:handleTouchEv(ev)
                if evts then
                    for _, event in ipairs(evts) do
                        -- Event:new("Gesture", ges) -> args[1] is the ges
                        gestures[#gestures + 1] = event.args[1]
                    end
                end
            end
        end
    end
    return gestures
end


-- Gesture-stream helpers (same shape as the mixedrouter suite's).
local function gesToString(g)
    return string.format("%s@%d,%d", tostring(g.ges), g.pos and g.pos.x or -1, g.pos and g.pos.y or -1)
end
local function streamToString(gestures)
    local parts = {}
    for _, g in ipairs(gestures) do parts[#parts + 1] = gesToString(g) end
    return table.concat(parts, " ")
end
local function count(gestures, ges)
    local n = 0
    for _, g in ipairs(gestures) do if g.ges == ges then n = n + 1 end end
    return n
end

local SlotGuard = dofile(slotguard_path)

-- makeInput(with_router) comes from the scaffold; every case here runs
-- with the router (as device.lua does) and toggles only the guard.
local function makeGuarded(with_guard)
    local input = makeInput(true)
    if with_guard then SlotGuard.install(input) end
    return input
end

------------------------------------------------------------------------
-- Streams.
------------------------------------------------------------------------

-- The field sequence (see header).  `input` is needed because the
-- inhibit/restore calls are method calls on the instance, not frames.
local function pinchThenResetThenGhost(input)
    local gestures = {}
    local function go(frames)
        for _, g in ipairs(feed(input, frames)) do gestures[#gestures + 1] = g end
    end
    go({
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, 10 },
                       { EV_ABS, ABS_MT_POSITION_X, 700 }, { EV_ABS, ABS_MT_POSITION_Y, 700 },
                       { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, 11 },
                       { EV_ABS, ABS_MT_POSITION_X, 1100 }, { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
    })
    for i = 1, 6 do
        go({ frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_POSITION_X, 700 + i * 30 },
                            { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_POSITION_X, 1100 - i * 30 } }) })
    end
    -- Finger B lifts: the pinch is emitted here, finger A is still down.
    go({ frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }) })
    -- ReaderRolling re-renders for the new font size.
    input:inhibitInput(true)
    go({ frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_POSITION_X, 900 } }) }) -- dropped
    input:inhibitInput(false)  -- -> Input:resetState(): slot tables wiped
    -- Finger A, still down, moves on Y only: neither its id nor X is re-sent.
    go({ frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_POSITION_Y, 720 } }) })
    -- The next pinch: finger C lands complete and pans.
    go({
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, 12 },
                       { EV_ABS, ABS_MT_POSITION_X, 1100 }, { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_POSITION_X, 1060 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_POSITION_X, 1020 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_POSITION_X, 980 } }),
    })
    -- Everything lifts.
    go({
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
    })
    return gestures
end

-- The other face of the same defect, with no reset involved: a contact
-- whose tracking id arrives a frame before its position (the "recorded
-- an initial_tev out of order for buddy slot" warning), then paired.
local function positionlessBuddy()
    return {
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, 10 },
                       { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, 11 },
                       { EV_ABS, ABS_MT_POSITION_X, 1000 }, { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_POSITION_X, 1040 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_POSITION_X, 1080 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_POSITION_X, 1120 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_POSITION_X, 800 }, { EV_ABS, ABS_MT_POSITION_Y, 700 },
                       { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_POSITION_X, 1160 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_POSITION_X, 760 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
    }
end

-- Control: the mixedrouter suite's own well-formed two-finger spread.
local function twoFingerSpread()
    return {
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, 10 },
                       { EV_ABS, ABS_MT_POSITION_X, 800 }, { EV_ABS, ABS_MT_POSITION_Y, 702 },
                       { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, 11 },
                       { EV_ABS, ABS_MT_POSITION_X, 1000 }, { EV_ABS, ABS_MT_POSITION_Y, 698 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_POSITION_X, 600 },
                       { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_POSITION_X, 1200 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 },
                       { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
    }
end

-- Control: a lift before any position ever arrived (a ghost that simply
-- goes away) must be harmless with and without the guard.
local function liftBeforePosition()
    return {
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, 10 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, 11 },
                       { EV_ABS, ABS_MT_POSITION_X, 500 }, { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
    }
end

------------------------------------------------------------------------
-- Assertions.
------------------------------------------------------------------------
local failures = 0
local function report(ok, label, detail)
    print((ok and "PASS: " or "FAIL: ") .. label .. (detail and (" -- " .. detail) or ""))
    if not ok then failures = failures + 1 end
end

local CRASH = "attempt to perform arithmetic on field 'x'"

local function run(with_guard, runner)
    clock_us = 2000000
    warnings = {}
    local input = makeGuarded(with_guard)
    local ok, res = pcall(runner, input)
    local out_of_order = 0
    for _, w in ipairs(warnings) do
        if w:find("initial_tev out of order", 1, true) then out_of_order = out_of_order + 1 end
    end
    return ok, res, out_of_order
end

-- 1. quirk: the glass crash, pinned (upstream behaviour, no guard).
do
    local ok, err, ooo = run(false, pinchThenResetThenGhost)
    report(not ok and tostring(err):find(CRASH, 1, true) ~= nil,
           "quirk:reset-ghost-buddy -- pinch, re-render reset, delta-only survivor, next pan THROWS (upstream)",
           ok and "did not throw" or tostring(err))
    report(ooo >= 1, "quirk:reset-ghost-buddy -- the 'initial_tev out of order' warning precedes it", tostring(ooo))
end
-- 2. fixed: same stream with the guard.
do
    local ok, err, ooo = run(true, pinchThenResetThenGhost)
    report(ok, "slotguard: the same sequence does not throw", not ok and tostring(err) or nil)
    report(ooo == 0, "slotguard: and emits no 'initial_tev out of order' warning", tostring(ooo))
end
-- 3. quirk: positionless tracking id paired as a buddy, pinned.
do
    local ok, err, ooo = run(false, function(input) return feed(input, positionlessBuddy()) end)
    report(not ok and tostring(err):find(CRASH, 1, true) ~= nil,
           "quirk:positionless-buddy -- id-before-position contact paired, next pan THROWS (upstream)",
           ok and "did not throw" or tostring(err))
end
do
    local ok, err, ooo = run(true, function(input) return feed(input, positionlessBuddy()) end)
    report(ok and ooo == 0, "slotguard: id-before-position contact is withheld until complete; no throw, no warning",
           not ok and tostring(err) or tostring(ooo))
end
-- 4. control: well-formed two-finger frames classify identically.
do
    local ok1, g1 = run(false, function(input) return feed(input, twoFingerSpread()) end)
    local ok2, g2 = run(true, function(input) return feed(input, twoFingerSpread()) end)
    report(ok1 and ok2 and count(g1, "spread") == 1 and count(g2, "spread") == 1
           and streamToString(g1) == streamToString(g2),
           "control: two-finger spread is one spread with and without the guard (identical streams)",
           ok1 and ok2 and (streamToString(g1) .. " vs " .. streamToString(g2)) or "threw")
end
-- 5. control: a lift before any position is harmless both ways.
do
    local ok1, g1 = run(false, function(input) return feed(input, liftBeforePosition()) end)
    local ok2, g2 = run(true, function(input) return feed(input, liftBeforePosition()) end)
    report(ok1 and ok2 and count(g2, "tap") == 1,
           "control: lift-before-position is harmless; the following real tap still lands",
           (ok1 and ok2) and streamToString(g2) or "threw")
end
-- 6. the guard is what device.lua installs (a wrapper, marked).
do
    local input = makeGuarded(true)
    report(input._wilkbook_slotguard == true and SlotGuard.filter_frame(input) == 0,
           "slotguard: installs as a handleTouchEv wrapper and is a no-op on an empty frame")
end

print(failures == 0 and "RESULT: ok" or ("RESULT: failed (" .. failures .. ")"))
os.exit(failures == 0 and 0 or 1)
