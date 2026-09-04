local protocol = assert(loadfile(arg[1] or "../../packages/platform-controls/broker_protocol.lua"))()
local failures = 0
local function check(value, label)
    print((value and "PASS: " or "FAIL: ") .. label)
    if not value then failures = failures + 1 end
end
local now, trace, outcomes, preparation_allowed, preparation_reason = 100, {}, {}, true, nil
local p = protocol.new{
    now = function() return now end,
    can_prepare = function()
        return preparation_allowed, preparation_reason
    end,
    emit_sleep = function() trace[#trace + 1] = "sleep" end,
    emit_wakeup = function() trace[#trace + 1] = "wake" end,
    suspend = function(fallback, id, trigger)
        trace[#trace + 1] = table.concat({ "suspend", tostring(fallback), id or "-", trigger or "-" }, ":")
        return unpack(table.remove(outcomes, 1) or { true, "button" })
    end,
    log = function(message) trace[#trace + 1] = "log:" .. message end,
}

check(p:physical_request("power"), "power tap emits a preparation request")
check(table.concat(trace, ",") == "sleep", "physical trigger does not suspend before acknowledgement")
check(p:ready("a-1"), "ready acknowledgement suspends")
check(table.concat(trace, ",") == "sleep,suspend:false:a-1:power,wake", "acknowledged transaction is exact")
local ok, why = p:ready("a-1")
check(not ok and why == "duplicate request", "duplicate id is ignored")

trace = {}
preparation_allowed, preparation_reason = false, "charging on rk817-charger"
ok, why = p:physical_request("power")
check(not ok and why == preparation_reason, "charging veto rejects power tap before preparation")
check(p:status().state == "IDLE" and not table.concat(trace, ","):find("sleep", 1, true)
      and not table.concat(trace, ","):find("wake", 1, true),
      "charging veto does not notify or repaint KOReader")
preparation_allowed, preparation_reason = true, nil

trace = {}
check(p:physical_request("cover"), "cover close starts one request")
ok, why = p:physical_request("cover")
check(not ok and why == "request already pending", "duplicate physical trigger coalesces")
now = 111
check(p:tick(), "missing acknowledgement uses fallback after ten seconds")
check(table.concat(trace, ",") == "sleep,suspend:true:-:cover,wake", "fallback transaction is exact")

trace = {}
p:set_enabled(false)
ok, why = p:ready("disabled-1")
check(not ok and why == "globally inhibited" and trace[#trace] == "wake", "enabled=0 rejects and releases KOReader")
p:set_enabled(true)
outcomes[1] = { false, "EBC busy" }
ok, why = p:ready("ebc-1")
check(not ok and why == "EBC busy" and p:status().state == "IDLE" and trace[#trace] == "wake",
      "failed transaction recovers to idle and wakes KOReader")

outcomes[1] = { true, "rtc" }
check(p:ready("rtc-1"), "RTC transaction completes")
now = now + 19
check(not p:tick(), "RTC backstop waits for settle")
now = now + 1
check(p:tick() and p:status().state == "WAIT_READY", "RTC backstop requests unattended re-suspend")

-- Glass, 2026-09-04: an RTC wake left its settle deadline behind, KOReader's
-- own idle timer suspended the device inside the window, and the next BUTTON
-- wake -- 37 minutes later -- was re-suspended seven seconds in by the stale
-- deadline; the reader looked dead to the operator.  Only an RTC wake may
-- leave a settle deadline behind.
outcomes[1] = { true, "rtc" }
check(p:ready("rtc-settle-1") and p:status().resuspend_at == now + 20,
      "the unattended re-suspend's own RTC wake re-arms the settle")
outcomes[1] = { true, "button" }
check(p:ready("koreader-2") and p:status().resuspend_at == nil,
      "quirk: a suspend that ends in a button wake clears the stale RTC settle deadline")
now = now + 2210
trace = {}
check(not p:tick() and p:status().state == "IDLE" and #trace == 0,
      "quirk: nothing re-suspends the reader after that button wake")
outcomes[1] = { true, "rtc" }
check(p:ready("rtc-3") and p:status().resuspend_at == now + 20,
      "an RTC wake after a button wake arms the settle again")
now = now + 20
outcomes[1] = { true, "cover" }
check(p:tick() and p:ready("settle-cover-1") and p:status().resuspend_at == nil,
      "quirk: a settle re-suspend that ends in a cover wake clears the deadline too")
outcomes[1] = { true, "rtc" }
check(p:ready("rtc-4"), "RTC wake")
now = now + 20
outcomes[1] = { false, "EBC busy" }
check(p:tick() and not p:ready("settle-fail-1") and p:status().resuspend_at == nil and p:status().state == "IDLE",
      "a settle re-suspend that fails drops the deadline instead of retrying every tick")

os.exit(failures == 0 and 0 or 1)
