-- Deterministic host-only tests for the auto-suspend daemon's post-wake
-- policy: what the daemon does with the idle timer after it comes back up.
--
-- The daemon cannot be loaded here -- it opens /dev/input/event*, exits
-- when there are none, and then never leaves its main loop -- so this
-- pulls the two pieces that decide the answer (`suspend_once()` and the
-- caller's branch on its result) VERBATIM out of autosuspend.lua and runs
-- them against injected fakes and a virtual clock.  Same contract as the
-- EBC host tools: the shipped source is what executes, not a paraphrase
-- of it, so a rebase or an edit that changes behaviour turns this red.
--
-- The finding this pins (2026-08-07).  An RTC-backstop wake means the
-- alarm fired, which means nobody pressed anything and nobody is looking
-- at the device.  Waiting out a fresh full idle period there is what made
-- standby cost ~2.7x the deep floor: at idle=300/backstop=900 a device
-- alone in a bag spent 300 s of every 1200 s awake at ~157 mA -- 54.7 mA
-- average, flat in ~3 days instead of ~8.  The 2026-08-03 unplugged soak
-- had already measured it (awake windows of 65/60/57 s after each RTC
-- resume at idle=60/backstop=240) and it was read as an argument FOR a
-- long idle default rather than as a bug.  A button wake is the opposite
-- case and must still get the whole idle period.
--
-- Usage: luajit test-autosuspend-policy.lua [autosuspend.lua] [autosuspend.scm]

local source_path = arg[1] or "pinenote/tools/power/autosuspend.lua"
local service_path = arg[2] or "pinenote/services/autosuspend.scm"

-- Measured inputs, not modelled ones: settled reader awake idle and the
-- deep rail floor from doc/artifacts/pinenote-awake-levers-20260806/,
-- against a 4000 mAh charge_full.  Everything derived from them below is
-- arithmetic on measurements, not itself a measurement.
local I_AWAKE_MA, I_DEEP_MA, CAPACITY_MAH = 156.9, 20.6, 4000

local failures = 0

local function report(ok, label, detail)
    if ok then
        print("PASS: " .. label)
    else
        failures = failures + 1
        print("FAIL: " .. label .. (detail and (" - " .. detail) or ""))
    end
end

-- Extraction failures are fatal rather than counted: every later
-- assertion would be vacuous, and a silently-empty suite is worse than
-- no suite.
local function fatal(msg)
    print("FAIL: " .. msg)
    os.exit(1)
end

local function read_lines(path)
    local f = io.open(path, "r")
    if not f then fatal("cannot open " .. path) end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    return lines
end

local lines = read_lines(source_path)

-- `local function name()` at column 0, closed by the first `end` at
-- column 0.
local function extract_function(name)
    local first
    for i, line in ipairs(lines) do
        if line:match("^local function " .. name .. "%(") then first = i break end
    end
    if not first then fatal("no `local function " .. name .. "` in " .. source_path) end
    for i = first + 1, #lines do
        if lines[i] == "end" then
            return table.concat(lines, "\n", first, i)
        end
    end
    fatal(name .. " never closes at column 0 in " .. source_path)
end

-- The suspend call in the idle branch of the main loop, through the end
-- of the if-chain that decides where last_activity lands.  Anchored on
-- `local slept_ok` so it still extracts from a tree without the fix (the
-- point of the negative test).
local function extract_decision()
    local first
    for i, line in ipairs(lines) do
        if line:match("local slept_ok") then first = i break end
    end
    if not first then fatal("no `local slept_ok = suspend_once()` in " .. source_path) end
    local if_line, indent
    for i = first, #lines do
        local ind = lines[i]:match("^(%s*)if not slept_ok then")
        if ind then if_line, indent = i, ind break end
    end
    if not if_line then fatal("no `if not slept_ok then` after the suspend call") end
    for i = if_line + 1, #lines do
        if lines[i] == indent .. "end" then
            return table.concat(lines, "\n", first, i)
        end
    end
    fatal("the post-suspend if-chain never closes")
end

-- Build-time default out of the `local opt = {` table.
local function opt_default(key)
    for _, line in ipairs(lines) do
        local v = line:match("^%s*" .. key .. "%s*=%s*(%d+),")
        if v then return tonumber(v) end
    end
    fatal("no numeric opt." .. key .. " default in " .. source_path)
end

local suspend_once_src = extract_function("suspend_once")
local decision_src = extract_decision()

-- One cycle of the loop the daemon runs when nobody is present: suspend,
-- wake, decide.  Returns the seconds the daemon will now stay awake
-- before the idle timer expires again, which is the whole quantity in
-- dispute -- 20 s of settle or a fresh 300 s idle period at ~157 mA.
local function cycle(s)
    local now = 1754500000
    local env = {}
    env.os = {
        time = function() return now end,
        execute = function() return 0 end,
    }
    env.tostring = tostring
    env.log = function() end
    env.opt = { overlay = true, power_grace_s = 2 }
    env.idle_secs = function() return s.idle end
    env.backstop_secs = function() return s.backstop end
    env.read_file = function(path)
        if path:find("mem_sleep", 1, true) then return s.mem_sleep or "s2idle [deep]" end
        return nil
    end
    env.write_file = function(path, _)
        if path == "/sys/power/state" then
            if s.mem_refused then return false end
            -- Wall clock advances across a real suspend; the monotonic
            -- clock does not.  os.time() is wall clock, which is why the
            -- daemon can measure the sleep at all.
            now = now + s.slept
            return true
        end
        return true
    end
    env.quiesce_gadget = function() return "fcc00000.dwc3" end
    env.restore_gadget = function() end
    env.arm_backstop = function() return s.arm ~= false end
    env.set_no_off_screen = function() end
    env.draw_banner = function() return true end
    env.restore_banner_area = function() return true end
    -- Frontlight ordering is load-bearing, so the fakes record a trace
    -- rather than just satisfying the call: the light must go out only
    -- AFTER the EBC gate has passed (an aborted suspend must not darken a
    -- live reader) and must come back only AFTER the wash (or the user is
    -- shown a lit banner instead of their page).
    local fl_order, fl_restored = {}, nil
    s._fl_order, s._fl = fl_order, nil
    env.frontlight_save_and_off = function()
        fl_order[#fl_order + 1] = "off"
        return { { dir = "/sys/class/backlight/backlight_cool",
                   name = "backlight_cool", value = "153" } }
    end
    env.frontlight_restore = function(saved)
        fl_order[#fl_order + 1] = "restore"
        fl_restored = saved
        s._fl = saved
    end
    -- Resume work (Wi-Fi re-association, banner restore, the GC16 wash)
    -- runs after the sleep duration is captured and before the caller
    -- stamps the idle timer, so it must not be able to reclassify a wake.
    env.cleanup_wash = function()
        fl_order[#fl_order + 1] = "wash"
        now = now + (s.resume_work or 0)
    end
    env.wait_ebc_idle = function() return s.ebc_idle ~= false end
    env.drain_all = function() end
    env.SLEEP_TEXT = "SUSPENDED - PRESS POWER TO RESUME"

    local chunk_src = table.concat({
        suspend_once_src,
        "local last_activity, power_ignore_until",
        "return function()",
        decision_src,
        "return last_activity",
        "end",
    }, "\n")
    local chunk = loadstring(chunk_src, "@" .. source_path .. ":extracted")
    if not chunk then fatal("extracted source does not compile") end
    setfenv(chunk, env)
    local last_activity = chunk()()
    -- Exactly the main loop's own next-iteration arithmetic.
    return s.idle - (now - last_activity)
end

-- Scenario parameters, deliberately not read from the source: the branch
-- has to key off whatever backstop is configured, and this is also the
-- pair that shipped with the bug.  The live defaults are read from the
-- source for the duty-cycle check further down.
local IDLE, BACKSTOP = 300, 900

-- An RTC-backstop wake settles briefly and goes back down.  The window
-- must stay open long enough to be usable: a human who sees the banner
-- clear, or an input event, has to be able to keep the device up, and a
-- non-positive value would be a suspend/resume thrash with no gap at all.
-- It must also be strictly shorter than the idle period, or the bug is
-- still there at short idle settings -- the 2026-08-03 soak ran
-- idle=60/backstop=240, where "a fresh idle period" is only 60 s and
-- passes any bound generous enough for the 300 s default.
local backstop_cases = {
    { label = "exact backstop", s = { idle = IDLE, backstop = BACKSTOP, slept = BACKSTOP } },
    { label = "alarm plus resume latency", s = { idle = IDLE, backstop = BACKSTOP, slept = BACKSTOP + 3 } },
    { label = "alarm a hair early", s = { idle = IDLE, backstop = BACKSTOP, slept = BACKSTOP - 4 } },
    { label = "slow resume work", s = { idle = IDLE, backstop = BACKSTOP, slept = BACKSTOP, resume_work = 5 } },
    { label = "one-hour backstop", s = { idle = IDLE, backstop = 3600, slept = 3600 } },
    { label = "four-minute backstop", s = { idle = 60, backstop = 240, slept = 240 } },
}
for _, case in ipairs(backstop_cases) do
    local awake = cycle(case.s)
    report(awake > 0 and awake <= 60 and awake < case.s.idle,
        "backstop wake re-suspends after a short settle (" .. case.label .. ")",
        ("stays awake %ss, wanted 0 < awake <= 60 and awake < idle=%ds")
            :format(tostring(awake), case.s.idle))
end

-- A button wake means somebody is here.  The tolerance either side of the
-- alarm has to stay tight, or a real user press gets read as the alarm
-- and the device sleeps under their hands.
local button_cases = {
    { label = "woke at 35s", s = { idle = IDLE, backstop = BACKSTOP, slept = 35 }, want = IDLE },
    { label = "woke 30s before the alarm", s = { idle = IDLE, backstop = BACKSTOP, slept = BACKSTOP - 30 }, want = IDLE },
    { label = "backstop is read from config, not hard-coded",
      s = { idle = IDLE, backstop = 3600, slept = BACKSTOP }, want = IDLE },
    { label = "instant wake", s = { idle = IDLE, backstop = BACKSTOP, slept = 0 }, want = IDLE },
}
for _, case in ipairs(button_cases) do
    local awake = cycle(case.s)
    report(awake == case.want,
        "button wake keeps the full idle period (" .. case.label .. ")",
        "stays awake " .. tostring(awake) .. "s, wanted " .. case.want)
end

-- A refused or aborted suspend is transient and retries fast; it must not
-- fall into the backstop branch just because it never slept.
local abort_cases = {
    { label = "kernel refused the mem write", s = { idle = IDLE, backstop = BACKSTOP, slept = 0, mem_refused = true } },
    { label = "EBC still active", s = { idle = IDLE, backstop = BACKSTOP, slept = 0, ebc_idle = false } },
    { label = "RTC alarm would not arm", s = { idle = IDLE, backstop = BACKSTOP, slept = 0, arm = false } },
    { label = "deep unavailable", s = { idle = IDLE, backstop = BACKSTOP, slept = 0, mem_sleep = "[s2idle]" } },
}
for _, case in ipairs(abort_cases) do
    local awake = cycle(case.s)
    report(awake > 0 and awake <= 60,
        "failed suspend retries without a full idle period (" .. case.label .. ")",
        "stays awake " .. tostring(awake) .. "s, wanted 0 < awake <= 60")
end

-- The duty cycle at the shipped defaults, which is the number that was
-- wrong.  Arithmetic on the measured draws above, and deliberately naive:
-- it charges the awake window at settled idle and ignores the per-cycle
-- resume burst (Wi-Fi re-association, wash) that the 2026-08-03 soak
-- measured at ~1.2 mAh, so it is a bound, not a prediction.  The
-- multi-day soak that would measure any of this end to end has not run.
local d_idle, d_backstop = opt_default("idle"), opt_default("backstop")
local awake = cycle({ idle = d_idle, backstop = d_backstop, slept = d_backstop })
local cycle_s = d_backstop + awake
local duty = awake / cycle_s
local avg_ma = (I_DEEP_MA * d_backstop + I_AWAKE_MA * awake) / cycle_s
local days = CAPACITY_MAH / avg_ma / 24
report(duty <= 0.05,
    ("shipped defaults idle=%ds backstop=%ds: %.1f%% awake duty cycle")
        :format(d_idle, d_backstop, duty * 100),
    ("%.1f%% awake, wanted <= 5%%"):format(duty * 100))
report(avg_ma <= 25 and days >= 6.5,
    ("shipped defaults model %.1f mA idle average, %.1f days on 4000 mAh")
        :format(avg_ma, days),
    ("%.1f mA / %.1f days, wanted <= 25 mA and >= 6.5 days"):format(avg_ma, days))

-- The service passes --idle/--backstop explicitly, so its defaults are
-- the ones that actually ship; the daemon's own are what anyone reading
-- or hand-running the script sees.  A silent divergence means the
-- documented value is not the deployed one.
do
    local scm = read_lines(service_path)
    local function scm_default(field)
        for _, line in ipairs(scm) do
            if line:find(field, 1, true) then
                local v = line:match("%(default (%d+)%)")
                if v then return tonumber(v) end
            end
        end
    end
    local svc_idle = scm_default("pinenote-autosuspend-idle-seconds")
    local svc_backstop = scm_default("pinenote-autosuspend-backstop-seconds")
    report(svc_idle == d_idle, "service idle default matches the daemon's",
        tostring(svc_idle) .. " vs " .. tostring(d_idle))
    report(svc_backstop == d_backstop, "service backstop default matches the daemon's",
        tostring(svc_backstop) .. " vs " .. tostring(d_backstop))
end

-- ---------------------------------------------------------------- --
-- Frontlight across suspend (2026-08-07).
--
-- The daemon never touched the frontlight.  Two failure modes, either
-- sufficient: a reader that falls asleep lit burns LED current for the
-- whole sleep (and every current figure in doc/power-management.md was
-- taken at frontlight ZERO), and mainline lm3630a_bl.c has no
-- dev_pm_ops, so after the rail drops the panel can return dark while
-- sysfs still reports the old brightness.  doc/hardware-deploy.md:184
-- already told the operator to re-set these by hand "or the box is pitch
-- black" -- that note IS this bug, worked around by hand.

local function order_of(s)
    cycle(s)
    return table.concat(s._fl_order, ",")
end

report(order_of({ idle = IDLE, backstop = BACKSTOP, slept = 30 }) == "off,wash,restore",
    "normal cycle: light out before sleeping, restored after the wash",
    order_of({ idle = IDLE, backstop = BACKSTOP, slept = 30 }))

report(order_of({ idle = IDLE, backstop = BACKSTOP, slept = 0, mem_refused = true })
       :find("restore", 1, true) ~= nil,
    "a refused suspend still restores the frontlight",
    "otherwise the reader is left dark AND awake, which reads as a dead device")

report(order_of({ idle = IDLE, backstop = BACKSTOP, slept = 0, ebc_idle = false }) == "",
    "an EBC-abort never touches the frontlight",
    "a suspend that does not happen must not darken a reader in use")

do
    local sc = { idle = IDLE, backstop = BACKSTOP, slept = 30 }
    cycle(sc)
    report(sc._fl and sc._fl[1] and sc._fl[1].value == "153",
        "the SAVED brightness is restored, not a hardcoded value",
        sc._fl and sc._fl[1] and tostring(sc._fl[1].value))
end

-- ---------------------------------------------------------------- --
-- Cover classification (2026-08-07).
--
-- The daemon counted ANY readable input event as activity, and its own
-- header said so: "buttons and the cover all count".  So closing the
-- cover -- the gesture meaning "I am putting this away" -- RESET the idle
-- timer and held the device awake for a further idle period at ~157 mA.

local ffi = require("ffi")
ffi.cdef[[
struct as_input_event {
    long tv_sec; long tv_usec;
    unsigned short type; unsigned short code; int value;
};
]]

local classify_src = extract_function("scan_activity_and_cover")

local function classify(events)
    local buf = ffi.new("struct as_input_event[?]", #events)
    for i, e in ipairs(events) do
        buf[i - 1].type, buf[i - 1].code, buf[i - 1].value = e[1], e[2], e[3]
    end
    local env = {
        ffi = ffi, math = math, tonumber = tonumber,
        drain = buf, INPUT_EVENT_SIZE = 24,
        EV_SYN = 0, EV_SW = 5, SW_LID = 0,
    }
    local chunk = loadstring(classify_src ..
        "\nreturn scan_activity_and_cover(...)", "@classify")
    if not chunk then fatal("scan_activity_and_cover does not compile standalone") end
    setfenv(chunk, env)
    return chunk(#events * 24)
end

local T_SYN, T_KEY, T_ABS, T_SW = 0, 1, 3, 5

do
    local act, closed, opened = classify({ { T_SW, 0, 1 }, { T_SYN, 0, 0 } })
    report(closed and not act and not opened,
        "cover CLOSE is a suspend request, not activity",
        string.format("activity=%s closed=%s opened=%s",
                      tostring(act), tostring(closed), tostring(opened)))
end

do
    local _, closed, opened = classify({ { T_SW, 0, 0 }, { T_SYN, 0, 0 } })
    report(opened and not closed,
        "cover OPEN counts as activity -- someone is picking the device up",
        string.format("opened=%s closed=%s", tostring(opened), tostring(closed)))
end

report(not (classify({ { T_SYN, 0, 0 } })), "a bare EV_SYN is not activity",
    "a lone SYN re-arming the timer is how the cover fix would defeat itself")

report(classify({ { T_ABS, 0, 512 }, { T_SYN, 0, 0 } }), "a touch IS activity",
    "EV_ABS must still keep the device awake")

report(classify({ { T_KEY, 116, 1 }, { T_SYN, 0, 0 } }), "a key press IS activity",
    "EV_KEY must still keep the device awake")

do
    local act, closed = classify({ { T_ABS, 0, 7 }, { T_SW, 0, 1 }, { T_SYN, 0, 0 } })
    report(act and closed, "a mixed batch reports BOTH activity and the close",
        string.format("activity=%s closed=%s", tostring(act), tostring(closed)))
end

-- The decision wiring lives in the main loop, which this harness does not
-- extract; assert it structurally instead.
do
    local src = table.concat(lines, "\n")
    report(src:find("if tapped or cover_closed then", 1, true) ~= nil,
        "a cover-close reaches the same suspend decision as a power tap",
        "cover_closed would be classified but never acted on")
    report(src:find("if tapped and os.time() < power_ignore_until", 1, true) ~= nil,
        "the resume grace gates only the power tap, never the cover",
        "the grace swallows the press that WOKE us; a cover-close is never that")
end

-- Cheapest gate available on a daemon nothing else on the host can run.
report(loadfile(source_path) ~= nil, "autosuspend.lua compiles")

print(failures == 0 and "autosuspend policy: all checks passed"
                    or ("autosuspend policy: " .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
