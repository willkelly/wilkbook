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
    publishNow and a hint owner that records arm, disarm and reset;
  * UIManager: a window stack with KOReader's toast/modal ordering, a
    recorded setDirty, scheduleIn/nextTick on a fake monotonic clock
    run by fire_due(), sendEvent/broadcastEvent, and paint(), which
    paints the top full-screen window the way _repaint does;
  * ui/time: the real module with realtime and monotonic replaced by
    fake clocks the test advances, so every stamp is reproducible;
  * the evdev queries (keystate, absinfo), InfoMessage, Menu and
    PluginLoader: recorders;
  * the fs: in memory, with the /data mount the store insists on, and
    per-op fault injection.

Scenario (each step asserts what doc/notebook.md and the command contract
in nb_controller.lua's header require):
module load (sentinel, hint reset), the Tools menu, New notebook; a pen
stroke (consumed, arm before the first publish, ink in the page and the
framebuffer, raw digitizer values and event times in the record, the
per-pen-up log line, the synthetic InputEvent on nextTick); lift and
proximity-out (append, then fsync); a swipe (page turn, render, 'ui'
dirty, washer charge) and back; a 3-finger undo and redo; a long press
(fire_due) opening the panel, which paints with inverted checked items;
a tap on a brush (prefs saved); a flick closing the panel; a foreign
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
timer, Suspend and a rotation, contained as the hook's are.

NOT covered here: the real UIManager paint and refresh loop, the real
InfoMessage and Menu widgets, and the device's ioctls.

Usage: luajit test-notebook-plugin.lua <koreader_dir> <plugin_dir> <device.lua>
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
    return true
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
    self:setDirty(nil, refreshtype, region)
end
function UIManager:setDirty(w, refreshtype, region)
    self.dirty[#self.dirty + 1] = { w = w, mode = refreshtype, region = region }
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
local washer = { charges = 0 }
function washer:chargePageTurn() self.charges = self.charges + 1 end
package.preload["pluginloader"] = function()
    return {
        getPluginInstance = function(_, name)
            if name == "idlewasher" then return washer end
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
-- Three fingers in slots 0..2 moving together, then lifting.
local function swipe3(dx, dy)
    local xs, ys = { 700, 800, 900 }, { 600, 600, 600 }
    local ev = {}
    for s = 0, 2 do
        tracking = tracking + 1
        ev[#ev + 1] = { 3, 47, s }
        ev[#ev + 1] = { 3, 57, tracking }
        ev[#ev + 1] = { 3, 53, xs[s + 1] }
        ev[#ev + 1] = { 3, 54, ys[s + 1] }
    end
    frame(ev)
    for k = 1, 4 do
        ev = {}
        for s = 0, 2 do
            ev[#ev + 1] = { 3, 47, s }
            ev[#ev + 1] = { 3, 53, xs[s + 1] + floor(dx * k / 4) }
            ev[#ev + 1] = { 3, 54, ys[s + 1] + floor(dy * k / 4) }
        end
        frame(ev)
    end
    frame{ { 3, 47, 0 }, { 3, 57, -1 }, { 3, 47, 1 }, { 3, 57, -1 },
           { 3, 47, 2 }, { 3, 57, -1 } }
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
local washer2 = { charges = 0, chargePageTurn = washer.chargePageTurn }
ui.idlewasher = washer2
swipe(900, 700, 900, 300)
report(w1.c.page_n == 0 and page_px(600, 500) == 0,
       "a rightward swipe turns back to page 0, replayed from the journal", "")
report(washer2.charges == 1 and washer.charges == 1,
       "the host's own idlewasher is preferred", "")

------------------------------------------------------------------------
-- 5. Three-finger undo and redo
------------------------------------------------------------------------

d0 = #UIManager.dirty
swipe3(0, 400)
report(page_px(600, 500) == 255 and count_lines(memfs.get(page0)) == 2,
       "a leftward 3-finger swipe undoes: record appended, stroke gone", "")
local reg = UIManager:dirty_since(d0, w1, "ui")
reg = reg[#reg] and reg[#reg].region
local lx, ly = G.to_logical(3, W, H, 600, 500)
report(reg and reg.x <= lx and lx < reg.x + reg.w and reg.y <= ly
       and ly < reg.y + reg.h and reg.w < 400,
       "the undo repaints a logical region around the stroke",
       reg and format("%d,%d %dx%d", reg.x, reg.y, reg.w, reg.h) or "none")
report((memfs.calls["fsync " .. page0] or 0) == 2,
       "an undo with the pen out of range is fsynced", "")
swipe3(0, -400)
report(page_px(600, 500) == 0 and count_lines(memfs.get(page0)) == 3,
       "a rightward 3-finger swipe redoes", "")

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
local pg = UIManager:dirty_since(d0, w1, "ui")
pg = pg[#pg] and pg[#pg].region
report(pg and L and pg.x == math.max(0, L.x) and pg.w <= L.w,
       "the panel's logical area is marked dirty 'ui'", "")
UIManager:paint()
local fine, pencil = item("brush:fine"), item("brush:pencil")
local function screen_px(lx0, ly0)
    return Screen.bb:getPixel(lx0, ly0):getColor8().a
end
report(fine and fine.checked and screen_px(fine.x + 6, fine.y + 6) == 0,
       "the checked brush is painted inverted", "")
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

-- The pen under the open panel: the page gets the ink, the framebuffer
-- keeps the panel, and the arm covers the panel at the plane default.
local lpx, lpy = L.x + 8, L.y + L.h - 8
local ppx, ppy = G.to_physical(3, W, H, lpx, lpy)
pen_enter(ppx, ppy)
report(hint.rects and hint.rects[2] and hint.rects[2].hint == 0x20
       and hint.rects[2].x == w1.panel_phys.x and hint.rects[2].w == w1.panel_phys.w,
       "with the panel open the arm adds its rect at 0x20", "")
pen_down(ppx, ppy)
pen_move(ppx + 6, ppy)
pen_up()
pen_leave()
report(page_px(ppx + 3, ppy) == 0 and fb_px(ppx + 3, ppy) == 255,
       "ink under the panel goes to the page, not over the panel", "")
advance_ms(1000)
local px, py = center_phys(pencil)
tap(px, py)
report(item("brush:pencil").checked and w1.prefs.brush == "pencil",
       "a tap on Pencil selects it", "")
report((memfs.get("/data/notebooks/prefs.json") or ""):find('"brush":"pencil"', 1, true) ~= nil,
       "the choice is saved to prefs.json", "")

d0 = #UIManager.dirty
local oldL = w1.panel_L
local title = item("title")
px, py = center_phys(title)
tracking = tracking + 1
frame{ { 3, 57, tracking }, { 3, 53, px }, { 3, 54, py } }
-- Fast along logical x (physical -y in portrait), 60 px every 10 ms.
for k = 1, 3 do frame{ { 3, 54, py - 60 * k } } end
frame{ { 3, 57, -1 } }
report(w1.panel_L == nil and w1.panel_phys == nil, "a flick closes the panel", "")
local closed = UIManager:dirty_since(d0, w1, "ui")
local covered = false
for _, d in ipairs(closed) do
    if d.region and d.region.x <= math.max(0, oldL.x) and d.region.y <= math.max(0, oldL.y) then
        covered = true
    end
end
report(covered, "the old panel area is repainted", "")

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
    stroke(px + 5, py + ph - 10)
    report(page_px(px + 10, py + ph - 10) == 0 and fb_px(px + 10, py + ph - 10) ~= 0,
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
    -- then a three-finger undo starts there, so its first finger carries
    -- no ABS_MT_SLOT and the second one's slot 0 would land on top of it.
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
    tracking = tracking + 3
    frame{ { 3, 57, tracking - 2 }, { 3, 53, 700 }, { 3, 54, 600 },
           { 3, 47, 0 }, { 3, 57, tracking - 1 }, { 3, 53, 800 }, { 3, 54, 600 },
           { 3, 47, 1 }, { 3, 57, tracking }, { 3, 53, 900 }, { 3, 54, 600 } }
    for k = 1, 4 do
        frame{ { 3, 47, 2 }, { 3, 54, 600 + 100 * k }, { 3, 47, 0 }, { 3, 54, 600 + 100 * k },
               { 3, 47, 1 }, { 3, 54, 600 + 100 * k } }
    end
    frame{ { 3, 47, 2 }, { 3, 57, -1 }, { 3, 47, 0 }, { 3, 57, -1 }, { 3, 47, 1 }, { 3, 57, -1 } }
    local undo = J.decode(last_line(memfs.get(pz)) or "")
    report(via_dialog and count_lines(memfs.get(pz)) == lines + 1 and undo and undo.k == "u",
           "back from a dialog, a three-finger undo from the kernel's slot 2 undoes", "")

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

if fail == 0 then
    print("RESULT: ok")
else
    print(format("RESULT: %d failure(s)", fail))
    os.exit(1)
end
