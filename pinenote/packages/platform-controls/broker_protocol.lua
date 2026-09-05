-- Pure state machine for the production suspend broker.
local Protocol = {}
Protocol.__index = Protocol

local function reject(self, reason)
    self.log("request rejected: " .. reason)
    self.emit_wakeup()
    self.state, self.deadline, self.trigger = "IDLE", nil, nil
    return false, reason
end

function Protocol:set_enabled(enabled)
    self.enabled = enabled and true or false
    if not self.enabled and self.state == "WAIT_READY" then
        return reject(self, "globally inhibited")
    end
    return true
end

function Protocol:physical_request(trigger)
    if trigger ~= "power" and trigger ~= "cover" and trigger ~= "rtc" then
        return false, "invalid trigger"
    end
    if not self.enabled then return false, "globally inhibited" end
    if self.state ~= "IDLE" then return false, "request already pending" end
    local allowed, reason = self.can_prepare(trigger)
    if not allowed then
        self.log("request rejected before preparation: " .. tostring(reason))
        return false, reason
    end
    self.state = "WAIT_READY"
    self.trigger = trigger
    self.deadline = self.now() + self.ack_timeout
    self.emit_sleep()
    return true
end

function Protocol:ready(request_id)
    if type(request_id) ~= "string" or not request_id:match("^[%w_.:-]+$") then
        return false, "malformed request id"
    end
    if self.seen[request_id] then return false, "duplicate request" end
    if not self.enabled then return reject(self, "globally inhibited") end
    if self.state == "SUSPENDING" then return false, "suspend in progress" end

    self.seen[request_id] = true
    self.state = "SUSPENDING"
    local ok, detail = self.suspend(false, request_id, self.trigger or "koreader")
    self.state, self.deadline, self.trigger = "IDLE", nil, nil
    self.emit_wakeup()
    self:settle_after(ok, detail, self.now())
    return ok, detail
end

-- An RTC backstop wake is unattended: the device settles for rtc_settle
-- seconds and goes back to sleep by itself.  Any OTHER wake -- button,
-- cover, or a suspend that failed -- ends with a person or a fault in the
-- loop, and must clear whatever settle deadline an earlier RTC wake left
-- behind.  Glass, 2026-09-04: an RTC wake set the deadline, KOReader's
-- own idle timer suspended the device inside the window, and the next
-- BUTTON wake -- 37 minutes later -- was re-suspended seven seconds in by
-- the stale deadline; the reader looked dead to the operator.
function Protocol:settle_after(ok, detail, now)
    if ok and detail == "rtc" then
        self.resuspend_at = now + self.rtc_settle
    else
        self.resuspend_at = nil
    end
end

function Protocol:tick()
    local now = self.now()
    if self.resuspend_at and now >= self.resuspend_at then
        self.resuspend_at = nil
        return self:physical_request("rtc")
    end
    if self.state ~= "WAIT_READY" or now < self.deadline then return false end
    if not self.enabled then return reject(self, "globally inhibited") end
    self.state = "SUSPENDING"
    local ok, detail = self.suspend(true, nil, self.trigger)
    self.state, self.deadline, self.trigger = "IDLE", nil, nil
    self.emit_wakeup()
    -- measured from the WAKE: `now` above is from before a suspend that may
    -- have lasted the whole backstop hour, and a deadline computed from it
    -- was already due at the next tick (review 2026-09-04)
    self:settle_after(ok, detail, self.now())
    return ok, detail
end

function Protocol:status()
    return { state = self.state, trigger = self.trigger, deadline = self.deadline,
             enabled = self.enabled, resuspend_at = self.resuspend_at }
end

local function new(deps)
    assert(type(deps) == "table", "broker protocol requires dependencies")
    for _, name in ipairs({ "now", "emit_sleep", "emit_wakeup", "suspend", "log", "can_prepare" }) do
        assert(type(deps[name]) == "function", "missing dependency: " .. name)
    end
    return setmetatable({
        now = deps.now, emit_sleep = deps.emit_sleep,
        emit_wakeup = deps.emit_wakeup, suspend = deps.suspend, log = deps.log,
        can_prepare = deps.can_prepare,
        ack_timeout = deps.ack_timeout or 10, rtc_settle = deps.rtc_settle or 20,
        enabled = true, state = "IDLE", seen = {},
    }, Protocol)
end

return { new = new }
