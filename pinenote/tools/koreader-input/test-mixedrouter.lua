--[[--
Host harness for the KOReader input-routing bug and the mixedrouter fix.

Runs the *verbatim* frontend/device/input.lua + gesturedetector.lua from
the native koreader-bin bundle (offline testing ladder; see README.md)
under the bundle's own luajit, constructs an Input instance exactly the
way pinenote/device.lua does (wacom_protocol + handleMixedTouchEv), and
feeds synthetic evdev streams through the same handlers Input:waitEvent
dispatches to (EV_KEY -> handleKeyBoardEv, EV_ABS/EV_SYN ->
handleTouchEv).  Each scenario runs twice: without the router (upstream
behavior, including the pen-hover tap-capture bug) and with the REPO's
mixedrouter.lua installed.

Usage: luajit test-mixedrouter.lua /path/to/bundle/lib/koreader \
           /path/to/repo/.../device/pinenote/mixedrouter.lua

Output: PASS/FAIL lines and a final "RESULT: ok" / "RESULT: failed".
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local mixedrouter_path = assert(arg[2], "arg2: path to mixedrouter.lua")

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
    return setmetatable({
        dbg = noop, info = noop, warn = noop, err = noop,
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

local function gesToString(g)
    local s = string.format("%s@(%d,%d)", g.ges, g.pos.x, g.pos.y)
    if g.direction then s = s .. " dir=" .. g.direction end
    if g.distance then s = s .. string.format(" dist=%.1f", g.distance) end
    return s
end

local function streamToString(gestures)
    if #gestures == 0 then return "(none)" end
    local parts = {}
    for _, g in ipairs(gestures) do parts[#parts + 1] = gesToString(g) end
    return table.concat(parts, "; ")
end

local function count(gestures, ges, x, y)
    local n = 0
    for _, g in ipairs(gestures) do
        if g.ges == ges and (not x or (g.pos.x == x and g.pos.y == y)) then
            n = n + 1
        end
    end
    return n
end

-- White-box view of Input's per-slot bookkeeping (self.ev_slots is the
-- ONE table upstream keeps for every input device, keyed by slot number).
local function snapshot(input, slot)
    local s = input.ev_slots[slot] or {}
    return { id = s.id, x = s.x, y = s.y, tool = s.tool }
end

local function snapToString(s)
    return string.format("id=%s x=%s y=%s tool=%s",
                         tostring(s.id), tostring(s.x),
                         tostring(s.y), tostring(s.tool))
end

------------------------------------------------------------------------
-- Scenario event streams.
------------------------------------------------------------------------

-- Successive hover coordinates differ: the kernel input core also
-- deduplicates unchanged ABS values, so a real stream never repeats.
local function penHoverInterleave()
    return {
        -- Pen enters hover range: BTN_TOOL_PEN comes in its own frame.
        frame(PEN, { { EV_KEY, BTN_TOOL_PEN, 1 } }),
        -- Hover frames around (1200,300): plain ABS_X/ABS_Y only.
        frame(PEN, { { EV_ABS, ABS_X, 1200 }, { EV_ABS, ABS_Y, 300 } }),
        frame(PEN, { { EV_ABS, ABS_X, 1202 }, { EV_ABS, ABS_Y, 301 } }),
        frame(PEN, { { EV_ABS, ABS_X, 1204 }, { EV_ABS, ABS_Y, 302 } }),
        -- Finger tap at (500,700).  Single-finger session = slot 0 the
        -- whole way, so the kernel emits NO ABS_MT_SLOT (dedup).
        frame(TOUCH, { { EV_ABS, ABS_MT_TRACKING_ID, 37 },
                       { EV_ABS, ABS_MT_POSITION_X, 500 },
                       { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
        -- Pen keeps hovering while the finger is down.
        frame(PEN, { { EV_ABS, ABS_X, 1206 }, { EV_ABS, ABS_Y, 303 } }),
        frame(PEN, { { EV_ABS, ABS_X, 1208 }, { EV_ABS, ABS_Y, 304 } }),
        -- Finger lift (~80 ms after contact: well inside tap timing).
        frame(TOUCH, { { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
    }
end

local scenarios = {}

scenarios[#scenarios + 1] = {
    name = "quirk:pen-hover-tap-capture",
    run = function(input)
        local frames = penHoverInterleave()
        -- Pen leaves proximity afterwards.
        frames[#frames + 1] = frame(PEN, { { EV_KEY, BTN_TOOL_PEN, 0 } })
        return feed(input, frames)
    end,
    check_without = function(g)
        -- The bug: the finger tap is swallowed into the pen slot and
        -- re-classified.  No tap anywhere; a pan and/or swipe instead.
        if count(g, "tap") ~= 0 then
            return false, "expected NO tap without the router, got one"
        end
        if count(g, "pan") + count(g, "swipe") + count(g, "multiswipe") == 0 then
            return false, "expected the pan/swipe misclassification, got neither"
        end
        return true, "finger tap swallowed into the pen slot, re-emitted as pan/swipe"
    end,
    check_with = function(g)
        if count(g, "tap", 500, 700) ~= 1 or count(g, "tap") ~= 1 then
            return false, "expected exactly one tap at (500,700)"
        end
        if count(g, "pan") + count(g, "swipe") + count(g, "multiswipe") ~= 0 then
            return false, "expected no pan/swipe with the router"
        end
        return true, "exactly one tap at (500,700), no pan/swipe"
    end,
}

scenarios[#scenarios + 1] = {
    name = "pen-contact-after-interleave",
    run = function(input)
        local frames = penHoverInterleave()
        -- Pen tip contact (pen still in proximity), small move, lift.
        frames[#frames + 1] = frame(PEN, { { EV_KEY, BTN_TOUCH, 1 },
                                           { EV_ABS, ABS_X, 1210 },
                                           { EV_ABS, ABS_Y, 306 } })
        frames[#frames + 1] = frame(PEN, { { EV_ABS, ABS_X, 1214 },
                                           { EV_ABS, ABS_Y, 308 } })
        frames[#frames + 1] = frame(PEN, { { EV_KEY, BTN_TOUCH, 0 } })
        frames[#frames + 1] = frame(PEN, { { EV_KEY, BTN_TOOL_PEN, 0 } })
        return feed(input, frames)
    end,
    check_without = function(g)
        -- Upstream baseline: pen contact works (cur_slot never left the
        -- pen slot) -- it is the *finger* tap that upstream loses.
        if count(g, "tap", 1214, 308) + count(g, "hold", 1214, 308) ~= 1 then
            return false, "expected the pen contact gesture at (1214,308)"
        end
        return true, "pen contact tap at (1214,308) (finger tap still lost)"
    end,
    check_with = function(g)
        -- Regression guard: the key-path re-route keeps the pen working
        -- *and* the finger tap survives in the same stream.
        if count(g, "tap", 1214, 308) + count(g, "hold", 1214, 308) ~= 1 then
            return false, "expected the pen contact gesture at (1214,308)"
        end
        if count(g, "tap", 500, 700) ~= 1 then
            return false, "expected the finger tap at (500,700) too"
        end
        return true, "pen contact tap at (1214,308) and finger tap at (500,700)"
    end,
}

-- A finger contact in a CHOSEN touchscreen slot while the pen hovers.
--
-- Reaching Input.pen_slot needs no fifth finger.  cyttsp5 advertises 32
-- MT slots (ABS_MT_SLOT max = 31) and does NOT allocate them densely: a
-- live 120 s capture whose peak was three simultaneous contacts used
-- slots {0, 1, 2, 5} (doc/artifacts/pinenote-input-clocks-20260824/).
-- A lone contact can therefore be assigned slot 4 -- which is exactly
-- upstream's pen_slot (main_finger_slot + 4).
--
-- The kernel DOES emit the explicit ABS_MT_SLOT here, because the
-- touchscreen's own slot is moving off its 0 default.  That is what
-- makes this a different bug from quirk:pen-hover-tap-capture rather
-- than another instance of it: there, the slot event was suppressed by
-- kernel dedup and the router synthesizes it back; here it arrives, is
-- honored, and still lands on the pen.
local function penHoverFingerInSlot(slot)
    return {
        frame(PEN, { { EV_KEY, BTN_TOOL_PEN, 1 } }),
        frame(PEN, { { EV_ABS, ABS_X, 1200 }, { EV_ABS, ABS_Y, 300 } }),
        frame(PEN, { { EV_ABS, ABS_X, 1202 }, { EV_ABS, ABS_Y, 301 } }),
        -- Finger down at (500,700) in `slot`.
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, slot },
                       { EV_ABS, ABS_MT_TRACKING_ID, 77 },
                       { EV_ABS, ABS_MT_POSITION_X, 500 },
                       { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
        -- Pen keeps hovering while the finger is down.
        frame(PEN, { { EV_ABS, ABS_X, 1206 }, { EV_ABS, ABS_Y, 303 } }),
        frame(PEN, { { EV_ABS, ABS_X, 1208 }, { EV_ABS, ABS_Y, 304 } }),
        -- Finger lift (~60 ms after contact: well inside tap timing).
        -- The touchscreen's own slot has not moved, so the kernel
        -- deduplicates ABS_MT_SLOT on the way out.
        frame(TOUCH, { { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
        frame(PEN, { { EV_KEY, BTN_TOOL_PEN, 0 } }),
    }
end

-- Feed that stream in stages, so the scenario can look at Input's
-- per-slot bookkeeping while the finger is still down.
local function runFingerInSlot(input, slot)
    local frames = penHoverFingerInSlot(slot)
    local gestures = {}
    local notes = { lines = {} }
    local function stage(first, last)
        local part = {}
        for i = first, last do part[#part + 1] = frames[i] end
        for _, g in ipairs(feed(input, part)) do
            gestures[#gestures + 1] = g
        end
    end
    local function record(key, label)
        notes[key] = snapshot(input, input.pen_slot)
        notes[key .. "_finger"] = snapshot(input, slot)
        notes.lines[#notes.lines + 1] = string.format(
            "%-14s pen_slot(%d): %-40s touch slot %d: %s",
            label, input.pen_slot, snapToString(notes[key]),
            slot, snapToString(notes[key .. "_finger"]))
    end
    stage(1, 3)     -- pen enters hover range and moves
    stage(4, 4)     -- finger down
    record("after_contact", "after contact")
    stage(5, 6)     -- pen hovers on while the finger is down
    record("after_hover", "after hover")
    stage(7, 8)     -- finger lift, then pen leaves proximity
    return gestures, notes
end

-- Control half of a one-variable A/B: identical stream, identical
-- coordinates, identical timing -- only the touchscreen slot number
-- differs, and it is chosen NOT to collide with pen_slot.
scenarios[#scenarios + 1] = {
    name = "pen-hover-finger-slot3",
    run = function(input) return runFingerInSlot(input, 3) end,
    check_both = function(g, notes)
        if count(g, "tap", 500, 700) ~= 1 or count(g, "tap") ~= 1 then
            return false, "expected exactly one tap at (500,700)"
        end
        if count(g, "pan") + count(g, "swipe") + count(g, "multiswipe") ~= 0 then
            return false, "expected no pan/swipe"
        end
        if notes.after_hover.id ~= nil then
            return false, "the pen slot must not carry a finger tracking id"
        end
        if notes.after_hover_finger.x ~= 500 or notes.after_hover_finger.y ~= 700 then
            return false, "the finger's own slot must still hold (500,700)"
        end
        return true, "finger tap at (500,700) survives; pen and finger keep separate slots"
    end,
    -- The pen only hovers, so the hover tracking the router restores is
    -- invisible in the gesture stream: it must not change the outcome.
    compare_streams = true,
}

-- quirk: THE SAME STREAM with the contact one slot over -- on pen_slot.
--
-- Upstream keeps ONE ev_slots table for every input device, so the pen
-- and a finger assigned kernel slot 4 write to the same entry.  The
-- router disambiguates by SOURCE, but here the two sources agree on the
-- slot number and there is nothing left for it to disambiguate; fixing
-- this means moving the pen out of the panel's slot space, which is a
-- different job from restoring the routing upstream already assumes
-- (mixedrouter.lua's header).  So BOTH halves assert today's behavior:
-- this is a pin, and any future change -- ours or upstream's -- turns it
-- red.  See doc/upstream-register.md item 11.
scenarios[#scenarios + 1] = {
    name = "quirk:pen-slot-collision",
    run = function(input) return runFingerInSlot(input, 4) end,
    check_both = function(g, notes)
        if count(g, "tap") ~= 0 then
            return false, "expected NO tap (the collision swallows it), got one"
        end
        if count(g, "pan", 1206, 303) ~= 1 or count(g, "swipe", 500, 700) ~= 1 then
            return false, "expected the pan-at-pen-coords + swipe misclassification"
        end
        -- White box: the finger's contact data lands IN the pen's slot...
        if notes.after_contact.id ~= 77
           or notes.after_contact.x ~= 500 or notes.after_contact.y ~= 700 then
            return false, "expected the finger's id/coords to land in the pen slot"
        end
        if notes.after_contact.tool ~= 1 then -- TOOL_TYPE_PEN
            return false, "expected the colliding slot to still be marked tool=PEN"
        end
        -- ...and the next hover frame overwrites it, because
        -- handleMixedTouchEv honors ABS_X/ABS_Y on a PEN-tooled slot.
        if notes.after_hover.id ~= 77
           or notes.after_hover.x ~= 1208 or notes.after_hover.y ~= 304 then
            return false, "expected pen hover coords to overwrite the live finger contact"
        end
        return true, "SHOULD be one tap at (500,700): finger id 77 lands in pen_slot 4, "
                     .. "pen hover rewrites it to (1208,304), the tap leaves as pan+swipe"
    end,
    -- Pins mixedrouter.lua's own claim that the collision is unchanged
    -- by it: the router is neutral here, for better and for worse.
    compare_streams = true,
}

-- quirk: the collision costs the PEN too, not only the finger.
--
-- With the finger one slot over, pen-contact-after-interleave above gets
-- BOTH the pen's tap and the finger's out of this shape of stream.  On
-- pen_slot, upstream's BTN_TOUCH handler writes the pen's contact state
-- onto the finger's live tracking id and neither survives -- so on a
-- device whose pen is for writing, an ink stroke leaves as a page-turn
-- swipe.  That is the stake for #20's stroke capture, not just for taps.
scenarios[#scenarios + 1] = {
    name = "quirk:pen-slot-collision-tip",
    run = function(input)
        return feed(input, {
            frame(PEN, { { EV_KEY, BTN_TOOL_PEN, 1 } }),
            frame(PEN, { { EV_ABS, ABS_X, 1200 }, { EV_ABS, ABS_Y, 300 } }),
            frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, 4 },
                           { EV_ABS, ABS_MT_TRACKING_ID, 77 },
                           { EV_ABS, ABS_MT_POSITION_X, 500 },
                           { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
            -- Pen tip down and up while the finger is still down.
            frame(PEN, { { EV_KEY, BTN_TOUCH, 1 },
                         { EV_ABS, ABS_X, 1210 }, { EV_ABS, ABS_Y, 306 } }),
            frame(PEN, { { EV_KEY, BTN_TOUCH, 0 } }),
            frame(TOUCH, { { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
            frame(PEN, { { EV_KEY, BTN_TOOL_PEN, 0 } }),
        })
    end,
    check_both = function(g)
        if count(g, "tap") ~= 0 or count(g, "hold") ~= 0 then
            return false, "expected NEITHER contact to produce a tap"
        end
        if count(g, "swipe", 500, 700) ~= 1 then
            return false, "expected the swipe misclassification"
        end
        return true, "SHOULD be a pen tap at (1210,306) and a finger tap at (500,700): "
                     .. "both are lost, the stroke leaves as a swipe"
    end,
    compare_streams = true,
}

-- Two fingers moving apart, in a CHOSEN pair of touchscreen slots.
local function twoFingerSpread(a, b)
    return {
        -- Two contacts down: multi-finger frames DO carry explicit
        -- ABS_MT_SLOT switches.
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, a },
                       { EV_ABS, ABS_MT_TRACKING_ID, 10 },
                       { EV_ABS, ABS_MT_POSITION_X, 800 },
                       { EV_ABS, ABS_MT_POSITION_Y, 702 },
                       { EV_ABS, ABS_MT_SLOT, b },
                       { EV_ABS, ABS_MT_TRACKING_ID, 11 },
                       { EV_ABS, ABS_MT_POSITION_X, 1000 },
                       { EV_ABS, ABS_MT_POSITION_Y, 698 } }),
        -- Fingers move apart (only X changes -> Y deduplicated).
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, a },
                       { EV_ABS, ABS_MT_POSITION_X, 600 },
                       { EV_ABS, ABS_MT_SLOT, b },
                       { EV_ABS, ABS_MT_POSITION_X, 1200 } }),
        -- Both lift.
        frame(TOUCH, { { EV_ABS, ABS_MT_SLOT, a },
                       { EV_ABS, ABS_MT_TRACKING_ID, -1 },
                       { EV_ABS, ABS_MT_SLOT, b },
                       { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
    }
end

scenarios[#scenarios + 1] = {
    name = "two-finger-spread",
    run = function(input) return feed(input, twoFingerSpread(0, 1)) end,
    check_both = function(g)
        if count(g, "spread") ~= 1 then
            return false, "expected one spread gesture"
        end
        return true, "spread detected"
    end,
    -- Plus: the full gesture streams must be identical (asserted below).
    compare_streams = true,
}

-- quirk: the same two fingers, one slot over, are not a gesture at all.
--
-- GestureDetector pairs contacts only when their slots are exactly
-- main_finger_slot and main_finger_slot + 1 (newContact's buddy_slot);
-- every other slot number has no buddy and is classified alone.  So the
-- SAME two fingers in slots {0,2} produce two independent swipes instead
-- of a spread -- on a reader, two page turns instead of a font-size
-- change.  Pinch works in the field because the controller usually hands
-- the first two contacts slots 0 and 1, not because slot numbers are
-- handled generally; the live capture that used {0,1,2,5} shows it does
-- not always.  Same root cause family as the pen-slot collision above:
-- upstream treats a slot NUMBER as an identity.  Pinned, not fixed --
-- doc/upstream-register.md item 11.
scenarios[#scenarios + 1] = {
    name = "quirk:buddy-slots-0-1-only",
    run = function(input) return feed(input, twoFingerSpread(0, 2)) end,
    check_both = function(g)
        if count(g, "spread") ~= 0 or count(g, "pinch") ~= 0 then
            return false, "expected NO two-finger gesture from slots {0,2}"
        end
        if count(g, "swipe", 800, 702) ~= 1 or count(g, "swipe", 1000, 698) ~= 1 then
            return false, "expected the two contacts to be classified independently"
        end
        return true, "SHOULD be one spread: slots {0,2} have no buddy, so it is two swipes"
    end,
    compare_streams = true,
}

scenarios[#scenarios + 1] = {
    name = "baseline-tap",
    run = function(input)
        return feed(input, {
            frame(TOUCH, { { EV_ABS, ABS_MT_TRACKING_ID, 42 },
                           { EV_ABS, ABS_MT_POSITION_X, 500 },
                           { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
            frame(TOUCH, { { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
        })
    end,
    check_without = function(g)
        if count(g, "tap", 500, 700) ~= 1 or count(g, "tap") ~= 1 then
            return false, "expected exactly one tap at (500,700)"
        end
        return true, "single tap at (500,700)"
    end,
    check_with = function(g)
        if count(g, "tap", 500, 700) ~= 1 or count(g, "tap") ~= 1 then
            return false, "expected exactly one tap at (500,700)"
        end
        return true, "single tap at (500,700)"
    end,
    compare_streams = true,
}

------------------------------------------------------------------------
-- Runner.
------------------------------------------------------------------------

local fail = 0

local function report(ok, label, msg, stream, notes)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label, msg))
    print(string.format("      gestures: %s", stream))
    if notes and notes.lines then
        for _, line in ipairs(notes.lines) do
            print(string.format("      slots:    %s", line))
        end
    end
    if not ok then fail = fail + 1 end
end

for _, sc in ipairs(scenarios) do
    local streams = {}
    -- check_both is for scenarios whose expectation is the same with and
    -- without the router (a quirk the router does not address, or a
    -- control it must not perturb).
    for _, mode in ipairs({ { false, "no-router", sc.check_without or sc.check_both },
                            { true, "mixedrouter", sc.check_with or sc.check_both } }) do
        local with_router, label, check = mode[1], mode[2], mode[3]
        clock_us = 2000000 -- fresh 2.000000s epoch per case
        local input = makeInput(with_router)
        local gestures, notes = sc.run(input)
        streams[label] = streamToString(gestures)
        local ok, msg = check(gestures, notes)
        report(ok, sc.name .. " [" .. label .. "]", msg, streams[label], notes)
    end
    if sc.compare_streams then
        if streams["no-router"] == streams["mixedrouter"] then
            print(string.format("PASS: %s: identical gesture stream with and without the router",
                                sc.name))
        else
            print(string.format("FAIL: %s: streams differ:\n      no-router:   %s\n      mixedrouter: %s",
                                sc.name, streams["no-router"], streams["mixedrouter"]))
            fail = fail + 1
        end
    end
end

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
