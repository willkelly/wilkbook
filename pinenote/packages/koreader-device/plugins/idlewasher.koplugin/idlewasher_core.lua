--[[--
idlewasher_core -- the pure decision core of the wilkbook idle washer.

No UIManager, no KOReader, no ffi: plain numbers in, action tables out,
so the whole debt/idle state machine runs table-driven on any luajit
(pinenote/tools/koreader-input/test-idlewasher-logic.lua).  main.lua
owns the wiring: it feeds the three inputs below and executes the
returned actions through UIManager.

Inputs (all times monotonic seconds, caller-supplied):

  * on_page_turn(now) -- a page became current (PageUpdate, or a
    page-changing PosUpdate in rolling scroll mode)
  * on_input(now)     -- any user input frame (UIManager's InputEvent
    hook fires once per input batch)
  * on_timer(now)     -- the armed idle timer fired
  * on_manual_deep_clean(now) -- a deep clean ran outside the idle
    chain (dispatcher action): retire the debt, mark the span done

Output: nil (nothing to do), or a table with any of:

  * wash = "bundled"|"idle" -- fire one full wash (debt was reset)
  * debt = <n>              -- the debt the wash/clean retired
  * deep_clean = true       -- fire the GC16 deep-clean sequence
  * arm / rearm = <seconds> -- (re)schedule the idle timer; `arm` comes
                               from on_input, `rearm` from on_timer --
                               identical meaning for the caller

Timer protocol (autosuspend's actual mechanism, not re-arm-per-event):
on_input only records the activity time; the timer stays armed.  When
it fires early (activity happened since arming), the core answers
rearm = the remaining idle window.  Once the idle threshold is crossed
the chain keeps re-arming toward the deep clean, then PARKS -- no
wakeups on an untouched device -- until the next input re-arms it.

Policy grounding (doc/refresh-policy.md, findings 6-10 + Decisions):
ioctl-path washes have never corrupted anything (finding 10) and GL16
fulls are optically ~free (finding 6), but each wash still interrupts
for ~447 ms -- so washes are steered onto natural pauses (idle) with a
hard debt ceiling as backstop (cadence <= 20 measured free, 48 diverse
washless turns stayed clean with autos off; 60 is far past any measured
need).  Only a GC16 deep clean re-scrubs believed-white residue under
the GL16 policy ("what the numbers say" #2) -- once per idle span.
--]]

local Core = {}
Core.__index = Core

Core.DEFAULTS = {
    debt_min = 15,          -- min debt for an idle wash to be worth it
    debt_max = 60,          -- hard ceiling: wash rides the page turn
    idle_s = 45,            -- pause length that counts as idle
    deepclean_idle_s = 600, -- pause length that earns a GC16 deep clean
}

function Core.new(cfg)
    cfg = cfg or {}
    local self = setmetatable({}, Core)
    self.enabled = cfg.enabled ~= false
    for k, default in pairs(Core.DEFAULTS) do
        local v = tonumber(cfg[k])
        self[k] = (v and v > 0) and v or default
    end
    self.debt = 0                 -- page turns since the last full wash
    self.last_activity = tonumber(cfg.now) or 0
    self.armed = false            -- caller's idle timer state, mirrored
    self.deepclean_done = false   -- a deep clean ran this idle span
    self.last_wash_at = nil       -- introspection/logging only
    self.last_deepclean_at = nil  -- "last GC16 time"
    return self
end

function Core:on_page_turn(now)
    if not self.enabled then return nil end
    self.debt = self.debt + 1
    if self.debt >= self.debt_max then
        local retired = self.debt
        self.debt = 0
        self.last_wash_at = now
        return { wash = "bundled", debt = retired }
    end
    return nil
end

function Core:on_input(now)
    if not self.enabled then return nil end
    self.last_activity = now
    self.deepclean_done = false   -- new activity opens a new idle span
    if not self.armed then
        self.armed = true
        return { arm = self.idle_s }
    end
    return nil
end

function Core:on_timer(now)
    if not self.enabled then return nil end
    self.armed = false
    local idle = now - self.last_activity
    if idle < self.idle_s then
        -- input happened since arming: not idle yet, check again when
        -- the current pause would reach the threshold
        self.armed = true
        return { rearm = self.idle_s - idle }
    end
    local out = {}
    if idle >= self.deepclean_idle_s and not self.deepclean_done then
        -- the deep clean IS a full wash (GC16 global): it retires the
        -- debt too, and supersedes a same-tick idle wash
        out.deep_clean = true
        out.debt = self.debt
        self.debt = 0
        self.deepclean_done = true
        self.last_wash_at = now
        self.last_deepclean_at = now
    elseif self.debt >= self.debt_min then
        out.wash = "idle"
        out.debt = self.debt
        self.debt = 0
        self.last_wash_at = now
    end
    if not self.deepclean_done then
        -- keep the chain alive until the deep clean has run; afterwards
        -- the timer parks until the next input re-arms it
        self.armed = true
        out.rearm = self.deepclean_idle_s - idle
    end
    if out.wash or out.deep_clean or out.rearm then return out end
    return nil
end

function Core:on_manual_deep_clean(now)
    if not self.enabled then return nil end
    local retired = self.debt
    self.debt = 0
    self.deepclean_done = true
    self.last_wash_at = now
    self.last_deepclean_at = now
    return { debt = retired }
end

return Core
