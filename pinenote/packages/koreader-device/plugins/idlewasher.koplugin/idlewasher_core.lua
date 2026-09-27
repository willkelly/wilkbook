--[[--
idlewasher_core -- the pure decision core of the wilkbook idle washer.

No UIManager, no KOReader, no ffi: plain numbers in, action tables out,
so the whole debt/idle state machine runs table-driven on any luajit
(pinenote/tools/koreader-input/test-idlewasher-logic.lua).  main.lua
owns the wiring: it feeds the inputs below and executes the
returned actions through UIManager.

Inputs (all times monotonic seconds, caller-supplied):

  * on_page_turn(now, n, held) -- n pages became current (default 1);
    held suppresses a bundled wash, accumulating at the debt ceiling
  * on_input(now)     -- any user input frame (UIManager's InputEvent
    hook fires once per input batch)
  * on_timer(now)     -- the armed idle timer fired
  * on_manual_deep_clean(now) -- a deep clean ran outside the idle
    chain (dispatcher action): retire the debt, mark the span done
  * on_charge(n)      -- n units of ghosting that no page turn counted
    (the notebook's erases, undos and panel closes): added to the debt,
    capped at debt_max, and never answered with a wash.  The caller
    charges straight after the user's own action, where a bundled wash
    would interrupt it; the idle wash, or the next page turn once the
    debt is at debt_max, retires it
  * begin_external_wash() / finish_external_wash(receipt, success, now)
    -- retire an explicit Refresh's old debt only after its queued ioctl
    succeeds; preserve charges since the receipt and reject stale receipts

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

One exception to "the timer stays armed": the chain has TWO horizons
(idle_s and deepclean_idle_s), and after a below-debt_min idle span the
timer is armed hundreds of seconds out, toward the deep clean.  When
reading resumes, on_input must pull that deadline back in to idle_s
after the new activity -- the core mirrors the caller's deadline in
armed_deadline for exactly this comparison.  Without it the idle wash
can never fire after any idle span that ends below debt_min (the
2026-07-11 acceptance-run bug: proven on glass, regression-tested in
test-idlewasher-logic.lua "resumed reading pulls a far deadline in").

Policy grounding (doc/refresh-policy.md, findings 6-10 + Decisions):
ioctl-path washes have never corrupted anything (finding 10) and GL16
fulls are optically ~free (finding 6), but each wash still interrupts
for ~596 ms -- so washes are steered onto natural pauses (idle) with a
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
    self.debt = 0                 -- page turns and charges since the last wash
    self.last_activity = tonumber(cfg.now) or 0
    self.armed = false            -- caller's idle timer state, mirrored
    self.armed_deadline = nil     -- ...and its absolute deadline
    self.deepclean_done = false   -- a deep clean ran this idle span
    self.last_wash_at = nil       -- introspection/logging only
    self.last_deepclean_at = nil  -- "last GC16 time"
    self.wash_epoch = 0
    self.charged = 0             -- capped increments, including after a receipt
    return self
end

function Core:on_page_turn(now, n, held)
    if not self.enabled then return nil end
    n = tonumber(n or 1)
    if not n or n ~= n or n <= 0 or n == math.huge then return nil end
    self.charged = self.charged + n
    self.debt = self.debt + n
    if held then self.debt = math.min(self.debt, self.debt_max) end
    if self.debt >= self.debt_max and not held then
        local retired = self.debt
        self.debt = 0
        self.wash_epoch = self.wash_epoch + 1
        self.last_wash_at = now
        return { wash = "bundled", debt = retired }
    end
    return nil
end

-- Accumulate only; always nil.  A non-positive or non-numeric n is ignored.
function Core:on_charge(n)
    if not self.enabled then return nil end
    n = tonumber(n)
    if not n or n ~= n or n <= 0 then return nil end
    -- A single charge cannot exceed the ceiling.  Keep the increments
    -- even when debt saturates, so a pending receipt cannot erase NEW
    -- debt merely because it was added while the old debt was at the cap.
    n = math.min(n, self.debt_max)
    self.charged = self.charged + n
    local debt = self.debt + n
    if debt > self.debt_max then debt = self.debt_max end
    self.debt = debt
    return nil
end

function Core:on_input(now)
    if not self.enabled then return nil end
    self.last_activity = now
    self.deepclean_done = false   -- new activity opens a new idle span
    local want = now + self.idle_s
    if not self.armed
       or (self.armed_deadline and self.armed_deadline > want) then
        -- not armed, or armed far out (a prior span's deep-clean
        -- horizon): pull the next check in to idle_s after THIS input
        self.armed = true
        self.armed_deadline = want
        return { arm = self.idle_s }
    end
    return nil
end

function Core:on_timer(now)
    if not self.enabled then return nil end
    self.armed = false
    self.armed_deadline = nil
    local idle = now - self.last_activity
    if idle < self.idle_s then
        -- input happened since arming: not idle yet, check again when
        -- the current pause would reach the threshold
        self.armed = true
        self.armed_deadline = now + (self.idle_s - idle)
        return { rearm = self.idle_s - idle }
    end
    local out = {}
    if idle >= self.deepclean_idle_s and not self.deepclean_done then
        -- the deep clean IS a full wash (GC16 global): it retires the
        -- debt too, and supersedes a same-tick idle wash
        out.deep_clean = true
        out.debt = self.debt
        self.debt = 0
        self.wash_epoch = self.wash_epoch + 1
        self.deepclean_done = true
        self.last_wash_at = now
        self.last_deepclean_at = now
    elseif self.debt >= self.debt_min then
        out.wash = "idle"
        out.debt = self.debt
        self.debt = 0
        self.wash_epoch = self.wash_epoch + 1
        self.last_wash_at = now
    end
    if not self.deepclean_done then
        -- keep the chain alive until the deep clean has run; afterwards
        -- the timer parks until the next input re-arms it
        self.armed = true
        out.rearm = self.deepclean_idle_s - idle
        self.armed_deadline = now + out.rearm
    end
    if out.wash or out.deep_clean or out.rearm then return out end
    return nil
end

function Core:on_manual_deep_clean(now)
    if not self.enabled then return nil end
    local retired = self.debt
    self.debt = 0
    self.wash_epoch = self.wash_epoch + 1
    self.deepclean_done = true
    self.last_wash_at = now
    self.last_deepclean_at = now
    return { debt = retired }
end

-- Explicit Refresh is asynchronous.  Retire only the request's debt,
-- only on a confirmed successful ioctl, and only once.  Other washes
-- invalidate the receipt; later charges (including saturated ones) stay.
function Core:begin_external_wash()
    if not self.enabled then return nil end
    return { core = self, epoch = self.wash_epoch, charged = self.charged }
end

function Core:finish_external_wash(receipt, success, now)
    if not receipt or receipt.core ~= self or receipt.done then return nil end
    receipt.done = true
    if not self.enabled or success ~= true or receipt.epoch ~= self.wash_epoch then
        return nil
    end
    local before = self.debt
    self.debt = math.min(self.debt, self.charged - receipt.charged)
    self.wash_epoch = self.wash_epoch + 1
    self.last_wash_at = now
    -- This is a normal full wash, not a GC16 deep-clean qualification.
    return { debt = before - self.debt }
end

return Core
