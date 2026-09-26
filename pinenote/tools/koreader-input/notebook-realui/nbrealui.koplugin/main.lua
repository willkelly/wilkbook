--[[--
Host-only controller for the notebook plugin inside a full native KOReader
(SDL emulator, offscreen), run by ../run-real-ui-test.sh.  Never shipped:
it lives outside pinenote/packages/koreader-device, which koreader.scm
grafts into every build.

The emulator is the SDL device, not the PineNote, so the plugin's device
seams are absent: Device.input_devices, the wilkbook_consumer hook,
Device.hint_owner and Device.publishNow.  This file installs them at load
time (PluginLoader loads plugins path-sorted, and "nbrealui" sorts before
"notebook", so the shim is in place before the notebook's own file-scope
hint reset runs), from the WORKING TREE's device.lua exports rather than
copies of them:

  * one adjust hook with device.lua's pen scaling (_adjustPenEvent, raw
    value kept) and touch mirror (_adjustTouchEvent, the glass-measured
    0..1871 x 0..1403 MT ranges); Generic.init's G-sensor handler
    (handleMiscGyroEv) and device.lua's orientation-bridge translation
    (_translateGyroEvent); _installGyroHandler; _consumerHook last --
    device.lua's order;
  * the real HintOwner (_newHintOwner) over a fake RECT_HINTS ioctl that
    decodes and records every submit;
  * the refresh-layer guard, wrapped around the SDL framebuffer's
    refreshFullImp, where every refresh*Imp ends on this backend;
  * publishNow as a counter;
  * the working tree's ffi/input_evdev (keystate, absinfo's value) in
    place of the bundle's copy.  The fake device paths do not exist, so
    its queries fail and the plugin takes its no-snapshot paths.

Not emulated: mixedrouter and slotguard, which sit on the PineNote's
wacom_protocol mixed pen+touch handler that the SDL input does not run.
The touch-slot handoff therefore takes the plugin's "no mixedrouter"
branch, and touch passed through to a foreign widget reaches KOReader's
generic MT handler.

Pen and touch are injected by wrapping the SDL backend's waitForEvent:
queued batches are returned in order, each stamped with CLOCK_REALTIME
when it is served (the PineNote's evdev clock), and the real timeout
runs in between, so long-press timers fire on real time.

Output: "NOTEBOOK_REAL_UI: " lines on stdout -- "ok:", "FAIL:", "shot:",
"note:", and one "result:ok" or "result:fail".  Screenshots are
Screen:shot PNGs (logical orientation, what a viewer sees) and one
physical page-buffer PNG, written to $NOTEBOOK_REAL_UI_SHOTS.
--]]

local PREFIX = "NOTEBOOK_REAL_UI: "
local function marker(s)
    io.stdout:write(PREFIX, s, "\n")
    io.stdout:flush()
end

if _G.__wilkbook_nbrealui_loaded then return { disabled = true } end
_G.__wilkbook_nbrealui_loaded = true

local ffi = require("ffi")
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local time = require("ui/time")

local ROOT = os.getenv("NOTEBOOK_REAL_UI_ROOT")
local KO_HOME = os.getenv("KO_HOME")
local SHOTS = os.getenv("NOTEBOOK_REAL_UI_SHOTS")
local ROTATION = tonumber(os.getenv("NOTEBOOK_REAL_UI_ROTATION") or "")

local Screen = Device.screen
local input = Device.input

-- Fake evdev nodes: every ev.src is compared against these, and nothing
-- can open them.
local PEN = "/nonexistent/wilkbook-notebook-real-ui/w9013-stylus"
local TOUCH = "/nonexistent/wilkbook-notebook-real-ui/cyttsp5"
local PENBTN = "/nonexistent/wilkbook-notebook-real-ui/ws8100"
local GSENSOR = "/nonexistent/wilkbook-notebook-real-ui/orientation"

-- The w9013's advertised axes and the cyttsp5's glass-measured MT ranges
-- (doc/status.md: "touch MT axes X=0..1871 Y=0..1403 (mirrored)").
local PEN_MAX_X, PEN_MAX_Y = 20966, 15725
local TOUCH_MAX_X, TOUCH_MAX_Y = 1871, 1403

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT = 0
local ABS_X, ABS_Y, ABS_PRESSURE = 0, 1, 24
local ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 47, 53, 54
local ABS_MT_TRACKING_ID = 57
local BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH = 320, 321, 330
local DRM_RECT_HINTS = 0x40106443

------------------------------------------------------------------------
-- The shim (load time)
------------------------------------------------------------------------

local shim = {
    ioctls = {},      -- decoded RECT_HINTS submits, in order
    publishes = 0,
    refreshes = 0,
    served = 0,       -- injected batches returned by waitForEvent
    pen_out_t = nil,  -- realtime us of the last served proximity-out
}
local queue = {}      -- { delay_us, due, events }

local function fake_ioctl(request, arg)
    local p = ffi.cast("uint8_t *", arg)
    local n = ffi.cast("uint32_t *", p + 4)[0]
    local rec = { request = request, set_default = p[0],
                  default_hint = p[1], rects = {} }
    if n > 0 then
        local base = ffi.cast("uint8_t *", arg[1])
        for i = 0, n - 1 do
            local r = base + 24 * i
            local s = ffi.cast("int32_t *", r + 8)
            rec.rects[i + 1] = { hint = r[0], x = s[0], y = s[1],
                                 w = s[2] - s[0], h = s[3] - s[1] }
        end
    end
    shim.ioctls[#shim.ioctls + 1] = rec
    return 0
end

local function install_shim()
    if not (ROOT and KO_HOME and SHOTS and ROTATION) then
        return "NOTEBOOK_REAL_UI_ROOT/_SHOTS/_ROTATION or KO_HOME unset"
    end
    if Device.input_devices ~= nil or Device.hint_owner ~= nil
       or Device.publishNow ~= nil or input.wilkbook_consumer ~= nil then
        return "the device already has the PineNote seams: not the SDL emulator"
    end
    if not (input.input and type(input.input.waitForEvent) == "function") then
        return "the input backend has no waitForEvent to wrap"
    end
    local PN = dofile(ROOT .. "/device.lua")
    for _, k in ipairs{ "_adjustPenEvent", "_adjustTouchEvent",
                        "_translateGyroEvent", "_installGyroHandler",
                        "_consumerHook", "_newHintOwner" } do
        if type(PN[k]) ~= "function" then
            return "device.lua does not export " .. k
        end
    end
    package.loaded["ffi/input_evdev"] = dofile(ROOT .. "/input_evdev.lua")

    local W, H = Screen.bb.w, Screen.bb.h
    shim.W, shim.H = W, H
    if W ~= TOUCH_MAX_X + 1 or H ~= TOUCH_MAX_Y + 1 then
        return string.format("emulated panel is %dx%d, not 1872x1404", W, H)
    end
    Device.input_devices = { pen = PEN, touch = TOUCH, penbtn = PENBTN,
                             gsensor = GSENSOR }

    local owner = PN._newHintOwner{
        ioctl = fake_ioctl, is_direct = true,
        bb = function() return Screen.bb end,
    }
    Device.hint_owner = owner
    Device.publishNow = function()
        shim.publishes = shim.publishes + 1
        return true
    end
    local full_imp = Screen.refreshFullImp
    Screen.refreshFullImp = function(this, x, y, w, h, d)
        shim.refreshes = shim.refreshes + 1
        owner:guard(x, y, w, h)
        return full_imp(this, x, y, w, h, d)
    end

    -- device.lua scales against the screen's physical size.
    local sx, sy = W / PEN_MAX_X, H / PEN_MAX_Y
    input:registerEventAdjustHook(function(_, ev)
        if ev.src == PEN then
            PN._adjustPenEvent(ev, sx, sy, W, H)
        elseif ev.src == TOUCH then
            PN._adjustTouchEvent(ev, TOUCH, 0, TOUCH_MAX_X, 0, TOUCH_MAX_Y)
        elseif ev.src == PENBTN and ev.type == EV_KEY
               and (ev.code == BTN_TOOL_PEN or ev.code == BTN_TOOL_RUBBER) then
            ev.type = 4
        end
    end)
    -- What Generic.init does for a device with a G-sensor (the PineNote
    -- has one; the SDL emulator does not), then device.lua's MSC_RAW
    -- translation of the orientation bridge.  Plugins load while ReaderUI
    -- has input inhibited, and inhibitInput(false) restores the handler it
    -- saved (input.lua), so an inhibited input gets it in that slot.
    if input._gyro_ev_handler ~= nil then
        input._gyro_ev_handler = input.handleMiscGyroEv
    else
        input.handleGyroEv = input.handleMiscGyroEv
    end
    input:registerEventAdjustHook(function(_, ev)
        PN._translateGyroEvent(ev, GSENSOR)
    end)
    PN._installGyroHandler(input)
    input:registerEventAdjustHook(PN._consumerHook)

    local backend = input.input
    local wait = backend.waitForEvent
    backend.waitForEvent = function(sec, usec)
        local item = queue[1]
        if item then
            local now = time.realtime()
            if now >= item.due then
                table.remove(queue, 1)
                local tv = { sec = math.floor(now / 1e6), usec = now % 1e6 }
                for _, ev in ipairs(item.events) do
                    ev.time = tv
                    if ev.src == PEN and ev.type == EV_KEY and ev.value == 0
                       and (ev.code == BTN_TOOL_PEN or ev.code == BTN_TOOL_RUBBER) then
                        shim.pen_out_t = now
                    end
                end
                if queue[1] then queue[1].due = now + queue[1].delay_us end
                shim.served = shim.served + 1
                return true, item.events
            end
            local left = item.due - now
            if not sec or left < sec * 1e6 + usec then
                sec, usec = math.floor(left / 1e6), left % 1e6
            end
        end
        return wait(sec, usec)
    end
    return nil
end

local ok_shim, shim_err = pcall(install_shim)
if ok_shim then
    shim.error = shim_err
else
    shim.error = "shim raised: " .. tostring(shim_err)
end

------------------------------------------------------------------------
-- Injection
------------------------------------------------------------------------

local function enqueue(delay_ms, events)
    local item = { delay_us = math.floor(delay_ms * 1000), events = events }
    queue[#queue + 1] = item
    if #queue == 1 then item.due = time.realtime() + item.delay_us end
end

-- The scripted session runs as a coroutine (Probe:onReaderReady); wait(s)
-- yields until a UIManager task resumes it.
local resume_script

local function wait(s)
    UIManager:scheduleIn(s, resume_script)
    coroutine.yield()
end

-- Until every queued batch has been served, then settle so nextTick
-- tasks and the repaint they ask for have run.
local function drain(settle)
    local deadline = time.realtime() + 20e6
    while queue[1] do
        if time.realtime() > deadline then error("injection queue stalled") end
        wait(0.02)
    end
    wait(settle or 0.2)
end

-- nb_config.palm_grace_us is 500 ms: a contact that lands sooner after
-- the pen left is a palm.  Touch gestures wait it out (with margin)
-- unless a step tests the rejection itself.
local PALM_CLEAR_US = 700000

local function palm_clear()
    while queue[1] do wait(0.02) end
    local left = shim.pen_out_t and shim.pen_out_t + PALM_CLEAR_US - time.realtime()
    if left and left > 0 then wait(left / 1e6) end
end

local function ev(src, ty, code, value)
    return { src = src, type = ty, code = code, value = value }
end

local function round(v) return math.floor(v + 0.5) end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Logical px -> physical, by the bundle's own Blitbuffer (an oracle
-- independent of the plugin's nb_geom).
local function physical(lx, ly)
    return Screen.bb:getPhysicalCoordinates(round(lx), round(ly))
end

-- The digitizer unit for a physical px: the inverse of nb_geom.raw_to_px.
local function pen_raw(lx, ly)
    local px, py = physical(lx, ly)
    return clamp(round(px * PEN_MAX_X / (shim.W - 1)), 0, PEN_MAX_X),
           clamp(round(py * PEN_MAX_Y / (shim.H - 1)), 0, PEN_MAX_Y)
end

-- One pen contact as the w9013 reports it: proximity in with a hover,
-- BTN_TOUCH:1, samples, BTN_TOUCH:0, a hover, proximity out.  pts are
-- logical {x, y, pressure}; per_batch reports share one waitForEvent.
local function pen_stroke(pts, tool, per_batch)
    per_batch = per_batch or 1
    local key = tool == "rubber" and BTN_TOOL_RUBBER or BTN_TOOL_PEN
    local syn = function() return ev(PEN, EV_SYN, SYN_REPORT, 0) end
    local x, y = pen_raw(pts[1][1], pts[1][2])
    enqueue(0, { ev(PEN, EV_KEY, key, 1), ev(PEN, EV_ABS, ABS_X, x),
                 ev(PEN, EV_ABS, ABS_Y, y + 60),
                 ev(PEN, EV_ABS, ABS_PRESSURE, 0), syn() })
    enqueue(3, { ev(PEN, EV_ABS, ABS_Y, y), syn() })
    enqueue(3, { ev(PEN, EV_KEY, BTN_TOUCH, 1),
                 ev(PEN, EV_ABS, ABS_PRESSURE, pts[1][3]), syn() })
    local batch = {}
    for i = 2, #pts do
        x, y = pen_raw(pts[i][1], pts[i][2])
        batch[#batch + 1] = ev(PEN, EV_ABS, ABS_X, x)
        batch[#batch + 1] = ev(PEN, EV_ABS, ABS_Y, y)
        batch[#batch + 1] = ev(PEN, EV_ABS, ABS_PRESSURE, pts[i][3])
        batch[#batch + 1] = syn()
        if (i - 1) % per_batch == 0 or i == #pts then
            enqueue(3 * per_batch, batch)
            batch = {}
        end
    end
    enqueue(3, { ev(PEN, EV_KEY, BTN_TOUCH, 0),
                 ev(PEN, EV_ABS, ABS_PRESSURE, 0), syn() })
    enqueue(3, { ev(PEN, EV_ABS, ABS_Y, y + 60), syn() })
    enqueue(3, { ev(PEN, EV_KEY, key, 0), syn() })
end

-- The pen hovering into range at logical (lx, ly), without contact, and
-- leaving again.
local function pen_hover_in(lx, ly)
    local x, y = pen_raw(lx, ly)
    enqueue(0, { ev(PEN, EV_KEY, BTN_TOOL_PEN, 1), ev(PEN, EV_ABS, ABS_X, x),
                 ev(PEN, EV_ABS, ABS_Y, y), ev(PEN, EV_ABS, ABS_PRESSURE, 0),
                 ev(PEN, EV_SYN, SYN_REPORT, 0) })
    enqueue(3, { ev(PEN, EV_ABS, ABS_Y, y + 40), ev(PEN, EV_SYN, SYN_REPORT, 0) })
end

local function pen_hover_out()
    enqueue(3, { ev(PEN, EV_KEY, BTN_TOOL_PEN, 0), ev(PEN, EV_SYN, SYN_REPORT, 0) })
end

-- The orientation bridge's report (KOReader mode 0..3 as MSC_RAW).
local function gyro(mode)
    enqueue(0, { ev(GSENSOR, 4, 3, mode), ev(GSENSOR, EV_SYN, SYN_REPORT, 0) })
end

-- A horizontal (logical) wave: n+1 samples from x0 to x1 around y, with
-- pressure p(i/n).
local function wave(x0, x1, y, amp, n, p)
    local pts = {}
    for i = 0, n do
        local f = i / n
        pts[#pts + 1] = { x0 + (x1 - x0) * f,
                          y + amp * math.sin(f * 2 * math.pi * 1.5),
                          round(p(f)) }
    end
    return pts
end

-- The kernel's current MT slot as the injected stream shows it: evdev
-- dedups ABS_MT_SLOT, so it is sent only on a change.
local kslot = 0
local next_tid = 1

local function touch_raw(lx, ly)
    local px, py = physical(lx, ly)
    -- device.lua mirrors v -> min + max - v; this is its inverse.
    return TOUCH_MAX_X - px, TOUCH_MAX_Y - py
end

-- One cyttsp5 frame.  contacts: {slot=, tid=(new contact), lx=, ly=} or
-- {slot=, up=true}.  first/last add BTN_TOUCH and the legacy single-touch
-- aliases the controller sends, which device.lua neutralises.
local function touch_frame(contacts, first, last)
    local evs = {}
    local lead
    for _, c in ipairs(contacts) do
        if c.slot ~= kslot then
            evs[#evs + 1] = ev(TOUCH, EV_ABS, ABS_MT_SLOT, c.slot)
            kslot = c.slot
        end
        if c.up then
            evs[#evs + 1] = ev(TOUCH, EV_ABS, ABS_MT_TRACKING_ID, -1)
        else
            if c.tid then
                evs[#evs + 1] = ev(TOUCH, EV_ABS, ABS_MT_TRACKING_ID, c.tid)
            end
            local rx, ry = touch_raw(c.lx, c.ly)
            evs[#evs + 1] = ev(TOUCH, EV_ABS, ABS_MT_POSITION_X, rx)
            evs[#evs + 1] = ev(TOUCH, EV_ABS, ABS_MT_POSITION_Y, ry)
            lead = lead or { rx, ry }
        end
    end
    if first then evs[#evs + 1] = ev(TOUCH, EV_KEY, BTN_TOUCH, 1) end
    if last then evs[#evs + 1] = ev(TOUCH, EV_KEY, BTN_TOUCH, 0) end
    if lead then
        evs[#evs + 1] = ev(TOUCH, EV_ABS, ABS_X, lead[1])
        evs[#evs + 1] = ev(TOUCH, EV_ABS, ABS_Y, lead[2])
    end
    evs[#evs + 1] = ev(TOUCH, EV_SYN, SYN_REPORT, 0)
    return evs
end

local function new_tid()
    next_tid = next_tid + 1
    return next_tid
end

local function touch_down(lx, ly, palm_ok)
    if not palm_ok then palm_clear() end
    enqueue(0, touch_frame({ { slot = 0, tid = new_tid(), lx = lx, ly = ly } },
                           true))
end

local function touch_up(delay_ms)
    enqueue(delay_ms, touch_frame({ { slot = 0, up = true } }, false, true))
end

local function tap(lx, ly, palm_ok)
    touch_down(lx, ly, palm_ok)
    touch_up(80)
end

-- One finger from a to b in `steps` moves, step_ms apart.
local function swipe(ax, ay, bx, by, steps, step_ms)
    touch_down(ax, ay)
    for i = 1, steps do
        local f = i / steps
        enqueue(step_ms, touch_frame({ { slot = 0, lx = ax + (bx - ax) * f,
                                         ly = ay + (by - ay) * f } }))
    end
    touch_up(step_ms)
end

-- n fingers landing together in slots 0..n-1, moving by dx, dy, lifting
-- together.
local function multi_swipe(starts, dx, dy, steps, step_ms)
    palm_clear()
    local down = {}
    for i, s in ipairs(starts) do
        down[i] = { slot = i - 1, tid = new_tid(), lx = s[1], ly = s[2] }
    end
    enqueue(0, touch_frame(down, true))
    for k = 1, steps do
        local f = k / steps
        local moved = {}
        for i, s in ipairs(starts) do
            moved[i] = { slot = i - 1, lx = s[1] + dx * f, ly = s[2] + dy * f }
        end
        enqueue(step_ms, touch_frame(moved))
    end
    local up = {}
    for i = #starts, 1, -1 do up[#up + 1] = { slot = i - 1, up = true } end
    enqueue(step_ms, touch_frame(up, false, true))
end

------------------------------------------------------------------------
-- The scripted session
------------------------------------------------------------------------

local Probe = WidgetContainer:extend{
    name = "nbrealui",
    is_doc_only = true,
}

local EXPECTED_OVERLAYS = {
    ["Book info cache database updated."] = true,
    ["Documents will be rendered in color on this device.\n"
        .. "If your device is grayscale, you can disable color rendering in "
        .. "the screen sub-menu for reduced memory usage."] = true,
}

function Probe:init()
    self.fails, self.oks, self.shot_n = 0, 0, 0
end

function Probe:check(cond, label, detail)
    if cond then
        self.oks = self.oks + 1
        marker("ok: " .. label)
    else
        self.fails = self.fails + 1
        marker("FAIL: " .. label
               .. (detail ~= nil and (" -- " .. tostring(detail)) or ""))
    end
    return cond
end

function Probe:_finish(code)
    if self.finished then return end
    self.finished = true
    UIManager:nextTick(function() UIManager:quit(code) end)
end

function Probe:_abort(msg)
    marker("FAIL: " .. tostring(msg))
    marker("result:fail")
    self:_finish(1)
end

function Probe:_resume()
    if self.finished then return end
    local ok, err = coroutine.resume(self.co)
    if not ok then
        self:_abort("script error: " .. debug.traceback(self.co, err))
    end
end

function Probe:window()
    for w in UIManager:topdown_widgets_iter() do
        if w.name == "notebook_window" then return w end
    end
end

function Probe:shot(name)
    UIManager:forceRePaint()
    self.shot_n = self.shot_n + 1
    local path = string.format("%s/r%d-%02d-%s.png", SHOTS, ROTATION,
                               self.shot_n, name)
    Screen:shot(path)
    local size = lfs.attributes(path, "size")
    self:check(size and size > 0, "screenshot written: " .. name, path)
    marker("shot:" .. path)
    return path
end

local function gray(bb, x, y)
    return bb:getPixel(x, y):getColor8().a
end

-- Dark pixels in logical column x of Screen.bb between y0 and y1.
local function dark_run(x, y0, y1)
    local n = 0
    for y = round(y0), round(y1) do
        if gray(Screen.bb, round(x), y) < 96 then n = n + 1 end
    end
    return n
end

-- Dark pixels in the page buffer (physical, rotation 0) under the same
-- logical column.
local function page_dark_run(page, x, y0, y1)
    local n = 0
    for y = round(y0), round(y1) do
        local px, py = physical(x, y)
        if gray(page, px, py) < 96 then n = n + 1 end
    end
    return n
end

-- Dark pixels on a coarse grid over the whole logical screen.
local function screen_dark(step)
    local n = 0
    for y = 0, Screen:getHeight() - 1, step do
        for x = 0, Screen:getWidth() - 1, step do
            if gray(Screen.bb, x, y) < 96 then n = n + 1 end
        end
    end
    return n
end

-- Screen pixels inside logical rect r that differ from the page buffer
-- beneath them, on a 3 px grid: where the screen shows the page.
local function screen_vs_page(page, r)
    local n = 0
    for y = r.y, r.y + r.h - 1, 3 do
        for x = r.x, r.x + r.w - 1, 3 do
            local px, py = physical(x, y)
            if math.abs(gray(Screen.bb, x, y) - gray(page, px, py)) > 8 then
                n = n + 1
            end
        end
    end
    return n
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function count(s, pat)
    local n = 0
    for _ in (s or ""):gmatch(pat) do n = n + 1 end
    return n
end

local function panel_item(win, id)
    local L = win.panel_L
    if not L then return nil end
    for _, it in ipairs(L.items) do
        if it.id == id then return it end
    end
end

-- A finger held still past nb_config.longpress_us (700 ms), then lifted.
function Probe:long_press(lx, ly)
    touch_down(lx, ly)
    drain(0.9)
    touch_up(0)
    drain()
end

function Probe:tap_item(win, id)
    local it = panel_item(win, id)
    if not self:check(it ~= nil, "panel shows item " .. id) then return end
    tap(it.x + it.w / 2, it.y + it.h / 2)
    drain()
end

-- A checked button is painted inverted (black background), an unchecked
-- one white: sample inside its border.
function Probe:item_dark(win, id)
    local it = panel_item(win, id)
    if not it then return nil end
    return gray(Screen.bb, it.x + 6, it.y + 6) < 96
end

function Probe:last_arm()
    for i = #shim.ioctls, 1, -1 do
        local rec = shim.ioctls[i]
        if #rec.rects > 0 then return rec, i end
    end
end

-- Open the notebook through the real ReaderMenu/TouchMenu path.
function Probe:open_through_menu()
    local reader_menu = self.ui.menu
    if not reader_menu.tab_item_table then reader_menu:setUpdateItemTable() end
    local function find(items, path)
        for _, it in ipairs(items or {}) do
            if it.id == "notebook" then
                path[#path + 1] = it
                return true
            end
            if it.sub_item_table then
                path[#path + 1] = it
                if find(it.sub_item_table, path) then return true end
                path[#path] = nil
            end
        end
    end
    local tab_index, path
    for i, tab in ipairs(reader_menu.tab_item_table) do
        local p = {}
        if find(tab, p) then
            tab_index, path = i, p
            break
        end
    end
    if not self:check(tab_index ~= nil, "Notebook is in the reader's main menu") then
        return
    end
    reader_menu:onShowMenu(tab_index)
    local touch_menu = reader_menu.menu_container and reader_menu.menu_container[1]
    if not self:check(touch_menu and touch_menu.onMenuSelect,
                      "the real TouchMenu is shown") then return end
    for _, it in ipairs(path) do touch_menu:onMenuSelect(it) end
    local new_item
    for _, it in ipairs(touch_menu.item_table or {}) do
        if it.text == "New notebook" then new_item = it end
    end
    if not self:check(new_item ~= nil, "the Notebook submenu offers New notebook") then
        return
    end
    touch_menu:onMenuSelect(new_item)
end

function Probe:dismiss_startup_overlays()
    local closed = 0
    for _ = 1, 4 do
        local top
        for w in UIManager:topdown_widgets_iter() do
            if not (w.invisible or w.toast) then
                top = w
                break
            end
        end
        if top == nil or top == self.dialog or top.covers_fullscreen then break end
        if not EXPECTED_OVERLAYS[top.text] then
            return self:_abort("unexpected startup overlay: " .. tostring(top.text))
        end
        UIManager:close(top)
        closed = closed + 1
    end
    marker("note: startup overlays dismissed: " .. closed)
    return true
end

function Probe:script()
    local ui = self.ui
    local root = ROOT .. "/data/notebooks"
    -- The fake data partition (run-real-ui-test.sh writes the mountinfo).
    local Config = require("nb_config")
    Config.notebooks_root = root
    local nbplugin = ui.notebook
    if not self:check(nbplugin ~= nil and nbplugin.launch ~= nil,
                      "ReaderUI instantiated the notebook plugin") then return end
    self:check(tostring(nbplugin.path):sub(1, #KO_HOME) == KO_HOME,
               "the notebook plugin is the KO_HOME (working-tree) copy",
               nbplugin.path)
    nbplugin.MOUNTINFO = ROOT .. "/mountinfo"
    local washer = ui.idlewasher
    local charges = 0
    if self:check(washer ~= nil and type(washer.chargePageTurn) == "function",
                  "the working-tree idle washer (chargePageTurn) is loaded",
                  washer and washer.path) then
        local charge = washer.chargePageTurn
        washer.chargePageTurn = function(w, ...)
            charges = charges + 1
            return charge(w, ...)
        end
    end

    -- Every event KOReader itself dispatches while the notebook is up is
    -- counted: consumed input must never become a Gesture.
    local open = false
    local gestures, input_hooks = 0, 0
    local handle = UIManager.handleInputEvent
    UIManager.handleInputEvent = function(this, event)
        if open and event and event.handler == "onGesture" then
            gestures = gestures + 1
        end
        return handle(this, event)
    end
    UIManager.event_hook:register("InputEvent", function()
        input_hooks = input_hooks + 1
    end)

    self:check(Screen:getRotationMode() == ROTATION,
               "KOReader runs in rotation mode " .. ROTATION,
               Screen:getRotationMode())
    local reader_page = ui:getCurrentPage()
    local lw, lh = Screen:getWidth(), Screen:getHeight()
    marker(string.format("note: logical %dx%d, physical %dx%d, bb rotation %d",
                         lw, lh, shim.W, shim.H, Screen.bb:getRotation()))
    self:shot("reader")

    -- Open ---------------------------------------------------------------
    local n_ioctl = #shim.ioctls
    self:open_through_menu()
    for _ = 1, 50 do
        if self:window() then break end
        wait(0.05)
    end
    local win = self:window()
    if not self:check(win ~= nil, "New notebook opens the notebook window") then
        return
    end
    open = true
    wait(0.3)
    self:check(UIManager:getTopmostVisibleWidget() == win,
               "the notebook window is topmost")
    self:check(input.wilkbook_consumer ~= nil and input.wilkbook_hold_rotation ~= nil,
               "the window installed the consumer and the rotation hold")
    local reset_seen = false
    for i = n_ioctl + 1, #shim.ioctls do
        local rec = shim.ioctls[i]
        if #rec.rects == 0 and rec.set_default == 1 and rec.default_hint == 32 then
            reset_seen = true
        end
    end
    self:check(reset_seen, "the open reset the hint plane to GL16 (0x20)")
    local id = win.session.id
    local page_path = root .. "/" .. id .. "/page-0.jsonl"
    self:check(screen_dark(4) == 0, "the new page is blank on screen")
    self:shot("open-blank")

    -- Stroke A: fine --------------------------------------------------------
    local pubs = shim.publishes
    local hooks = input_hooks
    local yA = 0.12 * lh
    pen_stroke(wave(0.08 * lw, 0.92 * lw, yA, 18, 80,
                    function() return 2700 end), "pen")
    drain()
    local runA = dark_run(lw / 2, yA - 40, yA + 40)
    self:check(runA > 0, "stroke A (fine) is ink on the framebuffer", runA)
    self:check(page_dark_run(win.page_bb, lw / 2, yA - 40, yA + 40) == runA,
               "stroke A is in the page buffer at the same physical pixels")
    self:check(shim.publishes - pubs >= 70, "ink published once per drawing report",
               shim.publishes - pubs)
    self:check(input_hooks > hooks, "pen use reached the InputEvent hook (activity)",
               input_hooks - hooks)
    local arm = self:last_arm()
    self:check(arm and #arm.rects == 1 and arm.rects[1].x == 0 and arm.rects[1].y == 0
               and arm.rects[1].w == shim.W and arm.rects[1].h == shim.H
               and arm.rects[1].hint == 0,
               "the pen armed DU (0x00) over the whole physical panel",
               arm and #arm.rects)
    local body = read_file(page_path)
    self:check(count(body, "\n") == 1 and body:find('"brush":"fine"', 1, true),
               "one fine stroke record on disk after proximity-out", body)
    self:shot("stroke-fine")

    -- Long press: the panel ------------------------------------------------
    local n_before = #shim.ioctls
    self:long_press(0.5 * lw, 0.75 * lh)
    self:check(win.panel_L ~= nil, "a long press opens the panel")
    local disarmed = false
    for i = n_before + 1, #shim.ioctls do
        if #shim.ioctls[i].rects == 0 then disarmed = true end
    end
    self:check(disarmed and not Device.hint_owner:is_armed(),
               "the panel's paint was preceded by a disarm")
    self:check(self:item_dark(win, "brush:fine") == true
               and self:item_dark(win, "brush:marker") == false,
               "the checked brush (fine) is painted inverted, the others not")
    self:shot("panel-open")

    -- Tap Marker, Close ------------------------------------------------------
    self:tap_item(win, "brush:marker")
    self:check(panel_item(win, "brush:marker") and panel_item(win, "brush:marker").checked,
               "tapping Marker checks it in the panel")
    self:check(self:item_dark(win, "brush:marker") == true
               and self:item_dark(win, "brush:fine") == false,
               "Marker is now painted checked and Fine unchecked")
    local prefs = read_file(root .. "/prefs.json")
    self:check(prefs and prefs:find('"brush":"marker"', 1, true), "prefs.json holds marker",
               prefs)
    self:shot("panel-marker")
    self:tap_item(win, "close")
    self:check(win.panel_L == nil, "Close hides the panel")
    self:shot("panel-closed")

    -- Stroke B: marker -------------------------------------------------------
    local yB = 0.22 * lh
    pen_stroke(wave(0.08 * lw, 0.92 * lw, yB, 18, 80,
                    function() return 2700 end), "pen")
    drain()
    local runB = dark_run(lw / 2, yB - 60, yB + 60)
    self:check(runB > runA, "the marker stroke is wider than the fine one",
               string.format("fine %d px, marker %d px", runA, runB))
    self:shot("stroke-marker")

    -- Brush pen through the panel, closed by a flick -------------------------
    self:long_press(0.5 * lw, 0.75 * lh)
    self:tap_item(win, "brush:brushpen")
    local L = win.panel_L
    if self:check(L ~= nil, "the panel is open for the flick") then
        -- Land on the panel's bottom padding (no button, not the title
        -- bar, so nothing drags), then 8 moves of 60 px up the panel 12 ms
        -- apart: ~5000 px/s, over flick_min_px_per_s even at twice the
        -- step time.
        local fx, fy = L.x + L.w / 2, L.y + L.h - 6
        swipe(fx, fy, fx, fy - 480, 8, 12)
        drain()
        self:check(win.panel_L == nil, "a flick closes the panel")
    end
    local yC = 0.32 * lh
    pen_stroke(wave(0.08 * lw, 0.92 * lw, yC, 0, 80,
                    function(f) return 300 + 3795 * math.sin(f * math.pi) end), "pen")
    drain()
    local c_end = dark_run(0.12 * lw, yC - 60, yC + 60)
    local c_mid = dark_run(0.5 * lw, yC - 60, yC + 60)
    self:check(c_mid > c_end and c_end > 0,
               "the brush pen's width follows pressure (light ends, heavy middle)",
               string.format("end %d px, middle %d px", c_end, c_mid))
    self:shot("stroke-brushpen")

    -- Pencil, three reports per input batch ----------------------------------
    self:long_press(0.5 * lw, 0.75 * lh)
    self:tap_item(win, "brush:pencil")
    self:tap_item(win, "close")
    self:check(win.panel_L == nil, "Close hides the panel again")
    local yD = 0.42 * lh
    pen_stroke(wave(0.08 * lw, 0.92 * lw, yD, 18, 80,
                    function() return 2700 end), "pen", 3)
    drain()
    self:check(dark_run(lw / 2, yD - 60, yD + 60) > 0, "the pencil stroke is ink")
    self:shot("stroke-pencil")

    -- Ink under the open panel -------------------------------------------------
    local yE = 0.62 * lh
    self:long_press(0.5 * lw, yE)
    L = win.panel_L
    if self:check(L ~= nil, "the panel is open over the next stroke's path") then
        local row = {}
        for x = L.x, L.x + L.w - 1 do row[#row + 1] = gray(Screen.bb, x, round(yE)) end
        pen_stroke(wave(0.05 * lw, 0.95 * lw, yE, 0, 90,
                        function() return 2700 end), "pen")
        -- Straight after the pen leaves, a finger is a palm: this Close
        -- lands inside palm_grace_us and must be ignored.
        drain(0.05)
        local close = panel_item(win, "close")
        tap(close.x + close.w / 2, close.y + close.h / 2, true)
        drain()
        self:check(win.panel_L ~= nil,
                   "a tap within the palm grace after the pen left is ignored")
        local same = true
        for i, x in ipairs(row) do
            if gray(Screen.bb, L.x + i - 1, round(yE)) ~= x then same = false end
        end
        self:check(same, "ink under the open panel leaves the panel's pixels alone")
        self:check(dark_run(L.x - 20, yE - 30, yE + 30) > 0,
                   "the stroke is ink beside the panel")
        local px, py = physical(L.x + L.w / 2, yE)
        self:check(gray(win.page_bb, px, py) < 96,
                   "the page buffer holds the stroke under the panel")
        arm = self:last_arm()
        local bx, by, bw, bh = Screen.bb:getBoundedRect(L.x, L.y, L.w, L.h)
        local ppx, ppy, ppw, pph = Screen.bb:getPhysicalRect(bx, by, bw, bh)
        local r2 = arm and arm.rects[2]
        self:check(r2 and r2.hint == 0x20 and r2.x == ppx and r2.y == ppy
                   and r2.w == ppw and r2.h == pph,
                   "the arm under the panel adds its physical rect at GL16 (0x20)",
                   r2 and string.format("%d,%d %dx%d vs %d,%d %dx%d", r2.x, r2.y,
                                        r2.w, r2.h, ppx, ppy, ppw, pph))
        self:shot("ink-under-panel")
        self:tap_item(win, "close")
        self:check(win.panel_L == nil, "Close hides the panel once the grace has passed")
        local stale = screen_vs_page(win.page_bb, L)
        self:check(stale == 0 and dark_run(L.x + L.w / 2, yE - 30, yE + 30) > 0,
                   "where the panel was, the screen shows the page, ink included",
                   stale .. " sampled pixels differ")
        self:shot("panel-closed-ink-revealed")
    end

    -- The rubber end: an area erase across stroke A --------------------------
    wait(0.3)
    local xR = 0.5 * lw
    local rub = {}
    for i = 0, 30 do
        rub[#rub + 1] = { xR + 6 * math.sin(i / 3), yA - 60 + 4 * i, 500 }
    end
    pen_stroke(rub, "rubber")
    drain()
    self:check(dark_run(xR, yA - 40, yA + 40) == 0,
               "the rubber end erased stroke A where it crossed",
               dark_run(xR, yA - 40, yA + 40))
    self:shot("rubber-erase")

    -- Undo: three fingers swiping left ----------------------------------------
    multi_swipe({ { 0.75 * lw, 0.5 * lh }, { 0.75 * lw, 0.6 * lh },
                  { 0.75 * lw, 0.7 * lh } }, -0.4 * lw, 0, 8, 40)
    drain()
    self:check(dark_run(xR, yA - 40, yA + 40) == runA,
               "a three-finger left swipe undid the erase",
               dark_run(xR, yA - 40, yA + 40))
    body = read_file(page_path)
    self:check(count(body, '"k":"s"') == 6 and count(body, '"k":"u"') == 1
               and count(body, '"tool":"eraser"') == 1,
               "the page file holds five pen strokes, one erase and one undo",
               body and string.format("s=%d u=%d eraser=%d", count(body, '"k":"s"'),
                                      count(body, '"k":"u"'),
                                      count(body, '"tool":"eraser"')))
    self:shot("undo")

    -- Page turns ---------------------------------------------------------------
    local live = ffi.string(win.page_bb.data, win.page_bb.stride * win.page_bb.h)
    swipe(0.85 * lw, 0.88 * lh, 0.15 * lw, 0.88 * lh, 10, 25)
    drain()
    self:check(win.c.page_n == 1, "a left swipe turns to page 1", win.c.page_n)
    self:check(screen_dark(4) == 0, "page 1 is blank on screen", screen_dark(4))
    self:check(charges == 1, "the turn charged the idle washer once", charges)
    self:shot("page-1")
    wait(0.1)
    swipe(0.15 * lw, 0.88 * lh, 0.85 * lw, 0.88 * lh, 10, 25)
    drain()
    self:check(win.c.page_n == 0, "a right swipe turns back to page 0", win.c.page_n)
    local replayed = ffi.string(win.page_bb.data, win.page_bb.stride * win.page_bb.h)
    local differ = 0
    if replayed ~= live then
        for i = 1, #live do
            if live:byte(i) ~= replayed:byte(i) then differ = differ + 1 end
        end
    end
    self:check(differ == 0,
               "page 0 re-rendered from its journal equals the live ink, byte for byte",
               differ .. " bytes differ")
    self:check(charges == 2, "each turn charged the washer", charges)
    self:shot("page-0-from-disk")
    local page_png = string.format("%s/r%d-page0-physical.png", SHOTS, ROTATION)
    local ok_png, png_err = require("nb_surface").write_png(win.page_bb, page_png)
    self:check(ok_png, "the physical page buffer PNG is written", png_err)
    marker("shot:" .. page_png)

    -- Rotation: held while the pen is in range, applied at proximity-out ----
    local other = ROTATION == 1 and 0 or 1
    local before_rot = ffi.string(win.page_bb.data, win.page_bb.stride * win.page_bb.h)
    pen_hover_in(0.5 * lw, 0.5 * lh)
    drain(0.1)
    gyro(other)
    drain()
    self:check(Screen:getRotationMode() == ROTATION,
               "a rotation while the pen hovers is held", Screen:getRotationMode())
    pen_hover_out()
    drain(0.5)
    self:check(Screen:getRotationMode() == other,
               "the held rotation is applied at proximity-out", Screen:getRotationMode())
    self:check(self:window() == win and win.c.mode == other,
               "the notebook stays open and its controller took the new mode",
               win.c.mode)
    self:check(ffi.string(win.page_bb.data, win.page_bb.stride * win.page_bb.h)
               == before_rot, "the physical page is untouched by the rotation")
    local rw, rh = Screen:getWidth(), Screen:getHeight()
    self:check(win.dimen.w == rw and win.dimen.h == rh,
               "the window re-sized to the rotated screen",
               string.format("%dx%d vs %dx%d", win.dimen.w, win.dimen.h, rw, rh))
    -- ReaderView:rotate's Notification carries no source, so it is not
    -- shown (notification.lua notify): nothing covers the notebook here.
    self:check(screen_vs_page(win.page_bb, { x = 0, y = 0, w = rw, h = rh }) == 0,
               "the rotated screen shows the physical page")
    -- Ink in the new orientation.
    local yF = 0.78 * rh
    pen_stroke(wave(0.1 * rw, 0.9 * rw, yF, 0, 60, function() return 2700 end), "pen")
    drain()
    local runF = dark_run(rw / 2, yF - 30, yF + 30)
    self:check(runF > 0 and page_dark_run(win.page_bb, rw / 2, yF - 30, yF + 30) == runF,
               "ink after the rotation lands under the pen in the new orientation", runF)
    self:shot("rotated")
    gyro(ROTATION)
    drain(0.5)
    self:check(Screen:getRotationMode() == ROTATION,
               "with the pen away, a rotation is applied at once", Screen:getRotationMode())
    self:check(screen_vs_page(win.page_bb, { x = 0, y = 0, w = lw, h = lh }) == 0,
               "rotated back, the screen shows the physical page")
    self:shot("rotated-back")

    self:check(gestures == 0, "no injected touch reached KOReader as a Gesture",
               gestures)

    -- The open list: a real Menu over the notebook takes touch ----------------
    self:long_press(0.5 * lw, 0.75 * lh)
    self:tap_item(win, "nb:open")
    local menu = UIManager:getTopmostVisibleWidget()
    if self:check(menu and menu ~= win and menu.item_table and #menu.item_table == 1,
                  "Open shows the real notebook Menu over the notebook") then
        UIManager:forceRePaint()
        local entry = menu.item_group and menu.item_group[1]
        local d = entry and entry.dimen
        self:shot("open-list")
        if self:check(d and d.w > 0 and d.h > 0, "the Menu painted its entry") then
            -- Through KOReader's own gesture detector: the tap's lift, then
            -- its double-tap window.
            local before = gestures
            tap(d.x + d.w / 2, d.y + d.h / 2)
            drain(0.8)
            self:check(gestures > before,
                       "with the Menu on top, touch reaches KOReader as a Gesture",
                       gestures - before)
            self:check(not UIManager:isWidgetShown(menu)
                       and UIManager:getTopmostVisibleWidget() == win,
                       "choosing the open notebook closes the Menu, the notebook stays")
        end
    end
    self:check(win.panel_L ~= nil, "the panel is still open under the Menu")

    -- Exit ---------------------------------------------------------------------
    local g_exit = gestures
    self:tap_item(win, "nb:close")
    wait(0.3)
    self:check(gestures == g_exit,
               "with the Menu gone, touch went back to the notebook (Exit was its tap)",
               gestures - g_exit)
    open = false
    self:check(self:window() == nil, "Exit closes the notebook window")
    self:check(input.wilkbook_consumer == nil and input.wilkbook_hold_rotation == nil,
               "closing removed the consumer and the rotation hold")
    self:check(not Device.hint_owner:is_armed(), "closing left the hint plane disarmed")
    local bad_submit
    for i, rec in ipairs(shim.ioctls) do
        if rec.request ~= DRM_RECT_HINTS or rec.set_default ~= 1
           or rec.default_hint ~= 32 then
            bad_submit = bad_submit or i
        end
    end
    self:check(bad_submit == nil,
               "every submit was RECT_HINTS with the plane default GL16 (0x20)",
               bad_submit)
    self:check(ui:getCurrentPage() == reader_page,
               "the book beneath never turned", ui:getCurrentPage())
    prefs = read_file(root .. "/prefs.json")
    self:check(prefs and prefs:find('"brush":"pencil"', 1, true)
               and prefs:find(id, 1, true),
               "prefs.json keeps the last brush and the notebook", prefs)
    self:shot("closed-reader")
    marker(string.format("note: %d batches injected, %d publishes, %d refreshes,"
                         .. " %d RECT_HINTS submits", shim.served, shim.publishes,
                         shim.refreshes, #shim.ioctls))
end

function Probe:onReaderReady()
    if shim.error then return self:_abort("shim: " .. shim.error) end
    resume_script = function() self:_resume() end
    UIManager:scheduleIn(60, function()
        if not self.finished then self:_abort("global deadline (60 s) expired") end
    end)
    UIManager:nextTick(function()
        if not self:dismiss_startup_overlays() then return end
        self.co = coroutine.create(function()
            self:script()
            marker(string.format("note: %d checks passed, %d failed",
                                 self.oks, self.fails))
            marker(self.fails == 0 and "result:ok" or "result:fail")
            self:_finish(self.fails == 0 and 0 or 1)
        end)
        self:_resume()
    end)
end

return Probe
