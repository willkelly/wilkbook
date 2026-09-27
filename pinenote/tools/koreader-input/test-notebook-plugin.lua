--[[--
Host harness for the notebook's KOReader shell (notebook.koplugin
main.lua): the real main.lua, controller, journal, panel, brush and
surface modules, the bundle's real Blitbuffer, InputContainer,
FrameContainer, TextWidget and fonts, and device.lua's own seam
(its consumer hook, pen scaling and rotation hold), driven headless.

What is faked, and how:

  * Device: a Screen whose bb is a real RGB16 1872x1404 Blitbuffer at
    rotation 3 (the seeded portrait mode), an input object with
    device.lua's adjust-hook chain (pen scaling, then consumerHook) and
    its gyro handler installed, resetState and the mixedrouter
    getTouchSlot/setTouchSlot pair recorded, input_devices, a counting
    publishNow and a hint owner that records arm, disarm and reset, with
    device.lua's guard reduced to its effect here (any refresh while
    armed disarms: the armed canvas covers the whole panel);
  * UIManager: a window stack with KOReader's toast/modal ordering, a
    recorded setDirty, scheduleIn/nextTick on a fake monotonic clock
    run by fire_due(), sendEvent/broadcastEvent, and paint(), which
    paints the top full-screen window the way _repaint does.  repaint()
    also keeps _refresh's queue (touching regions combine) and runs it
    after painting the dirty windows, each refresh behind the hint
    owner's guard as device.lua's refresh*Imp has it, tracing "paint
    <name>" and "refresh:<mode>"; audit() watches the
    framebuffer through a paint: after every page and panel blit and at
    every refresh.  It paints only when a test asks, where KOReader
    repaints after every input batch;
  * ui/time: the real module with realtime and monotonic replaced by
    fake clocks the test advances, so every stamp is reproducible;
  * the evdev queries (keystate, absinfo), InfoMessage, Menu and
    PluginLoader: recorders; the idle washer: a recorder of chargePageTurn
    and chargeDebt, except in the last section, which runs the working
    tree's real idlewasher.koplugin at its shipped defaults;
  * the fs: in memory, with the /data mount the store insists on, and
    per-op fault injection.

Scenario (each step asserts what doc/notebook.md and the command contract
in nb_controller.lua's header require):
module load (sentinel, hint reset), the Tools menu, New notebook; a pen
stroke (consumed, arm before the first publish, ink in the page and the
framebuffer, raw digitizer values and event times in the record, the
per-pen-up log line, the synthetic InputEvent on nextTick); lift and
proximity-out (append, then fsync); a swipe (page turn, render, 'ui'
dirty, washer charge) and back; a 2-finger undo and redo (one unit of
the washer's ghost debt each); a long press (fire_due) opening the
panel, which paints with inverted checked items; a tap on a brush
(prefs saved); a flick closing the panel (one unit); the
panel's repaints audited (open, a selection change by finger and by
pen, a drag step, Close, a flick, a change under a toast: one refresh,
no pixel through a value it does not keep); a foreign
widget on top (touch passed through only after every finger lifts, with
resetState and setTouchSlot; the pen still consumed but not inking);
suspend and resume; rotation held under the pen and replayed, and
forwarded to the view; New and the open list from the panel; a failed
append (io_error: the stroke rendered away, no ink after); closing from
the panel (consumer, hold and plane released, resetState and the
kernel's slot handed back); reopening the last notebook.  Then the
touch handoff through KOReader's real Input:waitEvent, mixedrouter and
slotguard (two-finger taps, which a stale slot corrupts); a pen
SYN_DROPPED (gap=1, resync_pen); a failed fsync; New after io_error; a
page that cannot be read; a rotation with the panel open; the poweroff
Close broadcast; opens the store refuses; and errors in the long-press
timer, Suspend and a rotation, contained as the hook's are.  Then the
panel's Refresh by finger and by pen (the page painted and published
where the panel was, no wash while the pen is in range, then one wash
after the settle wait that repaints no window), after a slow publish
with a timer that fires early (the wait counts from the publish's end),
under a toast (a window repaint instead of the in-place paint), and
right before suspend (dropped); and a session under the real idle
washer (erases, an undo and panel closes charged at the pen's leave or
the touch's end, a minute of writing with no wash, a stroke held across
the washer's deadline with no wash under the nib, then after 45 s of
quiet one idle wash that repaints the notebook whole, the guard dropping
the DU arm first).

NOT covered here: the real UIManager (notebook-realui/ runs it), the
real InfoMessage and Menu widgets, and the device's ioctls.

Usage: luajit test-notebook-plugin.lua <koreader_dir> <plugin_dir> <device.lua> \
           [idlewasher_dir (default: <plugin_dir>/../idlewasher.koplugin)]
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to notebook.koplugin")
local device_lua = assert(arg[3], "arg3: path to pinenote device.lua")

package.path = table.concat({
    plugin_dir .. "/?.lua",
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
package.cpath = koreader_dir .. "/?.so;" .. koreader_dir .. "/common/?.so;"
                .. package.cpath

local format, concat = string.format, table.concat
local floor = math.floor

local fail = 0
local function report(ok, label, msg)
    if msg and msg ~= "" then
        print(format("%s: %s: %s", ok and "PASS" or "FAIL", label, msg))
    else
        print(format("%s: %s", ok and "PASS" or "FAIL", label))
    end
    if not ok then fail = fail + 1 end
end

-- ffi/loadlib logs through print while it loads.
local real_print = print
print = function() end
require("ffi/loadlib")
local BB = require("ffi/blitbuffer")
print = real_print

------------------------------------------------------------------------
-- Stubs for the modules KOReader would have set up
------------------------------------------------------------------------

local noop = function() end
local log_lines = {}
local function log_capture(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    log_lines[#log_lines + 1] = concat(parts, " ")
end
package.preload["logger"] = function()
    return setmetatable({
        dbg = noop, info = log_capture, warn = log_capture, err = log_capture,
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
    return setmetatable({
        ngettext = function(s, p, n) return n == 1 and s or p end,
        pgettext = function(_, s) return s end,
    }, { __call = function(_, s) return s end })
end
package.preload["ffi/framebuffer"] = function()
    return {
        DEVICE_ROTATED_UPRIGHT = 0, DEVICE_ROTATED_CLOCKWISE = 1,
        DEVICE_ROTATED_UPSIDE_DOWN = 2, DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
    }
end
package.preload["ffi/archiver"] = function() return {} end
-- fontlist asks the canvas context about system fonts.
package.preload["document/canvascontext"] = function()
    local no = function() return false end
    return { isKindle = no, hasSystemFonts = no, isAndroid = no,
             isDesktop = no, isEmulator = no, isPocketBook = no }
end
G_reader_settings = {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    isFalse = function() return false end,
    nilOrTrue = function() return true end,
    has = function() return false end,
}

-- The fake clocks: realtime microseconds (event stamps, the controller)
-- and monotonic seconds (UIManager's scheduler).  advance() moves both.
local rt_us = 1790000000 * 1000000
local mono_s = 1000
local time = dofile(koreader_dir .. "/frontend/ui/time.lua")
time.realtime = function() return rt_us end
time.monotonic = function() return floor(mono_s * 1e6) end
package.loaded["ui/time"] = time
local function advance_ms(ms)
    rt_us = rt_us + floor(ms * 1000)
    mono_s = mono_s + ms / 1000
end

-- device.lua, for its exported seam: loaded before the fake device.
local PineNote = dofile(device_lua)
local Event = require("ui/event")

------------------------------------------------------------------------
-- The fake device
------------------------------------------------------------------------

local W, H = 1872, 1404
-- Half the w9013's ranges: a glue that replayed or inked with nb_config's
-- defaults instead of the live EVIOCGABS ranges would put ink at twice
-- the distance.
local XMAX, YMAX, PMAX = 10483, 7862, 4095
local PEN, TOUCH, PENBTN = "/dev/input/event3", "/dev/input/event6", "/dev/input/event9"
local GSENSOR, POWER = "/dev/input/event11", "/dev/input/event12"

-- An ordered record of every device-side effect whose order matters.
local trace = {}
local function tr(s) trace[#trace + 1] = s end
local function trace_from(i)
    local out = {}
    for k = i, #trace do out[#out + 1] = trace[k] end
    return concat(out, " ")
end

local Screen = {}
Screen.bb = BB.new(W, H, BB.TYPE_BBRGB16)
Screen.bb:fill(BB.COLOR_WHITE)
Screen.bb:setRotation(3)
function Screen:getWidth() return self.bb:getWidth() end
function Screen:getHeight() return self.bb:getHeight() end
function Screen:getDPI() return 227 end
function Screen:scaleBySize(px) return math.ceil(px * 2.34) end
function Screen:scaleByDPI(dp) return math.ceil(dp * 227 / 160) end
function Screen:getRotationMode() return (4 - self.bb:getRotation()) % 4 end
function Screen:setRotationMode(m) self.bb:setRotation((4 - m) % 4) end
function Screen:isColorEnabled() return false end

local hint = { armed = false, arms = 0, disarms = 0, resets = 0 }
function hint:arm(rects)
    self.arms = self.arms + 1
    self.armed = true
    self.rects = rects
    tr("arm")
    return true
end
function hint:disarm()
    self.disarms = self.disarms + 1
    self.armed = false
    tr("disarm")
    return true
end
function hint:reset()
    self.resets = self.resets + 1
    self.armed = false
    tr("reset")
    return true
end
function hint:is_armed() return self.armed end
-- device.lua's guard, which every refresh*Imp runs before it publishes or
-- washes: the armed canvas rect (0x00) covers the whole panel, so any
-- refresh while armed disarms.
function hint:guard()
    if not self.armed then return false end
    self:disarm()
    return true
end

local router_slot = 0
local input = { gesture_detector = { contact_count = 0 } }
input.eventAdjustHook = function() end
function input:registerEventAdjustHook(hook, params)
    local old = self.eventAdjustHook
    self.eventAdjustHook = function(this, ev)
        old(this, ev)
        hook(this, ev, params)
    end
end
function input:resetState() tr("resetState") end
input.getTouchSlot = function() return router_slot end
input.setTouchSlot = function(_, slot)
    router_slot = slot
    tr("setTouchSlot " .. slot)
end
-- Input's own handler: a gyro event nothing holds becomes the rotation
-- event Input would dispatch (gyro() below dispatches it).
input.handleMiscEv = function(_, ev)
    if ev.wilkbook_gsensor then return Event:new("SetRotationMode", ev.value) end
end
input.handleTouchEv = function() return nil end
input.handleGyroEv = function(_, ev) return Event:new("SetRotationMode", ev.value) end
-- device.lua's init order: its gyro handler, the pen scaling hook, then
-- the consumer hook last.
PineNote._installGyroHandler(input)
input:registerEventAdjustHook(function(_, ev)
    if ev.src == PEN then PineNote._adjustPenEvent(ev, W / XMAX, H / YMAX, W, H) end
end)
input:registerEventAdjustHook(PineNote._consumerHook)

local Device = {
    screen = Screen, input = input, hint_owner = hint,
    input_devices = { pen = PEN, touch = TOUCH, penbtn = PENBTN,
                      gsensor = GSENSOR, power_control = POWER },
    publishes = 0,
}
function Device:publishNow()
    self.publishes = self.publishes + 1
    tr("publish")
    return not self.fail_publish
end
function Device:isPineNote() return true end
package.preload["device"] = function() return Device end

-- The evdev queries: the pen's keys and axes, the kernel's touch slot.
local pen_keys = {}
local kernel_slot = 0
package.preload["ffi/input_evdev"] = function()
    return {
        keystate = function(path, codes)
            if path ~= PEN then return nil end
            local out = {}
            for _, c in ipairs(codes) do out[c] = pen_keys[c] == true end
            return out
        end,
        absinfo = function(path, code)
            if path == PEN then
                if code == 0 then return 0, XMAX, 0 end
                if code == 1 then return 0, YMAX, 0 end
                if code == 24 then return 0, PMAX, 0 end
            elseif path == TOUCH and code == 47 then
                return 0, 31, kernel_slot
            end
            return nil
        end,
    }
end

------------------------------------------------------------------------
-- The recording UIManager
------------------------------------------------------------------------

local HookContainer = require("ui/hook_container")
local UIManager = {
    _window_stack = {}, event_hook = HookContainer:new(), scheduled = {},
    dirty = {},
    -- KOReader's paint and refresh state, for repaint(): the windows
    -- marked dirty, the refreshes queued, and every refresh executed.
    dirty_w = {}, refresh_q = {}, refreshes = {},
}
function UIManager:show(w, refreshtype, region)
    local stack = self._window_stack
    for i = #stack, 0, -1 do
        local top = stack[i]
        if top and top.widget.toast then
            if w.toast then
                table.insert(stack, i + 1, { widget = w })
                break
            end
        elseif w.modal or not top or not top.widget.modal then
            table.insert(stack, i + 1, { widget = w })
            break
        end
    end
    self:setDirty(w, refreshtype, region)
    w:handleEvent(Event:new("Show"))
end
function UIManager:close(w, refreshtype, region)
    w:handleEvent(Event:new("FlushSettings"))
    w:handleEvent(Event:new("CloseWidget"))
    local stack = self._window_stack
    for i = #stack, 1, -1 do
        if stack[i].widget == w then table.remove(stack, i) end
    end
    -- What is left uncovered repaints, as UIManager:close has it do.
    for i = #stack, 1, -1 do
        self.dirty_w[stack[i].widget] = true
        if stack[i].widget.covers_fullscreen then break end
    end
    self:setDirty(nil, refreshtype, region)
end
function UIManager:setDirty(w, refreshtype, region)
    self.dirty[#self.dirty + 1] = { w = w, mode = refreshtype, region = region }
    if w == "all" then
        for _, win in ipairs(self._window_stack) do self.dirty_w[win.widget] = true end
    elseif w then
        self.dirty_w[w] = true
    end
    if type(refreshtype) == "string" then self:_enqueue(refreshtype, region) end
end
-- uimanager.lua _refresh's queue: a region that intersects a queued one,
-- or shares an edge with it (Geom:openIntersectWith), is combined with
-- it into their bounding box; nil is the whole screen.
function UIManager:_enqueue(mode, region)
    local r = region and { x = region.x, y = region.y, w = region.w, h = region.h }
              or { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    for i, q in ipairs(self.refresh_q) do
        local a, b = q.region, r
        if a.w * a.h > 0 and b.w * b.h > 0 and not (a.x > b.x + b.w or a.y > b.y + b.h
           or b.x > a.x + a.w or b.y > a.y + a.h) then
            table.remove(self.refresh_q, i)
            local x0, y0 = math.min(a.x, b.x), math.min(a.y, b.y)
            local x1 = math.max(a.x + a.w, b.x + b.w)
            local y1 = math.max(a.y + a.h, b.y + b.h)
            return self:_enqueue(mode, { x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
        end
    end
    self.refresh_q[#self.refresh_q + 1] = { mode = mode, region = r }
end
-- _repaint's shape: from the top full-screen window up, a dirty window and
-- every window above it paint; then the queued refreshes run, each
-- recorded with the framebuffer as it stood (when an audit watches).
function UIManager:repaint()
    local stack, from = self._window_stack, 1
    for i = #stack, 1, -1 do
        if stack[i].widget.covers_fullscreen then
            from = i
            break
        end
    end
    local painted = false
    for i = from, #stack do
        local w = stack[i].widget
        if painted or self.dirty_w[w] then
            if w.paintTo then
                tr("paint " .. tostring(w.name))
                w:paintTo(Screen.bb, 0, 0)
            end
            painted = true
        end
    end
    self.dirty_w = {}
    if painted and #self.refresh_q == 0 then self:_enqueue("partial") end
    for _, q in ipairs(self.refresh_q) do
        -- device.lua's refresh*Imp: the guard, then the refresh.
        Device.hint_owner:guard()
        tr("refresh:" .. q.mode)
        self.refreshes[#self.refreshes + 1] = {
            mode = q.mode, region = q.region, fb = self.watch and self.watch(),
        }
        if q.mode == "full" and Device.wilkbook_full_refresh_done and not self.no_ack then
            Device.wilkbook_full_refresh_done(self.full_result ~= false)
        end
    end
    self.refresh_q = {}
end
-- Run fn under watch, then repaint: the framebuffer's memory is kept
-- before fn, after every page and panel blit, at every refresh, and at
-- the end.  For each kept state, third counts the pixels that hold
-- neither their value before nor their value at the end: a deferred-io
-- flush that copied that state would move them away and back again.  A
-- refresh also has off, the pixels that differ from the end.  box is the
-- physical bounding box of the pixels that changed.
function UIManager:audit(fn)
    local ffi = require("ffi")
    -- The module table main.lua calls through, so the wrappers see its
    -- blits.
    local Surface = require("nb_surface")
    local bb = Screen.bb
    local size = tonumber(bb.stride) * bb.h
    local function mem() return ffi.string(bb.data, size) end
    self:repaint()
    local a = { stages = {}, d0 = #self.dirty, r0 = #self.refreshes }
    local before = mem()
    local blit_page, blit_panel = Surface.blit_page, Surface.blit_panel
    Surface.blit_page = function(...)
        blit_page(...)
        a.stages[#a.stages + 1] = { what = "page", fb = mem() }
    end
    Surface.blit_panel = function(...)
        blit_panel(...)
        a.stages[#a.stages + 1] = { what = "panel", fb = mem() }
    end
    self.watch = mem
    local ok, err = pcall(fn)
    self:repaint()
    Surface.blit_page, Surface.blit_panel = blit_page, blit_panel
    self.watch = nil
    if not ok then error(err, 0) end
    local final = mem()
    local U16 = ffi.typeof("const uint16_t *")
    local pb, pf = ffi.cast(U16, before), ffi.cast(U16, final)
    local row = tonumber(bb.stride) / 2
    local function third(state)
        local ps, n = ffi.cast(U16, state), 0
        for i = 0, row * bb.h - 1 do
            local v = ps[i]
            if v ~= pf[i] and v ~= pb[i] then n = n + 1 end
        end
        return n
    end
    a.refreshes = {}
    local function off(state)
        local ps, n = ffi.cast(U16, state), 0
        for i = 0, row * bb.h - 1 do
            if ps[i] ~= pf[i] then n = n + 1 end
        end
        return n
    end
    for k = a.r0 + 1, #self.refreshes do
        local r = self.refreshes[k]
        a.refreshes[#a.refreshes + 1] = r
        r.third, r.off, r.fb = third(r.fb), off(r.fb), nil
    end
    for _, st in ipairs(a.stages) do st.third, st.fb = third(st.fb), nil end
    local x0, y0, x1, y1
    for y = 0, bb.h - 1 do
        for x = 0, bb.w - 1 do
            if pb[y * row + x] ~= pf[y * row + x] then
                x0, x1 = math.min(x0 or x, x), math.max(x1 or x, x)
                y0, y1 = y0 or y, y
            end
        end
    end
    a.box = x0 and { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
    a.before, a.final = nil, nil
    return a
end
function UIManager:scheduleIn(s, fn)
    self.scheduled[#self.scheduled + 1] = { when = mono_s + s, fn = fn }
end
function UIManager:nextTick(fn) self:scheduleIn(0, fn) end
function UIManager:unschedule(fn)
    for i = #self.scheduled, 1, -1 do
        if self.scheduled[i].fn == fn then table.remove(self.scheduled, i) end
    end
end
function UIManager:getElapsedTimeSinceBoot() return floor(mono_s * 1e6) end
-- Run every task due now, including those the tasks schedule for now.
function UIManager:fire_due()
    for _ = 1, 100 do
        local due
        for i, t in ipairs(self.scheduled) do
            if t.when <= mono_s then
                due = table.remove(self.scheduled, i)
                break
            end
        end
        if not due then return end
        due.fn()
    end
    error("fire_due: tasks keep scheduling themselves")
end
function UIManager:topdown_widgets_iter()
    local stack, i = self._window_stack, #self._window_stack + 1
    return function()
        i = i - 1
        if i > 0 then return stack[i].widget end
    end
end
function UIManager:isWidgetShown(w)
    for _, win in ipairs(self._window_stack) do
        if win.widget == w then return true end
    end
    return false
end
function UIManager:sendEvent(ev)
    for i = #self._window_stack, 1, -1 do
        local w = self._window_stack[i].widget
        if not w.toast then return w:handleEvent(ev) end
    end
end
function UIManager:broadcastEvent(ev)
    for i = #self._window_stack, 1, -1 do
        self._window_stack[i].widget:handleEvent(ev)
    end
end
-- _repaint's shape: the topmost full-screen window, and what is above it.
function UIManager:paint()
    local stack, from = self._window_stack, 1
    for i = #stack, 1, -1 do
        if stack[i].widget.covers_fullscreen then
            from = i
            break
        end
    end
    for i = from, #stack do
        local w = stack[i].widget
        if w.paintTo then w:paintTo(Screen.bb, 0, 0) end
    end
end
function UIManager:dirty_since(i, w, mode)
    local out = {}
    for k = i + 1, #self.dirty do
        local d = self.dirty[k]
        if d.w == w and d.mode == mode then out[#out + 1] = d end
    end
    return out
end
package.preload["ui/uimanager"] = function() return UIManager end

-- Dialog stand-ins: they only need to sit on the stack.
local shown_messages = {}
package.preload["ui/widget/infomessage"] = function()
    local IM = {}
    function IM:new(o)
        o.modal = true
        o.handleEvent = noop
        shown_messages[#shown_messages + 1] = o
        return o
    end
    return IM
end
local menus = {}
package.preload["ui/widget/menu"] = function()
    local M = {}
    function M:new(o)
        o.handleEvent = noop
        menus[#menus + 1] = o
        return o
    end
    return M
end
local washer = { charges = 0, debt = 0 }
function washer:chargePageTurn() self.charges = self.charges + 1 end
function washer:chargeDebt(n) self.debt = self.debt + n end
package.preload["pluginloader"] = function()
    return {
        getPluginInstance = function(_, name)
            if name == "idlewasher" and not washer.absent then return washer end
        end,
    }
end

require("fontlist").fontdir = koreader_dir .. "/fonts"

------------------------------------------------------------------------
-- The in-memory fs, on a /data the store accepts
------------------------------------------------------------------------

local function MemFS()
    local nodes = { ["/"] = { dir = true } }
    local fs = { calls = {}, faults = {} }
    local function parent(p)
        local d = p:match("^(.*)/[^/]*$")
        if d == nil or d == "" then return "/" end
        return d
    end
    local function dirp(p)
        local d = nodes[parent(p)]
        return d and d.dir
    end
    local function hit(op, path)
        fs.calls[op] = (fs.calls[op] or 0) + 1
        local key = op .. " " .. path
        fs.calls[key] = (fs.calls[key] or 0) + 1
        local f = fs.faults[op]
        if f and (f.path == nil or f.path == path) then return f.err end
    end
    function fs.mkdir_excl(path)
        local e = hit("mkdir_excl", path)
        if e then return nil, e end
        if nodes[path] then return nil, "EEXIST" end
        if not dirp(path) then return nil, "ENOENT" end
        nodes[path] = { dir = true }
        return true
    end
    function fs.listdir(path)
        local e = hit("listdir", path)
        if e then return nil, e end
        if not (nodes[path] and nodes[path].dir) then return nil, "ENOENT" end
        local names = {}
        for p in pairs(nodes) do
            if p ~= "/" and parent(p) == path then
                names[#names + 1] = p:match("[^/]*$")
            end
        end
        table.sort(names)
        return names
    end
    function fs.read(path)
        local e = hit("read", path)
        if e then return nil, e end
        local n = nodes[path]
        if not n then return nil, "ENOENT" end
        if n.dir then return nil, "EISDIR" end
        return n.data
    end
    function fs.append(path, s)
        local e = hit("append", path)
        if e then return nil, e end
        if not dirp(path) then return nil, "ENOENT" end
        local n = nodes[path]
        if not n then
            n = { data = "" }
            nodes[path] = n
        end
        n.data = n.data .. s
        return true
    end
    function fs.truncate(path, len)
        local e = hit("truncate", path)
        if e then return nil, e end
        local n = nodes[path]
        if not n or n.dir then return nil, "ENOENT" end
        n.data = n.data:sub(1, len)
        return true
    end
    function fs.fsync(path)
        local e = hit("fsync", path)
        if e then return nil, e end
        if not nodes[path] then return nil, "ENOENT" end
        return true
    end
    function fs.fsync_dir(path)
        local e = hit("fsync_dir", path)
        if e then return nil, e end
        if not (nodes[path] and nodes[path].dir) then return nil, "ENOENT" end
        return true
    end
    function fs.write_atomic(path, s)
        local e = hit("write_atomic", path)
        if e then return nil, e end
        if not dirp(path) then return nil, "ENOENT" end
        nodes[path] = { data = s }
        return true
    end
    function fs.exists(path) return nodes[path] ~= nil end
    function fs.unlink(path)
        local e = hit("unlink", path)
        if e then return nil, e end
        local n = nodes[path]
        if not n or n.dir then return nil, "ENOENT" end
        nodes[path] = nil
        return true
    end
    function fs.put(path, data)
        nodes[path] = { data = data }
    end
    function fs.get(path) return nodes[path] and nodes[path].data end
    function fs.mkdir(path) nodes[path] = { dir = true } end
    return fs
end

local memfs = MemFS()
memfs.mkdir("/proc")
memfs.mkdir("/proc/self")
memfs.put("/proc/self/mountinfo", table.concat({
    "22 1 179:6 / / rw,relatime shared:1 - ext4 /dev/mmcblk0p6 rw",
    "30 22 179:7 / /data rw,relatime shared:2 - ext4 /dev/mmcblk0p7 rw",
    "",
}, "\n"))
memfs.mkdir("/data")

------------------------------------------------------------------------
-- Load the plugin
------------------------------------------------------------------------

local G = require("nb_geom")
local J = require("nb_journal")
local Surface = require("nb_surface")

local NB = dofile(plugin_dir .. "/main.lua")
report(type(NB) == "table" and NB.name == "notebook" and NB.is_doc_only == false,
       "main.lua loads as the notebook plugin class", tostring(NB.name))
report(hint.resets == 1, "module load resets the hint plane once",
       "resets=" .. hint.resets)
local again = dofile(plugin_dir .. "/main.lua")
report(type(again) == "table" and again.disabled == true and hint.resets == 1,
       "a second copy disables itself and resets nothing", "")
local meta = dofile(plugin_dir .. "/_meta.lua")
report(meta.name == "notebook" and meta.fullname == "Notebook",
       "_meta.lua names the plugin as main.lua does", meta.name)

local id_seq = 0
NB.fs = memfs
NB.rand = function()
    id_seq = id_seq + 0x10
    return id_seq
end

local view_modes = {}
local ui_registered
local ui = {
    menu = { registerToMainMenu = function(_, p) ui_registered = p end },
    view = {
        onSetRotationMode = function(_, m)
            view_modes[#view_modes + 1] = m
            Screen:setRotationMode(m)
        end,
    },
}
local plugin = NB:new{ ui = ui }
report(ui_registered == plugin, "init registers the plugin in the main menu", "")
local menu_items = {}
plugin:addToMainMenu(menu_items)
local entry = menu_items.notebook
local subs = {}
for i, it in ipairs(entry and entry.sub_item_table or {}) do subs[i] = it.text end
report(entry and entry.text == "Notebook" and entry.sorting_hint == "tools"
       and concat(subs, "|") == "Open last notebook|New notebook|Open notebook…",
       "menu: Notebook under Tools with Open last / New / Open…",
       concat(subs, "|"))

-- Consumed-event log on the InputEvent hook.
local input_events = 0
UIManager.event_hook:registerWidget("InputEvent",
    { onInputEvent = function() input_events = input_events + 1 end })

------------------------------------------------------------------------
-- Event helpers
------------------------------------------------------------------------

local function tv()
    return { sec = floor(rt_us / 1e6), usec = rt_us % 1000000 }
end
local function send(src, ty, code, value)
    local ev = { src = src, type = ty, code = code, value = value, time = tv() }
    input:eventAdjustHook(ev)
    return ev
end
-- One report: every event consumed?  Advances 2.77 ms (360 Hz).
local function report_events(src, list, step_ms)
    local all = true
    for _, e in ipairs(list) do
        if send(src, e[1], e[2], e[3]).type ~= 4 then all = false end
    end
    if send(src, 0, 0, 0).type ~= 4 then all = false end
    advance_ms(step_ms or 2.77)
    return all
end
local function RX(px) return floor(px * XMAX / (W - 1) + 0.5) end
local function RY(py) return floor(py * YMAX / (H - 1) + 0.5) end
local function pen(list) return report_events(PEN, list) end
local function pen_enter(x, y, rubber)
    return pen{ { 1, rubber and 321 or 320, 1 }, { 3, 0, RX(x) }, { 3, 1, RY(y) } }
end
-- dr offsets the raw values off the px grid, where px alone cannot
-- recover them.
local function pen_down(x, y, dr)
    dr = dr or 0
    return pen{ { 1, 330, 1 }, { 3, 0, RX(x) + dr }, { 3, 1, RY(y) + dr },
                { 3, 24, 2500 } }
end
local function pen_move(x, y) return pen{ { 3, 0, RX(x) }, { 3, 1, RY(y) } } end
local function pen_up() return pen{ { 1, 330, 0 }, { 3, 24, 0 } } end
-- The report that takes the pen out of range; the leave waits for it.
local function pen_out(rubber) return pen{ { 1, rubber and 321 or 320, 0 } } end
local function frame(list) return report_events(TOUCH, list, 10) end

-- Physical pixels: the page buffer, and the screen through a rotation-0
-- alias of its memory.
local fb_view = Surface.fb_alias(Screen.bb)
local function win()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w.name == "notebook_window" then return w end
    end
end
local function page_px(x, y) return win().page_bb:getPixel(x, y):getColor8().a end

-- The window's timer task alone, when it is due: not everything due, so
-- a test still sees what waits for nextTick.
local function run_timer()
    local w = win()
    if not w then return end
    for i, t in ipairs(UIManager.scheduled) do
        if t.fn == w._timer_task and t.when <= mono_s then
            table.remove(UIManager.scheduled, i)
            return t.fn()
        end
    end
end
-- Out of range for good: the report, then prox_leave_us later the
-- window's timer, which runs the leave.
local LEAVE_MS = dofile(plugin_dir .. "/nb_config.lua").prox_leave_us / 1000 + 1
local function pen_leave(rubber)
    local all = pen_out(rubber)
    advance_ms(LEAVE_MS)
    run_timer()
    return all
end
local function fb_px(x, y) return fb_view:getPixel(x, y):getColor8().a end

-- Touch gestures in physical px.  The slot is whatever the kernel's
-- current one is, as a single finger reports it.
local tracking = 100
local function swipe(x0, y0, x1, y1)
    tracking = tracking + 1
    local all = frame{ { 3, 57, tracking }, { 3, 53, x0 }, { 3, 54, y0 } }
    for k = 1, 4 do
        local x = floor(x0 + (x1 - x0) * k / 4 + 0.5)
        local y = floor(y0 + (y1 - y0) * k / 4 + 0.5)
        all = frame{ { 3, 53, x }, { 3, 54, y } } and all
    end
    return frame{ { 3, 57, -1 } } and all
end
local function tap(x, y)
    tracking = tracking + 1
    local all = frame{ { 3, 57, tracking }, { 3, 53, x }, { 3, 54, y } }
    advance_ms(40)
    return frame{ { 3, 57, -1 } } and all
end
-- Two fingers in slots 0..1 moving together, then lifting: the most the
-- cyttsp5 reports at once (nb_config's multi_min_fingers).
local function swipe2(dx, dy)
    local xs, ys = { 700, 900 }, { 600, 600 }
    local ev = {}
    for s = 0, 1 do
        tracking = tracking + 1
        ev[#ev + 1] = { 3, 47, s }
        ev[#ev + 1] = { 3, 57, tracking }
        ev[#ev + 1] = { 3, 53, xs[s + 1] }
        ev[#ev + 1] = { 3, 54, ys[s + 1] }
    end
    frame(ev)
    for k = 1, 4 do
        ev = {}
        for s = 0, 1 do
            ev[#ev + 1] = { 3, 47, s }
            ev[#ev + 1] = { 3, 53, xs[s + 1] + floor(dx * k / 4) }
            ev[#ev + 1] = { 3, 54, ys[s + 1] + floor(dy * k / 4) }
        end
        frame(ev)
    end
    frame{ { 3, 47, 0 }, { 3, 57, -1 }, { 3, 47, 1 }, { 3, 57, -1 } }
end

-- The panel's items, and a logical point as physical px.
local function item(id)
    for _, it in ipairs(win().panel_L and win().panel_L.items or {}) do
        if it.id == id then return it end
    end
end
local function center_phys(it)
    local r = Screen.bb:getRotation()
    local px, py = G.to_physical(r, W, H, floor(it.x + it.w / 2),
                                 floor(it.y + it.h / 2))
    return px, py
end

local function count_lines(s)
    local n = 0
    for _ in (s or ""):gmatch("[^\n]*\n") do n = n + 1 end
    return n
end
local function last_line(s)
    local out
    for l in (s or ""):gmatch("([^\n]*)\n") do out = l end
    return out
end
local function find_log(pat)
    for i = #log_lines, 1, -1 do
        if log_lines[i]:find(pat, 1, true) then return log_lines[i] end
    end
end

------------------------------------------------------------------------
-- 1. New notebook from the menu
------------------------------------------------------------------------

router_slot = 2
local t_open = #trace
entry.sub_item_table[2].callback()
report(win() == nil, "New notebook waits for nextTick (the menu closes first)", "")
UIManager:fire_due()
local w1 = win()
report(w1 ~= nil and w1.covers_fullscreen == true and not w1.modal,
       "the window is shown full-screen and not modal", "")
local nb_id = w1 and w1.session.id
report(nb_id == J.utc_stamp(floor(rt_us / 1e6)) .. "-000010",
       "Store:create made the notebook", tostring(nb_id))
local root = "/data/notebooks/" .. tostring(nb_id)
report((memfs.get(root .. "/notebook.json") or ""):find(
           format('"abs":[%d,%d,%d],"panel":[%d,%d,227]', XMAX, YMAX, PMAX, W, H),
           1, true) ~= nil,
       "notebook.json records the live axis ranges and panel", "")
report(input.wilkbook_consumer ~= nil and input.wilkbook_hold_rotation ~= nil,
       "the consumer and the rotation-hold predicate are set", "")
report(trace_from(t_open + 1) == "resetState reset disarm",
       "open: resetState, hint reset, then the controller's disarm",
       trace_from(t_open + 1))
report((memfs.get("/data/notebooks/prefs.json") or ""):find('"last_id":"'
       .. tostring(nb_id) .. '"', 1, true) ~= nil,
       "open saves prefs with last_id", "")
report(#UIManager:dirty_since(0, w1, "ui") > 0, "open repaints the window 'ui'", "")
report(page_px(600, 500) == 255, "the page buffer starts white", "")
-- Consumer normalization: sources by Device.input_devices only.
local e_pw = send(POWER, 1, 116, 1)
local e_gs = send(GSENSOR, 4, 3, 1)
report(e_pw.type == 1 and e_gs.type == 4 and e_gs.code == 3,
       "power-control and gsensor events pass through untouched", "")
local e_btn = send(PENBTN, 1, 158, 1)
local e_btn_syn = send(PENBTN, 0, 0, 0)
report(e_btn.type == 4 and e_btn_syn.type == 4,
       "the ws8100 pen-button keys are consumed", "")

------------------------------------------------------------------------
-- 2. A pen stroke
------------------------------------------------------------------------

local t_pen = #trace
local pub0 = Device.publishes
report(pen_enter(600, 500), "pen proximity-in: every event consumed (type 4)", "")
report(input.wilkbook_hold_rotation() == true, "the pen in range holds rotation", "")
report(hint.armed and hint.rects and hint.rects[1].hint == 0
       and hint.rects[1].w == W and hint.rects[1].h == H,
       "proximity-in arms the canvas at 0x00", "")
local t_stroke = rt_us
report(pen_down(600, 500, 2), "pen down consumed", "")
pen_move(620, 500)
pen_move(640, 502)
pen_move(660, 504)
local first_arm = trace_from(t_pen + 1):find("arm", 1, true)
local first_pub = trace_from(t_pen + 1):find("publish", 1, true)
report(first_arm and first_pub and first_arm < first_pub,
       "arm precedes the first publish", trace_from(t_pen + 1):sub(1, 40))
report(Device.publishes - pub0 == 4, "one publish per inking report",
       tostring(Device.publishes - pub0))
-- A foreign refresh (a toast, a wash) disarms through device.lua's guard
-- without the controller knowing; the next ink re-arms first.
hint.armed = false
local t_rearm = #trace
pen_move(680, 506)
report(trace_from(t_rearm + 1) == "arm publish",
       "ink re-arms the wanted rects when the owner lost them",
       trace_from(t_rearm + 1))
report(page_px(600, 500) == 0 and page_px(640, 502) == 0,
       "ink in the page buffer at the pen's physical px", "")
report(fb_px(600, 500) == 0 and fb_px(660, 504) == 0,
       "ink in the framebuffer at the same physical px", "")
report(input_events == 0, "no InputEvent inside the hook", "")
UIManager:fire_due()
report(input_events == 1, "one synthetic InputEvent on nextTick", tostring(input_events))

------------------------------------------------------------------------
-- 3. Lift, then proximity-out
------------------------------------------------------------------------

local page0 = root .. "/page-0.jsonl"
pen_up()
report(count_lines(memfs.get(page0)) == 1, "pen-up appends one record", "")
report((memfs.calls["fsync " .. page0] or 0) == 0, "no fsync while the pen is in range", "")
local rec = J.decode(last_line(memfs.get(page0)) or "")
report(rec and rec.d[2] == RX(600) + 2 and rec.d[3] == RY(500) + 2,
       "the record keeps the raw digitizer values (ev.raw_value)",
       rec and (rec.d[2] .. "," .. rec.d[3]) or "undecodable")
report(rec and rec.t0 == t_stroke, "the record's t0 is the event's realtime stamp",
       rec and tostring(rec.t0 - t_stroke) or "")
local pen_up_line = find_log("[notebook] pen-up")
report(pen_up_line ~= nil, "the per-pen-up log line", pen_up_line)
pen_leave()
report((memfs.calls["fsync " .. page0] or 0) == 1, "proximity-out fsyncs the page", "")
report(input.wilkbook_hold_rotation() == false, "proximity-out releases rotation", "")

------------------------------------------------------------------------
-- 4. Swipe to the next page and back
------------------------------------------------------------------------

advance_ms(1000)  -- past palm_grace_us
local d0 = #UIManager.dirty
-- Portrait (bb rotation 3): a logical leftward swipe is physical +y.
report(swipe(900, 300, 900, 700), "the swipe's touch events are consumed", "")
report(w1.c.page_n == 1 and page_px(600, 500) == 255,
       "a leftward swipe turns to page 1 (blank) and renders it", "")
report(#UIManager:dirty_since(d0, w1, "ui") > 0 and washer.charges == 1,
       "the turn repaints 'ui' and charges the washer (PluginLoader)",
       "charges=" .. washer.charges)
local washer2 = { charges = 0, debt = 0, chargePageTurn = washer.chargePageTurn,
                  chargeDebt = washer.chargeDebt }
ui.idlewasher = washer2
swipe(900, 700, 900, 300)
report(w1.c.page_n == 0 and page_px(600, 500) == 0,
       "a rightward swipe turns back to page 0, replayed from the journal", "")
report(washer2.charges == 1 and washer.charges == 1,
       "the host's own idlewasher is preferred", "")

------------------------------------------------------------------------
-- 5. Two-finger undo and redo
------------------------------------------------------------------------

-- KOReader repaints after every input batch; this harness paints only
-- when asked.  The turns' whole-window repaint runs here, as it would have
-- long before the undo (a region repaint waits for one still pending).
UIManager:repaint()
d0 = #UIManager.dirty
swipe2(0, 400)
report(page_px(600, 500) == 255 and count_lines(memfs.get(page0)) == 2,
       "a leftward 2-finger swipe undoes: record appended, stroke gone", "")
-- The region is painted in place, and only a refresh of it is asked for.
local reg = UIManager:dirty_since(d0, nil, "ui")
reg = reg[#reg] and reg[#reg].region
local lx, ly = G.to_logical(3, W, H, 600, 500)
report(reg and reg.x <= lx and lx < reg.x + reg.w and reg.y <= ly
       and ly < reg.y + reg.h and reg.w < 400 and fb_px(600, 500) == 255
       and #UIManager:dirty_since(d0, w1, "ui") == 0,
       "the undo paints a logical region around the stroke and asks for its refresh",
       reg and format("%d,%d %dx%d", reg.x, reg.y, reg.w, reg.h) or "none")
report((memfs.calls["fsync " .. page0] or 0) == 2,
       "an undo with the pen out of range is fsynced", "")
report(washer2.debt == 1 and washer.debt == 0,
       "the undo charged the host's washer one unit of ghost debt (chargeDebt)",
       "debt=" .. washer2.debt)
swipe2(0, -400)
report(page_px(600, 500) == 0 and fb_px(600, 500) == 0
       and count_lines(memfs.get(page0)) == 3,
       "a rightward 2-finger swipe redoes", "")
report(washer2.debt == 2, "and so did the redo", "debt=" .. washer2.debt)

------------------------------------------------------------------------
-- 6. Long press, the panel, a brush, a flick
------------------------------------------------------------------------

d0 = #UIManager.dirty
tracking = tracking + 1
frame{ { 3, 47, 0 }, { 3, 57, tracking }, { 3, 53, 1000 }, { 3, 54, 700 } }
report(w1.panel_L == nil, "no panel before the long-press timer", "")
advance_ms(800)
UIManager:fire_due()
report(w1.panel_L ~= nil and w1.panel_phys ~= nil,
       "a long press (fired by the scheduler) opens the panel", "")
frame{ { 3, 57, -1 } }
local L = w1.panel_L
local pg = UIManager:dirty_since(d0, nil, "ui")
pg = pg[#pg] and pg[#pg].region
report(pg and L and pg.x == math.max(0, L.x) and pg.w <= L.w
       and #UIManager:dirty_since(d0, w1, "ui") == 0,
       "the panel is painted in place and its logical area refreshed 'ui'", "")
local ball, pencil = item("brush:ballpoint"), item("brush:pencil")
local function screen_px(lx0, ly0)
    return Screen.bb:getPixel(lx0, ly0):getColor8().a
end
report(ball and ball.checked and screen_px(ball.x + 6, ball.y + 6) == 0,
       "the checked brush, the default Ballpoint, is painted inverted", "")
UIManager:paint()
report(pencil and not pencil.checked and screen_px(pencil.x + 6, pencil.y + 6) == 255,
       "an unchecked brush has a white face", "")
local undo_it = item("undo")
local dark = 0
if undo_it then
    for yy = undo_it.y, undo_it.y + undo_it.h - 1 do
        for xx = undo_it.x, undo_it.x + undo_it.w - 1 do
            if screen_px(xx, yy) < 128 then dark = dark + 1 end
        end
    end
end
report(undo_it and undo_it.enabled and dark > 50,
       "a label is drawn in its button", "dark px " .. dark)
local redo_it = item("redo")
-- RGB565 keeps 0x88 as 138.
local dim = redo_it and screen_px(redo_it.x + 1, redo_it.y + 1)
report(redo_it and not redo_it.enabled and dim > 64 and dim < 192,
       "a disabled button is dimmed (gray border)", tostring(dim))

-- The pen under the open panel: a stroke from the canvas into the panel.
-- The page gets all of it, the framebuffer keeps the panel, and the arm
-- covers the panel at the plane default.
local lpx, lpy = L.x + 8, L.y + L.h - 8
local ppx, ppy = G.to_physical(3, W, H, lpx, lpy)
do
    local sx, sy = G.to_physical(3, W, H, L.x - 30, lpy)
    local ex, ey = G.to_physical(3, W, H, L.x + 12, lpy)
    pen_enter(sx, sy)
    report(hint.rects and hint.rects[2] and hint.rects[2].hint == 0x20
           and hint.rects[2].x == w1.panel_phys.x and hint.rects[2].w == w1.panel_phys.w,
           "with the panel open the arm adds its rect at 0x20", "")
    pen_down(sx, sy)
    pen_move(ex, ey)
    pen_up()
    pen_leave()
    local bx, by = G.to_physical(3, W, H, L.x - 20, lpy)
    report(page_px(ppx, ppy) == 0 and fb_px(ppx, ppy) == 255 and fb_px(bx, by) == 0,
           "a stroke into the panel: ink beside it, and under it only in the page", "")
    -- A pen contact that starts on the panel is the panel's: nothing inks.
    local lines0 = count_lines(memfs.get(page0))
    local qx, qy = G.to_physical(3, W, H, L.x + 8, L.y + L.h - 40)
    advance_ms(1000)
    pen_enter(qx, qy)
    pen_down(qx, qy)
    pen_move(qx + 30, qy)
    pen_up()
    pen_leave()
    report(page_px(qx + 15, qy) == 255 and count_lines(memfs.get(page0)) == lines0,
           "a pen contact that starts on the panel inks and records nothing", "")
end
advance_ms(1000)
local px, py = center_phys(pencil)
tap(px, py)
report(item("brush:pencil").checked and w1.prefs.brush == "pencil",
       "a tap on Pencil selects it", "")
report((memfs.get("/data/notebooks/prefs.json") or ""):find('"brush":"pencil"', 1, true) ~= nil,
       "the choice is saved to prefs.json", "")

d0 = #UIManager.dirty
-- (A field, not a local: this chunk is at LuaJIT's 200-local limit.)
washer2.before_flick = washer2.debt
local oldL = w1.panel_L
local title = item("title")
px, py = center_phys(title)
tracking = tracking + 1
frame{ { 3, 57, tracking }, { 3, 53, px }, { 3, 54, py } }
-- Fast along logical x (physical -y in portrait), 60 px every 10 ms.
for k = 1, 3 do frame{ { 3, 54, py - 60 * k } } end
frame{ { 3, 57, -1 } }
report(w1.panel_L == nil and w1.panel_phys == nil, "a flick closes the panel", "")
report(washer2.debt == washer2.before_flick + 1,
       "the flick charged one unit (opening and a choice none)",
       "debt=" .. washer2.debt - washer2.before_flick)
local closed = UIManager:dirty_since(d0, nil, "ui")
local covered = false
for _, d in ipairs(closed) do
    if d.region and d.region.x <= math.max(0, oldL.x) and d.region.y <= math.max(0, oldL.y) then
        covered = true
    end
end
report(covered, "the old panel area is repainted", "")

------------------------------------------------------------------------
-- 6b. The panel's repaints (the generation-22 selection flicker)
------------------------------------------------------------------------

-- On glass a selection change made the panel vanish and come back.  The
-- paint blitted the whole page over the panel and drew the panel back
-- piece by piece, and the direct driver shows whatever a deferred-io flush
-- copies, which can be any state in between.  UIManager:audit keeps the
-- framebuffer after every blit and at every refresh: a pixel that holds
-- neither its old nor its new value at any of them is the flicker.  The
-- same holds for open, a drag step, Close and a flick, which may repaint
-- the page under the panel, once.
do
    local function scr(r)
        local x0, y0 = math.max(0, r.x), math.max(0, r.y)
        local x1 = math.min(Screen:getWidth(), r.x + r.w)
        local y1 = math.min(Screen:getHeight(), r.y + r.h)
        return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end
    local function inside(r, box)
        return r.x >= box.x and r.y >= box.y and r.x + r.w <= box.x + box.w
               and r.y + r.h <= box.y + box.h
    end
    local function same(r, box)
        return r.x == box.x and r.y == box.y and r.w == box.w and r.h == box.h
    end
    local function union(a, b)
        local x0, y0 = math.min(a.x, b.x), math.min(a.y, b.y)
        local x1 = math.max(a.x + a.w, b.x + b.w)
        local y1 = math.max(a.y + a.h, b.y + b.h)
        return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end
    local function phys(it)
        local x, y, w, h = G.rect_to_physical(3, W, H, it.x, it.y, it.w, it.h)
        return { x = x, y = y, w = w, h = h }
    end
    local function stages(a, what)
        local n = 0
        for _, st in ipairs(a.stages) do
            if st.what == what then n = n + 1 end
        end
        return n
    end
    -- Whether the audit marked the window itself dirty: a whole-window
    -- paint, rather than a region painted in place.
    local function whole(a)
        for k = a.d0 + 1, #UIManager.dirty do
            if UIManager.dirty[k].w == w1 then return true end
        end
        return false
    end
    local function seen(a)
        local parts = {}
        for _, st in ipairs(a.stages) do
            parts[#parts + 1] = st.what .. " third=" .. st.third
        end
        for _, r in ipairs(a.refreshes) do
            parts[#parts + 1] = format("refresh(%d,%d %dx%d third=%d off=%d)", r.region.x,
                                       r.region.y, r.region.w, r.region.h, r.third, r.off)
        end
        local b = a.box
        parts[#parts + 1] = b and format("changed %d,%d %dx%d", b.x, b.y, b.w, b.h)
                            or "unchanged"
        return concat(parts, "; ")
    end
    -- One refresh, inside region, showing the end state, and no pixel
    -- ever through a third value.
    local function clean(a, region)
        if #a.refreshes ~= 1 then return false end
        local r = a.refreshes[1]
        if r.third ~= 0 or r.off ~= 0 or not inside(r.region, region) then return false end
        for _, st in ipairs(a.stages) do
            if st.third ~= 0 then return false end
        end
        return true
    end
    -- The screen over logical rect r shows the page, on a 7 px grid.
    local function shows_page(r)
        for y = r.y, r.y + r.h - 1, 7 do
            for x = r.x, r.x + r.w - 1, 7 do
                local qx, qy = G.to_physical(3, W, H, x, y)
                if math.abs(screen_px(x, y) - page_px(qx, qy)) > 8 then return false end
            end
        end
        return true
    end
    local function long_press()
        tracking = tracking + 1
        frame{ { 3, 47, 0 }, { 3, 57, tracking }, { 3, 53, 1000 }, { 3, 54, 700 } }
        advance_ms(800)
        UIManager:fire_due()
        frame{ { 3, 57, -1 } }
    end

    advance_ms(1000)
    local a = UIManager:audit(long_press)
    local P = w1.panel_L and scr(w1.panel_L)
    report(P and clean(a, P) and same(a.refreshes[1].region, P)
           and stages(a, "panel") == 1 and stages(a, "page") == 0 and not whole(a),
           "open: one refresh over the panel's rect, one panel blit, no third value",
           seen(a))

    advance_ms(1000)
    local was, now = item("brush:pencil"), item("brush:marker")
    local tx, ty = center_phys(now)
    a = UIManager:audit(function() tap(tx, ty) end)
    report(clean(a, P) and a.box and inside(a.box, union(phys(was), phys(now)))
           and stages(a, "panel") == 1 and stages(a, "page") == 0 and not whole(a)
           and item("brush:marker").checked and screen_px(now.x + 6, now.y + 6) == 0,
           "a selection change: one refresh within the panel, only the two buttons change,"
           .. " no pixel through a third value", seen(a))
    a = UIManager:audit(function() tap(tx, ty) end)
    report(#a.refreshes == 0 and #a.stages == 0 and a.box == nil,
           "a tap on the button already checked paints and refreshes nothing", seen(a))

    -- The pen's tap on the panel repaints the same way.
    advance_ms(1000)
    was, now = item("size:M"), item("size:L")
    tx, ty = center_phys(now)
    a = UIManager:audit(function()
        pen_enter(tx, ty)
        pen_down(tx, ty)
        pen_up()
        pen_leave()
    end)
    report(clean(a, P) and a.box and inside(a.box, union(phys(was), phys(now)))
           and not whole(a) and w1.c:_pref("size") == "L"
           and (memfs.get("/data/notebooks/prefs.json") or ""):find('"size":"L"', 1, true),
           "a pen tap on a size: one refresh within the panel, only the two buttons change,"
           .. " the choice saved at the leave", seen(a))

    -- Two drag steps by the title bar, each audited on its own.
    advance_ms(1000)
    tx, ty = center_phys(item("title"))
    tracking = tracking + 1
    frame{ { 3, 57, tracking }, { 3, 53, tx }, { 3, 54, ty } }
    for step = 1, 2 do
        local old = scr(w1.panel_L)
        a = UIManager:audit(function() frame{ { 3, 54, ty - 40 * step } } end)
        local new = scr(w1.panel_L)
        report(clean(a, union(old, new)) and same(a.refreshes[1].region, union(old, new))
               and not same(old, new) and not whole(a),
               "drag step " .. step .. ": one refresh over the old and new rects,"
               .. " no pixel through a third value", seen(a))
    end
    advance_ms(200) -- the finger stops before it lifts: no flick
    frame{ { 3, 57, -1 } }

    advance_ms(1000)
    P = scr(w1.panel_L)
    tx, ty = center_phys(item("close"))
    a = UIManager:audit(function() tap(tx, ty) end)
    report(w1.panel_L == nil and clean(a, P) and same(a.refreshes[1].region, P)
           and stages(a, "page") == 1 and stages(a, "panel") == 0 and not whole(a)
           and shows_page(P),
           "Close: one refresh over the panel's rect, the page repainted once under it,"
           .. " no third value", seen(a))

    -- Under a toast the region cannot be painted in place: the window
    -- repaints whole, still with no third value and one refresh.
    advance_ms(1000)
    long_press()
    UIManager:repaint()
    P = scr(w1.panel_L)
    local toast = { name = "toast", toast = true, handleEvent = noop }
    UIManager:show(toast)
    was, now = item("brush:marker"), item("brush:fine")
    tx, ty = center_phys(now)
    a = UIManager:audit(function() tap(tx, ty) end)
    UIManager:close(toast)
    report(clean(a, P) and whole(a) and a.box and inside(a.box, union(phys(was), phys(now))),
           "under a toast: the window repaints whole, one refresh, only the buttons change,"
           .. " no third value", seen(a))

    -- New ink clears Redo while the pen hovers, and the pen can tap the
    -- panel: the panel repaints at the pen-up, once, within its rect.
    do
        advance_ms(1000)
        UIManager:repaint()
        tx, ty = center_phys(item("undo"))
        tap(tx, ty)
        UIManager:repaint()
        local on = item("redo") and item("redo").enabled
        P = scr(w1.panel_L)
        -- A canvas point clear of the panel, above or below it.
        local ly = P.y > 120 and 40 or Screen:getHeight() - 80
        local cx, cy = G.to_physical(3, W, H, 40, ly)
        advance_ms(1000)
        a = UIManager:audit(function()
            pen_enter(cx, cy)
            pen_down(cx, cy)
            pen_move(cx + 20, cy + 20)
            pen_up()
        end)
        local redo = item("redo")
        report(on and redo and not redo.enabled and w1.c:pen_in_range()
               and clean(a, P) and not whole(a)
               and stages(a, "panel") == 1 and stages(a, "page") == 0,
               "new ink under a hovering pen: Redo shows off at the pen-up, one refresh"
               .. " within the panel, no third value", seen(a))
        pen_leave()
    end

    -- A flick from the panel's body (its bottom padding: no button, not
    -- the title bar) closes it.
    advance_ms(1000)
    UIManager:repaint()
    local L = w1.panel_L
    P = scr(L)
    tx, ty = G.to_physical(3, W, H, floor(L.x + L.w / 2), L.y + L.h - 6)
    a = UIManager:audit(function()
        tracking = tracking + 1
        frame{ { 3, 57, tracking }, { 3, 53, tx }, { 3, 54, ty } }
        for k = 1, 3 do frame{ { 3, 54, ty - 60 * k } } end
        frame{ { 3, 57, -1 } }
    end)
    report(w1.panel_L == nil and clean(a, P) and same(a.refreshes[1].region, P)
           and stages(a, "page") == 1 and not whole(a) and shows_page(P),
           "a flick: one refresh over the panel's rect, the page repainted once under it,"
           .. " no third value", seen(a))
end

------------------------------------------------------------------------
-- 7. A foreign widget on top
------------------------------------------------------------------------

UIManager:fire_due()
local t_f = #trace
tracking = tracking + 1
local c1 = frame{ { 3, 57, tracking }, { 3, 53, 300 }, { 3, 54, 300 } }
local foreign = { name = "dialog", modal = true, handleEvent = noop }
UIManager:show(foreign)
local c2 = frame{ { 3, 53, 305 } }
local c3 = frame{ { 3, 57, -1 } }
report(c1 and c2 and c3 and trace_from(t_f + 1) == "",
       "a finger down before the dialog stays with the notebook to its lift", "")
tracking = tracking + 1
local p1 = frame{ { 3, 57, tracking }, { 3, 53, 310 }, { 3, 54, 310 } }
local p2 = frame{ { 3, 57, -1 } }
report(not p1 and not p2, "the next finger passes through to the dialog", "")
report(trace_from(t_f + 1) == "resetState setTouchSlot 0",
       "the switch runs resetState and hands mixedrouter the kernel's slot",
       trace_from(t_f + 1))
local pubs = Device.publishes
advance_ms(1000)
local pc = pen_enter(400, 900)
pen_down(400, 900)
pen_move(420, 900)
pen_up()
pen_leave()
report(pc and Device.publishes == pubs and page_px(420, 900) == 255,
       "the pen stays consumed under the dialog but does not ink", "")
UIManager:close(foreign)
t_f = #trace
advance_ms(1000)
local b1 = tap(310, 310)
report(b1 and trace_from(t_f + 1) == "resetState",
       "after the dialog closes the notebook takes touch back", trace_from(t_f + 1))

------------------------------------------------------------------------
-- 8. Suspend and resume
------------------------------------------------------------------------

pen_enter(500, 800)
report(hint.armed, "hovering pen armed", "")
-- A stroke the pen is still hovering after: appended, not yet fsynced.
pen_down(500, 800)
pen_move(520, 800)
pen_up()
local syncs = memfs.calls["fsync " .. page0] or 0
UIManager:broadcastEvent(Event:new("Suspend"))
report(not hint.armed and w1.suspended
       and (memfs.calls["fsync " .. page0] or 0) == syncs + 1,
       "Suspend fsyncs the page written under the pen, and disarms", "")
local arms = hint.arms
pen_down(500, 900)
pen_move(520, 900)
pen_up()
report(hint.arms == arms and page_px(520, 900) == 255,
       "no arm and no ink while suspended", "")
-- The pen left while the device slept and its events were lost: the
-- key snapshot at resume, not the pre-suspend range, decides.
pen_keys = {}
UIManager:broadcastEvent(Event:new("Resume"))
report(not w1.suspended and not hint.armed and hint.arms == arms,
       "Resume reads the pen's keys: it left, so nothing arms", "")
advance_ms(LEAVE_MS)
run_timer()
report(input.wilkbook_hold_rotation() == false,
       "the leave the snapshot began releases rotation", "")
pen_enter(500, 800)
report(hint.armed and hint.arms == arms + 1, "the next proximity-in arms", "")
pen_leave()

------------------------------------------------------------------------
-- 9. Rotation: held under the pen, replayed, forwarded
------------------------------------------------------------------------

pen_enter(500, 800)
local held = input:handleMiscEv({ wilkbook_gsensor = true, code = 71, value = 0 })
report(held == nil and #view_modes == 0,
       "a rotation while the pen is in range is held", "")
pen_leave()
report(#view_modes == 0, "the release waits for nextTick", "")
UIManager:fire_due()
report(view_modes[1] == 0 and Screen:getRotationMode() == 0
       and w1.dimen.w == W and w1.c.mode == 0,
       "released at proximity-out, forwarded to the view, then the controller", "")
advance_ms(1000)
local pg_before = w1.c.page_n
swipe(1300, 700, 900, 700)  -- rotation 0: logical left is physical -x
report(w1.c.page_n == pg_before + 1,
       "a swipe is judged in the new orientation", tostring(w1.c.page_n))
UIManager:sendEvent(Event:new("SetRotationMode", 1))
report(view_modes[2] == 1 and Screen:getRotationMode() == 1 and w1.c.mode == 1,
       "SetRotationMode sent to the window reaches the view", "")
swipe(900, 700, 900, 300)
report(w1.c.page_n == pg_before, "back to page " .. pg_before, "")

do
    -- A gyro event as Input:waitEvent handles it: held, or dispatched.
    local function gyro(mode)
        local ev = input:handleMiscEv({ wilkbook_gsensor = true, code = 71, value = mode })
        if ev then UIManager:sendEvent(ev) end
        return ev
    end

    -- A finger the notebook consumes holds rotation as the pen does: the
    -- gesture detector never counts it.  A rotation mid-swipe would read
    -- the rest of the travel in the new orientation.
    advance_ms(1000)
    local vm0 = #view_modes
    tracking = tracking + 1
    frame{ { 3, 57, tracking }, { 3, 53, 900 }, { 3, 54, 300 } }
    report(input.wilkbook_hold_rotation() == true,
           "a consumed finger on the glass holds rotation", "")
    local dispatched = gyro(0)
    for k = 1, 4 do frame{ { 3, 54, 300 + 100 * k } } end
    frame{ { 3, 57, -1 } }
    report(dispatched == nil and #view_modes == vm0 and w1.c.page_n == pg_before + 1,
           "a rotation mid-swipe waits: the swipe is judged as it began and turns the page",
           "page " .. w1.c.page_n)
    report(input.wilkbook_hold_rotation() == false, "the lift ends the hold", "")
    UIManager:fire_due()
    report(view_modes[#view_modes] == 0 and w1.c.mode == 0,
           "the held rotation lands after the lift", tostring(view_modes[#view_modes]))
    gyro(1)
    report(w1.c.mode == 1, "with nothing held a rotation applies at once", "")
    swipe(900, 700, 900, 300)
    report(w1.c.page_n == pg_before, "and back to page " .. pg_before, "")

    -- A proximity dropout mid-stroke (pen-1's Y=0 edge): the nib stays on
    -- the glass, so nothing that waits for the pen to leave may run.
    advance_ms(1000)
    local pgf = root .. "/page-" .. w1.c.page_n .. ".jsonl"
    pen_enter(700, 1300)
    pen_down(700, 1300)
    pen_move(720, 1300)
    local syncs_d = memfs.calls["fsync " .. pgf] or 0
    local vm_d = #view_modes
    local lines_d = count_lines(memfs.get(pgf))
    pen{ { 1, 330, 0 }, { 3, 24, 0 }, { 1, 320, 0 } }
    advance_ms(20)
    local held_d = input.wilkbook_hold_rotation()
    local gy_d = gyro(0)
    pen{ { 1, 320, 1 }, { 1, 330, 1 }, { 3, 24, 4095 }, { 3, 0, RX(725) }, { 3, 1, RY(1300) } }
    pen_move(760, 1300)
    advance_ms(LEAVE_MS)
    run_timer()
    UIManager:fire_due()
    report(held_d and gy_d == nil and (memfs.calls["fsync " .. pgf] or 0) == syncs_d
           and #view_modes == vm_d and w1.c.mode == 1,
           "a dropout neither fsyncs nor releases the rotation it holds",
           format("held %s, dispatched %s, fsyncs %d, modes %d, mode %d", tostring(held_d),
                  tostring(gy_d), (memfs.calls["fsync " .. pgf] or 0) - syncs_d,
                  #view_modes - vm_d, w1.c.mode))
    pen_up()
    pen_leave()
    UIManager:fire_due()
    local r1 = J.decode(select(1, (memfs.get(pgf) or ""):match(("[^\n]*\n"):rep(lines_d) .. "([^\n]*)\n")) or "")
    report(count_lines(memfs.get(pgf)) == lines_d + 2 and r1 and r1.gap == 1
           and (memfs.calls["fsync " .. pgf] or 0) == syncs_d + 1,
           "the dropout splits the stroke (gap=1); the real leave fsyncs once", "")
    report(view_modes[#view_modes] == 0 and w1.c.mode == 0,
           "the rotation held through the dropout lands at the leave", "")
    gyro(1)

    -- A palm resting on the canvas before the pen comes into range: its long
    -- press opens the panel by timer, and the pen arriving over the still
    -- palm takes the panel back.
    advance_ms(1000)
    tracking = tracking + 1
    frame{ { 3, 57, tracking }, { 3, 53, 1000 }, { 3, 54, 700 } }
    advance_ms(800)
    UIManager:fire_due()
    local palm_opened = w1.panel_L ~= nil
    frame{ { 3, 53, 1002 } }
    pen_enter(300, 300)
    report(palm_opened and w1.panel_L == nil and w1.panel_phys == nil,
           "a palm's long press is taken back when the pen arrives over it", "")
    frame{ { 3, 57, -1 } }
    pen_leave()
end

------------------------------------------------------------------------
-- 10. New notebook and the list, from the panel
------------------------------------------------------------------------

local function panel_tap(id)
    tracking = tracking + 1
    frame{ { 3, 57, tracking }, { 3, 53, 1000 }, { 3, 54, 700 } }
    advance_ms(800)
    UIManager:fire_due()
    frame{ { 3, 57, -1 } }
    local it = item(id)
    if not it then return false end
    tap(center_phys(it))
    return true
end
advance_ms(1000)
panel_tap("nb:new")
UIManager:fire_due()
local nb2 = w1.session.id
report(win() == w1 and nb2 ~= nb_id and memfs.exists("/data/notebooks/" .. nb2 .. "/notebook.json"),
       "New from the panel switches the window to a new notebook", tostring(nb2))
report(w1.panel_L == nil and w1.panel_phys == nil,
       "the old notebook's panel goes with it", "")
report(w1.c.page_n == 0 and page_px(600, 500) == 255, "the new notebook opens blank", "")
panel_tap("nb:open")
UIManager:fire_due()
local menu = menus[#menus]
report(menu and #menu.item_table == 2 and UIManager:isWidgetShown(menu),
       "Open lists both notebooks in a Menu over the notebook",
       menu and tostring(#menu.item_table) or "")
-- Newest first: the first notebook is the last item.
local chosen = menu and menu.item_table[#menu.item_table]
report(chosen and chosen.mandatory == "1 page", "items show the page count", chosen and chosen.mandatory or "")
advance_ms(1000)
local passed = tap(300, 300)
report(not passed, "touch goes to the list while it is on top", "")
chosen.callback()
menu.close_callback()
UIManager:fire_due()
report(w1.session.id == nb_id and page_px(600, 500) == 0,
       "choosing a notebook switches back to it, on its last page", w1.session.id)

------------------------------------------------------------------------
-- 11. A failed append
------------------------------------------------------------------------

advance_ms(1000)
memfs.faults.append = { err = "ENOSPC" }
pen_enter(300, 1000)
pen_down(300, 1000)
pen_move(330, 1000)
report(page_px(330, 1000) == 0, "ink is drawn live before the write", "")
pen_up()
local appends = memfs.calls.append
report(find_log("[notebook] io-error ENOSPC") ~= nil,
       "the failed append is logged", find_log("io-error"))
report(page_px(330, 1000) == 255 and not hint.armed,
       "io_error renders the unsaved stroke away and disarms", "")
UIManager:fire_due()
local msg = shown_messages[#shown_messages]
report(msg and msg.timeout and msg.text:find("ENOSPC", 1, true) ~= nil,
       "a timed toast says why", msg and msg.text or "")
UIManager:close(msg)
memfs.faults.append = nil
pubs, arms = Device.publishes, hint.arms
pen_down(300, 1100)
pen_move(340, 1100)
pen_up()
pen_leave()
report(Device.publishes == pubs and hint.arms == arms and memfs.calls.append == appends
       and page_px(340, 1100) == 255,
       "after io_error: no arm, no ink, no append", "")

-- The executor's side of the failure contract, on a list built by hand:
-- after the first failed write, later append, arm, ink and publish_ink
-- are skipped, everything else runs, and io_error comes last with the
-- very command table that failed.
local ctl = w1.c
local spied
ctl.io_error = function(_, m, cmd)
    spied = { msg = m, cmd = cmd }
    return { { op = "log", line = "io_error ran" } }
end
memfs.faults.append = { err = "EIO" }
local t_x, logs_x = #trace, #log_lines
local failing = { op = "append", page = 5, line = '{"k":"u","a":1}' }
w1:_run({
    failing,
    { op = "arm", rects = { { x = 0, y = 0, w = W, h = H, hint = 0 } } },
    { op = "ink", spans = { 10, 10, 20 }, comp = "black", pat = "solid" },
    { op = "publish_ink" },
    { op = "append", page = 5, line = '{"k":"u","a":2}' },
    { op = "log", line = "later command ran" },
})
local tail = {}
for i = logs_x + 1, #log_lines do tail[#tail + 1] = log_lines[i] end
report(trace_from(t_x + 1) == "" and page_px(15, 10) == 255
       and memfs.calls["append " .. root .. "/page-5.jsonl"] == 1,
       "a failed append skips the list's later arm, ink, publish and append", "")
report(concat(tail, "|") == "[notebook] later command ran|[notebook] io_error ran",
       "the rest of the list runs, then io_error", concat(tail, "|"))
report(spied and spied.cmd == failing
       and spied.msg == "EIO " .. root .. "/page-5.jsonl",
       "io_error gets the failed command table and its error",
       spied and spied.msg or "")
ctl.io_error = nil
memfs.faults.append = nil

------------------------------------------------------------------------
-- 12. Closing from the panel, and reopening the last notebook
------------------------------------------------------------------------

advance_ms(1000)
kernel_slot = 5
tracking = tracking + 1
frame{ { 3, 47, 5 }, { 3, 57, tracking }, { 3, 53, 1000 }, { 3, 54, 700 } }
advance_ms(800)
UIManager:fire_due()
frame{ { 3, 57, -1 } }
local exit = item("nb:close")
local t_close = #trace
tap(center_phys(exit))
report(win() == w1, "Exit waits for nextTick", "")
UIManager:fire_due()
report(win() == nil and input.wilkbook_consumer == nil
       and input.wilkbook_hold_rotation == nil,
       "Exit closes the window and clears the consumer and hold", "")
report(trace_from(t_close + 1) == "disarm resetState setTouchSlot 5 disarm",
       "close: the controller's disarm, resetState, the kernel's slot, the plane",
       trace_from(t_close + 1))
local after = send(PEN, 1, 320, 1)
report(after.type == 1, "after close the pen reaches KOReader again", "")
send(PEN, 1, 320, 0)

entry.sub_item_table[1].callback()
UIManager:fire_due()
local w2 = win()
report(w2 and w2 ~= w1 and w2.session.id == nb_id,
       "Open last reopens the last notebook in a new window", w2 and w2.session.id or "")
report(w2 and page_px(600, 500) == 0, "on the page last written, replayed", "")

-- An error inside the adjust hook would end KOReader: it is contained,
-- the event that hit it is consumed, the next ones reach KOReader, and
-- the window closes on the next tick.
w2.c.feed = function() error("boom") end
local hit = send(PEN, 1, 320, 1)
local next_ev = send(PEN, 1, 320, 0)
report(hit.type == 4 and next_ev.type == 1 and input.wilkbook_consumer == nil,
       "a consumer error stops consumption at once", "")
UIManager:fire_due()
local last_msg = shown_messages[#shown_messages]
report(win() == nil and last_msg.text:find("internal error", 1, true) ~= nil
       and find_log("[notebook] input error:") ~= nil,
       "and closes the notebook with a message", last_msg.text)

-- Opened with the pen already hovering (a menu tapped with it): the key
-- snapshot at open puts it in range, so it arms and holds rotation
-- without waiting for a proximity-in.
UIManager:close(last_msg)
pen_keys = { [320] = true }
arms = hint.arms
entry.sub_item_table[1].callback()
UIManager:fire_due()
report(win() ~= nil and hint.armed and hint.arms == arms + 1
       and input.wilkbook_hold_rotation() == true,
       "opening under a hovering pen resyncs, arms and holds rotation", "")
pen_keys = {}
plugin:onCloseWidget()
report(win() == nil and input.wilkbook_consumer == nil,
       "the host closing takes the window with it", "")

------------------------------------------------------------------------
-- 13. The handoff through KOReader's real Input
------------------------------------------------------------------------

-- Everything above feeds the hook chain directly.  Here Device.input is
-- KOReader's own Input, built as device.lua builds it (the mixed touch
-- handler, mixedrouter, slotguard, pen scaling, the gyro handler, the
-- consumer hook last), and batches go through Input:waitEvent, so the
-- gesture detector says what KOReader would have done.  A stale touch
-- slot shows only with two fingers: a lone finger taps from any KOReader
-- slot, but a second finger's ABS_MT_SLOT then lands on top of it.
-- KOReader pairs two-finger gestures only in slots 0 and 1
-- (gesturedetector.lua newContact), so the fingers use those, and its
-- touch rotation is one pixel off nb_geom's (recon ko-ui).
do
    local pn_dir = device_lua:match("^(.*)/[^/]*$")
    Screen.DEVICE_ROTATED_UPRIGHT, Screen.DEVICE_ROTATED_CLOCKWISE = 0, 1
    Screen.DEVICE_ROTATED_UPSIDE_DOWN = 2
    Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE = 3
    function Screen:getTouchRotation() return self:getRotationMode() end
    local no = function() return false end
    local IDevice = { screen = Screen, display_dpi = 227, isSDL = no,
                      isAndroid = no, isPocketBook = no, isGSensorLocked = no }
    function IDevice:isAlwaysFullscreen() return true end
    function IDevice:hasEinkScreen() return true end
    local batches = {}
    local Backend = { is_ffi = true }
    function Backend.waitForEvent()
        local b = table.remove(batches, 1)
        if b then return true, b end
        return false, 62
    end
    local rin = require("device/input"):new{
        device = IDevice, wacom_protocol = true, disable_double_tap = true,
        input = Backend, event_map = {},
    }
    -- The detector's contact tables are class-level; give this Input its own.
    rin.gesture_detector.active_contacts = {}
    rin.gesture_detector.previous_tap = {}
    rin.gesture_detector.contact_count = 0
    rin.handleTouchEv = rin.handleMixedTouchEv
    dofile(pn_dir .. "/mixedrouter.lua").install(rin, PEN, TOUCH)
    dofile(pn_dir .. "/slotguard.lua").install(rin)
    rin:registerEventAdjustHook(function(_, ev)
        if ev.src == PEN then PineNote._adjustPenEvent(ev, W / XMAX, H / YMAX, W, H) end
    end)
    rin.handleGyroEv = function(_, ev) return Event:new("SetRotationMode", ev.value) end
    PineNote._installGyroHandler(rin)
    rin:registerEventAdjustHook(PineNote._consumerHook)
    local fake_input = Device.input
    Device.input = rin

    -- One batch of frames {src, events, step_ms}; returns what KOReader
    -- handled, gestures as ges@x,y in logical px.
    local function run(frames)
        local b = {}
        for _, fr in ipairs(frames) do
            local stamp = tv()
            for _, e in ipairs(fr[2]) do
                b[#b + 1] = { src = fr[1], type = e[1], code = e[2], value = e[3], time = stamp }
            end
            b[#b + 1] = { src = fr[1], type = 0, code = 0, value = 0, time = stamp }
            advance_ms(fr[3] or 10)
        end
        batches[1] = b
        local g = {}
        for _, ev in ipairs(rin:waitEvent(nil, nil) or {}) do
            local a = ev.args and ev.args[1]
            g[#g + 1] = a and a.ges and format("%s@%d,%d", a.ges, a.pos.x, a.pos.y)
                        or tostring(ev.handler)
        end
        return concat(g, " ")
    end
    -- The first finger in the kernel's current slot `sa` (so no
    -- ABS_MT_SLOT), the second in slot 0, both lifted together.
    local function two_tap(sa, xa, ya, xb, yb)
        tracking = tracking + 2
        return run{
            { TOUCH, { { 3, 57, tracking - 1 }, { 3, 53, xa }, { 3, 54, ya } } },
            { TOUCH, { { 3, 47, 0 }, { 3, 57, tracking }, { 3, 53, xb }, { 3, 54, yb } } },
            { TOUCH, { { 3, 47, sa }, { 3, 57, -1 }, { 3, 47, 0 }, { 3, 57, -1 } }, 40 },
        }
    end

    UIManager:fire_due()
    entry.sub_item_table[1].callback()
    UIManager:fire_due()
    local w3 = win()
    report(w3 ~= nil and rin.wilkbook_consumer ~= nil,
           "real Input: the consumer is set on KOReader's own Input", "")
    advance_ms(1000)
    local g = run{
        { PEN, { { 1, 320, 1 }, { 3, 0, RX(700) }, { 3, 1, RY(700) } } },
        { PEN, { { 1, 330, 1 }, { 3, 0, RX(700) }, { 3, 1, RY(700) }, { 3, 24, 2500 } } },
        { PEN, { { 3, 0, RX(740) } } },
        { PEN, { { 1, 330, 0 }, { 3, 24, 0 } } },
        { PEN, { { 1, 320, 0 } } },
    }
    report(g == "" and rin.gesture_detector.contact_count == 0 and page_px(720, 700) == 0,
           "real Input: a pen stroke inks and KOReader handles nothing", "[" .. g .. "]")
    -- The notebook consumes the kernel's move to slot 1.
    advance_ms(1000)
    tracking = tracking + 1
    g = run{ { TOUCH, { { 3, 47, 1 }, { 3, 57, tracking }, { 3, 53, 500 }, { 3, 54, 500 } } },
             { TOUCH, { { 3, 57, -1 } } } }
    report(g == "", "real Input: a finger in slot 1 is the notebook's", "[" .. g .. "]")
    local dlg = { name = "dialog", modal = true, handleEvent = noop }
    UIManager:show(dlg)
    g = two_tap(1, 600, 400, 700, 400)
    report(g == "touch@1004,600 touch@1004,700 two_finger_tap@1004,650",
           "real Input: under a dialog, fingers in slots 1 and 0 are KOReader's two-finger tap",
           "[" .. g .. "]")
    UIManager:close(dlg)
    advance_ms(1000)
    local pg0 = w3.c.page_n
    tracking = tracking + 1
    local fr = { { TOUCH, { { 3, 47, 1 }, { 3, 57, tracking }, { 3, 53, 900 }, { 3, 54, 300 } } } }
    for k = 1, 4 do fr[#fr + 1] = { TOUCH, { { 3, 54, 300 + 100 * k } } } end
    fr[#fr + 1] = { TOUCH, { { 3, 57, -1 } } }
    g = run(fr)
    report(g == "" and w3.c.page_n == pg0 + 1,
           "real Input: with the dialog gone the notebook's swipe turns the page",
           "[" .. g .. "] page " .. w3.c.page_n)
    -- The kernel is on slot 1 at close, and KOReader last saw slot 0.
    UIManager:close(w3)
    advance_ms(1000)
    g = two_tap(1, 300, 1000, 400, 1000)
    report(g == "touch@404,300 touch@404,400 two_finger_tap@404,350"
           and rin.gesture_detector.contact_count == 0,
           "real Input: after close, fingers in slots 1 and 0 are KOReader's two-finger tap",
           "[" .. g .. "]")
    g = run{ { PEN, { { 1, 320, 1 }, { 3, 0, RX(800) }, { 3, 1, RY(800) } } },
             { PEN, { { 1, 330, 1 } } },
             { PEN, { { 1, 330, 0 } }, 40 },
             { PEN, { { 1, 320, 0 } } } }
    report(g == "touch@603,800 tap@603,800", "real Input: after close a pen tap is KOReader's",
           "[" .. g .. "]")
    Device.input = fake_input
end

------------------------------------------------------------------------
-- 14. Failure paths, and errors outside the hook
------------------------------------------------------------------------

do
    local function reopen()
        entry.sub_item_table[1].callback()
        UIManager:fire_due()
        return win()
    end
    local function close_messages()
        for i = #UIManager._window_stack, 1, -1 do
            local x = UIManager._window_stack[i].widget
            if x.name ~= "notebook_window" then UIManager:close(x) end
        end
    end
    local function open_panel()
        advance_ms(1000)
        tracking = tracking + 1
        frame{ { 3, 57, tracking }, { 3, 53, 1000 }, { 3, 54, 700 } }
        advance_ms(800)
        UIManager:fire_due()
        frame{ { 3, 57, -1 } }
    end
    local function stroke(x, y)
        pen_enter(x, y)
        pen_down(x, y)
        pen_move(x + 40, y)
        pen_up()
        pen_leave()
    end

    -- A pen SYN_DROPPED mid-stroke: the cut stroke is appended with
    -- gap=1, and the report that ends the discard asks for a key snapshot.
    local w = reopen()
    local pg = root:gsub("[^/]*$", "") .. w.session.id .. "/page-" .. w.c.page_n .. ".jsonl"
    advance_ms(1000)
    local Evdev = require("ffi/input_evdev")
    local keystate, snaps = Evdev.keystate, 0
    Evdev.keystate = function(...)
        snaps = snaps + 1
        return keystate(...)
    end
    pen_keys = { [320] = true, [330] = true }
    pen_enter(200, 200)
    pen_down(200, 200)
    pen_move(230, 200)
    local lines0 = count_lines(memfs.get(pg))
    send(PEN, 0, 3, 0)
    send(PEN, 3, 0, RX(260))
    local snaps0 = snaps
    pen{ { 3, 1, RY(200) } }
    local cut = J.decode(last_line(memfs.get(pg)) or "")
    report(count_lines(memfs.get(pg)) == lines0 + 1 and cut and cut.gap == 1,
           "a pen SYN_DROPPED appends the cut stroke with gap=1", "")
    report(snaps == snaps0 + 1 and find_log("drops=1") ~= nil,
           "then one key snapshot (resync_pen), and the log counts the drop", "")
    pen_up()
    pen_keys = {}
    pen_leave()
    Evdev.keystate = keystate

    -- A failed fsync at proximity-out: io_error; the stroke whose append
    -- landed stays, nothing inks after, pages still turn.
    advance_ms(1000)
    memfs.faults.fsync = { err = "EIO" }
    stroke(200, 400)
    memfs.faults.fsync = nil
    report(find_log("[notebook] io-error EIO") ~= nil and page_px(220, 400) == 0,
           "a failed fsync goes to io_error; the appended stroke stays", "")
    local pubs = Device.publishes
    stroke(200, 600)
    report(Device.publishes == pubs and page_px(220, 600) == 255,
           "after a failed fsync nothing inks", "")
    advance_ms(1000)
    local n0 = w.c.page_n
    swipe(900, 300, 900, 700)
    report(w.c.page_n == n0 + 1, "after a failed fsync pages still turn", "")
    UIManager:fire_due()
    close_messages()

    -- New from the panel builds a fresh controller, which inks again.
    local old_id = w.session.id
    open_panel()
    tap(center_phys(item("nb:new")))
    UIManager:fire_due()
    advance_ms(1000)
    pubs = Device.publishes
    stroke(200, 800)
    report(w.session.id ~= old_id and Device.publishes > pubs and page_px(220, 800) == 0,
           "after io_error, New opens a notebook that inks again", "")

    -- A page that cannot be read: a toast, and the page on screen stays.
    advance_ms(1000)
    local p1 = root:gsub("[^/]*$", "") .. w.session.id .. "/page-1.jsonl"
    memfs.put(p1, "")
    memfs.faults.read = { path = p1, err = "EIO" }
    local nmsg = #shown_messages
    swipe(900, 300, 900, 700)
    memfs.faults.read = nil
    UIManager:fire_due()
    local m = shown_messages[#shown_messages]
    report(w.c.page_n == 0 and page_px(220, 800) == 0 and #shown_messages == nmsg + 1
           and m.text == "Notebook: cannot read page 1 (EIO " .. p1 .. ").",
           "a page that cannot be read: a toast, the page stays", "")
    close_messages()

    -- A rotation with the panel open moves its physical rect, and ink
    -- under the moved panel stays out of the framebuffer.
    open_panel()
    local before = w.panel_phys
    UIManager:sendEvent(Event:new("SetRotationMode", 0))
    local L = w.panel_L
    local px, py, pw, ph = G.rect_to_physical(Screen.bb:getRotation(), W, H,
                                              L.x, L.y, L.w, L.h)
    local now = w.panel_phys
    report(w.c.mode == 0 and now.x == px and now.y == py and now.w == pw and now.h == ph
           and (before.x ~= px or before.y ~= py or before.w ~= pw),
           "a rotation with the panel open moves its physical rect", "")
    advance_ms(1000)
    -- From the canvas into the panel: a contact that starts on the panel
    -- would ink nothing at all.
    stroke(px - 30, py + ph - 10)
    report(page_px(px + 5, py + ph - 10) == 0 and fb_px(px + 5, py + ph - 10) ~= 0
           and fb_px(px - 10, py + ph - 10) == 0,
           "ink under the rotated panel stays out of the framebuffer", "")
    UIManager:sendEvent(Event:new("SetRotationMode", 1))

    -- Poweroff broadcasts Close: the page written under the hovering pen
    -- is fsynced on the way out.
    advance_ms(1000)
    pen_enter(300, 300)
    pen_down(300, 300)
    pen_move(340, 300)
    pen_up()
    local p0 = root:gsub("[^/]*$", "") .. w.session.id .. "/page-0.jsonl"
    local syncs = memfs.calls["fsync " .. p0] or 0
    UIManager:broadcastEvent(Event:new("Close"))
    report(win() == nil and (memfs.calls["fsync " .. p0] or 0) == syncs + 1,
           "a Close broadcast closes the window and fsyncs the page", "")
    pen_leave()

    -- Opens the store refuses: a toast and no window.
    local mi = memfs.get("/proc/self/mountinfo")
    memfs.put("/proc/self/mountinfo",
              "22 1 179:6 / / rw,relatime shared:1 - ext4 /dev/mmcblk0p6 rw\n")
    entry.sub_item_table[1].callback()
    UIManager:fire_due()
    memfs.put("/proc/self/mountinfo", mi)
    m = shown_messages[#shown_messages]
    report(win() == nil and m.text:find("not the data partition", 1, true) ~= nil,
           "/data on the OS root: no window, a toast", "")
    close_messages()
    memfs.faults.append = { path = "/data/notebooks/.probe", err = "EROFS" }
    entry.sub_item_table[2].callback()
    UIManager:fire_due()
    memfs.faults.append = nil
    m = shown_messages[#shown_messages]
    report(win() == nil and m.text == "Notebook: cannot save to /data/notebooks"
           .. " (EROFS /data/notebooks/.probe).",
           "a /data that refuses the probe append: no window, a toast", "")
    close_messages()

    -- Touch comes back to the notebook at the kernel's slot, not at the
    -- last one nb_input saw: a dialog's finger moves the kernel to slot 2,
    -- then a two-finger undo starts there, so its first finger carries
    -- no ABS_MT_SLOT and the second one's slot 0 would land on top of it:
    -- one contact, no undo.
    w = reopen()
    local pz = root:gsub("[^/]*$", "") .. w.session.id .. "/page-" .. w.c.page_n .. ".jsonl"
    advance_ms(1000)
    tracking = tracking + 1
    frame{ { 3, 47, 0 }, { 3, 57, tracking }, { 3, 53, 300 }, { 3, 54, 300 } }
    frame{ { 3, 57, -1 } }
    local dlg = { name = "dialog", modal = true, handleEvent = noop }
    UIManager:show(dlg)
    tracking = tracking + 1
    local via_dialog = not frame{ { 3, 47, 2 }, { 3, 57, tracking },
                                  { 3, 53, 300 }, { 3, 54, 300 } }
    frame{ { 3, 57, -1 } }
    UIManager:close(dlg)
    advance_ms(1000)
    local lines = count_lines(memfs.get(pz))
    tracking = tracking + 2
    frame{ { 3, 57, tracking - 1 }, { 3, 53, 700 }, { 3, 54, 600 },
           { 3, 47, 0 }, { 3, 57, tracking }, { 3, 53, 900 }, { 3, 54, 600 } }
    for k = 1, 4 do
        frame{ { 3, 47, 2 }, { 3, 54, 600 + 100 * k }, { 3, 47, 0 }, { 3, 54, 600 + 100 * k } }
    end
    frame{ { 3, 47, 2 }, { 3, 57, -1 }, { 3, 47, 0 }, { 3, 57, -1 } }
    local undo = J.decode(last_line(memfs.get(pz)) or "")
    report(via_dialog and count_lines(memfs.get(pz)) == lines + 1 and undo and undo.k == "u",
           "back from a dialog, a two-finger undo from the kernel's slot 2 undoes", "")

    -- A finger whose lift a touch SYN_DROPPED lost must not keep touch
    -- from a dialog shown after it: the glue forgets fingers at a drop.
    advance_ms(1000)
    tracking = tracking + 1
    frame{ { 3, 47, 0 }, { 3, 57, tracking }, { 3, 53, 400 }, { 3, 54, 400 } }
    send(TOUCH, 0, 3, 0)
    send(TOUCH, 0, 0, 0)
    UIManager:show(dlg)
    advance_ms(1000)
    tracking = tracking + 1
    local q1 = frame{ { 3, 57, tracking }, { 3, 53, 410 }, { 3, 54, 410 } }
    local q2 = frame{ { 3, 57, -1 } }
    report(not q1 and not q2, "after a touch SYN_DROPPED a dialog still gets the next finger", "")
    UIManager:close(dlg)
    UIManager:close(w)
    UIManager:fire_due()
    close_messages()

    -- An error in a scheduled task (the long press) or an event handler
    -- would end KOReader as surely as one in the hook: each is contained,
    -- stops consuming, and closes the notebook with a message.
    local function contained(label, provoke)
        local wx = reopen()
        local nm = #shown_messages
        local ok, err = pcall(provoke, wx)
        local stopped = input.wilkbook_consumer == nil
        UIManager:fire_due()
        local msg = shown_messages[#shown_messages]
        report(ok and stopped and win() == nil and #shown_messages == nm + 1
               and msg.text:find("internal error", 1, true) ~= nil,
               label, ok and "" or tostring(err):match("[^/]*$"))
        close_messages()
    end
    contained("an error in the long-press timer is contained", function(wx)
        wx.c.on_timer = function() error("timer") end
        advance_ms(1000)
        tracking = tracking + 1
        frame{ { 3, 57, tracking }, { 3, 53, 1000 }, { 3, 54, 700 } }
        advance_ms(800)
        UIManager:fire_due()
        frame{ { 3, 57, -1 } }
    end)
    contained("an error in Suspend is contained", function(wx)
        wx.c.suspend = function() error("suspend") end
        UIManager:broadcastEvent(Event:new("Suspend"))
    end)
    contained("an error on a rotation is contained", function(wx)
        wx.c.set_rotation = function() error("rotation") end
        UIManager:sendEvent(Event:new("SetRotationMode", 0))
    end)
    -- No window is left to forward it: back to portrait through the view.
    ui.view:onSetRotationMode(1)
end

------------------------------------------------------------------------
-- 15. Refresh: the page where the panel was, published, then one wash
------------------------------------------------------------------------

-- The helpers of sections 15 and 16, in one table: this chunk is at
-- LuaJIT's 200-local limit.
local H15 = {}
H15.SETTLE_MS = dofile(plugin_dir .. "/nb_config.lua").refresh_settle_us / 1000

function H15.reopen()
    entry.sub_item_table[1].callback()
    UIManager:fire_due()
    return win()
end

function H15.long_press()
    tracking = tracking + 1
    frame{ { 3, 57, tracking }, { 3, 53, 1000 }, { 3, 54, 700 } }
    advance_ms(800)
    UIManager:fire_due()
    frame{ { 3, 57, -1 } }
end

-- A pen stroke on the canvas, from its entry to its leave; the rubber end
-- when rubber is set.
function H15.stroke(x, y, rubber)
    pen_enter(x, y, rubber)
    pen_down(x, y)
    pen_move(x + 40, y)
    pen_up()
    pen_leave(rubber)
end

-- The page on the screen over logical rect r (clipped), on a 7 px grid.
function H15.shows_page(r)
    local x0, y0 = math.max(0, r.x), math.max(0, r.y)
    local x1 = math.min(Screen:getWidth(), r.x + r.w)
    local y1 = math.min(Screen:getHeight(), r.y + r.h)
    for y = y0, y1 - 1, 7 do
        for x = x0, x1 - 1, 7 do
            local qx, qy = G.to_physical(Screen.bb:getRotation(), W, H, x, y)
            if math.abs(Screen.bb:getPixel(x, y):getColor8().a - page_px(qx, qy)) > 8 then
                return false
            end
        end
    end
    return true
end

-- setDirty calls since index i with the given window and mode.
function H15.dirties(i, w, mode)
    local n = 0
    for k = i + 1, #UIManager.dirty do
        local d = UIManager.dirty[k]
        if d.w == w and d.mode == mode then n = n + 1 end
    end
    return n
end

do
    UIManager:fire_due()
    local w = H15.reopen()
    advance_ms(1000)
    H15.stroke(300, 300)
    advance_ms(1000)
    H15.long_press()
    UIManager:repaint()
    local P = w.panel_L
    local rit = item("refresh")
    local debt0 = washer2.debt
    local t0, d0 = #trace, #UIManager.dirty
    tap(center_phys(rit))
    report(w.panel_L == nil and H15.shows_page(P) and trace_from(t0 + 1) == "disarm publish",
           "Refresh by finger: the panel goes, the page is painted where it was and published",
           trace_from(t0 + 1))
    report(H15.dirties(d0, nil, "full") == 0 and H15.dirties(d0, "all", "full") == 0,
           "Refresh by finger: no wash yet", "")
    UIManager:repaint()
    -- frame() already moved the clocks 10 ms past the lift.
    advance_ms(H15.SETTLE_MS - 10 - 1)
    run_timer()
    report(H15.dirties(d0, nil, "full") == 0,
           "Refresh by finger: none a millisecond short of the settle wait", "")
    local t1 = #trace
    advance_ms(2)
    run_timer()
    UIManager:repaint()
    local last = UIManager.refreshes[#UIManager.refreshes]
    report(H15.dirties(d0, nil, "full") == 1 and H15.dirties(d0, "all", "full") == 0
           and H15.dirties(d0, w, "full") == 0 and trace_from(t1 + 1) == "disarm refresh:full"
           and last.mode == "full" and last.region.w == Screen:getWidth()
           and last.region.h == Screen:getHeight(),
           "Refresh by finger: after the wait, one full-screen wash that repaints no window",
           trace_from(t1 + 1))
    report(washer2.debt == debt0 and find_log("[notebook] refresh: one full wash") ~= nil,
           "Refresh by finger: charges the washer nothing, and logs the wash", "")

    -- By the pen tip: it still hovers after the tap, so the wash waits for
    -- its leave, then the settle wait.
    advance_ms(1000)
    H15.long_press()
    UIManager:repaint()
    P = w.panel_L
    local px, py = center_phys(item("refresh"))
    t0, d0 = #trace, #UIManager.dirty
    pen_enter(px, py)
    pen_down(px, py)
    pen_up()
    report(w.panel_L == nil and trace_from(t0 + 1) == "arm disarm publish",
           "Refresh by pen: the tip's lift hides the panel and publishes its place",
           trace_from(t0 + 1))
    UIManager:repaint()
    advance_ms(400)
    run_timer()
    UIManager:fire_due()
    UIManager:repaint()
    report(H15.dirties(d0, nil, "full") == 0 and H15.shows_page(P),
           "Refresh by pen: no wash while the pen hovers", "")
    pen_leave()
    report(H15.dirties(d0, nil, "full") == 0, "Refresh by pen: none at the leave either", "")
    t1 = #trace
    advance_ms(H15.SETTLE_MS + 1)
    run_timer()
    UIManager:repaint()
    report(H15.dirties(d0, nil, "full") == 1 and trace_from(t1 + 1) == "disarm refresh:full",
           "Refresh by pen: one wash, a settle wait after the pen's leave",
           trace_from(t1 + 1))

    -- A slow publish (the fsync takes 20 ms) and a timer that fires early
    -- (KOReader's scheduler reads CLOCK_MONOTONIC_COARSE): the wait still
    -- counts from the publish's end, not from the tap's handling.
    advance_ms(1000)
    H15.long_press()
    UIManager:repaint()
    local publish = Device.publishNow
    Device.publishNow = function(this)
        local r = publish(this)
        advance_ms(20)
        H15.pub_end = mono_s
        return r
    end
    t0, d0 = #trace, #UIManager.dirty
    tap(center_phys(item("refresh")))
    Device.publishNow = publish
    UIManager:repaint()
    advance_ms((H15.pub_end - mono_s) * 1000 + H15.SETTLE_MS - 1)
    w._timer_task()
    report(H15.dirties(d0, nil, "full") == 0,
           "Refresh, a slow publish: an early timer 1 ms short of the settle after it washes"
           .. " nothing", "")
    advance_ms(2)
    run_timer()
    UIManager:repaint()
    report(H15.dirties(d0, nil, "full") == 1,
           "Refresh, a slow publish: the wash a settle wait after the publish's end", "")

    -- Under a toast (KOReader's Notification: on top, takes no input): the
    -- finger still reaches the panel, the page goes back through a window
    -- repaint that paints the toast over it, and the wash still waits.
    advance_ms(1000)
    H15.long_press()
    UIManager:repaint()
    P = w.panel_L
    H15.toast = { name = "toast", toast = true, handleEvent = noop,
                  paintTo = function() end }
    UIManager:show(H15.toast)
    UIManager:repaint()
    t0, d0 = #trace, #UIManager.dirty
    tap(center_phys(item("refresh")))
    report(w.panel_L == nil and H15.dirties(d0, w, "ui") == 1
           and H15.dirties(d0, nil, "ui") == 0 and trace_from(t0 + 1) == "disarm publish",
           "Refresh under a toast: the window is marked for a repaint, not painted in place",
           trace_from(t0 + 1))
    t1 = #trace
    UIManager:repaint()
    report(trace_from(t1 + 1) == "paint notebook_window paint toast refresh:ui"
           and H15.shows_page(P),
           "Refresh under a toast: the repaint puts the page back, the toast over it",
           trace_from(t1 + 1))
    advance_ms(H15.SETTLE_MS)
    run_timer()
    UIManager:repaint()
    report(H15.dirties(d0, nil, "full") == 1 and H15.dirties(d0, "all", "full") == 0,
           "Refresh under a toast: one wash after the settle wait, repainting nothing", "")
    UIManager:close(H15.toast)
    UIManager:repaint()

    -- Right before suspend: the Suspend inside the wait drops the wash, and
    -- nothing washes after the resume.
    advance_ms(1000)
    H15.long_press()
    UIManager:repaint()
    t0, d0 = #trace, #UIManager.dirty
    tap(center_phys(item("refresh")))
    advance_ms(50)
    pen_keys = {}
    UIManager:broadcastEvent(Event:new("Suspend"))
    UIManager:broadcastEvent(Event:new("Resume"))
    advance_ms(2 * H15.SETTLE_MS)
    run_timer()
    UIManager:fire_due()
    UIManager:repaint()
    report(w.panel_L == nil and H15.dirties(d0, nil, "full") == 0
           and H15.dirties(d0, "all", "full") == 0,
           "Refresh right before suspend: the Suspend drops the wash", "")
    UIManager:close(w)
    UIManager:fire_due()
end

------------------------------------------------------------------------
-- 16. Ghost debt and the real idle washer
------------------------------------------------------------------------

-- The working tree's idle washer, as PluginLoader would give it to the
-- host, over this file's UIManager and clocks at its shipped defaults:
-- the notebook's erases, undo and panel closes charge it at the pen's
-- leave or the touch's end, writing keeps its idle clock back, and 45 s of
-- quiet then washes the notebook once, repainting it whole first.
do
    local washer_dir = arg[4] or (plugin_dir .. "/../idlewasher.koplugin")
    package.preload["idlewasher_core"] = function()
        return dofile(washer_dir .. "/idlewasher_core.lua")
    end
    package.preload["dispatcher"] = function()
        return { registerAction = function() end }
    end
    local IdleWasher = dofile(washer_dir .. "/main.lua")
    local Core = require("idlewasher_core")

    local real = IdleWasher:new{}
    ui.idlewasher = real
    local w = H15.reopen()
    local charged = {}
    real.chargeDebt = function(this, n)
        charged[#charged + 1] = n
        return IdleWasher.chargeDebt(this, n)
    end
    local d_all = #UIManager.dirty
    local function now_s() return floor(mono_s * 1e6) / 1e6 end

    advance_ms(1000)
    H15.stroke(300, 500)
    UIManager:fire_due()
    report(real.core.debt == 0 and math.abs(real.core.last_activity - now_s()) < 0.1,
           "real washer: the pen's contact is activity, and ink charges nothing",
           format("debt=%d idle=%.3fs", real.core.debt, now_s() - real.core.last_activity))

    -- Three rubber erases in one visit: nothing at each pen-up, 3 at the
    -- leave.
    advance_ms(1000)
    pen_enter(300, 500, true)
    for k = 0, 2 do
        pen_down(310 + 10 * k, 500)
        pen_move(310 + 10 * k, 520)
        pen_up()
    end
    local at_up = real.core.debt
    pen_leave(true)
    report(at_up == 0 and concat(charged, ",") == "3" and real.core.debt == 3,
           "real washer: three rubber erases charge 3 at the leave, none at a pen-up",
           "charged " .. concat(charged, ","))

    -- A two-finger undo and two panel closes (Close, a flick), each at
    -- the touch's end.
    advance_ms(1000)
    swipe2(0, 400)
    H15.long_press()
    advance_ms(1000)
    tap(center_phys(item("close")))
    H15.long_press()
    local tx, ty = center_phys(item("title"))
    tracking = tracking + 1
    frame{ { 3, 57, tracking }, { 3, 53, tx }, { 3, 54, ty } }
    for k = 1, 3 do frame{ { 3, 54, ty - 60 * k } } end
    frame{ { 3, 57, -1 } }
    report(concat(charged, ",") == "3,1,1,1" and real.core.debt == 6,
           "real washer: the undo, the Close and the flick charge one each",
           "charged " .. concat(charged, ","))

    -- Nine more erases, one visit each: debt_min.
    for k = 1, 9 do
        advance_ms(1000)
        H15.stroke(200 + 60 * k, 900, true)
    end
    UIManager:fire_due()
    report(real.core.debt == Core.DEFAULTS.debt_min and H15.dirties(d_all, "all", "full") == 0,
           "real washer: debt_min reached, and no charge washed",
           "debt=" .. real.core.debt)
    -- KOReader repaints after every input batch; this harness only when
    -- asked, so the panel's and the undo's refreshes run here.
    UIManager:repaint()

    -- A minute of writing, a stroke every 5 s: the washer's timer comes
    -- due and finds the pen's activity each time.
    for _ = 1, 12 do
        advance_ms(5000)
        H15.stroke(600, 1200)
        UIManager:fire_due()
    end
    report(H15.dirties(d_all, "all", "full") == 0 and real.core.debt == Core.DEFAULTS.debt_min,
           "real washer: no wash lands while the user writes, a minute past idle_s", "")
    report(hint.armed, "real washer: the last stroke left the DU rectangle armed", "")

    -- A slow writer: a pause just short of idle_s, then a stroke held across
    -- the washer's deadline, a report every 100 ms.  The pen's contact is
    -- activity at most once a second, and the timer due mid-stroke finds
    -- it: no wash under the nib.
    advance_ms(Core.DEFAULTS.idle_s * 1000 - 500)
    UIManager:fire_due()
    pen_enter(900, 1200)
    pen_down(900, 1200)
    H15.mid = 0
    for k = 1, 30 do
        advance_ms(100)
        pen_move(900 + 4 * k, 1200)
        UIManager:fire_due()
        H15.mid = H15.dirties(d_all, "all", "full")
    end
    pen_up()
    pen_leave()
    UIManager:fire_due()
    report(H15.mid == 0 and H15.dirties(d_all, "all", "full") == 0
           and real.core.debt == Core.DEFAULTS.debt_min,
           "real washer: a stroke held across the washer's deadline gets no wash under the nib",
           "washes=" .. H15.dirties(d_all, "all", "full"))

    -- 45 s of quiet: one idle wash, the notebook repainted whole, then the
    -- full refresh, whose guard drops the DU arm.
    advance_ms(Core.DEFAULTS.idle_s * 1000 + 100)
    UIManager:fire_due()
    report(H15.dirties(d_all, "all", "full") == 1 and real.core.debt == 0
           and find_log("[idlewasher] idle wash (debt=15)") ~= nil,
           "real washer: after idle_s of quiet, one idle wash of the 15 units",
           "washes=" .. H15.dirties(d_all, "all", "full"))
    local t0, r0 = #trace, #UIManager.refreshes
    UIManager:repaint()
    report(trace_from(t0 + 1) == "paint notebook_window disarm refresh:full"
           and #UIManager.refreshes == r0 + 1 and not hint.armed
           and H15.shows_page({ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }),
           "real washer: the notebook repaints whole, the guard disarms, then one full refresh",
           trace_from(t0 + 1))
    advance_ms(100000)
    UIManager:fire_due()
    report(H15.dirties(d_all, "all", "full") == 1,
           "real washer: no second wash with the debt retired", "")
    t0 = #trace
    advance_ms(1000)
    pen_enter(700, 700)
    pen_down(700, 700)
    pen_move(740, 700)
    report(trace_from(t0 + 1):match("^arm publish") ~= nil,
           "real washer: the next ink re-arms the rectangle the wash disarmed",
           trace_from(t0 + 1))
    pen_up()
    pen_leave()

    -- Hover suppresses both automatic washes without emitting activity.
    -- The debt must still be serviced when the deferred leave completes.
    UIManager:fire_due()
    real:chargeDebt(15)
    local activity = input_events
    local last = real.core.last_activity
    pen_enter(700, 700)
    local d0 = #UIManager.dirty
    advance_ms(700000)
    UIManager:fire_due()
    report(real.core.debt == 15 and real.held_timer and H15.dirties(d0, "all", "full") == 0
           and real.core.last_activity == last and input_events == activity,
           "real washer: long hover holds idle/deep wash without AutoSuspend activity")
    pen_leave()
    UIManager:fire_due()
    report(real.core.debt == 0 and H15.dirties(d0, "all", "full") == 1,
           "real washer: the leave releases an overdue wash without another input")
    UIManager:repaint()

    -- Page turns tapped with the pen reach debt_max only on the leave.
    advance_ms(1000)
    H15.long_press()
    real:chargeDebt(59)
    local px, py = center_phys(item("page:next"))
    pen_enter(px, py)
    pen_down(px, py)
    pen_up()
    d0 = #UIManager.dirty
    report(real.core.debt == 59 and w.c.turn_debt == 1,
           "real washer: panel pen Next defers the threshold charge while hovering")
    pen_leave()
    report(real.core.debt == 0 and w.c.turn_debt == 0 and H15.dirties(d0, "all", "full") == 1,
           "real washer: Next's threshold wash is charged once at the leave")
    UIManager:repaint()

    for _, result in ipairs{ "success", "failure", "missing", "publish failure" } do
        advance_ms(1000)
        H15.long_press()
        real:chargeDebt(20)
        advance_ms(1000)
        Device.fail_publish = result == "publish failure"
        tap(center_phys(item("refresh")))
        Device.fail_publish = nil
        advance_ms(200)
        UIManager:fire_due()
        local before = real.core.debt
        report(before >= 20 and (w.pending_wash ~= nil) == (result ~= "publish failure"),
               "Refresh " .. result .. ": queued full has not retired debt")
        real:chargeDebt(3)
        UIManager.full_result = result ~= "failure"
        UIManager.no_ack = result == "missing"
        UIManager:repaint()
        if result == "missing" then
            advance_ms(1100)
            UIManager:fire_due()
        end
        local expected = result == "success" and 3 or math.min(60, before + 3)
        report(real.core.debt == expected and not w.pending_wash
               and Device.wilkbook_full_refresh_done == nil,
               "Refresh " .. result .. ": only acknowledged old debt retired; observer released",
               "debt=" .. real.core.debt)
        UIManager.full_result, UIManager.no_ack = nil, nil
    end

    -- A dialog cancelling Refresh releases its hold without a pen
    -- proximity transition; otherwise a timer parked in the settle wait
    -- would never run again until another contact.
    H15.long_press()
    advance_ms(1000)
    tap(center_phys(item("refresh")))
    real.timer_task()
    report(real.held_timer, "Refresh settle wait holds an automatic wash")
    w:_run(w.c:set_ink_live(false))
    UIManager:fire_due()
    report(not real.held_timer and not w.c.wash_wanted,
           "cancelling Refresh releases a parked timer without changing proximity")
    w:_run(w.c:set_ink_live(true))

    -- Even a controller close that throws cannot retain a hold/receipt.
    H15.long_press()
    advance_ms(1000)
    tap(center_phys(item("refresh")))
    advance_ms(200)
    UIManager:fire_due()
    pen_enter(700, 700)
    local close = w.c.close
    w.c.close = function() error("injected close failure") end
    UIManager:close(w)
    report(next(real.holds) == nil and Device.wilkbook_full_refresh_done == nil
           and not w.pending_wash, "close error releases wash hold and pending receipt")
    w.c.close = close
    w = H15.reopen()
    pen_enter(700, 700)
    w:_fault("test", "injected input failure")
    report(next(real.holds) == nil and Device.wilkbook_full_refresh_done == nil,
           "input error releases wash hold immediately, before deferred close")
    UIManager:fire_due()
    UIManager:close(shown_messages[#shown_messages])
    w = H15.reopen()
    advance_ms(1000)
    H15.stroke(500, 600)
    UIManager:fire_due()
    real:onCloseWidget()

    -- The lookup is nil-guarded: no washer at all, an older copy without
    -- chargeDebt, and a disabled washer (no core) each take an undo's
    -- charge without an error.
    local page = root:gsub("[^/]*$", "") .. w.session.id .. "/page-" .. w.c.page_n .. ".jsonl"
    local lines0, logs0 = count_lines(memfs.get(page)), #log_lines
    local function errors_since()
        local n = 0
        for i = logs0 + 1, #log_lines do
            if log_lines[i]:find("error", 1, true) then n = n + 1 end
        end
        return n
    end
    ui.idlewasher, washer.absent = nil, true
    advance_ms(1000)
    swipe2(0, 400)
    local older = { charges = 0, chargePageTurn = washer.chargePageTurn }
    ui.idlewasher, washer.absent = older, nil
    advance_ms(1000)
    swipe2(0, -400)
    local read = G_reader_settings.readSetting
    G_reader_settings.readSetting = function(_, key)
        if key == "idlewasher_enabled" then return false end
    end
    local off = IdleWasher:new{}
    G_reader_settings.readSetting = read
    ui.idlewasher = off
    advance_ms(1000)
    swipe2(0, 400)
    report(count_lines(memfs.get(page)) == lines0 + 3 and win() == w and off.core == nil
           and errors_since() == 0,
           "washer lookup: absent, without chargeDebt, or disabled, an undo's charge is"
           .. " dropped without an error",
           format("lines +%d, window %s, core %s, errors %d",
                  count_lines(memfs.get(page)) - lines0, tostring(win() == w),
                  tostring(off.core), errors_since()))
    ui.idlewasher = washer2
    UIManager:close(w)
    UIManager:fire_due()
end

-- Template lifecycle through the production shell: preflight, page failure,
-- blank page, reopening and switching to an ordinary notebook.
do
    local w = H15.reopen()
    local id, n, dir = w.session.id, w.c.page_n, w.nb.dir
    UIManager:close(w)
    UIManager:fire_due()
    memfs.put(dir .. "/backgrounds.conf", "wilkbook-backgrounds-v1 1872 1404\n" .. n .. "\n" .. (n+1) .. "\n")
    memfs.put(dir .. "/background-" .. n .. ".pgm", "P5\n1872 1404\n255\n" .. string.char(85):rep(W*H))
    w = H15.reopen()
    report(w and w.paper and w.paper:getPixel(0,0):getColor8().a == 85,
           "template open loads the declared physical paper")
    local old = w.paper
    local commands = {}
    w.c:_turn(1, commands)
    report(commands[#commands].op == "load_page" and commands[#commands].page == n+1,
           "template test requests the next page through normal navigation")
    w:_run(commands)
    report(w.c.page_n == n and w.paper == old,
           "missing next background leaves the current page and paper intact")
    UIManager:fire_due()
    for _, msg in ipairs(shown_messages) do UIManager:close(msg) end
    memfs.put(dir .. "/background-" .. (n+1) .. ".pgm", "P5\n1872 1404\n255\n" .. string.char(170):rep(W*H))
    commands = {}
    w.c:_turn(1, commands)
    w:_run(commands)
    report(w.c.page_n == n+1 and w.paper:getPixel(0,0):getColor8().a == 170,
           "successful turn replaces paper before the new page is rendered")
    commands = {}
    w.c:_turn(1, commands)
    w:_run(commands)
    report(w.c.page_n == n+2 and w.paper == nil,
           "page beyond the template has blank paper")
    commands = {}
    w.c:_turn(-2, commands)
    w:_run(commands)
    w:_switch("new")
    report(w.session.id ~= id and w.paper == nil,
           "switching to an ordinary notebook releases template paper")
    w:_switch("id", id)
    report(w.paper and w.paper:getPixel(0,0):getColor8().a == 85,
           "switching back restores template paper")
    UIManager:close(w)
    UIManager:fire_due()
    report(w.paper == nil, "close releases template paper")
end

if fail == 0 then
    print("RESULT: ok")
else
    print(format("RESULT: %d failure(s)", fail))
    os.exit(1)
end
