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
  * the refresh layer as device.lua shapes it: every refresh*Imp it
    overrides is a leaf that runs the guard, here recording its mode and
    ending in the SDL framebuffer's one real refresh, refreshFullImp;
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

The panel's repaints (open, a selection change by finger and by pen, a
drag step, Close, a flick, Refresh by finger and by pen) run under a paint
audit: every setDirty the window makes, every refresh with its mode and
region, every publish, every RECT_HINTS arm and disarm, and the
framebuffer after each page and panel blit and at each refresh.  Each must be one refresh, inside the panel's rect (or the old
and new rects of a drag step), with no pixel ever holding a value that
is neither its old nor its new one: on the PineNote a deferred-io flush
can copy the framebuffer at any of those moments, and the driver shows
what it copied (the generation-22 selection flicker).  Each audit prints
a "note: repaint:" line.

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
    modes = {},       -- refreshes by mode
    served = 0,       -- injected batches returned by waitForEvent
    pen_out_t = nil,  -- realtime us of the last served proximity-out
    pen_out_mono = nil, -- and its monotonic time, the audit's clock
}
local queue = {}      -- { delay_us, due, events }

-- The paint audit (Probe:audit): while it is set, every setDirty on the
-- notebook window, every paint of it, every refresh and every RECT_HINTS
-- submit is recorded in order.
local audit

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
    if audit then
        audit.events[#audit.events + 1] = { k = n > 0 and "arm" or "disarm" }
    end
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
        if audit then
            audit.events[#audit.events + 1] = { k = "publish", t = time.monotonic() }
        end
        return true
    end
    local full_imp = Screen.refreshFullImp
    local IMPS = { refreshPartialImp = "partial", refreshUIImp = "ui",
                   refreshFastImp = "fast", refreshA2Imp = "a2",
                   refreshFlashUIImp = "flashui",
                   refreshFlashPartialImp = "flashpartial", refreshFullImp = "full" }
    for name, mode in pairs(IMPS) do
        Screen[name] = function(this, x, y, w, h, d)
            shim.refreshes = shim.refreshes + 1
            shim.modes[mode] = (shim.modes[mode] or 0) + 1
            owner:guard(x, y, w, h)
            if audit then audit:on_refresh(x, y, w, h, mode) end
            return full_imp(this, x, y, w, h, d)
        end
    end
    -- The notebook window's setDirty calls, and the refresh-only ones
    -- (no widget) it makes for a region it painted in place.
    local set_dirty = UIManager.setDirty
    UIManager.setDirty = function(this, widget, mode, region, dither)
        local own = type(widget) == "table" and widget.name == "notebook_window"
        if audit and (own or (widget == nil and type(mode) == "string")) then
            audit.events[#audit.events + 1] = {
                k = own and "dirty" or "refresh_only", mode = mode,
                region = region and { x = region.x, y = region.y,
                                      w = region.w, h = region.h },
            }
        end
        return set_dirty(this, widget, mode, region, dither)
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
                        shim.pen_out_mono = time.monotonic()
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

-- A tap of the pen tip at logical (lx, ly) that leaves the pen hovering:
-- proximity in, BTN_TOUCH:1 then :0 3 ms apart, a hover report.
local function pen_tap_hover(lx, ly)
    local x, y = pen_raw(lx, ly)
    local syn = function() return ev(PEN, EV_SYN, SYN_REPORT, 0) end
    enqueue(0, { ev(PEN, EV_KEY, BTN_TOOL_PEN, 1), ev(PEN, EV_ABS, ABS_X, x),
                 ev(PEN, EV_ABS, ABS_Y, y + 60), ev(PEN, EV_ABS, ABS_PRESSURE, 0), syn() })
    enqueue(3, { ev(PEN, EV_ABS, ABS_Y, y), syn() })
    enqueue(3, { ev(PEN, EV_KEY, BTN_TOUCH, 1), ev(PEN, EV_ABS, ABS_PRESSURE, 2700), syn() })
    enqueue(3, { ev(PEN, EV_KEY, BTN_TOUCH, 0), ev(PEN, EV_ABS, ABS_PRESSURE, 0), syn() })
    enqueue(3, { ev(PEN, EV_ABS, ABS_Y, y + 60), syn() })
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
-- The paint audit
------------------------------------------------------------------------

-- On the PineNote the driver copies whatever the framebuffer holds when a
-- deferred-io flush runs: at the refresh's publish, or at the 250 ms
-- deferred-io timer, which starts at the first write after the last flush
-- and so can fire in the middle of a paint.  A pixel that holds a value
-- during the paint that is neither its value before nor its value after
-- can therefore reach the glass and be taken back by the next flush.  The
-- audit snapshots the framebuffer at each stage of the notebook's paint and
-- at each refresh, and counts such pixels.

local U16P = ffi.typeof("const uint16_t *")

-- The framebuffer's memory, rotation-free.
local function fb_bytes()
    local bb = Screen.bb
    return ffi.string(bb.data, tonumber(bb.stride) * bb.h)
end

local Audit = {}
Audit.__index = Audit

function Audit:snap(label)
    self.snaps[#self.snaps + 1] = { label = label, bytes = fb_bytes(),
                                    t = time.monotonic() }
    return #self.snaps
end

function Audit:on_refresh(x, y, w, h, mode)
    local snap = self:snap("refresh")
    self.events[#self.events + 1] = { k = "refresh", mode = mode, x = x, y = y,
                                      w = w, h = h, snap = snap,
                                      t = self.snaps[snap].t }
end

-- third: pixels in the snapshot that are neither before nor final;
-- off: pixels that differ from final.  box: the physical bounding box of
-- the pixels before and final disagree on.
local function compare(before, snap, final)
    local bb = Screen.bb
    local n = tonumber(bb.stride) / 2 * bb.h
    local pb, ps, pf = ffi.cast(U16P, before), ffi.cast(U16P, snap),
                       ffi.cast(U16P, final)
    local third, off = 0, 0
    for i = 0, n - 1 do
        local s, f = ps[i], pf[i]
        if s ~= f then
            off = off + 1
            if s ~= pb[i] then third = third + 1 end
        end
    end
    return third, off
end

local function changed_box(before, final)
    local bb = Screen.bb
    local row = tonumber(bb.stride) / 2
    local pb, pf = ffi.cast(U16P, before), ffi.cast(U16P, final)
    local x0, y0, x1, y1
    for y = 0, bb.h - 1 do
        local base = y * row
        for x = 0, bb.w - 1 do
            if pb[base + x] ~= pf[base + x] then
                if not x0 or x < x0 then x0 = x end
                if not x1 or x > x1 then x1 = x end
                if not y0 then y0 = y end
                y1 = y
            end
        end
    end
    if not x0 then return nil end
    return { x = x0, y = y0, w = x1 - x0 + 1, h = y1 - y0 + 1 }
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

-- Run action() under the paint audit.  Returns the audit: events (dirty,
-- refresh_only, paint, refresh, arm, disarm, in order), snaps with
-- third/off counts against the state before and after, and box, what
-- changed (physical).  A snap is taken after every page and panel blit,
-- at the first panel item a paint builds (the generation-22 paint drew
-- the panel straight onto the screen, item by item), at the end of a
-- whole-window paint and at every refresh.
function Probe:audit(win, action)
    UIManager:forceRePaint()
    local a = setmetatable({ events = {}, snaps = {}, before = fb_bytes() }, Audit)
    local Surface = require("nb_surface")
    local blit_page, blit_panel = Surface.blit_page, Surface.blit_panel
    Surface.blit_page = function(target, ...)
        -- Observe individual destination writes too: a Surface-level
        -- snapshot alone missed the old copy-then-invert night-mode path.
        local proxy = setmetatable({}, { __index = function(_, key)
            local value = target[key]
            if type(value) ~= "function" then return value end
            return function(_, ...)
                local result = value(target, ...)
                if key == "blitFrom" or key == "invertblitFrom" or key == "invertRect" then
                    a:snap(key)
                end
                return result
            end
        end })
        blit_page(proxy, ...)
        a:snap("page")
    end
    Surface.blit_panel = function(...)
        blit_panel(...)
        a:snap("panel")
    end
    -- Instance fields over the class methods, removed afterwards.
    local paint_to, item_widget = win.paintTo, win._item_widget
    win.paintTo = function(this, ...)
        local ev = { k = "paint" }
        a.events[#a.events + 1] = ev
        a.first_item = true
        local t0 = time.monotonic()
        paint_to(this, ...)
        ev.us = time.monotonic() - t0
        ev.snap = a:snap("painted")
    end
    win._item_widget = function(this, ...)
        if a.first_item then
            a.first_item = false
            a:snap("item")
        end
        return item_widget(this, ...)
    end
    audit = a
    local ok, err = pcall(action)
    audit = nil
    Surface.blit_page, Surface.blit_panel = blit_page, blit_panel
    win.paintTo, win._item_widget = nil, nil
    if not ok then error(err, 0) end
    a.final = fb_bytes()
    for _, s in ipairs(a.snaps) do
        s.third, s.off = compare(a.before, s.bytes, a.final)
        s.bytes = nil
    end
    a.box = changed_box(a.before, a.final)
    a.before, a.final = nil, nil
    return a
end

function Audit:describe()
    local parts = {}
    for _, e in ipairs(self.events) do
        if e.k == "dirty" or e.k == "refresh_only" then
            local r = e.region
            parts[#parts + 1] = string.format("%s(%s %s)", e.k, tostring(e.mode),
                r and string.format("%d,%d %dx%d", r.x, r.y, r.w, r.h) or "all")
        elseif e.k == "paint" then
            local s = self.snaps[e.snap]
            parts[#parts + 1] = string.format("paint(%.1fms third=%d off=%d)",
                                              e.us / 1000, s.third, s.off)
        elseif e.k == "refresh" then
            local s = self.snaps[e.snap]
            parts[#parts + 1] = string.format("refresh:%s(%d,%d %dx%d third=%d off=%d)",
                                              tostring(e.mode), e.x, e.y, e.w, e.h,
                                              s.third, s.off)
        else
            parts[#parts + 1] = e.k
        end
    end
    local stages = {}
    for _, s in ipairs(self.snaps) do
        if s.label ~= "refresh" and s.label ~= "painted" then
            stages[#stages + 1] = string.format("%s third=%d", s.label, s.third)
        end
    end
    local b = self.box
    return table.concat(parts, " ") .. " | stages: " .. table.concat(stages, ", ")
        .. " | changed: " .. (b and string.format("%d,%d %dx%d", b.x, b.y, b.w, b.h)
                              or "nothing")
end

-- Events of kind k (and, for a refresh, of mode `mode`).
function Audit:count(k, mode)
    local n = 0
    for _, e in ipairs(self.events) do
        if e.k == k and (mode == nil or e.mode == mode) then n = n + 1 end
    end
    return n
end

-- The first event of kind k (and mode), and its index.
function Audit:first(k, mode)
    for i, e in ipairs(self.events) do
        if e.k == k and (mode == nil or e.mode == mode) then return e, i end
    end
end

-- The clean repaint: exactly one refresh, inside region (logical), the
-- framebuffer at it the end state; no pixel at any snap through a value
-- that is neither its old nor its new one; no whole-window paint; and,
-- when changed (physical) is given, nothing changed outside it.
function Probe:check_repaint(a, label, region, changed)
    local ok, refresh = a:count("refresh") == 1 and a:count("paint") == 0, nil
    for _, e in ipairs(a.events) do
        if e.k == "refresh" then refresh = e end
    end
    if refresh then
        local s = a.snaps[refresh.snap]
        ok = ok and s.off == 0 and refresh.x >= region.x and refresh.y >= region.y
             and refresh.x + refresh.w <= region.x + region.w
             and refresh.y + refresh.h <= region.y + region.h
    end
    for _, s in ipairs(a.snaps) do
        if s.third ~= 0 then ok = false end
    end
    if changed then
        local b = a.box
        ok = ok and b ~= nil and b.x >= changed.x and b.y >= changed.y
             and b.x + b.w <= changed.x + changed.w and b.y + b.h <= changed.y + changed.h
    end
    self:check(ok, label, a:describe())
    marker("note: repaint: " .. a:describe())
    return ok
end

-- A logical rect clipped to the screen.
local function on_screen(r)
    local x0, y0 = math.max(0, r.x), math.max(0, r.y)
    local x1 = math.min(Screen:getWidth(), r.x + r.w)
    local y1 = math.min(Screen:getHeight(), r.y + r.h)
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- The physical bounding box of panel items a and b: where a selection
-- change between them may change pixels.
local function items_box(a, b)
    local r = {}
    for i, it in ipairs({ a, b }) do
        local bx, by, bw, bh = Screen.bb:getBoundedRect(it.x, it.y, it.w, it.h)
        local px, py, pw, ph = Screen.bb:getPhysicalRect(bx, by, bw, bh)
        r[i] = { x = px, y = py, w = pw, h = ph }
    end
    local x0, y0 = math.min(r[1].x, r[2].x), math.min(r[1].y, r[2].y)
    local x1 = math.max(r[1].x + r[1].w, r[2].x + r[2].w)
    local y1 = math.max(r[1].y + r[1].h, r[2].y + r[2].h)
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
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
    local charges, debt = 0, 0
    if self:check(washer ~= nil and type(washer.chargePageTurn) == "function"
                  and type(washer.chargeDebt) == "function",
                  "the working-tree idle washer (chargePageTurn, chargeDebt) is loaded",
                  washer and washer.path) then
        local charge = washer.chargePageTurn
        washer.chargePageTurn = function(w, ...)
            charges = charges + 1
            return charge(w, ...)
        end
        local charge_debt = washer.chargeDebt
        washer.chargeDebt = function(w, n, ...)
            debt = debt + n
            return charge_debt(w, n, ...)
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

    -- Stroke A: the default brush, Ballpoint M -----------------------------
    local pubs = shim.publishes
    local hooks = input_hooks
    local yA = 0.12 * lh
    pen_stroke(wave(0.08 * lw, 0.92 * lw, yA, 18, 80,
                    function() return 2700 end), "pen")
    drain()
    -- At lw / 2 the wave is at a trough, so a column cuts the stroke
    -- square: at 2700, about the median contact pressure, Ballpoint M's
    -- radius is 2.52 px, 5 px across (~0.56 mm), 6 when the sample's
    -- fractional px straddles a row.
    local runA = dark_run(lw / 2, yA - 40, yA + 40)
    self:check(runA >= 5 and runA <= 6,
               "stroke A (the default Ballpoint) is ink ~0.56 mm wide at the median pressure",
               runA)
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
    self:check(count(body, "\n") == 1
               and body:find('"brush":"ballpoint","size":"M"', 1, true),
               "one Ballpoint M stroke record on disk after proximity-out", body)
    self:shot("stroke-ballpoint")

    -- Long press: the panel ------------------------------------------------
    local n_before = #shim.ioctls
    local au_open = self:audit(win, function() self:long_press(0.5 * lw, 0.75 * lh) end)
    self:check(win.panel_L ~= nil, "a long press opens the panel")
    if win.panel_L then
        self:check_repaint(au_open, "panel open: one refresh over the panel, no pixel"
                           .. " through a third value, no whole-window paint",
                           on_screen(win.panel_L))
    end
    local disarmed = false
    for i = n_before + 1, #shim.ioctls do
        if #shim.ioctls[i].rects == 0 then disarmed = true end
    end
    self:check(disarmed and not Device.hint_owner:is_armed(),
               "the panel's paint was preceded by a disarm")
    self:check(self:item_dark(win, "brush:ballpoint") == true
               and self:item_dark(win, "brush:marker") == false,
               "the checked brush (the default Ballpoint) is painted inverted, the others not")
    self:shot("panel-open")

    -- Tap Marker, Close ------------------------------------------------------
    -- The generation-22 flicker: a selection change must be one refresh
    -- inside the panel, with only the two buttons changing.
    local au = self:audit(win, function() self:tap_item(win, "brush:marker") end)
    self:check_repaint(au, "a selection change: one refresh inside the panel, only the"
                       .. " two buttons change, no pixel through a third value",
                       on_screen(win.panel_L),
                       items_box(panel_item(win, "brush:ballpoint"),
                                 panel_item(win, "brush:marker")))
    self:check(panel_item(win, "brush:marker") and panel_item(win, "brush:marker").checked,
               "tapping Marker checks it in the panel")
    self:check(self:item_dark(win, "brush:marker") == true
               and self:item_dark(win, "brush:ballpoint") == false,
               "Marker is now painted checked and Ballpoint unchecked")
    local prefs = read_file(root .. "/prefs.json")
    self:check(prefs and prefs:find('"brush":"marker"', 1, true), "prefs.json holds marker",
               prefs)
    self:shot("panel-marker")
    local closing = on_screen(win.panel_L)
    local au_close = self:audit(win, function() self:tap_item(win, "close") end)
    self:check(win.panel_L == nil, "Close hides the panel")
    self:check_repaint(au_close, "Close: one refresh over the panel, the page back under"
                       .. " it, no pixel through a third value", closing)
    self:check(screen_vs_page(win.page_bb, closing) == 0,
               "where the panel was, the screen shows the page")
    self:check(debt == 1, "Close charged the idle washer one unit of ghost debt", debt)
    self:shot("panel-closed")

    -- Stroke B: marker -------------------------------------------------------
    local yB = 0.22 * lh
    pen_stroke(wave(0.08 * lw, 0.92 * lw, yB, 18, 80,
                    function() return 2700 end), "pen")
    drain()
    local runB = dark_run(lw / 2, yB - 60, yB + 60)
    self:check(runB > runA, "the marker stroke is wider than the ballpoint one",
               string.format("ballpoint %d px, marker %d px", runA, runB))
    self:shot("stroke-marker")

    -- Brush pen through the panel, a drag, closed by a flick ----------------
    self:long_press(0.5 * lw, 0.75 * lh)
    self:tap_item(win, "brush:brushpen")
    local L = win.panel_L
    if self:check(L ~= nil, "the panel is open for the drag and the flick") then
        -- The title bar dragged 40 px past the tap slop, then one more
        -- 40 px step, audited on its own; the finger rests before it lifts,
        -- so the release is no flick.
        local title = panel_item(win, "title")
        local tx, ty = title.x + title.w / 2, title.y + title.h / 2
        touch_down(tx, ty)
        enqueue(40, touch_frame({ { slot = 0, lx = tx - 40, ly = ty } }))
        drain(0.1)
        local old = on_screen(win.panel_L)
        local au_drag = self:audit(win, function()
            enqueue(0, touch_frame({ { slot = 0, lx = tx - 80, ly = ty } }))
            drain(0.1)
        end)
        local new = on_screen(win.panel_L)
        local both = { x = math.min(old.x, new.x), y = math.min(old.y, new.y) }
        both.w = math.max(old.x + old.w, new.x + new.w) - both.x
        both.h = math.max(old.y + old.h, new.y + new.h) - both.y
        self:check(new.x == old.x - 40, "the drag step moved the panel 40 px",
                   string.format("%d -> %d", old.x, new.x))
        self:check_repaint(au_drag, "a drag step: one refresh over the old and new rects,"
                           .. " no pixel through a third value", both)
        touch_up(300)
        drain()
        L = win.panel_L
        self:check(L ~= nil, "a drag that stops before the lift leaves the panel open")
        -- Land on the panel's bottom padding (no button, not the title
        -- bar, so nothing drags), then 8 moves of 60 px up the panel 12 ms
        -- apart: ~5000 px/s, over flick_min_px_per_s even at twice the
        -- step time.
        local fx, fy = L.x + L.w / 2, L.y + L.h - 6
        local flicked = on_screen(L)
        local au_flick = self:audit(win, function()
            swipe(fx, fy, fx, fy - 480, 8, 12)
            drain()
        end)
        self:check(win.panel_L == nil, "a flick closes the panel")
        self:check_repaint(au_flick, "a flick: one refresh over the panel, no pixel"
                           .. " through a third value", flicked)
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

    -- Pencil, chosen with the pen; three reports per input batch ----------
    self:long_press(0.5 * lw, 0.75 * lh)
    do
        local was, it = panel_item(win, "brush:brushpen"), panel_item(win, "brush:pencil")
        local P = on_screen(win.panel_L)
        local pubs0, lines0 = shim.publishes, count(read_file(page_path), "\n")
        local au_pen = self:audit(win, function()
            pen_stroke({ { it.x + it.w / 2, it.y + it.h / 2, 2700 } }, "pen")
            drain()
        end)
        self:check_repaint(au_pen, "a pen tap on Pencil: one refresh inside the panel, only"
                           .. " the two buttons change, no pixel through a third value",
                           P, items_box(was, it))
        self:check(panel_item(win, "brush:pencil").checked
                   and count(read_file(page_path), "\n") == lines0
                   and shim.publishes == pubs0,
                   "the pen's tap chose Pencil, and inked and recorded nothing")
    end
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
    local debt_erase = debt
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
    self:check(debt == debt_erase + 1, "the erase charged one unit, at the pen's leave",
               debt - debt_erase)
    self:shot("rubber-erase")

    -- Undo: two fingers swiping left ------------------------------------------
    multi_swipe({ { 0.75 * lw, 0.5 * lh }, { 0.75 * lw, 0.65 * lh } }, -0.4 * lw, 0, 8, 40)
    drain()
    self:check(dark_run(xR, yA - 40, yA + 40) == runA,
               "a two-finger left swipe undid the erase",
               dark_run(xR, yA - 40, yA + 40))
    self:check(debt == debt_erase + 2, "the undo charged one unit", debt - debt_erase)
    body = read_file(page_path)
    self:check(count(body, '"k":"s"') == 6 and count(body, '"k":"u"') == 1
               and count(body, '"tool":"eraser"') == 1,
               "the page file holds five pen strokes, one erase and one undo",
               body and string.format("s=%d u=%d eraser=%d", count(body, '"k":"s"'),
                                      count(body, '"k":"u"'),
                                      count(body, '"tool":"eraser"')))
    self:shot("undo")

    -- Refresh by finger ------------------------------------------------------
    -- The panel goes and the page is painted where it was (one "ui"
    -- refresh) and published; a settle wait later, one full refresh of the
    -- whole screen that repaints no window, with the plane disarmed.
    self:long_press(0.5 * lw, 0.75 * lh)
    if self:check(win.panel_L ~= nil, "the panel is open for Refresh") then
        local P = on_screen(win.panel_L)
        local debt0 = debt
        local au_ref = self:audit(win, function()
            self:tap_item(win, "refresh")
            wait(0.2)
        end)
        marker("note: refresh: " .. au_ref:describe())
        local pub, ipub = au_ref:first("publish")
        local ui_r, iui = au_ref:first("refresh", "ui")
        local full, ifull = au_ref:first("refresh", "full")
        local W, H = shim.W, shim.H
        self:check(win.panel_L == nil and screen_vs_page(win.page_bb, P) == 0
                   and ui_r ~= nil and au_ref:count("refresh", "ui") == 1
                   and pub ~= nil and ipub < iui,
                   "Refresh by finger: the panel goes, the page painted where it was is"
                   .. " published, then refreshed", au_ref:describe())
        -- The SDL backend takes the rect in the rotated space: compare areas.
        self:check(full ~= nil and au_ref:count("refresh", "full") == 1
                   and ifull > iui and full.x == 0 and full.y == 0
                   and full.w * full.h == W * H and au_ref:count("paint") == 0
                   and au_ref:count("dirty") == 0,
                   "Refresh by finger: then one full refresh of the whole screen, and no"
                   .. " window repainted for it", au_ref:describe())
        self:check(full ~= nil and pub ~= nil and full.t - pub.t >= 150000,
                   "Refresh by finger: the wash comes the settle wait after the publish",
                   full and pub and string.format("%.1f ms", (full.t - pub.t) / 1000))
        self:check(not Device.hint_owner:is_armed() and debt == debt0,
                   "Refresh by finger: the plane is disarmed, and nothing is charged")
    end
    self:shot("refresh-finger")

    -- Refresh by the pen tip: no wash while it hovers, then one a leave and
    -- a settle wait after it goes.
    self:long_press(0.5 * lw, 0.75 * lh)
    local rit = panel_item(win, "refresh")
    if self:check(rit ~= nil, "the panel shows Refresh for the pen") then
        local hovering
        local au_pen_ref = self:audit(win, function()
            pen_tap_hover(rit.x + rit.w / 2, rit.y + rit.h / 2)
            drain(0.4)
            -- `audit` is the audit in progress (Probe:audit sets it).
            hovering = audit:count("refresh", "full")
            pen_hover_out()
            drain(0.6)
        end)
        marker("note: refresh by pen: " .. au_pen_ref:describe())
        local full = au_pen_ref:first("refresh", "full")
        self:check(win.panel_L == nil and hovering == 0,
                   "Refresh by pen: the tap closes the panel, and no wash while the pen hovers",
                   hovering)
        self:check(full ~= nil and au_pen_ref:count("refresh", "full") == 1
                   and shim.pen_out_mono and full.t - shim.pen_out_mono >= 300000,
                   "Refresh by pen: one wash, the leave and a settle wait after the pen went",
                   full and shim.pen_out_mono
                   and string.format("%.1f ms", (full.t - shim.pen_out_mono) / 1000))
    end
    self:shot("refresh-pen")

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

    -- Night-mode page blits must never expose the un-inverted page,
    -- including the bands outside an open panel during a full repaint.
    Screen.bb:setInverse(1)
    self:long_press(0.5 * lw, 0.75 * lh)
    UIManager:setDirty(win, "ui")
    UIManager:forceRePaint()
    local inverted = self:audit(win, function()
        UIManager:setDirty(win, "ui")
        UIManager:forceRePaint()
    end)
    local clean = #inverted.snaps > 0
    for _, snap in ipairs(inverted.snaps) do
        if snap.third > 0 or snap.off > 0 then clean = false end
    end
    self:check(clean, "night mode: unchanged full repaint never exposes un-inverted pixels")
    local closing = on_screen(win.panel_L)
    inverted = self:audit(win, function() self:tap_item(win, "close") end)
    self:check_repaint(inverted, "night mode Close: one-pass inverted page blit", closing)
    Screen.bb:setInverse(0)
    UIManager:setDirty(win, "ui")
    UIManager:forceRePaint()

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
