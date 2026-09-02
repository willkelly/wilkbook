-- broker_quiesce.lua: the decision and the wait, proven offline (issue #42).
local Quiesce = assert(loadfile(arg[1] or "../../packages/platform-controls/broker_quiesce.lua"))()
local failures = 0
local function check(ok, label, detail)
    print((ok and "PASS: " or "FAIL: ") .. label .. (detail and (" -- " .. tostring(detail)) or ""))
    if not ok then failures = failures + 1 end
end
local logs = {}
local function log(s) logs[#logs + 1] = s end

-- A fake EBC: `series` is the interrupt count returned on successive reads.
local function fake(series, has_barrier, barrier_result)
    local i, slept = 0, 0
    local q = Quiesce.new{
        driver_has_barrier = function() return has_barrier end,
        barrier = function() return unpack(barrier_result or { true, "barrier" }) end,
        irq_count = function() i = i + 1; return series[math.min(i, #series)] end,
        sleep_ms = function(ms) slept = slept + ms end,
        log = log, stable_ms = 250, poll_ms = 25, timeout_ms = 10000,
    }
    return q, function() return slept end
end

-- 1. Shipping driver: the barrier is used, and its verdict is the verdict.
do
    local q = fake({ 100 }, true, { true, "barrier" })
    local ok, detail = q:wait()
    check(ok and detail == "barrier", "shipping driver: REFRESH_BARRIER path is taken and its result returned", detail)
    local q2 = fake({ 100 }, true, { false, "SUBMIT ioctl returned -1 (errno 110)" })
    local ok2, detail2 = q2:wait()
    check(not ok2 and detail2:find("errno 110", 1, true), "shipping driver: a barrier failure is a failure", detail2)
end
-- 2. Direct driver: a panel mid-refresh (count climbing) then idle.
do
    -- 12 climbing reads (~300 ms of frames), then flat.
    local series = {}
    for n = 1, 13 do series[n] = 1000 + n end
    local q, slept = fake(series, false)
    local ok, detail = q:wait()
    check(ok and detail == "idle", "direct driver: waits through the refresh and returns idle", detail)
    check(slept() >= 250 + 12 * 25 and slept() < 10000, "direct driver: idle is declared after the count is flat for stable_ms", slept())
end
-- 3. Direct driver: never idle -> timeout, reported as EBC busy.
do
    local series = {}
    for n = 1, 1000 do series[n] = n end
    local q, slept = fake(series, false)
    local ok, detail = q:wait()
    check(not ok and detail:find("EBC busy", 1, true) and slept() >= 10000,
          "direct driver: a panel that never goes quiet times out as EBC busy", detail)
end
-- 4. Direct driver: no interrupt line at all is a hard failure, not a pass.
do
    local q = fake({}, false)   -- irq_count returns nil
    local ok, detail = q:wait()
    check(not ok and detail:find("not found", 1, true), "direct driver: a missing EBC interrupt line refuses to suspend", detail)
end
-- 5. Direct driver: already idle -> returns after stable_ms, not immediately.
do
    local q, slept = fake({ 5 }, false)
    local ok = q:wait()
    check(ok and slept() == 250, "direct driver: an already-idle panel still proves stable_ms of silence", slept())
end
-- 6. The choice is logged either way (the log is the field evidence).
check(#logs >= 6 and logs[1]:find("REFRESH_BARRIER", 1, true) ~= nil, "both paths log which quiesce ran")
-- 7. Dependencies are mandatory.
do
    local ok = pcall(Quiesce.new, { driver_has_barrier = function() end })
    check(not ok, "constructor refuses missing dependencies")
end
os.exit(failures == 0 and 0 or 1)
