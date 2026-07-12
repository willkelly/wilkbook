--[[--
Idle washer -- the wilkbook userspace refresh manager for the PineNote.

Owns full-panel washes from userspace, replacing both of the mechanisms
it obsoletes (doc/refresh-policy.md):

  * the driver's threshold auto-refresh -- DISABLED in the shipped
    config (`auto_refresh=0`): its wash path is the proven cause of
    believed-white corruption (finding 10, the 2x2);
  * KOReader's fixed every-N-turns promotion -- a page-turn interruption
    on a fixed cadence, blind to reading pauses.

Every wash this plugin fires goes through UIManager:setDirty("all",
"full") -> the pinenote device's refreshFullImp -> the EBC
GLOBAL_REFRESH ioctl (frontend/device/pinenote/device.lua) -- the wash
path that has never corrupted anything (finding 10).  An explicit
region-less "full" also resets UIManager's own promotion counter
(uimanager.lua _refresh), so the two mechanisms never double-fire.

Three mechanisms, decided by the pure core (idlewasher_core.lua, tested
offline in pinenote/tools/koreader-input/test-idlewasher-logic.lua):

  * bundled wash: page-turn debt reaches debt_max -> the wash rides the
    turn's own repaint (one flash, not two);
  * idle wash: debt >= debt_min and the user pauses idle_s -> the wash
    lands where nobody is reading;
  * deep clean: after deepclean_idle_s of inactivity, one GC16 global
    (refresh_waveform flipped to 4 and restored after settle -- the
    reader-session.scm %panel-blank-lua pattern, via UIManager timers)
    -- the only mechanism that re-scrubs believed-white residue under
    the GL16 policy.  Once per idle span.

Config (G_reader_settings; absent keys = defaults):

  idlewasher_enabled           true  -- false: plugin registers NOTHING
  idlewasher_debt_min          15    -- min debt for an idle wash
  idlewasher_debt_max          60    -- hard debt ceiling (bundled wash)
  idlewasher_idle_s            45    -- idle seconds before an idle wash
  idlewasher_deepclean_idle_s  600   -- idle seconds before a deep clean

Every action logs one greppable "[idlewasher] ..." logger.info line --
these land in the same session log the optics trace harvest pulls,
alongside the [pn-refresh] lines the washes themselves emit.
--]]

local logger = require("logger")

-- Two copies of this plugin can coexist: the bundle's grafted
-- plugins/idlewasher.koplugin and a copy the optics harness pushes into
-- KO_HOME/plugins/ for reflash-free iteration (driver.py).  The first
-- copy to load claims this sentinel; later copies disable themselves.
-- PluginLoader loads path-sorted (pluginloader.lua sortProvidersFirst),
-- so the absolute KO_HOME path ("/root/...") sorts before the bundle's
-- relative "plugins/..." and the PUSHED copy wins -- exactly what live
-- iteration wants.
if _G.__wilkbook_idlewasher_loaded then
    logger.info("[idlewasher] duplicate copy skipped:",
                (debug.getinfo(1, "S") or {}).source)
    return { disabled = true }
end
_G.__wilkbook_idlewasher_loaded = true

local Core = require("idlewasher_core")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local time = require("ui/time")
local _ = require("gettext")

local IdleWasher = WidgetContainer:extend{
    name = "idlewasher",
    is_doc_only = false,
    -- Overridable by the host harness (a plain temp file); the real
    -- runtime-writable module param on the device.
    WAVEFORM_SYSFS = "/sys/module/rockchip_ebc/parameters/refresh_waveform",
    GC16 = "4",
    -- Restore margin after the deep-clean wash: GC16 is 38 phases /
    -- ~447 ms at room bins but 1.54 s at the 0 C bin -- 3 s is the same
    -- settle wait %panel-blank-lua uses.
    RESTORE_DELAY_S = 3,
}

local function read_setting(key, default)
    local ok, v = pcall(function()
        return G_reader_settings and G_reader_settings.readSetting
            and G_reader_settings:readSetting(key)
    end)
    if ok and v ~= nil then return v end
    return default
end

local function now_s()
    return time.to_number(UIManager:getElapsedTimeSinceBoot())
end

-- sysfs I/O, pcall-guarded: on non-device hosts (QEMU virt, the
-- workstation harness) the node is absent or unwritable and these
-- helpers just answer nil/false -- the plugin then degrades to plain
-- (shipped-waveform) full washes.
function IdleWasher:_read_waveform()
    local ok, v = pcall(function()
        local f = io.open(self.WAVEFORM_SYSFS, "r")
        if not f then return nil end
        local s = f:read("*l")
        f:close()
        return s
    end)
    if ok then return v end
    return nil
end

function IdleWasher:_write_waveform(v)
    local ok, done = pcall(function()
        local f = io.open(self.WAVEFORM_SYSFS, "w")
        if not f then return false end
        f:write(tostring(v))
        f:close()
        return true
    end)
    return (ok and done) or false
end

function IdleWasher:init()
    if read_setting("idlewasher_enabled", true) == false then
        logger.info("[idlewasher] disabled (idlewasher_enabled=false);"
                    .. " registering nothing")
        return
    end
    self.core = Core.new{
        enabled = true,
        debt_min = tonumber(read_setting("idlewasher_debt_min",
                                         Core.DEFAULTS.debt_min)),
        debt_max = tonumber(read_setting("idlewasher_debt_max",
                                         Core.DEFAULTS.debt_max)),
        idle_s = tonumber(read_setting("idlewasher_idle_s",
                                       Core.DEFAULTS.idle_s)),
        deepclean_idle_s = tonumber(read_setting(
            "idlewasher_deepclean_idle_s", Core.DEFAULTS.deepclean_idle_s)),
        now = now_s(),
    }

    -- Handlers become INSTANCE fields only when enabled, so a disabled
    -- plugin exposes no event handlers at all ("registers nothing").
    self.onPageUpdate = self._onPageUpdate
    self.onPosUpdate = self._onPosUpdate
    self.onInputEvent = self._onInputEvent
    self.onIdleWasherDeepClean = self._onIdleWasherDeepClean
    self.onDispatcherRegisterActions = self._registerDispatcherActions

    -- Instance-specific closures so unschedule() from THIS instance
    -- never touches another instance's tasks (the autosuspend pattern).
    self.timer_task = function() self:_apply(self.core:on_timer(now_s())) end
    self.restore_task = function() self:_restore_waveform() end
    self._restore_pending = nil
    self._last_page = nil

    -- One callback per input batch, before the events are handled
    -- (uimanager.lua handleInput dispatches hooks first).
    UIManager.event_hook:registerWidget("InputEvent", self)
    self:onDispatcherRegisterActions()

    logger.info(string.format(
        "[idlewasher] enabled debt_min=%d debt_max=%d idle_s=%d"
        .. " deepclean_idle_s=%d",
        self.core.debt_min, self.core.debt_max, self.core.idle_s,
        self.core.deepclean_idle_s))

    -- Arm the idle chain as if startup were input: a session opened and
    -- then left alone still reaches its deep clean.
    self:_apply(self.core:on_input(now_s()))
end

function IdleWasher:_registerDispatcherActions()
    Dispatcher:registerAction("idlewasher_deep_clean", {
        category = "none",
        event = "IdleWasherDeepClean",
        title = _("PineNote deep clean (GC16 wash)"),
        general = true,
    })
end

-- Execute one core decision through UIManager.
function IdleWasher:_apply(actions)
    if not actions then return end
    if actions.deep_clean then
        self:_deep_clean()
    elseif actions.wash == "bundled" then
        UIManager:setDirty("all", "full")
        logger.info("[idlewasher] bundled wash (debt max)")
    elseif actions.wash == "idle" then
        UIManager:setDirty("all", "full")
        logger.info(string.format("[idlewasher] idle wash (debt=%d)",
                                  actions.debt))
    end
    local delay = actions.arm or actions.rearm
    if delay then
        UIManager:unschedule(self.timer_task)
        UIManager:scheduleIn(delay, self.timer_task)
    end
end

function IdleWasher:_onInputEvent()
    self:_apply(self.core:on_input(now_s()))
end

-- Page turns: ReaderPaging emits PageUpdate (readerpaging.lua
-- _gotoPage), ReaderRolling emits PageUpdate in page mode
-- (readerrolling.lua _gotoPage) and PosUpdate in scroll mode
-- (readerrolling.lua _gotoPos); count a scroll as a turn when the page
-- number changes -- the statistics plugin's pattern.
function IdleWasher:_onPageUpdate(pageno)
    self._last_page = pageno
    self:_apply(self.core:on_page_turn(now_s()))
end

function IdleWasher:_onPosUpdate(pos, pageno)
    if pageno and pageno ~= self._last_page then
        self:_onPageUpdate(pageno)
    end
end

-- The dispatcher-exposed manual deep clean (gesture-assignable).
function IdleWasher:_onIdleWasherDeepClean()
    logger.info("[idlewasher] deep clean requested (dispatcher)")
    self:_deep_clean()
    self.core:on_manual_deep_clean(now_s())
    return true
end

-- The %panel-blank-lua pattern through UIManager: flip the global
-- refresh waveform to GC16, fire one full wash, restore the prior
-- value after the wash settles.
function IdleWasher:_deep_clean()
    local flipped = false
    if self._restore_pending ~= nil then
        flipped = true      -- an earlier flip is still in flight; reuse
    else
        local prior = self:_read_waveform()
        if prior == self.GC16 then
            flipped = true  -- already GC16 globally; nothing to restore
        elseif prior ~= nil and self:_write_waveform(self.GC16) then
            self._restore_pending = prior
        end
    end
    UIManager:setDirty("all", "full")
    if flipped or self._restore_pending then
        logger.info("[idlewasher] deep clean (GC16)")
    else
        logger.info("[idlewasher] deep clean"
                    .. " (GC16 flip unavailable; plain full wash)")
    end
    if self._restore_pending then
        UIManager:unschedule(self.restore_task)
        UIManager:scheduleIn(self.RESTORE_DELAY_S, self.restore_task)
    end
end

function IdleWasher:_restore_waveform()
    local prior = self._restore_pending
    self._restore_pending = nil
    if prior == nil then return end
    if self:_write_waveform(prior) then
        logger.info(string.format(
            "[idlewasher] deep clean restore (refresh_waveform=%s)", prior))
    else
        logger.warn(string.format(
            "[idlewasher] deep clean restore FAILED"
            .. " (wanted refresh_waveform=%s)", prior))
    end
end

-- event_hook:registerWidget wraps this to also unregister the hook.
function IdleWasher:onCloseWidget()
    if not self.core then return end
    UIManager:unschedule(self.timer_task)
    -- Never leave the panel parked on GC16: restore NOW if in flight.
    if self._restore_pending then
        UIManager:unschedule(self.restore_task)
        self:_restore_waveform()
    end
    self.core = nil
end

return IdleWasher
