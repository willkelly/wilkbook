local source_path = arg[1] or "pinenote/packages/koreader-device/frontend/device/pinenote/power_capabilities.lua"
local module = assert(loadfile(source_path))()
local failures = 0

local capability_names = {
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

local function report(name, ok, detail)
    if ok then
        print("PASS: " .. name)
    else
        failures = failures + 1
        print("FAIL: " .. name .. " - " .. detail)
    end
end

local function expect_error(name, fn, expected)
    local ok, err = pcall(fn)
    report(name, not ok and tostring(err):find(expected, 1, true) ~= nil,
        "expected error containing " .. expected .. ", got " .. tostring(err))
end

local function copy_providers(overrides)
    local providers = {}
    for _, name in ipairs(capability_names) do
        providers[name] = function(...)
            return name, select("#", ...), ...
        end
    end
    for name, value in pairs(overrides or {}) do
        providers[name] = value
    end
    return providers
end

local function exact_keys(table_value, expected)
    local seen = {}
    for name in pairs(table_value) do
        seen[name] = true
    end
    for _, name in ipairs(expected) do
        if not seen[name] or type(table_value[name]) ~= "function" then
            return false
        end
        seen[name] = nil
    end
    return next(seen) == nil
end

report("module exports only new", exact_keys(module, { "new" }), "unexpected module exports")

expect_error("non-table providers fail", function()
    module.new(false)
end, "power capabilities requires a providers table")

expect_error("metatable providers fail", function()
    module.new(setmetatable({}, { __index = copy_providers() }))
end, "malformed provider: checkpoint")

for _, name in ipairs(capability_names) do
    local missing = copy_providers()
    missing[name] = nil
    expect_error("missing provider " .. name, function()
        module.new(missing)
    end, "malformed provider: " .. name)

    local malformed = copy_providers()
    malformed[name] = false
    expect_error("non-function provider " .. name, function()
        module.new(malformed)
    end, "malformed provider: " .. name)
end

expect_error("extra provider fails", function()
    module.new(copy_providers({ unexpected = function() end }))
end, "unsupported provider: unexpected")

expect_error("extra providers fail deterministically", function()
    module.new(copy_providers({ zzz = function() end, aaa = function() end }))
end, "unsupported provider: aaa")

local calls = {}
local prior_frontlight = { brightness = 23 }
local providers = copy_providers({
    checkpoint = function(reason, level)
        calls[#calls + 1] = { "checkpoint", reason, level }
        return "saved", reason, level
    end,
    frontlight_off = function()
        calls[#calls + 1] = { "frontlight_off" }
        return prior_frontlight
    end,
    frontlight_restore = function(state)
        calls[#calls + 1] = { "frontlight_restore", state }
        return state == prior_frontlight, "restored"
    end,
    suspend_requester = function(mode)
        calls[#calls + 1] = { "suspend_requester", mode }
        return "requested"
    end,
    wake_source_capture = function()
        calls[#calls + 1] = { "wake_source_capture" }
        return "button"
    end,
    wake_reader = function()
        error("wake provider error")
    end,
    wifi_quiesce = function()
        return false, "not ready"
    end,
})
local capabilities = module.new(providers)

report("returned table has exact capability keys", exact_keys(capabilities, capability_names),
    "missing, malformed, or extra capability keys")

local first, second, third = capabilities.checkpoint("sleep", 7)
report("calls forward arguments and multiple results",
    first == "saved" and second == "sleep" and third == 7
        and #calls == 1 and calls[1][1] == "checkpoint" and calls[1][2] == "sleep" and calls[1][3] == 7,
    "checkpoint call was not transparent")

local saved_state = capabilities.frontlight_off()
local restored, detail = capabilities.frontlight_restore(saved_state)
report("paired restore forwards prior state", saved_state == prior_frontlight and restored and detail == "restored"
        and calls[2][1] == "frontlight_off" and calls[3][1] == "frontlight_restore"
        and calls[3][2] == prior_frontlight,
    "frontlight state was not preserved")

local requested = capabilities.suspend_requester("mem")
report("mode requester forwards", requested == "requested" and calls[4][1] == "suspend_requester"
        and calls[4][2] == "mem" and #calls[4] == 2,
    "requester did not receive the selected mode")

local wake_source = capabilities.wake_source_capture()
report("wake-source capture forwards", wake_source == "button" and calls[5][1] == "wake_source_capture",
    "wake-source result was not transparent")

local quiesced, quiesce_detail = capabilities.wifi_quiesce()
report("false results forward unchanged", quiesced == false and quiesce_detail == "not ready",
    "false result was swallowed or changed")

expect_error("provider errors propagate", function()
    capabilities.wake_reader()
end, "wake provider error")

local second_capabilities = module.new(providers)
capabilities.checkpoint = function()
    return "mutated"
end
local untouched = second_capabilities.checkpoint("fresh")
report("returned tables are independent", untouched == "saved" and capabilities ~= second_capabilities,
    "constructor shared a returned capability table")

local handle = assert(io.open(source_path, "r"))
local source = handle:read("*a")
handle:close()
for _, forbidden in ipairs({
    "require", "io", "os", "ffi", "loadfile", "package",
    "/sys", "/proc", "/dev", "subprocess",
}) do
    local present
    if forbidden:sub(1, 1) == "/" then
        present = source:find(forbidden, 1, true) ~= nil
    else
        present = source:find("%f[%a]" .. forbidden .. "%f[^%a]") ~= nil
    end
    report("source excludes " .. forbidden, not present,
        "forbidden authority present")
end

if failures > 0 then
    print("RESULT: failed")
    os.exit(1)
end
print("RESULT: ok")
