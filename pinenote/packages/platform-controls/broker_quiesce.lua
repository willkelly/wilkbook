-- EBC quiescence before suspend, chosen by what the bound driver offers.
--
-- The broker must not cut power while the panel is mid-refresh (the sleep
-- frame KOReader just painted is still being driven).  wilkbook's SHIPPING
-- driver has a REFRESH_BARRIER ioctl for exactly this (DRM command 0x03);
-- hrdl's direct-mode driver never had it, and registers RECT_HINTS at 0x03
-- instead -- so the barrier's SUBMIT lands in the wrong handler and fails
-- with EFAULT, aborting every suspend (issue #42, glass 2026-09-02).
--
-- So: barrier when the driver registers it, otherwise wait for the EBC's
-- interrupt line to go quiet.  Every frame the EBC drives raises exactly
-- one interrupt (doc/testing.md: "a global refresh costs 1 IRQ; a partial
-- costs 1 per frame" -- either way, no frames means no interrupts, and the
-- lab's frame-clock instrument measures the panel with this very counter).
-- A count unchanged for `stable_ms` (default 250 ms, > 13 frame periods at
-- the panel's ~18 ms worst case) means the drive sequence has ended.
--
-- Pure: every side effect is an injected function, so the decision and
-- the wait are proven offline (test-quiesce.lua).
local Quiesce = {}
Quiesce.__index = Quiesce

function Quiesce:wait()
    if self.driver_has_barrier() then
        self.log("EBC quiesce: driver registers REFRESH_BARRIER; submitting barrier")
        return self.barrier()
    end
    self.log("EBC quiesce: no REFRESH_BARRIER on this driver; waiting for interrupt quiescence")
    local last = self.irq_count()
    if last == nil then return false, "EBC interrupt line not found" end
    local elapsed, stable_for = 0, 0
    while elapsed < self.timeout_ms do
        self.sleep_ms(self.poll_ms)
        elapsed = elapsed + self.poll_ms
        local now = self.irq_count()
        if now == nil then return false, "EBC interrupt line vanished" end
        if now == last then
            stable_for = stable_for + self.poll_ms
            if stable_for >= self.stable_ms then
                self.log(string.format("EBC quiesce: idle (no interrupts for %d ms, %d ms total)",
                                       stable_for, elapsed))
                return true, "idle"
            end
        else
            stable_for = 0
            last = now
        end
    end
    return false, string.format("EBC busy: still interrupting after %d ms", elapsed)
end

local function new(deps)
    assert(type(deps) == "table", "quiesce requires dependencies")
    for _, name in ipairs({ "driver_has_barrier", "barrier", "irq_count", "sleep_ms", "log" }) do
        assert(type(deps[name]) == "function", "missing dependency: " .. name)
    end
    return setmetatable({
        driver_has_barrier = deps.driver_has_barrier, barrier = deps.barrier,
        irq_count = deps.irq_count, sleep_ms = deps.sleep_ms, log = deps.log,
        stable_ms = deps.stable_ms or 250, poll_ms = deps.poll_ms or 25,
        timeout_ms = deps.timeout_ms or 10000,
    }, Quiesce)
end

return { new = new }
