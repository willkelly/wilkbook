-- Deterministic host-only tests for the pure PineNote suspend coordinator.

local source_path = "pinenote/packages/koreader-device/frontend/device/pinenote/power_coordinator.lua"
local coordinator = assert(loadfile(source_path))()
local failures = 0

local function report(ok, label)
    print((ok and "PASS: " or "FAIL: ") .. label)
    if not ok then
        failures = failures + 1
    end
end

local function equal(actual, expected, label)
    report(actual == expected, label)
end

local function trace_equal(trace, expected, label)
    equal(table.concat(trace, ","), table.concat(expected, ","), label)
end

local function pack(...)
    return { n = select("#", ...), ... }
end

local names = {
    "checkpoint",
    "idlewasher_pause",
    "idlewasher_resume",
    "input_quarantine",
    "input_restore",
    "ebc_sleep_frame_barrier",
    "ebc_resume_full_refresh",
    "frontlight_off",
    "frontlight_restore",
    "wifi_quiesce",
    "wifi_restore",
    "storage_flush",
    "durable_state_commit",
    "suspend_requester",
    "wake_source_capture",
    "wake_reader",
}

local function snapshot(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[snapshot(key)] = snapshot(item) end
    return copy
end

local function fake(options)
    options = options or {}
    local trace = {}
    local records = {}
    local capabilities = {}
    for _, name in ipairs(names) do
        capabilities[name] = function(...)
            trace[#trace + 1] = name
            if options.call then
                options.call(name, trace, ...)
            end
            local outcome = options.outcomes and options.outcomes[name]
            local result = pack()
            if outcome then
                result = pack(outcome(...))
            elseif name == "wake_source_capture" then
                result = pack("fake-wake")
            end
            if name == "durable_state_commit" and select("#", ...) == 1 and result[1] ~= false then
                records[#records + 1] = snapshot(select(1, ...))
            end
            return unpack(result, 1, result.n)
        end
    end
    return capabilities, trace, records
end

local function expect_new_error(capabilities, message, label)
    local ok, err = pcall(coordinator.new, capabilities)
    report(not ok and tostring(err):match(message) ~= nil, label)
end

local function expected_failure(failing)
    local forward = {
        "checkpoint",
        "ebc_sleep_frame_barrier",
        "idlewasher_pause",
        "input_quarantine",
        "frontlight_off",
        "wifi_quiesce",
        "storage_flush",
        "durable_state_commit",
    }
    local undo = {
        idlewasher_pause = "idlewasher_resume",
        input_quarantine = "input_restore",
        ebc_sleep_frame_barrier = "ebc_resume_full_refresh",
        frontlight_off = "frontlight_restore",
        wifi_quiesce = "wifi_restore",
    }
    local trace, completed = {}, {}
    for _, name in ipairs(forward) do
        trace[#trace + 1] = name
        if name == failing then break end
        if name ~= failing and undo[name] then completed[name] = undo[name] end
    end
    for _, name in ipairs({
        "ebc_sleep_frame_barrier", "input_quarantine", "frontlight_off",
        "idlewasher_pause", "wifi_quiesce",
    }) do
        if completed[name] then trace[#trace + 1] = completed[name] end
    end
    trace[#trace + 1] = "durable_state_commit"
    return trace
end

for _, outcome in ipairs({
    { label = "provider failure", result = function() return false end },
    { label = "missing", result = function() end },
    { label = "ambiguous", result = function() return "button", "cover" end },
}) do
    local capabilities, trace, records = fake({
        outcomes = { wake_source_capture = outcome.result },
    })
    local instance = coordinator.new(capabilities)
    local ok, failure = instance:suspend("mem")
    report(not ok and failure.primary:match("wake_source_capture") ~= nil,
        "wake attribution " .. outcome.label .. " result fails closed")
    equal(instance:status().state, "POISONED", "wake attribution " .. outcome.label .. " poisons")
    trace_equal(trace, {
        "checkpoint", "ebc_sleep_frame_barrier", "idlewasher_pause", "input_quarantine",
        "frontlight_off", "wifi_quiesce", "storage_flush", "durable_state_commit",
        "suspend_requester", "wake_source_capture", "ebc_resume_full_refresh", "input_restore",
        "frontlight_restore", "idlewasher_resume", "wifi_restore", "durable_state_commit",
    }, "wake attribution " .. outcome.label .. " restores while input remains quarantined")
    equal(#records, 2, "wake attribution " .. outcome.label .. " retains prepared and failed records")
end

do
    local capabilities, trace = fake()
    local instance = coordinator.new(capabilities)
    local ok = instance:suspend()
    report(not ok and #trace == 0, "missing mode invokes no capabilities")
    ok = instance:suspend("freeze")
    report(not ok and #trace == 0, "unsupported mode invokes no capabilities")
    ok = instance:suspend("deep")
    report(not ok and #trace == 0, "unsupported deep mode invokes no capabilities")
    ok = instance:suspend("mem", "extra")
    report(not ok and #trace == 0, "extra mode argument invokes no capabilities")
end

do
    local policy = assert(io.open("pinenote/packages/koreader-device/frontend/device/pinenote/suspend_policy.lua", "r")):read("*a")
    equal(policy, "return false\n", "suspend policy remains exactly hard-off")
    local device = assert(io.open("pinenote/packages/koreader-device/frontend/device/pinenote/device.lua", "r")):read("*a")
    report(not device:find("power_coordinator", 1, true) and not device:find("power_capabilities", 1, true),
        "production device imports neither dormant power module")
end

do
    local module_keys = {}
    for key in pairs(coordinator) do module_keys[#module_keys + 1] = key end
    table.sort(module_keys)
    equal(table.concat(module_keys, ","), "new", "module exports only new")
end

do
    expect_new_error(nil, "requires a capabilities table", "non-table capabilities rejected")
    local capabilities = select(1, fake())
    capabilities.wifi_restore = false
    expect_new_error(capabilities, "malformed capability: wifi_restore", "malformed capability rejected")
    capabilities = select(1, fake())
    capabilities.unapproved = function() end
    expect_new_error(capabilities, "unsupported capability: unapproved", "unsupported capability rejected")
end

do
    local capabilities, trace, records = fake()
    local instance = coordinator.new(capabilities)
    local ok = instance:suspend("mem")
    report(ok, "successful transaction returns true")
    equal(instance:status().state, "IDLE", "successful transaction returns to IDLE")
    trace_equal(trace, {
        "checkpoint", "ebc_sleep_frame_barrier", "idlewasher_pause", "input_quarantine",
        "frontlight_off", "wifi_quiesce", "storage_flush", "durable_state_commit",
        "suspend_requester", "wake_source_capture", "ebc_resume_full_refresh", "input_restore", "frontlight_restore",
        "idlewasher_resume", "wifi_restore", "wake_reader",
    }, "successful transaction has exact trace")
    equal(#records, 1, "successful transaction writes one durable record")
    equal(records[1].state, "prepared", "successful transaction records prepared state")
end

do
    local states = {
        idlewasher_pause = { timer = "idle" },
        input_quarantine = { frame = "input" },
        ebc_sleep_frame_barrier = { generation = "ebc" },
        frontlight_off = { brightness = "frontlight" },
        wifi_quiesce = { associated = "wifi" },
    }
    local restored = {}
    local wake = { source = "button" }
    local capabilities, trace = fake({
        outcomes = {
            idlewasher_pause = function() return states.idlewasher_pause end,
            input_quarantine = function() return states.input_quarantine end,
            ebc_sleep_frame_barrier = function() return nil, states.ebc_sleep_frame_barrier end,
            frontlight_off = function() return states.frontlight_off end,
            wifi_quiesce = function() return states.wifi_quiesce end,
            wake_source_capture = function() return wake end,
            idlewasher_resume = function(...) restored.idlewasher = { n = select("#", ...), ... } end,
            input_restore = function(...) restored.input = { n = select("#", ...), ... } end,
            ebc_resume_full_refresh = function(first, second)
                restored.ebc = { n = 2, first, second }
            end,
            frontlight_restore = function(...) restored.frontlight = { n = select("#", ...), ... } end,
            wifi_restore = function(...) restored.wifi = { n = select("#", ...), ... } end,
            wake_reader = function(source) restored.wake = source end,
        },
    })
    local instance = coordinator.new(capabilities)
    report(instance:suspend("mem"), "stateful transaction succeeds")
    report(restored.idlewasher.n == 1 and restored.idlewasher[1] == states.idlewasher_pause
        and restored.input.n == 1 and restored.input[1] == states.input_quarantine
        and restored.ebc.n == 2 and restored.ebc[1] == nil and restored.ebc[2] == states.ebc_sleep_frame_barrier
        and restored.frontlight.n == 1 and restored.frontlight[1] == states.frontlight_off
        and restored.wifi.n == 1 and restored.wifi[1] == states.wifi_quiesce
        and restored.wake == wake,
        "each restore receives its exact captured prepare state")
    trace_equal(trace, {
        "checkpoint", "ebc_sleep_frame_barrier", "idlewasher_pause", "input_quarantine",
        "frontlight_off", "wifi_quiesce", "storage_flush", "durable_state_commit",
        "suspend_requester", "wake_source_capture", "ebc_resume_full_refresh", "input_restore", "frontlight_restore",
        "idlewasher_resume", "wifi_restore", "wake_reader",
    }, "stateful transaction restores EBC before input/frontlight and Wi-Fi last")
end

for _, failing in ipairs({
    "checkpoint", "ebc_sleep_frame_barrier", "idlewasher_pause", "input_quarantine",
    "frontlight_off", "wifi_quiesce", "storage_flush", "durable_state_commit",
}) do
    local durable_calls = 0
    local capabilities, trace, records = fake({
        outcomes = { [failing] = function()
            if failing ~= "durable_state_commit" then return false end
            durable_calls = durable_calls + 1
            if durable_calls == 1 then return false end
        end },
    })
    local instance = coordinator.new(capabilities)
    local ok, failure = instance:suspend("mem")
    report(not ok and failure.primary:match(failing) ~= nil, "forward failure: " .. failing)
    equal(instance:status().state, "POISONED", "forward failure poisons: " .. failing)
    trace_equal(trace, expected_failure(failing), "forward rollback trace: " .. failing)
    equal(#records, 1, "forward failure durable record: " .. failing)
    equal(records[#records].state, "failed", "forward failure records failed state: " .. failing)
end

do
    local capabilities, trace = fake({
        outcomes = { input_quarantine = function() return false end },
    })
    local instance = coordinator.new(capabilities)
    instance:suspend("mem")
    trace_equal(trace, expected_failure("input_quarantine"), "failed prepare is not restored")
end

do
    local requester_arity, requester_mode
    local capabilities, trace = fake({
        call = function(name, _, ...)
            if name == "suspend_requester" then
                requester_arity, requester_mode = select("#", ...), select(1, ...)
            end
        end,
    })
    local instance = coordinator.new(capabilities)
    instance:suspend("mem")
    report(requester_arity == 1 and requester_mode == "mem", "requester receives exactly the selected mode")
    trace_equal({ trace[#trace - 1], trace[#trace] }, { "wifi_restore", "wake_reader" },
        "wake notification follows final Wi-Fi handoff")
end

do
    local capabilities, trace, records = fake({
        outcomes = { suspend_requester = function() return false end },
    })
    local instance = coordinator.new(capabilities)
    local ok, failure = instance:suspend("mem")
    report(not ok and failure.primary:match("suspend_requester") ~= nil,
           "requester failure is retained")
    equal(instance:status().state, "POISONED", "requester failure poisons")
    trace_equal(trace, {
        "checkpoint", "ebc_sleep_frame_barrier", "idlewasher_pause", "input_quarantine",
        "frontlight_off", "wifi_quiesce", "storage_flush", "durable_state_commit",
        "suspend_requester", "ebc_resume_full_refresh", "input_restore", "frontlight_restore",
        "idlewasher_resume", "wifi_restore", "durable_state_commit",
    }, "requester failure has exact rollback trace")
    equal(#records, 2, "requester failure retains prepared and failed records")
    equal(records[2].primary, failure.primary, "requester failure record preserves primary failure")
    equal(#records[2].rollback_errors, #failure.rollback_errors,
          "requester failure record preserves rollback errors")
end

do
    local capabilities, trace, records = fake({
        outcomes = {
            wifi_quiesce = function() return false end,
            frontlight_restore = function() error("light restore failed") end,
            ebc_resume_full_refresh = function() return false end,
        },
    })
    local instance = coordinator.new(capabilities)
    local ok, failure = instance:suspend("mem")
    report(not ok and #failure.rollback_errors == 2, "all rollback failures are retained")
    report(failure.rollback_errors[1]:match("ebc_resume_full_refresh") ~= nil
           and failure.rollback_errors[2]:match("frontlight_restore") ~= nil,
           "rollback errors retain safe restore order")
    trace_equal(trace, {
        "checkpoint", "ebc_sleep_frame_barrier", "idlewasher_pause", "input_quarantine",
        "frontlight_off", "wifi_quiesce", "ebc_resume_full_refresh", "input_restore", "frontlight_restore",
        "idlewasher_resume", "durable_state_commit",
    }, "rollback remains best effort after failures")
    equal(#records, 1, "rollback failure writes one failed record before preparation")
    equal(records[1].primary, failure.primary, "rollback failure record retains primary error")
    equal(#records[1].rollback_errors, #failure.rollback_errors,
          "rollback failure record retains all rollback errors")
end

do
    local capabilities, trace, records = fake({
        outcomes = { wake_reader = function() return false end },
    })
    local instance = coordinator.new(capabilities)
    local ok, failure = instance:suspend("mem")
    report(not ok and failure.primary == "resume restoration failed",
           "wake reader failure fails the resumed transaction")
    report(#failure.rollback_errors == 1
           and failure.rollback_errors[1]:match("wake_reader") ~= nil,
           "wake reader failure is retained after safe restoration")
    equal(instance:status().state, "POISONED", "wake reader failure poisons")
    trace_equal(trace, {
        "checkpoint", "ebc_sleep_frame_barrier", "idlewasher_pause", "input_quarantine",
        "frontlight_off", "wifi_quiesce", "storage_flush", "durable_state_commit",
        "suspend_requester", "wake_source_capture", "ebc_resume_full_refresh", "input_restore", "frontlight_restore",
        "idlewasher_resume", "wifi_restore", "wake_reader", "durable_state_commit",
    }, "wake reader failure has exact trace")
    equal(#records, 2, "wake reader failure retains prepared and failed records")
    equal(records[2].rollback_errors[1], failure.rollback_errors[1],
          "wake reader durable record preserves the wake error")
    local before = #trace
    instance:suspend("mem")
    equal(#trace, before, "wake reader poison prevents retry capabilities")
end

do
    local capabilities, trace, records = fake({
        outcomes = { wifi_restore = function() return false end },
    })
    local instance = coordinator.new(capabilities)
    local ok, failure = instance:suspend("mem")
    report(not ok and failure.primary == "resume restoration failed", "rollback-only failure after wake fails")
    equal(instance:status().state, "POISONED", "rollback-only failure poisons")
    trace_equal(trace, {
        "checkpoint", "ebc_sleep_frame_barrier", "idlewasher_pause", "input_quarantine",
        "frontlight_off", "wifi_quiesce", "storage_flush", "durable_state_commit",
        "suspend_requester", "wake_source_capture", "ebc_resume_full_refresh", "input_restore", "frontlight_restore",
        "idlewasher_resume", "wifi_restore", "wake_reader", "durable_state_commit",
    }, "wake restoration failure has exact trace")
    equal(#records, 2, "wake restoration failure retains prepared and failed records")
end

do
    local calls = 0
    local capabilities, trace, records = fake({
        outcomes = {
            checkpoint = function() return false end,
            durable_state_commit = function()
                calls = calls + 1
                if calls == 1 then return false end
            end,
        },
    })
    local instance = coordinator.new(capabilities)
    local ok, failure = instance:suspend("mem")
    report(not ok and failure.durable_record_error:match("durable_state_commit") ~= nil,
           "durable failure-record write is retained")
    equal(#records, 0, "failed durable record is not reported as committed")
    trace_equal(trace, { "checkpoint", "durable_state_commit" }, "durable record failure has exact trace")
end

do
    local instance
    local nested_ok, nested_error
    local capabilities, trace = fake({
        call = function(name)
            if name == "checkpoint" then
                nested_ok, nested_error = instance:suspend("mem")
            end
        end,
    })
    instance = coordinator.new(capabilities)
    local ok = instance:suspend("mem")
    report(ok and not nested_ok and nested_error == "suspend already in progress",
           "reentrant request is rejected")
    equal(#trace, 16, "reentrant request invokes no extra capabilities")
    local second_ok = instance:suspend("mem")
    report(second_ok, "completed request can be repeated")
    equal(#trace, 32, "repeated request has one additional transaction")
end

do
    local capabilities, trace = fake({ outcomes = { checkpoint = function() return false end } })
    local instance = coordinator.new(capabilities)
    instance:suspend("mem")
    local before = #trace
    local ok = instance:suspend("mem")
    report(not ok and #trace == before, "poisoned request invokes no capabilities")
end

do
    local capabilities, trace = fake()
    local instance = coordinator.new(capabilities)
    capabilities.checkpoint = function() error("mutated capability") end
    report(instance:suspend("mem"), "coordinator snapshots validated capabilities at construction")
    equal(#trace, 16, "mutating caller capability table does not change transaction")
end

do
    local source = assert(io.open(source_path, "r")):read("*a")
    local forbidden = {
        "io%.", "os%.", "ffi", "require%s*%(", "loadfile", "dofile", "package%.",
        "/sys", "/proc", "/dev", "popen", "execute", "subprocess",
    }
    local clean = true
    for _, pattern in ipairs(forbidden) do
        if source:find(pattern) then clean = false end
    end
    report(clean, "coordinator has no filesystem, sysfs, FFI, or subprocess authority")
end

if failures == 0 then
    print("RESULT: ok")
    os.exit(0)
end
print("RESULT: failed")
os.exit(1)
