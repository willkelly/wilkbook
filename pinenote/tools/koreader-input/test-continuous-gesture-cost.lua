--[[--
What a continuous two-finger gesture actually costs, measured (issue #26).

Issue #26 assumed a pinch "spans several size steps, and each step
presumably re-renders and re-publishes the whole page" -- seconds of
panel activity at ~596 ms per GL16/GC16 full update.  This harness
measures the premise instead of designing against it, by replaying
synthetic evdev streams through the *verbatim* upstream
frontend/device/input.lua + gesturedetector.lua out of the native
koreader-bin bundle (same instrument as test-mixedrouter.lua; see
README.md) and counting what actually reaches a consumer.

The measurement, in one line: **upstream already coalesces, and it
coalesces at the gesture-detection layer, not with a timer.**
`pinch`/`spread` are terminal gestures -- `Contact:panState` only builds
them on the contact-lift branch (`tev.id == -1`), so one two-finger
gesture emits exactly one of them no matter how many evdev frames it
spanned.  The per-frame `inward_pan`/`outward_pan` events the detector
also emits have **no consumer anywhere** in the bundle, so they cost
zero panel passes.

What this file therefore pins:

  1. `pinch-emits-once` / `spread-emits-once` -- one terminal gesture per
     interaction across a 1..40 intermediate-frame sweep, and an
     identical `distance` in every case (it is the summed contact
     travel, so the sample rate cannot change the outcome either).
  2. `continuous-variants-have-no-consumer` -- a whole-tree scan of the
     bundle's frontend/ + plugins/ AND the repo's koreader-device
     overlay: nothing outside gesturedetector.lua mentions
     inward_pan / outward_pan / two_finger_pan / two_finger_hold_pan /
     two_finger_pan_release.  Goes red the day upstream adds one.
  3. `one-gesture-one-font-step` -- the *verbatim* `ReaderFont:steps` and
     `ReaderFont:gesToFontSize` extracted from the bundle's
     readerfont.lua, run on each measured pinch: the same single delta
     for every frame count, capped at the table's last entry.
  4. `quirk:slow-pinch-is-a-silent-no-op` -- `Contact:isSwipe` gates the
     terminal gesture on the whole interaction finishing inside
     SWIPE_INTERVAL_MS (900 ms).  A slower, more deliberate pinch emits
     `two_finger_pan_release` instead, which also has no consumer: the
     font size does not change and nothing tells the reader why.
  5. `binding-shape` -- the shipped reader defaults really are
     pinch->decrease_font / spread->increase_font, and both are
     `incrementalnumber` actions, which is the Dispatcher branch that
     forwards the *gesture object* (so the one delta comes from the one
     gesture).
  6. `reachability` -- which members of the two-finger family this input
     stack can actually produce, and the standing slot constraint they
     all inherit (`quirk:buddy-slots-0-1-only`, already pinned in
     test-mixedrouter.lua for spread; re-asserted here for pinch).

NOT covered, deliberately: how many `[pn-refresh]` traces the *downstream*
repaint costs.  That needs UIManager + ReaderUI, which this harness does
not run; the source-derived count is recorded in doc/refresh-policy.md
and labelled there as source-derived.  And nothing here has been seen on
a panel.

Usage: luajit test-continuous-gesture-cost.lua /path/to/bundle/lib/koreader \
           /path/to/repo/pinenote/packages/koreader-device

Output: PASS/FAIL lines and a final "RESULT: ok" / "RESULT: failed".
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local overlay_dir = assert(arg[2], "arg2: repo koreader-device dir")

package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

------------------------------------------------------------------------
-- Stubs.  package.preload beats package.path, so these shadow the
-- bundle's heavier modules.  Everything the exercised code *computes
-- with* (ui/time, ui/geometry, optmath, device/key, ui/event, the ffi
-- cdefs) is the bundle's real code; the stubs only cut off I/O, logging
-- and the framebuffer.  Same set as test-mixedrouter.lua.
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
        DEVICE_ROTATED_UPSIDE_DOWN       = 2,
        DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
    }
end

-- gesturedetector reads G_reader_settings at module load time: no user
-- overrides, so SWIPE_INTERVAL_MS et al keep their upstream defaults.
G_reader_settings = {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    isFalse = function() return false end,
    nilOrTrue = function() return true end,
    has = function() return false end,
}

-- The PineNote panel: 1872x1404 @ 227 DPI, upright (test-mixedrouter's
-- convention).  PAN_THRESHOLD = scaleByDPI(35) = 50 px.
local Screen = {
    DEVICE_ROTATED_UPRIGHT           = 0,
    DEVICE_ROTATED_CLOCKWISE         = 1,
    DEVICE_ROTATED_UPSIDE_DOWN       = 2,
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

local Input = require("device/input")
local lfs = require("libs/libkoreader-lfs")

local fail = 0
local function report(ok, label, msg)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label, msg))
    if not ok then fail = fail + 1 end
end

------------------------------------------------------------------------
-- Event plumbing (mirrors test-mixedrouter.lua).
------------------------------------------------------------------------

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT = 0
local ABS_MT_SLOT = 0x2f
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
local ABS_MT_TRACKING_ID = 0x39
local TOUCH = "/dev/input/event2"

local clock_us
local frame_gap_us

local function stamp()
    return { sec = math.floor(clock_us / 1000000), usec = clock_us % 1000000 }
end

-- One input frame: every event shares the frame timestamp, a SYN_REPORT
-- is appended, then the clock advances by the configured frame gap.
local function frame(evs)
    local out = {}
    for _, e in ipairs(evs) do
        out[#out + 1] = { type = e[1], code = e[2], value = e[3],
                          src = TOUCH, time = stamp() }
    end
    out[#out + 1] = { type = EV_SYN, code = SYN_REPORT, value = 0,
                      src = TOUCH, time = stamp() }
    clock_us = clock_us + frame_gap_us
    return out
end

local function makeInput()
    local input = Input:new{
        device = FakeDevice,
        wacom_protocol = true,
        disable_double_tap = true,
        input = StubBackend,
    }
    -- Upstream treats GestureDetector's contact/tap tables as
    -- process-global state; give each case its own, as a fresh process
    -- would have.
    input.gesture_detector.active_contacts = {}
    input.gesture_detector.previous_tap = {}
    input.gesture_detector.contact_count = 0
    -- Mirror pinenote/device.lua.  The mixedrouter is deliberately NOT
    -- installed: it is neutral on pure-touch streams (test-mixedrouter
    -- pins that with compare_streams), and leaving it out keeps this
    -- file measuring upstream's own behavior.
    input.handleTouchEv = input.handleMixedTouchEv
    return input
end

local function feed(input, frames)
    local gestures = {}
    for _, fr in ipairs(frames) do
        for _, ev in ipairs(fr) do
            if ev.type == EV_KEY then
                input:handleKeyBoardEv(ev)
            else
                local evts = input:handleTouchEv(ev)
                if evts then
                    for _, event in ipairs(evts) do
                        gestures[#gestures + 1] = event.args[1]
                    end
                end
            end
        end
    end
    return gestures
end

local function count(gestures, ges)
    local n = 0
    for _, g in ipairs(gestures) do
        if g.ges == ges then n = n + 1 end
    end
    return n
end

local function first(gestures, ges)
    for _, g in ipairs(gestures) do
        if g.ges == ges then return g end
    end
end

local function tally(gestures)
    local seen, order = {}, {}
    for _, g in ipairs(gestures) do
        if not seen[g.ges] then order[#order + 1] = g.ges end
        seen[g.ges] = (seen[g.ges] or 0) + 1
    end
    table.sort(order)
    local parts = {}
    for _, k in ipairs(order) do
        parts[#parts + 1] = string.format("%s=%d", k, seen[k])
    end
    return table.concat(parts, " ")
end

------------------------------------------------------------------------
-- Stream builders.  Two contacts in slots {0,1} (the only pair upstream
-- buddies -- see quirk:buddy-slots-0-1-only), converging or diverging
-- over `steps` intermediate frames.
------------------------------------------------------------------------

-- ax0/bx0 -> ax1/bx1 on the X axis at a fixed Y; the kernel dedups
-- unchanged ABS values, so the move frames carry X only.
local function twoFingerDrag(slot_a, slot_b, ax0, bx0, ax1, bx1, steps, gap_us)
    frame_gap_us = gap_us
    local frames = {
        frame({ { EV_ABS, ABS_MT_SLOT, slot_a },
                { EV_ABS, ABS_MT_TRACKING_ID, 10 },
                { EV_ABS, ABS_MT_POSITION_X, ax0 },
                { EV_ABS, ABS_MT_POSITION_Y, 700 },
                { EV_ABS, ABS_MT_SLOT, slot_b },
                { EV_ABS, ABS_MT_TRACKING_ID, 11 },
                { EV_ABS, ABS_MT_POSITION_X, bx0 },
                { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
    }
    for i = 1, steps do
        local t = i / steps
        frames[#frames + 1] = frame({
            { EV_ABS, ABS_MT_SLOT, slot_a },
            { EV_ABS, ABS_MT_POSITION_X, math.floor(ax0 + (ax1 - ax0) * t) },
            { EV_ABS, ABS_MT_SLOT, slot_b },
            { EV_ABS, ABS_MT_POSITION_X, math.floor(bx0 + (bx1 - bx0) * t) } })
    end
    frames[#frames + 1] = frame({
        { EV_ABS, ABS_MT_SLOT, slot_a }, { EV_ABS, ABS_MT_TRACKING_ID, -1 },
        { EV_ABS, ABS_MT_SLOT, slot_b }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } })
    return frames
end

-- Fingers 800 px apart converge to 40 px apart: 760 px of summed travel.
local function pinchFrames(steps, gap_us, slot_a, slot_b)
    return twoFingerDrag(slot_a or 0, slot_b or 1, 500, 1300, 880, 920,
                         steps, gap_us or 20000)
end

-- The same interaction reversed.
local function spreadFrames(steps, gap_us)
    return twoFingerDrag(0, 1, 880, 920, 500, 1300, steps, gap_us or 20000)
end

-- Every case starts from a fresh 2.000000s epoch: the stream builders
-- stamp frames as they go, so the clock has to be reset BEFORE building.
local function resetClock()
    clock_us = 2000000
end

local function replay(build)
    resetClock()
    return feed(makeInput(), build())
end

------------------------------------------------------------------------
-- 1. One terminal gesture per interaction, whatever the frame count.
------------------------------------------------------------------------

local FRAME_SWEEP = { 1, 2, 6, 12, 20, 40 }

-- Measured pinches, kept for the font-size arithmetic below.
local measured_pinches = {}

local function sweepCase(name, ges, builder)
    local distances, mids = {}, {}
    local ok, msg = true, nil
    for _, steps in ipairs(FRAME_SWEEP) do
        local g = replay(function() return builder(steps) end)
        local n = count(g, ges)
        local terminal = first(g, ges)
        local mid = count(g, "inward_pan") + count(g, "outward_pan")
                    + count(g, "two_finger_pan")
        mids[#mids + 1] = string.format("%d:%d", steps, mid)
        if n ~= 1 then
            ok = false
            msg = string.format("steps=%d emitted %d %s (want exactly 1); stream [%s]",
                                steps, n, ges, tally(g))
            break
        end
        distances[#distances + 1] = math.floor(terminal.distance + 0.5)
        if ges == "pinch" then
            measured_pinches[#measured_pinches + 1] =
                { steps = steps, ges = terminal }
        end
    end
    if ok then
        for i = 2, #distances do
            if distances[i] ~= distances[1] then
                ok = false
                msg = string.format("distance varied with the frame count: %s",
                                    table.concat(distances, ","))
                break
            end
        end
    end
    if ok then
        msg = string.format(
            "exactly one %s per interaction across %d..%d intermediate frames, "
            .. "distance=%d px every time; unconsumed mid-gesture pans (steps:n) %s",
            ges, FRAME_SWEEP[1], FRAME_SWEEP[#FRAME_SWEEP], distances[1],
            table.concat(mids, " "))
    end
    report(ok, name, msg)
end

sweepCase("pinch-emits-once", "pinch", function(steps) return pinchFrames(steps) end)
sweepCase("spread-emits-once", "spread", function(steps) return spreadFrames(steps) end)

------------------------------------------------------------------------
-- 2. The mid-gesture variants have no consumer anywhere.
------------------------------------------------------------------------

-- The gestures the detector emits *during* a two-finger interaction.
-- If any of these ever gains a handler, the "one gesture, one render"
-- conclusion in doc/refresh-policy.md stops holding and this goes red.
local CONTINUOUS_GESTURES = {
    "inward_pan", "outward_pan", "two_finger_pan",
    "two_finger_hold_pan", "two_finger_pan_release",
}

-- Where they are legitimately named: the detector that emits them.
local EMITTER = "frontend/device/gesturedetector.lua"

local function walkLua(root, prefix, acc)
    local names = {}
    for entry in lfs.dir(root) do
        if entry ~= "." and entry ~= ".." then names[#names + 1] = entry end
    end
    table.sort(names) -- lfs.dir order is filesystem order; keep output stable
    for _, entry in ipairs(names) do
        local path = root .. "/" .. entry
        local rel = prefix == "" and entry or (prefix .. "/" .. entry)
        local mode = lfs.attributes(path, "mode")
        if mode == "directory" then
            walkLua(path, rel, acc)
        elseif mode == "file" and entry:sub(-4) == ".lua" then
            acc[#acc + 1] = { path = path, rel = rel }
        end
    end
    return acc
end

do
    local files = {}
    walkLua(koreader_dir .. "/frontend", "frontend", files)
    walkLua(koreader_dir .. "/plugins", "plugins", files)
    walkLua(overlay_dir, "koreader-device", files)

    local hits = {}
    for _, f in ipairs(files) do
        if f.rel ~= EMITTER then
            local fh = assert(io.open(f.path, "r"))
            local src = fh:read("*a")
            fh:close()
            for _, ges in ipairs(CONTINUOUS_GESTURES) do
                -- Only a quoted gesture name binds or compares one.
                if src:find('"' .. ges .. '"', 1, true)
                   or src:find("'" .. ges .. "'", 1, true) then
                    hits[#hits + 1] = f.rel .. ":" .. ges
                end
            end
        end
    end
    table.sort(hits)

    if #hits == 0 then
        report(true, "continuous-variants-have-no-consumer", string.format(
            "%d .lua files scanned (bundle frontend/ + plugins/ + repo overlay); "
            .. "nothing outside %s names %s -- the per-frame events cost zero panel passes",
            #files, EMITTER, table.concat(CONTINUOUS_GESTURES, "/")))
    else
        report(false, "continuous-variants-have-no-consumer",
               "a mid-gesture variant gained a consumer: " .. table.concat(hits, " "))
    end

    -- Control: the scan can see a real binding.  pinch/spread DO have
    -- consumers, so a scan that finds nothing for them is broken.
    local control = 0
    for _, f in ipairs(files) do
        if f.rel ~= EMITTER then
            local fh = assert(io.open(f.path, "r"))
            local src = fh:read("*a")
            fh:close()
            if src:find('"pinch"', 1, true) then control = control + 1 end
        end
    end
    report(control > 0, "continuous-variants-scan-control", string.format(
        'the same scan finds "pinch" in %d file(s) -- it is not silently matching nothing',
        control))
end

------------------------------------------------------------------------
-- 3. One gesture, one font step: the VERBATIM upstream arithmetic.
------------------------------------------------------------------------

local READERFONT = koreader_dir .. "/frontend/apps/reader/modules/readerfont.lua"

local function slurp(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local src = fh:read("*a")
    fh:close()
    return src
end

do
    local src = slurp(READERFONT)
    if not src then
        report(false, "one-gesture-one-font-step", "cannot read " .. READERFONT)
    else
        -- Extracted at run time, never copied: the tests exercise exactly
        -- the code the bundle ships (doc/testing.md rule 1).
        local steps_src = src:match("\n%s*steps%s*=%s*(%b{})%s*,")
        local body = src:match(
            "\nfunction ReaderFont:gesToFontSize%(ges%)\n(.-)\nend\n")
        if not steps_src or not body then
            report(false, "one-gesture-one-font-step",
                   "upstream readerfont.lua no longer has the expected "
                   .. "`steps = {...}` / `ReaderFont:gesToFontSize(ges)` shape; "
                   .. "re-derive this gate before trusting it")
        else
            local chunk = assert(loadstring(
                "local Screen = ...\n"
                .. "local ReaderFont = { steps = " .. steps_src .. " }\n"
                .. "function ReaderFont:gesToFontSize(ges)\n" .. body .. "\nend\n"
                .. "return ReaderFont", "=readerfont:gesToFontSize"))
            local ReaderFont = chunk(Screen)
            local cap = ReaderFont.steps[#ReaderFont.steps]

            local deltas = {}
            local ok, msg = true, nil
            for _, m in ipairs(measured_pinches) do
                -- Dispatcher's incrementalnumber branch hands the gesture
                -- table straight through when the bound value is 0.
                local d = ReaderFont:gesToFontSize(m.ges)
                deltas[#deltas + 1] = string.format("%d:%s", m.steps, tostring(d))
                if type(d) ~= "number" then
                    ok, msg = false, "gesToFontSize returned a non-number for steps="
                                     .. m.steps
                    break
                end
                if d > cap then
                    ok, msg = false, string.format(
                        "delta %d exceeds the steps-table cap %d", d, cap)
                    break
                end
            end
            if ok and #measured_pinches == 0 then
                ok, msg = false, "no measured pinch to feed the arithmetic"
            end
            if ok then
                local firstd = deltas[1]:match(":(.*)$")
                for _, e in ipairs(deltas) do
                    if e:match(":(.*)$") ~= firstd then
                        ok, msg = false,
                            "the font delta varied with the frame count: "
                            .. table.concat(deltas, " ")
                        break
                    end
                end
                if ok then
                    msg = string.format(
                        "one pinch -> one delta of %s point(s) (cap %d) for every "
                        .. "frame count (steps:delta %s); the interaction is a "
                        .. "single re-render, not one per step",
                        firstd, cap, table.concat(deltas, " "))
                end
            end
            report(ok, "one-gesture-one-font-step", msg)
        end
    end
end

------------------------------------------------------------------------
-- 4. quirk: a slow, deliberate pinch does nothing at all.
------------------------------------------------------------------------
--
-- Contact:isSwipe() gates the whole terminal-gesture branch on the
-- interaction finishing within ges_swipe_interval (SWIPE_INTERVAL_MS =
-- 900 ms upstream).  Past that the lift is a two_finger_pan_release,
-- which -- per the scan above -- nothing consumes.  So the SLOWER and
-- more deliberate the pinch, the more likely it is to silently do
-- nothing.  That is the opposite failure mode from the one issue #26
-- expected, and it is an upstream wart, not ours: pinned, not fixed
-- (doc/upstream-register.md).

do
    local GD = require("device/gesturedetector")
    local interval_ms = GD.SWIPE_INTERVAL_MS
    -- 12 intermediate frames at 80 ms = 1040 ms end to end.
    local slow = replay(function() return pinchFrames(12, 80000) end)
    -- The same geometry at 20 ms/frame = 260 ms.
    local brisk = replay(function() return pinchFrames(12, 20000) end)
    local ok = interval_ms == 900
        and count(slow, "pinch") == 0
        and count(slow, "two_finger_pan_release") == 1
        and count(brisk, "pinch") == 1
    report(ok, "quirk:slow-pinch-is-a-silent-no-op", string.format(
        "SWIPE_INTERVAL_MS=%s; the same pinch geometry over 1040 ms gives [%s] "
        .. "(no pinch, and two_finger_pan_release has no consumer), over 260 ms "
        .. "gives [%s]",
        tostring(interval_ms), tally(slow), tally(brisk)))
end

------------------------------------------------------------------------
-- 5. The binding shape the shipped defaults really carry.
------------------------------------------------------------------------
--
-- Source gates, not execution: loading the gestures plugin's defaults
-- needs a full Device.  They pin the two links that make "one gesture ->
-- one font event" true, and go red if upstream re-shapes either.

do
    local defaults = slurp(koreader_dir .. "/plugins/gestures.koplugin/defaults.lua")
    local dispatcher = slurp(koreader_dir .. "/frontend/dispatcher.lua")
    local reader_section = defaults and defaults:match("gesture_reader%s*=%s*(%b{})")
    local ok_bind = reader_section ~= nil
        and reader_section:find("pinch_gesture%s*=%s*{%s*decrease_font%s*=%s*0%s*,?%s*}") ~= nil
        and reader_section:find("spread_gesture%s*=%s*{%s*increase_font%s*=%s*0%s*,?%s*}") ~= nil
    report(ok_bind, "binding-shape:reader-defaults",
           ok_bind
           and "gesture_reader ships pinch_gesture={decrease_font=0} and "
               .. "spread_gesture={increase_font=0}"
           or "the shipped reader gesture defaults no longer bind pinch/spread "
              .. "to decrease_font/increase_font at value 0")

    local ok_cat = dispatcher ~= nil
        and dispatcher:find('decrease_font%s*=%s*{%s*category%s*=%s*"incrementalnumber"') ~= nil
        and dispatcher:find('increase_font%s*=%s*{%s*category%s*=%s*"incrementalnumber"') ~= nil
        and dispatcher:find('arg%s*=%s*v%s*~=%s*0%s+and%s+v%s+or%s+gesture%s+or%s+0') ~= nil
    report(ok_cat, "binding-shape:dispatcher-forwards-the-gesture",
           ok_cat
           and "increase_font/decrease_font are incrementalnumber actions and the "
               .. "Dispatcher's incrementalnumber branch forwards the gesture object "
               .. "when the bound value is 0 -- one gesture, one event, one delta"
           or "the Dispatcher no longer forwards the gesture object for "
              .. "incrementalnumber actions bound at 0; re-derive this gate")
end

------------------------------------------------------------------------
-- 6. Reachability of the two-finger family on this input stack.
------------------------------------------------------------------------

do
    -- rotate: one contact immobile (the pivot), the other swinging past
    -- PAN_THRESHOLD and lifting first.
    frame_gap_us = 20000
    resetClock()
    local rotate_frames = {
        frame({ { EV_ABS, ABS_MT_SLOT, 0 },
                { EV_ABS, ABS_MT_TRACKING_ID, 20 },
                { EV_ABS, ABS_MT_POSITION_X, 900 },
                { EV_ABS, ABS_MT_POSITION_Y, 700 },
                { EV_ABS, ABS_MT_SLOT, 1 },
                { EV_ABS, ABS_MT_TRACKING_ID, 21 },
                { EV_ABS, ABS_MT_POSITION_X, 1200 },
                { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
        -- Only slot 1 moves, and it moves off-axis.
        frame({ { EV_ABS, ABS_MT_SLOT, 1 },
                { EV_ABS, ABS_MT_POSITION_X, 1150 },
                { EV_ABS, ABS_MT_POSITION_Y, 560 } }),
        frame({ { EV_ABS, ABS_MT_SLOT, 1 },
                { EV_ABS, ABS_MT_POSITION_X, 1080 },
                { EV_ABS, ABS_MT_POSITION_Y, 460 } }),
        -- The moving contact lifts first: it is the rotate trigger.
        frame({ { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
        frame({ { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
    }
    local rot = feed(makeInput(), rotate_frames)

    -- two_finger_tap: both contacts down and up inside the tap window,
    -- neither moving.
    frame_gap_us = 20000
    resetClock()
    local tft = feed(makeInput(), {
        frame({ { EV_ABS, ABS_MT_SLOT, 0 },
                { EV_ABS, ABS_MT_TRACKING_ID, 30 },
                { EV_ABS, ABS_MT_POSITION_X, 800 },
                { EV_ABS, ABS_MT_POSITION_Y, 700 },
                { EV_ABS, ABS_MT_SLOT, 1 },
                { EV_ABS, ABS_MT_TRACKING_ID, 31 },
                { EV_ABS, ABS_MT_POSITION_X, 1000 },
                { EV_ABS, ABS_MT_POSITION_Y, 700 } }),
        frame({ { EV_ABS, ABS_MT_SLOT, 0 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 },
                { EV_ABS, ABS_MT_SLOT, 1 }, { EV_ABS, ABS_MT_TRACKING_ID, -1 } }),
    })

    -- two_finger_swipe: both contacts travelling the same way.
    resetClock()
    local tfs = feed(makeInput(), twoFingerDrag(0, 1, 500, 700, 1100, 1300, 4, 20000))

    local pinch_g = replay(function() return pinchFrames(12) end)
    local spread_g = replay(function() return spreadFrames(12) end)

    local rows = {
        { "pinch", count(pinch_g, "pinch") == 1, tally(pinch_g) },
        { "spread", count(spread_g, "spread") == 1, tally(spread_g) },
        { "rotate", count(rot, "rotate") == 1, tally(rot) },
        { "two_finger_tap", count(tft, "two_finger_tap") == 1, tally(tft) },
        { "two_finger_swipe", count(tfs, "two_finger_swipe") == 1, tally(tfs) },
    }
    local reachable, unreachable = {}, {}
    for _, r in ipairs(rows) do
        if r[2] then reachable[#reachable + 1] = r[1]
        else unreachable[#unreachable + 1] = r[1] .. " [" .. r[3] .. "]" end
    end
    report(#unreachable == 0, "reachability:two-finger-family", string.format(
        "reachable from slots {0,1}: %s%s",
        table.concat(reachable, ", "),
        #unreachable == 0 and "" or ("; NOT reached: " .. table.concat(unreachable, ", "))))

    -- Every one of them inherits the standing slot constraint.  The
    -- spread half is already pinned in test-mixedrouter.lua; pinch is
    -- the one the operator actually uses, so pin it here too.
    local off = replay(function() return pinchFrames(12, 20000, 0, 2) end)
    report(count(off, "pinch") == 0 and count(off, "spread") == 0,
           "quirk:buddy-slots-0-1-only:pinch", string.format(
           "the same pinch in slots {0,2} produces no two-finger gesture at all "
           .. "-- [%s]; upstream buddies only main_finger_slot and +1 "
           .. "(doc/upstream-register.md item 11)", tally(off)))
end

------------------------------------------------------------------------

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
