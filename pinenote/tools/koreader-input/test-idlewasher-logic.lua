--[[--
Host harness for the idle-washer refresh manager (offline ladder).

Two layers, both run under the koreader-bin bundle's own luajit:

 1. the PURE decision core (idlewasher_core.lua) -- table-driven cases
    over the debt/idle state machine: debt accrual, idle-fire only at
    debt >= debt_min, debt-max bundling, deep-clean once-per-idle-span
    with timer parking, early-fire re-arm, manual deep clean, and
    disabled = no actions;
 2. the REAL plugin main.lua wired to a recording UIManager stub (the
    bundle's verbatim ui/hook_container underneath) -- proving the
    registration contract (a disabled plugin registers nothing), the
    setDirty("all","full") wash calls, the GC16 sysfs flip + scheduled
    restore against a fake sysfs file, the duplicate-copy load sentinel,
    and onCloseWidget teardown (timer unscheduled, GC16 never left
    active).

NOT covered here (the residual gap, stated precisely): UIManager's real
scheduler/paint loop and the PageUpdate/PosUpdate emission by
ReaderPaging/ReaderRolling (verified by inspection: readerpaging.lua
_gotoPage, readerrolling.lua _gotoPage/_gotoPos) -- QEMU-rung-4v /
device territory.  Every wash/clean/arm decision and every UIManager
call the plugin makes is executed here.

Usage: luajit test-idlewasher-logic.lua /path/to/bundle/lib/koreader \
           /path/to/repo/.../plugins/idlewasher.koplugin
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to idlewasher.koplugin")

package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")

local fail = 0
local function report(ok, label, msg)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label,
                        msg or ""))
    if not ok then fail = fail + 1 end
end

------------------------------------------------------------------------
-- 1. The pure core, table-driven.
------------------------------------------------------------------------

local Core = dofile(plugin_dir .. "/idlewasher_core.lua")

local function eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not eq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function fmt(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. tostring(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Each case: a fresh core from cfg, then steps of {event, t, expect}.
-- Optional post-checks against the core's own state.
local cases = {
    {
        name = "debt accrual: turns below debt_max decide nothing",
        cfg = { now = 0 },
        steps = (function()
            local s = {}
            for i = 1, 59 do s[#s + 1] = { "on_page_turn", i, nil } end
            return s
        end)(),
        post = function(c) return c.debt == 59, "debt=" .. c.debt end,
    },
    {
        name = "debt-max bundling: turn 60 washes, debt resets, recount",
        cfg = { now = 0 },
        steps = (function()
            local s = {}
            for i = 1, 59 do s[#s + 1] = { "on_page_turn", i, nil } end
            s[#s + 1] = { "on_page_turn", 60, { wash = "bundled", debt = 60 } }
            s[#s + 1] = { "on_page_turn", 61, nil }
            return s
        end)(),
        post = function(c) return c.debt == 1, "debt=" .. c.debt end,
    },
    {
        name = "idle fire below debt_min: no wash, chain re-arms only",
        cfg = { now = 0 },
        steps = {
            { "on_input", 0, { arm = 45 } },
            { "on_page_turn", 1, nil },     -- debt 1 < debt_min 15
            { "on_timer", 45, { rearm = 555 } },
        },
        post = function(c) return c.debt == 1, "debt=" .. c.debt end,
    },
    {
        name = "idle wash at debt >= debt_min; second fire has no debt",
        cfg = { now = 0 },
        steps = (function()
            local s = { { "on_input", 0, { arm = 45 } } }
            for i = 1, 15 do s[#s + 1] = { "on_page_turn", 1, nil } end
            s[#s + 1] = { "on_timer", 45,
                          { wash = "idle", debt = 15, rearm = 555 } }
            -- chain continues toward the deep clean with debt now 0
            s[#s + 1] = { "on_timer", 300, { rearm = 300 } }
            return s
        end)(),
    },
    {
        name = "early timer fire (activity since arming) re-arms remainder",
        cfg = { now = 0 },
        steps = {
            { "on_input", 0, { arm = 45 } },
            { "on_input", 30, nil },          -- armed already: no re-arm
            { "on_timer", 45, { rearm = 30 } }, -- idle only 15 of 45
            { "on_timer", 75, { rearm = 555 } }, -- idle 45: threshold, no debt
        },
    },
    {
        name = "deep clean once per idle span, then the timer parks",
        cfg = { now = 0 },
        steps = (function()
            local s = { { "on_input", 0, { arm = 45 } } }
            for i = 1, 5 do s[#s + 1] = { "on_page_turn", 1, nil } end
            -- debt 5 < debt_min: idle fires never wash, chain re-arms
            s[#s + 1] = { "on_timer", 45, { rearm = 555 } }
            -- deep clean retires even sub-min debt; NO rearm = parked
            s[#s + 1] = { "on_timer", 600, { deep_clean = true, debt = 5 } }
            -- new input opens a new span and re-arms
            s[#s + 1] = { "on_input", 700, { arm = 45 } }
            s[#s + 1] = { "on_timer", 745, { rearm = 555 } }
            s[#s + 1] = { "on_timer", 1300, { deep_clean = true, debt = 0 } }
            return s
        end)(),
        post = function(c)
            return c.debt == 0 and c.deepclean_done and not c.armed
                   and c.last_deepclean_at == 1300,
                   string.format("debt=%d done=%s armed=%s last=%s",
                                 c.debt, tostring(c.deepclean_done),
                                 tostring(c.armed),
                                 tostring(c.last_deepclean_at))
        end,
    },
    {
        name = "manual deep clean retires debt and marks the span done",
        cfg = { now = 0 },
        steps = (function()
            local s = { { "on_input", 0, { arm = 45 } } }
            for i = 1, 20 do s[#s + 1] = { "on_page_turn", 1, nil } end
            s[#s + 1] = { "on_manual_deep_clean", 10, { debt = 20 } }
            -- the span's deep clean is done and the debt is retired:
            -- the idle chain has nothing left to do until new input
            s[#s + 1] = { "on_timer", 55, nil }
            s[#s + 1] = { "on_timer", 610, nil }
            return s
        end)(),
    },
    {
        name = "disabled = no actions, ever",
        cfg = { now = 0, enabled = false },
        steps = (function()
            local s = {}
            for i = 1, 80 do s[#s + 1] = { "on_page_turn", i, nil } end
            s[#s + 1] = { "on_input", 81, nil }
            s[#s + 1] = { "on_timer", 900, nil }
            s[#s + 1] = { "on_manual_deep_clean", 901, nil }
            return s
        end)(),
        post = function(c) return c.debt == 0, "debt=" .. c.debt end,
    },
    {
        -- The 2026-07-11 acceptance-run bug: an idle span that ends below
        -- debt_min re-arms the timer for the DEEP-CLEAN horizon (hundreds
        -- of seconds out).  When reading resumes, on_input must pull the
        -- deadline back in to idle_s after the new activity -- otherwise
        -- the next idle window passes while the timer is still parked on
        -- the old span's deep-clean deadline, and the idle wash NEVER
        -- fires in normal reading (proven on glass: bundled washes fired,
        -- idle washes did not).  on_timer may only fire at the armed
        -- deadline -- this case respects that schedule throughout.
        name = "resumed reading pulls a far (deep-clean) deadline back in",
        cfg = { now = 0, debt_min = 5, debt_max = 10, idle_s = 20,
                deepclean_idle_s = 600 },
        steps = {
            { "on_input", 0, { arm = 20 } },       -- deadline 20
            { "on_input", 1, nil }, { "on_page_turn", 1, nil },
            { "on_input", 2, nil }, { "on_page_turn", 2, nil },
            -- deadline 20: idle 18 of 20 -> remainder
            { "on_timer", 20, { rearm = 2 } },     -- deadline 22
            -- deadline 22: idle 20, debt 2 < 5 -> no wash; chain re-arms
            -- for the deep-clean horizon (600 - 20 = 580; deadline 602)
            { "on_timer", 22, { rearm = 580 } },
            -- reading resumes: the far deadline MUST come back to +idle_s
            { "on_input", 100, { arm = 20 } },     -- deadline 120
            { "on_page_turn", 100, nil },
            { "on_input", 102, nil }, { "on_page_turn", 102, nil },
            { "on_input", 104, nil }, { "on_page_turn", 104, nil },
            { "on_input", 106, nil }, { "on_page_turn", 106, nil },
            { "on_input", 108, nil }, { "on_page_turn", 108, nil },
            -- deadline 120: idle 12 of 20 -> remainder (deadline 128)
            { "on_timer", 120, { rearm = 8 } },
            -- deadline 128: idle 20, debt 7 >= 5 (the sub-min span
            -- retired nothing, so its 2 turns carry) -> THE IDLE WASH
            { "on_timer", 128, { wash = "idle", debt = 7, rearm = 580 } },
        },
        post = function(c) return c.debt == 0, "debt=" .. c.debt end,
    },
    {
        name = "config overrides: debt_max=3, idle_s=10, deepclean=30",
        cfg = { now = 0, debt_min = 2, debt_max = 3, idle_s = 10,
                deepclean_idle_s = 30 },
        steps = {
            { "on_input", 0, { arm = 10 } },
            { "on_page_turn", 1, nil },
            { "on_page_turn", 2, nil },
            { "on_page_turn", 3, { wash = "bundled", debt = 3 } },
            { "on_page_turn", 4, nil },
            { "on_page_turn", 5, nil },
            { "on_timer", 10, { wash = "idle", debt = 2, rearm = 20 } },
            { "on_timer", 30, { deep_clean = true, debt = 0 } },
        },
    },
}

for _, case in ipairs(cases) do
    local core = Core.new(case.cfg)
    local bad
    for i, step in ipairs(case.steps) do
        local ev, t, expect = step[1], step[2], step[3]
        local got = core[ev](core, t)
        if not eq(got, expect) then
            bad = string.format("step %d %s(t=%s): got %s want %s",
                                i, ev, tostring(t), fmt(got), fmt(expect))
            break
        end
    end
    if bad then
        report(false, "core: " .. case.name, bad)
    elseif case.post then
        local ok, msg = case.post(core)
        report(ok, "core: " .. case.name, msg)
    else
        report(true, "core: " .. case.name,
               #case.steps .. " steps as expected")
    end
end

------------------------------------------------------------------------
-- 2. The real plugin main.lua on a recording UIManager stub.
------------------------------------------------------------------------

local noop = function() end

-- captured log lines (main.lua only ever calls logger.info/warn)
local log_lines = {}
local function log_capture(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    log_lines[#log_lines + 1] = table.concat(parts, " ")
end
local function log_grep(pat)
    local n = 0
    for _, l in ipairs(log_lines) do
        if l:find(pat, 1, true) then n = n + 1 end
    end
    return n
end

package.preload["logger"] = function()
    return setmetatable({
        dbg = noop, info = log_capture, warn = log_capture,
        err = log_capture, LvDEBUG = noop, setLevel = noop,
    }, { __call = noop })
end

package.preload["gettext"] = function()
    local identity = function(_, s) return s end
    return setmetatable({
        ngettext = function(_, s) return s end,
        pgettext = function(_, _, s) return s end,
    }, { __call = identity })
end

-- fake time: plain numbers; main.lua only does to_number(abs_time)
local fake_now = 0
package.preload["ui/time"] = function()
    return { to_number = function(x) return x end }
end

-- recording dispatcher
local dispatcher_actions = {}
package.preload["dispatcher"] = function()
    return {
        registerAction = function(_, name, props)
            dispatcher_actions[name] = props
        end,
    }
end

-- minimal WidgetContainer with KOReader's extend/new(:init) semantics
package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}
    function WC:extend(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end
    function WC:new(o)
        o = self:extend(o)
        if o.init then o:init() end
        return o
    end
    return WC
end

-- recording UIManager over the bundle's VERBATIM hook container
local HookContainer = require("ui/hook_container")
local UIManager = {
    event_hook = HookContainer:new(),
    scheduled = {},   -- array of {when=<abs s>, fn=<fn>}
    dirty = {},       -- array of {widget, refreshtype}
}
function UIManager:scheduleIn(s, fn)
    table.insert(self.scheduled, { when = fake_now + s, fn = fn })
end
function UIManager:unschedule(fn)
    for i = #self.scheduled, 1, -1 do
        if self.scheduled[i].fn == fn then table.remove(self.scheduled, i) end
    end
end
function UIManager:setDirty(widget, refreshtype)
    table.insert(self.dirty, { widget, refreshtype })
end
function UIManager:getElapsedTimeSinceBoot() return fake_now end
-- test helper: run every task due at fake_now (a scheduler tick)
function UIManager:fire_due()
    local due = {}
    for i = #self.scheduled, 1, -1 do
        if self.scheduled[i].when <= fake_now then
            table.insert(due, 1, table.remove(self.scheduled, i).fn)
        end
    end
    for _, fn in ipairs(due) do fn() end
end
function UIManager:washes()
    local n = 0
    for _, d in ipairs(self.dirty) do
        if d[1] == "all" and d[2] == "full" then n = n + 1 end
    end
    return n
end
package.preload["ui/uimanager"] = function() return UIManager end

-- settings the plugin reads at init
local settings = {}
G_reader_settings = {
    readSetting = function(_, key) return settings[key] end,
}

package.preload["idlewasher_core"] = function()
    return dofile(plugin_dir .. "/idlewasher_core.lua")
end

-- a fake sysfs refresh_waveform node (a plain temp file)
local wf_path = os.tmpname()
local function write_wf(v)
    local f = assert(io.open(wf_path, "w"))
    f:write(v)
    f:close()
end
local function read_wf()
    local f = assert(io.open(wf_path, "r"))
    local v = f:read("*l")
    f:close()
    return v
end

-- 2a. load the REAL main.lua; the duplicate-copy sentinel admits one
local IdleWasher = dofile(plugin_dir .. "/main.lua")
report(type(IdleWasher) == "table" and IdleWasher.name == "idlewasher",
       "main.lua loads as the idlewasher plugin class",
       tostring(IdleWasher.name))
local second = dofile(plugin_dir .. "/main.lua")
report(type(second) == "table" and second.disabled == true,
       "duplicate copy self-disables via the load sentinel",
       "disabled=" .. tostring(second.disabled))
IdleWasher.WAVEFORM_SYSFS = wf_path

-- 2b. disabled: registers NOTHING
settings.idlewasher_enabled = false
local off = IdleWasher:new{}
report(rawget(off, "onPageUpdate") == nil
       and rawget(off, "onPosUpdate") == nil
       and rawget(off, "onInputEvent") == nil
       and rawget(off, "onIdleWasherDeepClean") == nil
       and IdleWasher.onPageUpdate == nil
       and IdleWasher.onInputEvent == nil,
       "disabled: no event handlers exist (instance or class)", "")
report((UIManager.event_hook.InputEvent == nil
        or #UIManager.event_hook.InputEvent == 0)
       and #UIManager.scheduled == 0
       and next(dispatcher_actions) == nil
       and #UIManager.dirty == 0,
       "disabled: no hook, no timer, no dispatcher action, no washes",
       string.format("sched=%d dirty=%d", #UIManager.scheduled,
                     #UIManager.dirty))
report(log_grep("[idlewasher] disabled") == 1,
       "disabled: logs one [idlewasher] disabled line", "")

-- 2c. enabled: full wiring (fast config so the test drives the chain)
settings.idlewasher_enabled = nil          -- absent = default true
settings.idlewasher_debt_min = 2
settings.idlewasher_debt_max = 4
settings.idlewasher_idle_s = 10
settings.idlewasher_deepclean_idle_s = 30
write_wf("6")
fake_now = 0
local pl = IdleWasher:new{}
report(#UIManager.event_hook.InputEvent == 1,
       "enabled: InputEvent hook registered (bundle's hook container)",
       #UIManager.event_hook.InputEvent .. " hook(s)")
report(dispatcher_actions.idlewasher_deep_clean ~= nil
       and dispatcher_actions.idlewasher_deep_clean.event
           == "IdleWasherDeepClean",
       "enabled: dispatcher deep-clean action registered", "")
report(#UIManager.scheduled == 1
       and UIManager.scheduled[1].when == 10,
       "enabled: startup arms the idle timer at idle_s",
       #UIManager.scheduled .. " scheduled")
report(log_grep("[idlewasher] enabled debt_min=2 debt_max=4 idle_s=10"
                .. " deepclean_idle_s=30") == 1,
       "enabled: logs its live config", "")

-- page turns to debt_max: the 4th wash is bundled
for i = 1, 4 do pl:onPageUpdate(i) end
report(UIManager:washes() == 1
       and log_grep("[idlewasher] bundled wash (debt max)") == 1,
       "debt_max page turn fires one bundled setDirty(all,full)",
       UIManager:washes() .. " wash(es)")

-- PosUpdate counts only page CHANGES (rolling scroll mode)
pl:onPosUpdate(120, 4)      -- same page as the last PageUpdate: no debt
pl:onPosUpdate(140, 5)      -- page changed: debt
report(pl.core.debt == 1,
       "PosUpdate: same page ignored, page change counts",
       "debt=" .. pl.core.debt)

-- idle wash: input at t=2, debt 2 >= debt_min by t=12
fake_now = 2
UIManager.event_hook:execute("InputEvent")
pl:onPageUpdate(6)
report(pl.core.debt == 2, "debt accrues across the input",
       "debt=" .. pl.core.debt)
fake_now = 12
UIManager:fire_due()
report(UIManager:washes() == 2
       and log_grep("[idlewasher] idle wash (debt=2)") == 1,
       "idle timer fires the idle wash at debt >= debt_min",
       UIManager:washes() .. " wash(es)")

-- deep clean at deepclean_idle_s: GC16 flip + wash + scheduled restore
fake_now = 32                               -- idle = 30 since t=2
UIManager:fire_due()
report(read_wf() == "4"
       and log_grep("[idlewasher] deep clean (GC16)") == 1,
       "deep clean flips the sysfs waveform to GC16 and washes",
       "wf=" .. tostring(read_wf()))
report(UIManager:washes() == 3,
       "deep clean fired exactly one more full wash",
       UIManager:washes() .. " wash(es)")
local restore_due, timer_still = 0, 0
for _, s in ipairs(UIManager.scheduled) do
    if s.fn == pl.restore_task then restore_due = s.when end
    if s.fn == pl.timer_task then timer_still = timer_still + 1 end
end
report(restore_due == 32 + IdleWasher.RESTORE_DELAY_S,
       "restore scheduled RESTORE_DELAY_S after the deep clean",
       "at t=" .. tostring(restore_due))
report(timer_still == 0,
       "idle chain parks after the deep clean (no timer re-arm)",
       timer_still .. " timer task(s)")
fake_now = 35
UIManager:fire_due()
report(read_wf() == "6"
       and log_grep("[idlewasher] deep clean restore"
                    .. " (refresh_waveform=6)") == 1,
       "restore puts the prior waveform back after settle",
       "wf=" .. tostring(read_wf()))

-- manual dispatcher deep clean, then teardown mid-restore-window
fake_now = 40
UIManager.event_hook:execute("InputEvent")  -- new span, re-arms
pl:onPageUpdate(7)
pl:onIdleWasherDeepClean()
report(read_wf() == "4" and pl.core.debt == 0,
       "dispatcher deep clean flips GC16 and retires the debt",
       string.format("wf=%s debt=%d", tostring(read_wf()), pl.core.debt))
pl:onCloseWidget()
report(read_wf() == "6",
       "onCloseWidget restores the waveform immediately (never parked"
       .. " on GC16)", "wf=" .. tostring(read_wf()))
local leftovers = 0
for _, s in ipairs(UIManager.scheduled) do
    if s.fn == pl.timer_task or s.fn == pl.restore_task then
        leftovers = leftovers + 1
    end
end
report(leftovers == 0, "onCloseWidget unschedules this instance's tasks",
       leftovers .. " leftover(s)")
report(#UIManager.event_hook.InputEvent == 0,
       "onCloseWidget unregisters the InputEvent hook (hook wrapper)",
       #UIManager.event_hook.InputEvent .. " hook(s)")

os.remove(wf_path)

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
