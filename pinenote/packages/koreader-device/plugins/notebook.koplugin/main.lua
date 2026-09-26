--[[--
notebook -- pen and paper on the PineNote (doc/notebook.md): the KOReader
shell around the notebook's pure modules.

nb_controller decides everything and returns commands; this file runs
them against KOReader, the device and the disk, and owns what only the
shell can know:

  * Input.  device.lua calls input.wilkbook_consumer for every event,
    last in its adjust-hook chain (plugins never register hooks: Input
    cannot unregister one, and a plugin is instantiated per host).  While
    the notebook window is open the consumer takes every pen and pen
    button event, and every touch event unless a foreign widget (a
    dialog, the open list, the screensaver) is on top: KOReader's widgets
    answer only Gesture events, so a dialog over a notebook that kept
    touch could never be dismissed.  Touch changes owner only between
    frames with no finger on the glass, with Input:resetState() and the
    kernel's slot handed to whichever side reads the stream next
    (mixedrouter's setTouchSlot, or the controller's set_touch_slot).  A
    consumed event is rewritten to EV_MSC, which KOReader drops.
  * Ink.  Ink is live only while the window is topmost and the device is
    awake.  It goes into the page buffer and into a rotation-0 alias of
    the framebuffer, and is published with an untraced fsync
    (Device:publishNow).  A foreign refresh disarms the DU rectangle
    behind the controller's back (device.lua's hint owner), so an ink
    command re-arms first when the owner is no longer armed.
  * Failure.  On the first failed append or fsync in a command list the
    rest of the list runs without its writes and ink, then c:io_error
    gets the failed command table (nb_controller's header).
  * UI context.  The consumer runs inside Input:waitEvent.  Showing or
    closing a widget waits for UIManager:nextTick, and so does the
    synthetic InputEvent that tells AutoSuspend and the idle washer the
    pen is in use: UIManager's cached clock is stale inside the hook.
  * Rotation.  While the pen is in range, or a finger it consumes is on
    the glass, the window holds rotation (input.wilkbook_hold_rotation):
    KOReader's own hold counts the gesture detector's contacts, which a
    consumed touch never reaches.  What arrived meanwhile is replayed
    when the last hold ends.  A SetRotationMode reaches only the topmost
    window, so the window forwards it to the reader or file manager
    beneath.

Everything that can be absent off the PineNote (Device.hint_owner,
Device.input_devices, Device.publishNow, the touch-slot pair, the evdev
key and axis queries) is nil-checked, so the plugin loads on the SDL
emulator.  pinenote/tools/koreader-input/test-notebook-plugin.lua drives
this file headless.
--]]

local logger = require("logger")

-- Two copies can coexist (the bundle's and one pushed into KO_HOME for
-- iteration); the first to load claims this and later ones disable
-- themselves, as idlewasher's main.lua does.
if _G.__wilkbook_notebook_loaded then
    logger.info("[notebook] duplicate copy skipped:",
                (debug.getinfo(1, "S") or {}).source)
    return { disabled = true }
end
_G.__wilkbook_notebook_loaded = true

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local time = require("ui/time")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

local Config = require("nb_config")
local Ctl = require("nb_controller")
local Fs = require("nb_fs")
local G = require("nb_geom")
local J = require("nb_journal")
local Surface = require("nb_surface")

local Screen = Device.screen

-- The evdev queries (EVIOCGKEY, EVIOCGABS) are the repo's ffi backend;
-- a build without it still opens notebooks, it just cannot resync.
local ok_evdev, Evdev = pcall(require, "ffi/input_evdev")
if not ok_evdev then Evdev = nil end

-- A rectangle a crashed KOReader left armed would render every paint
-- inside it thresholded; clear it once per process, before anything
-- paints.  Each open resets again (NotebookWindow:_start).  The reset
-- writes back the module's own default_hint (device.lua reads it at
-- init), so it clears rects without changing the reading hint; it does
-- clear any rects a lab set on the running plane.
if Device.hint_owner then Device.hint_owner:reset() end

local EV_SYN, EV_ABS, EV_MSC = 0, 3, 4
local SYN_REPORT, SYN_DROPPED = 0, 3
local ABS_X, ABS_Y, ABS_PRESSURE = 0, 1, 24
local ABS_MT_SLOT, ABS_MT_TRACKING_ID = 47, 57
local BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH = 320, 321, 330
local PEN_KEYS = { BTN_TOOL_PEN, BTN_TOOL_RUBBER, BTN_TOUCH }

local TOAST_S = 3
local PANEL_BORDER = 3
local BUTTON_BORDER = 2
local C_WHITE, C_BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
-- The panel sits under the plane default (GL16), so a disabled button
-- can be gray.
local C_DIM = Blitbuffer.COLOR_DARK_GRAY

-- Event times and the controller's clock are CLOCK_REALTIME
-- microseconds (ui/time's fts is microseconds).  Timings are durations,
-- on the monotonic clock; time.now is the coarse one, too coarse here.
local function now_rt_us() return time.realtime() end
local function mono_us() return time.monotonic() end

local function toast(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = TOAST_S })
end

-- "20260926T120000Z-00c0de" -> "2026-09-26 12:00 UTC": the id's own
-- clock, named, so the panel and the open list read the same.
local function title_of(id)
    local y, mo, d, h, mi =
        tostring(id):match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)")
    if not y then return tostring(id) end
    return string.format("%s-%s-%s %s:%s UTC", y, mo, d, h, mi)
end

-- An id suffix from the kernel's entropy; LuaJIT's math.random starts
-- from the same seed in every process.
local function rand24()
    local f = io.open("/dev/urandom", "rb")
    if f then
        local s = f:read(3)
        f:close()
        if s and #s == 3 then
            local a, b, c = s:byte(1, 3)
            return a * 65536 + b * 256 + c
        end
    end
    return math.random(0, 0xffffff)
end

-- The pen's keys now, from a transient fd (EVIOCGKEY flushes the
-- caller's queued key events, so never KOReader's own fd): only
-- proximity and tool, never a stroke start (nb_input's rule).
local function pen_snapshot(devs)
    if not (Evdev and Evdev.keystate and devs.pen) then return nil end
    local k = Evdev.keystate(devs.pen, PEN_KEYS)
    if not k then return nil end
    local tool
    if k[BTN_TOOL_RUBBER] then
        tool = "rubber"
    elseif k[BTN_TOOL_PEN] then
        tool = "pen"
    end
    return { prox = tool ~= nil, tool = tool, touching = k[BTN_TOUCH] == true }
end

-- nb_config with this device's geometry: Screen.bb's physical size and
-- the digitizer's real axis ranges.  Every replay and the controller use
-- this one table, or px points fall back to the config's defaults.
local function live_cfg()
    local cfg = {}
    for k, v in pairs(Config) do cfg[k] = v end
    local bb = Screen.bb
    cfg.W, cfg.H = bb.w, bb.h
    cfg.dpi = Screen:getDPI()
    local pen = Device.input_devices and Device.input_devices.pen
    if Evdev and pen then
        local _x, xmax = Evdev.absinfo(pen, ABS_X)
        local _y, ymax = Evdev.absinfo(pen, ABS_Y)
        local _p, pmax = Evdev.absinfo(pen, ABS_PRESSURE)
        if xmax and xmax > 0 then cfg.abs_x_max = xmax end
        if ymax and ymax > 0 then cfg.abs_y_max = ymax end
        if pmax and pmax > 0 then cfg.abs_p_max = pmax end
    end
    return cfg
end

-- A page file's lines as the controller's page, with the live cfg.
local function replay(lines, cfg, id, n)
    local page = J.replay(lines, cfg)
    if page.bad_lines > 0 then
        logger.warn(string.format("[notebook] %s page %d: %d unreadable"
                                  .. " line(s) skipped", id, n, page.bad_lines))
    end
    return page
end

-- Everything an open needs, read before anything changes, so a failure
-- leaves the screen and any open notebook as they were.  how: "new",
-- "last" or "id".  Returns the session, or nil and the toast's text.
local function prepare(plugin, how, id, prefs)
    local cfg = live_cfg()
    local fs = plugin.fs
    local root = cfg.notebooks_root
    local store = J.Store.new{ fs = fs, root = root, cfg = cfg,
                               rand = plugin.rand }
    -- The reader image mounts /data from p7, or leaves a placeholder on
    -- the OS root that the next reflash wipes; notebooks go only to the
    -- real partition, and one real append proves it takes writes.
    local ok, why = store:check_data(fs.read(plugin.MOUNTINFO))
    if ok then ok, why = store:probe() end
    if not ok then
        return nil, T(_("Notebook: cannot save to %1 (%2)."), root, why)
    end
    if not prefs then
        local err
        prefs, err = store:load_prefs()
        if err then logger.warn("[notebook] prefs ignored:", err) end
    end
    local nb, err
    if how == "new" then
        id, err = store:create(math.floor(now_rt_us() / 1e6))
        if id then nb, err = store:open(id) end
    elseif how == "id" then
        nb, err = store:open(id)
    else
        -- The last notebook, else the newest, else a first one: "Open
        -- last" on a fresh device should give paper, not a message.
        if prefs.last_id then nb = store:open(prefs.last_id) end
        if not nb then
            local list = store:list()
            if list and list[1] then
                nb, err = store:open(list[1].id)
            else
                id, err = store:create(math.floor(now_rt_us() / 1e6))
                if id then nb, err = store:open(id) end
            end
        end
    end
    if not nb then
        return nil, T(_("Notebook: cannot open a notebook (%1)."), err)
    end
    id = nb.id
    local n = prefs.last_page and prefs.last_page[id] or 0
    -- page_lines repairs a torn tail before any append to the page.
    local lines, lerr = nb:page_lines(n)
    if not lines then
        return nil, T(_("Notebook: cannot read page %1 (%2)."), n, lerr)
    end
    return { cfg = cfg, store = store, nb = nb, id = id, page_n = n,
             page = replay(lines, cfg, id, n), prefs = prefs }
end

------------------------------------------------------------------------
-- The notebook window
------------------------------------------------------------------------

-- The one open window, if any: one notebook per process.
local current

local NotebookWindow = InputContainer:extend{
    name = "notebook_window",
    -- Nothing beneath is painted while it is up; not modal, so the open
    -- list and dialogs stack above it.
    covers_fullscreen = true,
}

function NotebookWindow:init()
    local s = self.session
    self.cfg, self.store, self.prefs = s.cfg, s.store, s.prefs
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(),
                           h = Screen:getHeight() }
    self.devs = Device.input_devices or {}
    self.page_bb = Surface.new_page(self.cfg.W, self.cfg.H)
    self.fb = Surface.fb_alias(Screen.bb)
    self.item_widgets = {}
    -- The kernel's touch stream as it passes, whoever reads it: the
    -- current slot and which slots hold a finger, so touch changes owner
    -- only between frames with nothing down.
    self.kslot, self.kdown, self.kdown_n = 0, {}, 0
    self.tframe_open = false
    self.touch_consumed = true
    -- Stable closures: UIManager:unschedule matches by identity.
    self._consumer = function(_, ev)
        local ok, err = pcall(self._consume, self, ev)
        if not ok then self:_fault("input", err) end
    end
    -- The pen in range (the controller's rotation_hold), or a finger the
    -- window consumes still down.
    self._hold_pred = function()
        return self.hold == true or (self.touch_consumed and self.kdown_n > 0)
    end
    self._timer_task = function()
        if self.shown then self:_guard("timer", self._on_timer) end
    end
    self._activity_task = function()
        UIManager.event_hook:execute("InputEvent")
    end
    self._live_task = function()
        if self.shown then self:_guard("paint", self._update_live) end
    end
end

function NotebookWindow:_on_timer()
    self:_run(self.c:on_timer(now_rt_us()))
end

function NotebookWindow:onShow()
    if self.shown or self.closed then return end
    self.shown = true
    current = self
    local input = Device.input
    input.wilkbook_consumer = self._consumer
    input.wilkbook_hold_rotation = self._hold_pred
    -- KOReader may be holding a pen or finger contact it will never see
    -- end; a clean slate means nothing fires later (a hold, a pinned
    -- rotation deferral).
    input:resetState()
    self.kslot = self:_initial_touch_slot()
    self:_start(self.session)
end

-- mixedrouter's slot is where KOReader's reading of the touch stream
-- stands, which is exactly where this consumer starts reading it; the
-- kernel's current slot (EVIOCGABS) can be ahead of it by events still
-- queued.  Without mixedrouter (no pen or no touch node) the kernel's
-- slot is the best there is.
function NotebookWindow:_initial_touch_slot()
    local input = Device.input
    local slot = input.getTouchSlot and input:getTouchSlot()
    if type(slot) ~= "number" and Evdev and self.devs.touch then
        local _min, _max, v = Evdev.absinfo(self.devs.touch, ABS_MT_SLOT)
        slot = v
    end
    return type(slot) == "number" and slot or 0
end

-- A new controller on session s: at the first open, and for every
-- notebook opened from the panel (the old one closed first).
function NotebookWindow:_start(s)
    self.session, self.nb = s, s.nb
    self.cfg, self.store = s.cfg, s.store
    -- A refused arm stays refused until reset(); an open is the natural
    -- point to try again.
    local hint = Device.hint_owner
    if hint then hint:reset() end
    self.hint_wanted = nil
    self.live = nil
    -- A new controller starts with its panel closed, and close() emits
    -- no hide (the window normally takes its panel with it): drop the
    -- old notebook's panel here.  open's full repaint clears its pixels.
    self.panel_L, self.panel_phys = nil, nil
    local c = Ctl.new{ cfg = s.cfg, prefs = self.prefs,
                       rotation_mode = Screen:getRotationMode(),
                       now_rt_us = now_rt_us }
    self.c = c
    self:_run(c:open({ id = s.id, title = title_of(s.id) }, s.page_n, s.page))
    c:set_touch_slot(self.kslot)
    -- The pen may already hover (a menu tapped with it): without this
    -- it inks nothing and palm rejection is off until it leaves and
    -- comes back.
    local snap = pen_snapshot(self.devs)
    if snap then self:_run(c:resync(snap, now_rt_us())) end
    self:_update_live(true)
    logger.info(string.format("[notebook] open %s page %d", s.id, s.page_n))
end

-- Open another notebook in this window.  The new one is read first, so a
-- failure leaves the current one open; then the current one is closed
-- through the controller, while its nb still takes close's fsyncs.
function NotebookWindow:_switch(how, id)
    if not self.shown then return end
    if how == "id" and id == self.session.id then return end
    local s, err = prepare(self.plugin, how, id, self.prefs)
    if not s then return toast(err) end
    self:_run(self.c:close())
    self:_start(s)
end

function NotebookWindow:_is_topmost()
    for w in UIManager:topdown_widgets_iter() do
        -- A toast (Notification) takes no input and goes by itself.
        if not (w.invisible or w.toast) then return w == self end
    end
    return false
end

function NotebookWindow:_update_live(force)
    local live = (self.shown and not self.suspended and self:_is_topmost())
                 == true
    if live ~= self.live or force then
        self.live = live
        self:_run(self.c:set_ink_live(live))
    end
end

------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------

function NotebookWindow:_consume(ev)
    local ty, src = ev.type, ev.src
    -- EV_MSC was neutralised upstream (device.lua's touch and ws8100
    -- aliases); an SDL event has no source at all.
    if ty == EV_MSC or src == nil then return end
    local devs, kind = self.devs, nil
    if src == devs.pen then
        kind = "pen"
        -- Polled once per report: no hook exists for another widget
        -- being shown, and a stroke must not start under a dialog.
        if ty == EV_SYN and ev.code == SYN_REPORT then self:_update_live() end
    elseif src == devs.touch then
        if not self:_touch_gate(ev) then return end
        kind = "touch"
        -- The frame that lifts the last consumed finger ends its hold.
        if ty == EV_SYN and ev.code == SYN_REPORT and self.kdown_n == 0 then
            self.release_after = true
        end
    elseif src == devs.penbtn then
        -- The ws8100 keys would turn the book beneath or sleep the device.
        kind = "penbtn"
    else
        return
    end
    ev.type = EV_MSC
    -- A fresh table per event: nb_input reads it and keeps nothing, but
    -- a reused one would be one refactor away from aliasing.
    local nev = { src = kind, type = ty, code = ev.code, value = ev.value,
                  t = time.timeval(ev.time) }
    if kind == "pen" and ty == EV_ABS
       and (ev.code == ABS_X or ev.code == ABS_Y) then
        nev.raw = ev.raw_value
    end
    self:_run(self.c:feed(nev))
    -- After the frame is judged: a swipe or tap is read in the
    -- orientation it began in, and the rotation lands after it.
    if self.release_after then
        self.release_after = false
        self:_replay_rotation()
    end
end

-- A rotation device.lua deferred while this window held it, once nothing
-- holds it: through handleGyroEv, which honours the sensor lock and
-- inhibitInput and returns the event to dispatch, on nextTick (this runs
-- inside Input:waitEvent).  Only the newest pending orientation is kept.
function NotebookWindow:_replay_rotation()
    if self._hold_pred() then return end
    local input = Device.input
    local mode = input.takePendingRotation and input:takePendingRotation()
    if mode == nil then return end
    UIManager:nextTick(function()
        local ev = input.handleGyroEv and input:handleGyroEv({ value = mode })
        if ev then UIManager:sendEvent(ev) end
    end)
end

-- Track the touch stream and decide who reads this event.  Returns true
-- when the notebook consumes it.
function NotebookWindow:_touch_gate(ev)
    local ty, code = ev.type, ev.code
    if not self.tframe_open and self.kdown_n == 0 then
        local want = self:_is_topmost()
        if want ~= self.touch_consumed then self:_switch_touch(want) end
    end
    if ty == EV_SYN then
        if code == SYN_REPORT then
            self.tframe_open = false
        elseif code == SYN_DROPPED then
            -- A lift lost in the gap would leave a phantom finger that
            -- keeps touch here, and a dialog above could then never be
            -- dismissed; forgetting the fingers errs the other way.  The
            -- frame stays open until the next report.
            self.kdown, self.kdown_n = {}, 0
            self.tframe_open = true
        end
    else
        self.tframe_open = true
        if ty == EV_ABS then
            if code == ABS_MT_SLOT then
                self.kslot = ev.value
            elseif code == ABS_MT_TRACKING_ID then
                local slot, down = self.kslot, ev.value >= 0
                if down ~= (self.kdown[slot] == true) then
                    self.kdown[slot] = down or nil
                    self.kdown_n = self.kdown_n + (down and 1 or -1)
                end
            end
        end
    end
    return self.touch_consumed
end

function NotebookWindow:_switch_touch(consume)
    local input = Device.input
    input:resetState()
    if consume then
        self.c:set_touch_slot(self.kslot)
    elseif input.setTouchSlot then
        input:setTouchSlot(self.kslot)
    end
    self.touch_consumed = consume
end

-- An error inside the input hook would end KOReader (UIManager:run has
-- no pcall).  Stop consuming, say so, and close the notebook; every
-- stroke already appended is on disk.
function NotebookWindow:_fault(where, err)
    logger.err("[notebook] " .. where .. " error:", err)
    if self.faulted then return end
    self.faulted = true
    local input = Device.input
    if input.wilkbook_consumer == self._consumer then
        input.wilkbook_consumer = nil
    end
    UIManager:nextTick(function()
        toast(_("Notebook: internal error; the notebook was closed."))
        if self.shown then UIManager:close(self, "ui") end
    end)
end

-- fn(self, ...) under the consumer's rule.  Scheduled tasks and event
-- handlers end KOReader just the same (UIManager's task loop and event
-- dispatch have no pcall, and the window is not a plugin class whose
-- handlers PluginLoader wraps), and they run the same controller code.
function NotebookWindow:_guard(where, fn, ...)
    local ok, err = pcall(fn, self, ...)
    if not ok then self:_fault(where, err) end
end

------------------------------------------------------------------------
-- The command executor
------------------------------------------------------------------------

-- After the first failed write in a list, these are skipped.
local SKIP_AFTER_FAIL = { append = true, arm = true, ink = true,
                          publish_ink = true }

local EXEC = {}

function NotebookWindow:_run(cmds)
    local failed, failed_err
    for i = 1, #cmds do
        local cmd = cmds[i]
        local op = cmd.op
        if not (failed and SKIP_AFTER_FAIL[op]) then
            local fn = EXEC[op]
            if fn then
                local ok, err = fn(self, cmd)
                if ok == false then
                    if failed then
                        logger.warn("[notebook] also failed:", err)
                    else
                        failed, failed_err = cmd, err
                    end
                end
            else
                logger.warn("[notebook] unknown command:", op)
            end
        end
    end
    if failed then self:_run(self.c:io_error(failed_err, failed)) end
end

function EXEC.arm(self, cmd)
    -- Kept as wanted until a disarm, for the re-arm before ink.
    self.hint_wanted = cmd.rects
    local hint = Device.hint_owner
    if hint then hint:arm(cmd.rects) end
end

function EXEC.disarm(self)
    self.hint_wanted = nil
    local hint = Device.hint_owner
    if hint then hint:disarm() end
end

function EXEC.ink(self, cmd)
    -- A toast or a wash disarms through the refresh guard without the
    -- controller knowing.  A refused arm reads as armed, so this cannot
    -- turn one failure into an ioctl per report.
    local hint = Device.hint_owner
    if hint and self.hint_wanted and not hint:is_armed() then
        hint:arm(self.hint_wanted)
    end
    local t0 = mono_us()
    Surface.ink(self.page_bb, cmd, nil)
    -- The open panel is painted over the canvas; the page buffer holds
    -- what is under it, the framebuffer shows the panel.
    Surface.ink(self.fb, cmd, self.panel_phys)
    self.c:note_timing("stamp", mono_us() - t0)
end

function EXEC.publish_ink(self)
    if not Device.publishNow then return end
    local t0 = mono_us()
    Device:publishNow()
    self.c:note_timing("publish", mono_us() - t0)
end

function EXEC.append(self, cmd)
    local t0 = mono_us()
    local ok, err = self.nb:append(cmd.page, cmd.line)
    self.c:note_timing("append", mono_us() - t0)
    if not ok then return false, err end
end

function EXEC.fsync(self, cmd)
    local t0 = mono_us()
    local ok, err = self.nb:fsync(cmd.page)
    self.c:note_timing("fsync", mono_us() - t0)
    if not ok then return false, err end
end

-- Answered at once: a page is one file, read and replayed in a few ms.
function EXEC.load_page(self, cmd)
    local n = cmd.page
    local lines, err = self.nb:page_lines(n)
    if not lines then return self:_run(self.c:page_loaded(n, nil, err)) end
    local page = replay(lines, self.cfg, self.session.id, n)
    self:_run(self.c:page_loaded(n, page))
end

function EXEC.render_page(self, cmd)
    Surface.render_page(self.page_bb, cmd.page, cmd.strokes, self.cfg,
                        cmd.region)
end

-- A physical rect as the logical Geom covering the same pixels.
function NotebookWindow:_logical_geom(x, y, w, h)
    local r, W, H = Screen.bb:getRotation(), self.cfg.W, self.cfg.H
    local ax, ay = G.to_logical(r, W, H, x, y)
    local bx, by = G.to_logical(r, W, H, x + w - 1, y + h - 1)
    if bx < ax then ax, bx = bx, ax end
    if by < ay then ay, by = by, ay end
    return Geom:new{ x = ax, y = ay, w = bx - ax + 1, h = by - ay + 1 }
end

-- "ui" for every notebook redraw: never promoted to a flash
-- (full_refresh_count) and never a wash.
function EXEC.repaint(self, cmd)
    local r = cmd.region
    if r then
        UIManager:setDirty(self, "ui", self:_logical_geom(r.x, r.y, r.w, r.h))
    else
        UIManager:setDirty(self, "ui")
    end
end

-- A logical rect clipped to the screen (a dragged panel may hang off
-- an edge), as a dirty region.
local function screen_geom(x, y, w, h)
    local x0, y0 = math.max(0, x), math.max(0, y)
    local x1 = math.min(Screen:getWidth(), x + w)
    local y1 = math.min(Screen:getHeight(), y + h)
    if x1 <= x0 or y1 <= y0 then return nil end
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

function EXEC.panel(self, cmd)
    local old, L = self.panel_L, cmd.layout
    self.panel_L, self.panel_phys = L, nil
    if L then
        local px, py, pw, ph = G.rect_to_physical(Screen.bb:getRotation(),
            self.cfg.W, self.cfg.H, L.x, L.y, L.w, L.h)
        if pw > 0 and ph > 0 then
            self.panel_phys = { x = px, y = py, w = pw, h = ph }
        end
    end
    -- The old area shows the page again, the new one the panel.
    local g = old and screen_geom(old.x, old.y, old.w, old.h)
    if g then UIManager:setDirty(self, "ui", g) end
    g = L and screen_geom(L.x, L.y, L.w, L.h)
    if g then UIManager:setDirty(self, "ui", g) end
end

function EXEC.washer_charge(self)
    -- Resolved per call: the washer belongs to the current host, and is
    -- absent when disabled or not installed.
    local w = self.ui and self.ui.idlewasher
    if not w then
        local ok, PluginLoader = pcall(require, "pluginloader")
        w = ok and PluginLoader:getPluginInstance("idlewasher") or nil
    end
    if w and w.chargePageTurn then w:chargePageTurn() end
end

function EXEC.activity(self)
    UIManager:unschedule(self._activity_task)
    UIManager:nextTick(self._activity_task)
end

-- One timer (nb_input's long press and the controller's pending leave):
-- the newest request replaces any pending one, and the controller always
-- asks for the sooner deadline.
function EXEC.schedule(self, cmd)
    UIManager:unschedule(self._timer_task)
    UIManager:scheduleIn(cmd.delay_us / 1e6, self._timer_task)
end

function EXEC.resync_pen(self)
    local snap = pen_snapshot(self.devs)
    if snap then self:_run(self.c:resync(snap, now_rt_us())) end
end

function EXEC.rotation_hold(self, cmd)
    self.hold = cmd.on == true
    if not self.hold then self:_replay_rotation() end
end

function EXEC.save_prefs(self, cmd)
    -- Kept even when the write fails: the next controller starts from
    -- the choices made, not from what the disk holds.
    self.prefs = cmd.prefs
    local ok, err = self.store:save_prefs(cmd.prefs)
    if not ok then logger.warn("[notebook] prefs not saved:", err) end
end

function EXEC.log(self, cmd)
    logger.info("[notebook] " .. cmd.line)
end

function EXEC.toast(self, cmd)
    local text = cmd.text
    UIManager:nextTick(function() toast(text) end)
end

function EXEC.new_notebook(self)
    UIManager:nextTick(function()
        self:_guard("switch", self._switch, "new")
    end)
end

function EXEC.open_list(self)
    UIManager:nextTick(function()
        if self.shown then self.plugin:showList() end
    end)
end

function EXEC.close_notebook(self)
    UIManager:nextTick(function()
        if self.shown then UIManager:close(self, "ui") end
    end)
end

------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------

-- The page is physical; blit_page matches its rotation and inverse to
-- the screen's, so physical lands on physical in any orientation.
function NotebookWindow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    Surface.blit_page(bb, self.page_bb, x, y)
    local L = self.panel_L
    if L then self:_paint_panel(bb, x, y, L) end
    -- A widget closing above this window repaints it, and there is no
    -- other notice of that: ink may be live again.
    UIManager:unschedule(self._live_task)
    UIManager:nextTick(self._live_task)
end

-- Font:getFace scales its size by scaleBySize; the panel's layout
-- assumed font_px pixels.
function NotebookWindow:_face(px)
    if self._face_px ~= px then
        local unit = Screen:scaleBySize(1000) / 1000
        local size = math.max(1, math.floor(px / unit + 0.5))
        self._face_obj = Font:getFace("cfont", size)
        self._face_px = px
    end
    return self._face_obj
end

-- Checked items are inverted and disabled ones gray.  Labels are
-- bounded to their button: the panel sized them from an estimate.
function NotebookWindow:_build_item(it, px)
    local face = self:_face(px)
    if it.kind == "title" then
        return LeftContainer:new{
            dimen = Geom:new{ w = it.w, h = it.h },
            TextWidget:new{ text = it.label, face = face, bold = true,
                            max_width = it.w },
        }
    end
    local b = BUTTON_BORDER
    return FrameContainer:new{
        width = it.w, height = it.h,
        bordersize = b, padding = 0, margin = 0,
        color = it.enabled and C_BLACK or C_DIM,
        background = it.checked and C_BLACK or C_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = it.w - 2 * b, h = it.h - 2 * b },
            TextWidget:new{
                text = _(it.label), face = face,
                fgcolor = it.checked and C_WHITE
                          or (it.enabled and C_BLACK or C_DIM),
                max_width = it.w - 4 * b,
            },
        },
    }
end

-- Widgets by what they show, so a dragged panel reuses them.
function NotebookWindow:_item_widget(it, px)
    local key = table.concat({ it.kind, it.label, it.checked and 1 or 0,
                               it.enabled and 1 or 0, it.w, it.h, px }, "\0")
    local w = self.item_widgets[key]
    if w == nil then
        -- paintTo runs outside any pcall; a missing font must cost the
        -- labels, not KOReader.
        local ok, built = pcall(self._build_item, self, it, px)
        if not ok then
            logger.warn("[notebook] panel label failed:", built)
            built = false
        end
        self.item_widgets[key] = built
        w = built
    end
    return w or nil
end

function NotebookWindow:_paint_panel(bb, x, y, L)
    local lx, ly = x + L.x, y + L.y
    bb:paintRect(lx, ly, L.w, L.h, C_WHITE)
    bb:paintBorder(lx, ly, L.w, L.h, PANEL_BORDER, C_BLACK)
    for _, it in ipairs(L.items) do
        local w = self:_item_widget(it, L.font_px)
        if w then
            w:paintTo(bb, x + it.x, y + it.y)
        elseif it.kind == "button" then
            -- Without text the buttons still show where they are.
            bb:paintBorder(x + it.x, y + it.y, it.w, it.h,
                           it.checked and 3 * BUTTON_BORDER or BUTTON_BORDER,
                           it.enabled and C_BLACK or C_DIM)
        end
    end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

-- The gyro's SetRotationMode is sent to the topmost window only, so the
-- reader or file manager beneath would never rotate (menu.lua's
-- pattern).  The page stays physical; only the panel moves.
function NotebookWindow:onSetRotationMode(mode)
    local ui = self.ui
    if ui then
        if ui.view then
            ui.view:onSetRotationMode(mode)
        elseif ui.onSetRotationMode then
            ui:onSetRotationMode(mode)
        end
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(),
                           h = Screen:getHeight() }
    if self.shown then
        self:_guard("rotation", self._rotated)
        UIManager:setDirty(self, "ui")
    end
    return true
end

-- The mode the host settled on: a locked sensor may have refused it.
function NotebookWindow:_rotated()
    self:_run(self.c:set_rotation(Screen:getRotationMode()))
end

-- The screensaver is already up (the window is not topmost), then this;
-- the adjust hook keeps running while input is inhibited.
function NotebookWindow:onSuspend()
    if not self.shown then return end
    self.suspended = true
    self:_guard("suspend", self._suspend)
end

function NotebookWindow:_suspend()
    self:_run(self.c:suspend())
    self:_update_live()
end

-- The pen may have left, arrived or lifted while the device slept.
function NotebookWindow:onResume()
    if not self.shown then return end
    self.suspended = false
    self:_guard("resume", self._resume)
end

function NotebookWindow:_resume()
    self:_run(self.c:resume(pen_snapshot(self.devs)))
    self:_update_live()
end

-- Poweroff and reboot broadcast Close: close through the normal path so
-- the pages are fsynced.
function NotebookWindow:onClose()
    if self.shown then UIManager:close(self, "ui") end
end

function NotebookWindow:onCloseWidget()
    if self.closed then return end
    self.closed = true
    local was_shown = self.shown
    self.shown = false
    if current == self then current = nil end
    if was_shown then
        -- The close is the fsync.  A failed write goes through _run's
        -- io_error path; an error (a bug) must not stop the teardown
        -- below, or the consumer would outlive the window.
        local ok, err = pcall(function() self:_run(self.c:close()) end)
        if not ok then logger.err("[notebook] close error:", err) end
        local input = Device.input
        if input.wilkbook_consumer == self._consumer then
            input.wilkbook_consumer = nil
        end
        if input.wilkbook_hold_rotation == self._hold_pred then
            input.wilkbook_hold_rotation = nil
        end
        -- KOReader reads the touch stream again from where it stands.
        input:resetState()
        if input.setTouchSlot then input:setTouchSlot(self.kslot) end
        local hint = Device.hint_owner
        if hint then hint:disarm() end
    end
    UIManager:unschedule(self._timer_task)
    UIManager:unschedule(self._activity_task)
    UIManager:unschedule(self._live_task)
    for _, w in pairs(self.item_widgets) do
        if w and w.free then w:free() end
    end
    self.item_widgets = {}
    if self.page_bb then
        self.page_bb:free()
        self.page_bb = nil
    end
end

------------------------------------------------------------------------
-- The plugin: one instance per ReaderUI or FileManager
------------------------------------------------------------------------

local Notebook = WidgetContainer:extend{
    name = "notebook",
    is_doc_only = false,
    -- Injection points for the host harness: the real fs, the id
    -- suffix source, and where the mount table is read.
    fs = Fs,
    rand = rand24,
    MOUNTINFO = "/proc/self/mountinfo",
}

function Notebook:init()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
end

-- Menu callbacks run before the menu closes, so the window opens on the
-- next tick, over a screen the menu has left.
function Notebook:_later(how, id)
    UIManager:nextTick(function() self:launch(how, id) end)
end

function Notebook:addToMainMenu(menu_items)
    menu_items.notebook = {
        text = _("Notebook"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Open last notebook"),
              callback = function() self:_later("last") end },
            { text = _("New notebook"),
              callback = function() self:_later("new") end },
            { text = _("Open notebook…"),
              callback = function()
                  UIManager:nextTick(function() self:showList() end)
              end },
        },
    }
end

--- how: "new", "last" or "id" (with id).  With a notebook already open
-- its window switches to the new one.
function Notebook:launch(how, id)
    if current then
        return current:_guard("switch", current._switch, how, id)
    end
    local s, err = prepare(self, how, id)
    if not s then return toast(err) end
    UIManager:show(NotebookWindow:new{ plugin = self, ui = self.ui,
                                       session = s }, "ui")
end

--- The notebooks, newest first, as a KOReader Menu.  Over an open
-- notebook it takes touch (the window passes it through) and choosing
-- one switches the window to it.
function Notebook:showList()
    local store = J.Store.new{ fs = self.fs, root = Config.notebooks_root }
    local list, err = store:list()
    if not list then
        return toast(T(_("Notebook: cannot list notebooks (%1)."), err))
    end
    if #list == 0 then return toast(_("No notebooks yet.")) end
    local items = {}
    for i, e in ipairs(list) do
        local id, n = e.id, #e.pages
        items[i] = {
            text = title_of(id),
            mandatory = T(N_("1 page", "%1 pages", n), n),
            callback = function() self:_later("id", id) end,
        }
    end
    local menu
    menu = Menu:new{
        title = _("Open notebook"),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        close_callback = function() UIManager:close(menu, "ui") end,
    }
    UIManager:show(menu)
end

-- The host (ReaderUI or FileManager) is going away: exit, restart or a
-- document change.  The window must not outlive it.
function Notebook:onCloseWidget()
    if current and UIManager:isWidgetShown(current) then
        UIManager:close(current, "ui")
    end
end

-- Plugin management turned the notebook off.
function Notebook:stopPlugin()
    self:onCloseWidget()
end

return Notebook
