--[[--
Replay a raw evdev capture through KOReader's verbatim input stack.

Takes the byte stream `cat /dev/input/eventN > file` produces on the
device (struct input_event, 24 bytes on aarch64: two int64 timeval
fields, u16 type, u16 code, s32 value), rebuilds the per-SYN frames,
applies the SAME rewrite pinenote/device.lua applies to touchscreen
events (BTN_TOUCH and the legacy ABS_X/ABS_Y/ABS_PRESSURE aliases
neutralized, MT axes mirrored), and feeds them to the bundle's real
frontend/device/input.lua + gesturedetector.lua exactly as
test-mixedrouter.lua does (handleMixedTouchEv + the repo's mixedrouter).

What it reports: every logger.warn the stack emits, with the frames that
led up to it and the gesture detector's contact table at that instant
(slot, tracking id, whether initial_tev was ever recorded and what it
holds, current x/y, state); and, if the stack throws, the traceback plus
the same dump for the frame that killed it.  Exit status 1 on a throw.

This is an instrument, not a gate: it exists because a KOReader crash on
glass (2026-09-02, gesturedetector.lua:325, nil initial_tev.x in the
two-finger path) had "initial_tev out of order" warnings as its
precursor, and the only honest way to see WHICH frames cause those is to
replay the real stream.

Usage: luajit replay-evdev.lua KOREADER_DIR MIXEDROUTER_LUA \
           touch=CAPTURE [pen=CAPTURE] [--context N] [--all-frames]
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local mixedrouter_path = assert(arg[2], "arg2: path to mixedrouter.lua")
local captures, context, all_frames = {}, 8, false
for i = 3, #arg do
    local k, v = arg[i]:match("^(%w+)=(.+)$")
    if k == "touch" or k == "pen" then captures[k] = v
    elseif arg[i] == "--context" then context = tonumber(arg[i + 1])
    elseif arg[i] == "--all-frames" then all_frames = true end
end
assert(captures.touch or captures.pen, "need touch=FILE and/or pen=FILE")

-- Lua 5.2 compat the device's luajit is built with (LUAJIT_ENABLE_LUA52COMPAT).
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
table.unpack = table.unpack or unpack

package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")

------------------------------------------------------------------------
-- Stubs (same shape as test-mixedrouter.lua; the logger RECORDS warns).
------------------------------------------------------------------------
local noop = function() end
local warnings = {}          -- { frame = n, text = "..." }
local current_frame = 0
package.preload["logger"] = function()
    local function warn(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        warnings[#warnings + 1] = { frame = current_frame, text = table.concat(parts, " ") }
    end
    return setmetatable({ dbg = noop, info = noop, warn = warn, err = warn,
                          LvDEBUG = noop, setLevel = noop }, { __call = noop })
end
package.preload["dbg"] = function()
    local dbg = { is_on = false, ev_log = noop }
    function dbg:guard() end
    function dbg:dassert(check) return check end
    return setmetatable(dbg, { __call = noop })
end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/nonexistent" end,
             getDataDir = function() return "/nonexistent" end }
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

package.preload["luasettings"] = function()
    local LS = {}
    function LS:open() return self end
    function LS:readSetting() return nil end
    function LS:isTrue() return false end
    function LS:nilOrTrue() return true end
    function LS:has() return false end
    function LS:saveSetting() end
    function LS:flush() end
    return LS
end
G_reader_settings = { readSetting = function() return nil end, isFalse = function() return false end,
                      isTrue = function() return false end,
                      nilOrTrue = function() return true end,
                      has = function() return false end,
                      saveSetting = noop, makeTrue = noop, makeFalse = noop,
                      flipNilOrFalse = noop }

local Screen = { DEVICE_ROTATED_UPRIGHT = 0, DEVICE_ROTATED_CLOCKWISE = 1,
                 DEVICE_ROTATED_UPSIDE_DOWN = 2, DEVICE_ROTATED_COUNTER_CLOCKWISE = 3 }
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
local MixedRouter = dofile(mixedrouter_path)
local PEN, TOUCH = "/dev/input/pen", "/dev/input/touch"

local input = Input:new{ device = FakeDevice, wacom_protocol = true,
                         disable_double_tap = true, input = StubBackend }
input.gesture_detector.active_contacts = {}
input.gesture_detector.previous_tap = {}
input.gesture_detector.contact_count = 0
input.handleTouchEv = input.handleMixedTouchEv
MixedRouter.install(input, PEN, TOUCH)

------------------------------------------------------------------------
-- Capture parsing.
------------------------------------------------------------------------
local ffi = require("ffi")
ffi.cdef[[ struct wb_input_event { int64_t sec; int64_t usec; uint16_t type; uint16_t code; int32_t value; }; ]]
assert(ffi.sizeof("struct wb_input_event") == 24)

local EV_SYN, EV_KEY, EV_ABS, EV_MSC = 0, 1, 3, 4
local SYN_REPORT = 0
local ABS_X, ABS_Y, ABS_PRESSURE = 0x00, 0x01, 0x18
local ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x2f, 0x35, 0x36
local ABS_MT_TRACKING_ID = 0x39
local BTN_TOUCH = 0x14a
-- Measured on glass (reader-session.log): touch MT axes X=0..1871 Y=0..1403.
local TOUCH_MIN_X, TOUCH_MAX_X, TOUCH_MIN_Y, TOUCH_MAX_Y = 0, 1871, 0, 1403

local function load(path, src)
    local f = assert(io.open(path, "rb"), "cannot open " .. path)
    local data = f:read("*a"); f:close()
    local n = math.floor(#data / 24)
    local buf = ffi.new("uint8_t[?]", #data); ffi.copy(buf, data, #data)
    local evs = ffi.cast("struct wb_input_event *", buf)
    local out = {}
    for i = 0, n - 1 do
        local e = evs[i]
        out[#out + 1] = { type = e.type, code = e.code, value = e.value, src = src,
                          sec = tonumber(e.sec), usec = tonumber(e.usec), _buf = buf }
    end
    return out
end

local events = {}
if captures.touch then for _, e in ipairs(load(captures.touch, TOUCH)) do events[#events + 1] = e end end
if captures.pen then for _, e in ipairs(load(captures.pen, PEN)) do events[#events + 1] = e end end
-- Stable merge by timestamp (ties keep file order: touch before pen).
for i, e in ipairs(events) do e._i = i end
table.sort(events, function(a, b)
    if a.sec ~= b.sec then return a.sec < b.sec end
    if a.usec ~= b.usec then return a.usec < b.usec end
    return a._i < b._i
end)
assert(#events > 0, "empty capture")
local t0 = events[1].sec + events[1].usec / 1e6

-- The device layer's touch rewrite (pinenote/device.lua adjustTouchEvent).
local function adjust(ev)
    if ev.src ~= TOUCH then return end
    if ev.type == EV_KEY and ev.code == BTN_TOUCH then ev.type = EV_MSC
    elseif ev.type == EV_ABS then
        if ev.code == ABS_MT_POSITION_X then ev.value = TOUCH_MIN_X + TOUCH_MAX_X - ev.value
        elseif ev.code == ABS_MT_POSITION_Y then ev.value = TOUCH_MIN_Y + TOUCH_MAX_Y - ev.value
        elseif ev.code == ABS_X or ev.code == ABS_Y or ev.code == ABS_PRESSURE then ev.type = EV_MSC end
    end
end

------------------------------------------------------------------------
-- Frame bookkeeping and dumps.
------------------------------------------------------------------------
local CODE = { [ABS_MT_SLOT] = "SLOT", [ABS_MT_TRACKING_ID] = "ID", [ABS_MT_POSITION_X] = "X",
               [ABS_MT_POSITION_Y] = "Y", [0x30] = "MAJOR", [0x31] = "MINOR", [0x3a] = "MT_PRESS",
               [0x37] = "TOOL", [ABS_X] = "absx", [ABS_Y] = "absy", [ABS_PRESSURE] = "press" }
local function ev_str(e)
    if e.type == EV_SYN then return "SYN"
    elseif e.type == EV_KEY then return string.format("KEY%x:%d", e.code, e.value)
    elseif e.type == EV_ABS then return string.format("%s:%d", CODE[e.code] or string.format("abs%x", e.code), e.value)
    elseif e.type == EV_MSC then return string.format("(msc %s:%d)", CODE[e.code] or e.code, e.value)
    else return string.format("t%d/c%x:%d", e.type, e.code, e.value) end
end

-- Map Contact state functions back to names via their definition lines.
local state_names = {}
do
    local f = io.open(koreader_dir .. "/frontend/device/gesturedetector.lua")
    if f then
        local n = 0
        for line in f:lines() do
            n = n + 1
            local name = line:match("^function Contact:(%w+)%(")
            if name then state_names[n] = name end
        end
        f:close()
    end
end
local function state_name(fn)
    if type(fn) ~= "function" then return tostring(fn) end
    local info = debug.getinfo(fn, "S")
    return state_names[info.linedefined] or ("fn@" .. tostring(info.linedefined))
end

local function contacts_dump()
    local gd = input.gesture_detector
    local lines = {}
    for slot, c in pairs(gd.active_contacts) do
        local it, ct = c.initial_tev, c.current_tev
        lines[#lines + 1] = string.format(
            "    slot %d: id=%s state=%s down=%s initial_tev=%s cur=%s buddy=%s",
            slot, tostring(c.id), state_name(c.state), tostring(c.down),
            it and string.format("{id=%s x=%s y=%s}", tostring(it.id), tostring(it.x), tostring(it.y)) or "NIL",
            ct and string.format("{id=%s x=%s y=%s}", tostring(ct.id), tostring(ct.x), tostring(ct.y)) or "NIL",
            c.buddy_contact and tostring(c.buddy_contact.slot) or "-")
    end
    lines[#lines + 1] = "    ev_slots:"
    for slot, s in pairs(input.ev_slots) do
        lines[#lines + 1] = string.format("      [%d] id=%s x=%s y=%s tool=%s", slot,
            tostring(s.id), tostring(s.x), tostring(s.y), tostring(s.tool))
    end
    lines[#lines + 1] = string.format("    contact_count=%d cur_slot=%s", gd.contact_count, tostring(input.cur_slot))
    return table.concat(lines, "\n")
end

local frames = {}     -- frame index -> { t = seconds, evs = { strings } , fed = { slot summaries } }
local function frame_str(n)
    local fr = frames[n]
    if not fr then return string.format("  f%d: (none)", n) end
    return string.format("  f%-6d t=%+9.3fs  %s  => fed %s", n, fr.t, table.concat(fr.evs, " "), fr.fed)
end

------------------------------------------------------------------------
-- Replay.
------------------------------------------------------------------------
local gestures_seen = {}
local cur = { evs = {}, t = 0 }
local warned_before = 0
local crashed = false

local function dispatch(ev)
    if ev.type == EV_KEY then return input:handleKeyBoardEv(ev)
    elseif ev.type == EV_ABS or ev.type == EV_SYN then return input:handleTouchEv(ev) end
end

for _, raw in ipairs(events) do
    local ev = { type = raw.type, code = raw.code, value = raw.value, src = raw.src,
                 time = { sec = raw.sec, usec = raw.usec } }
    adjust(ev)
    cur.evs[#cur.evs + 1] = ev_str(ev)
    cur.t = raw.sec + raw.usec / 1e6 - t0
    local is_syn = ev.type == EV_SYN and ev.code == SYN_REPORT
    if is_syn then
        current_frame = current_frame + 1
        -- What the detector will be fed: the slots present in this frame.
        local fed = {}
        for _, s in ipairs(input.MTSlots) do
            fed[#fed + 1] = string.format("[%d id=%s x=%s y=%s]", s.slot, tostring(s.id), tostring(s.x), tostring(s.y))
        end
        cur.fed = #fed > 0 and table.concat(fed, "") or "(nothing)"
        frames[current_frame] = cur
        if all_frames then print(frame_str(current_frame)) end
    end
    local ok, res = pcall(dispatch, ev)
    if not ok then
        crashed = true
        print(string.format("\nCRASH at frame %d (t=%+.3fs): %s", current_frame, cur.t, tostring(res)))
        print("frames leading up to it:")
        for n = math.max(1, current_frame - context), current_frame do print(frame_str(n)) end
        print("detector state at the crash:")
        print(contacts_dump())
        break
    elseif type(res) == "table" then
        for _, event in ipairs(res) do
            local g = event.args and event.args[1]
            if g then gestures_seen[#gestures_seen + 1] = string.format("f%d %s", current_frame, tostring(g.ges)) end
        end
    end
    if is_syn then
        if #warnings > warned_before then
            for i = warned_before + 1, #warnings do
                print(string.format("\nWARN at frame %d (t=%+.3fs): %s", warnings[i].frame, cur.t, warnings[i].text))
            end
            print("frames leading up to it:")
            for n = math.max(1, current_frame - context), current_frame do print(frame_str(n)) end
            print("detector state after the frame:")
            print(contacts_dump())
            warned_before = #warnings
        end
        cur = { evs = {}, t = cur.t }
    end
end

print(string.format("\nreplayed %d events / %d frames over %.1fs; %d warnings; %s",
    #events, current_frame, frames[current_frame] and frames[current_frame].t or 0, #warnings,
    crashed and "CRASHED" or "no crash"))
print("gestures: " .. (#gestures_seen > 0 and table.concat(gestures_seen, ", ") or "(none)"))
os.exit(crashed and 1 or 0)
