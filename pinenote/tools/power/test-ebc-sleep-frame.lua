local ffi = require("ffi")
local path = arg[1] or "pinenote/packages/koreader-device/frontend/device/pinenote/ebc_sleep_frame.lua"
local module = assert(loadfile(path))()
local barrier_module = assert(loadfile("../../packages/koreader-device/frontend/device/pinenote/ebc_barrier.lua"))()
local capabilities_module = assert(loadfile("../../packages/koreader-device/frontend/device/pinenote/power_capabilities.lua"))()
local coordinator_module = assert(loadfile("../../packages/koreader-device/frontend/device/pinenote/power_coordinator.lua"))()
local failures = 0

local function check(ok, label)
    print((ok and "PASS: " or "FAIL: ") .. label)
    if not ok then failures = failures + 1 end
end

local function dependencies()
    local trace, payload, generation = {}, { saved = true }, {}
    local deps = {
        paint_show = function() trace[#trace + 1] = "paint"; return payload end,
        force_repaint = function() trace[#trace + 1] = "force" end,
        framebuffer_fd = 9,
        fsync = function(fd) trace[#trace + 1] = "fsync:" .. fd; return 0 end,
        barrier = { submit_and_wait = function() trace[#trace + 1] = "barrier"; return true, generation end },
        restore = function(state) trace[#trace + 1] = "restore"; return state == payload end,
    }
    return deps, trace, payload, generation
end

local function high_id()
    return ffi.new("uint64_t", 0x200000) * ffi.new("uint64_t", 0x100000000) + 1
end

local function actual_adapter(trace)
    local id = high_id()
    return barrier_module.new({
        -- card is required (no default): the EBC's DRM card index is not
        -- stable across images, so production must resolve it.  Not card0,
        -- so a reintroduced hardcode could not pass unnoticed.
        card = "/dev/dri/card9",
        open = function() trace[#trace + 1] = "open"; return 12 end,
        ioctl = function(_, _, arg)
            if arg[0].op == 1 then
                trace[#trace + 1] = "submit"
                arg[0].request_id, arg[0].result = id, -115
            else
                trace[#trace + 1] = "wait"
                arg[0].result = 0
            end
            return 0
        end,
        close = function() trace[#trace + 1] = "close"; return 0 end,
        errno = function() return 0 end,
    }), id
end

do
    local deps, trace, payload = dependencies()
    local provider = module.new(deps)
    local token, extra = provider:prepare()
    check(type(token) == "table" and next(token) == nil and extra == nil and provider:status().state == "PREPARED"
        and table.concat(trace, ",") == "paint,force,fsync:9,barrier", "prepare returns only private coordinator token")
    check(provider:restore(token) and provider:status().state == "IDLE"
        and table.concat(trace, ",") == "paint,force,fsync:9,barrier,restore,force,fsync:9,barrier",
        "restore uses private payload identity and exact trace")
    check(payload.saved and next(token) == nil, "payload and generation remain private")
end

do
    local deps, trace = dependencies()
    local provider = module.new(deps)
    deps.barrier.submit_and_wait = function() error("mutated barrier") end
    deps.paint_show = function() error("mutated paint") end
    local token = provider:prepare()
    check(type(token) == "table" and provider:restore(token)
        and table.concat(trace, ",") == "paint,force,fsync:9,barrier,restore,force,fsync:9,barrier",
        "provider snapshots validated dependencies at construction")
end

do
    local calls = {}
    local adapter, id = actual_adapter(calls)
    local deps, trace = dependencies()
    deps.barrier = adapter
    local provider = module.new(deps)
    local token = provider:prepare()
    check(type(rawget(adapter, "submit_and_wait")) == "function" and type(token) == "table"
        and table.concat(calls, ",") == "open,submit,wait,close" and provider:restore(token)
        and table.concat(calls, ",") == "open,submit,wait,close,open,submit,wait,close"
        and type(id) == "cdata", "actual bound adapter composes with strict sleep provider")
end

do
    local sleep_trace, provider_trace = {}, {}
    local deps = dependencies()
    deps.paint_show = function() provider_trace[#provider_trace + 1] = "paint"; return {} end
    deps.force_repaint = function() provider_trace[#provider_trace + 1] = "force" end
    deps.fsync = function() provider_trace[#provider_trace + 1] = "fsync"; return 0 end
    deps.barrier = { submit_and_wait = function() provider_trace[#provider_trace + 1] = "barrier"; return true, {} end }
    deps.restore = function() provider_trace[#provider_trace + 1] = "restore"; return true end
    local sleep = module.new(deps)
    local names = {
        "checkpoint", "idlewasher_pause", "idlewasher_resume", "input_quarantine", "input_restore",
        "ebc_sleep_frame_barrier", "ebc_resume_full_refresh", "frontlight_off", "frontlight_restore",
        "wifi_quiesce", "wifi_restore", "storage_flush", "durable_state_commit", "suspend_requester",
        "wake_source_capture", "wake_reader",
    }
    local providers = {}
    for _, name in ipairs(names) do
        providers[name] = function(...) sleep_trace[#sleep_trace + 1] = name end
    end
    local token, restored
    providers.ebc_sleep_frame_barrier = function()
        sleep_trace[#sleep_trace + 1] = "ebc_sleep_frame_barrier"
        token = sleep:prepare()
        return token
    end
    providers.ebc_resume_full_refresh = function(...)
        sleep_trace[#sleep_trace + 1] = "ebc_resume_full_refresh"
        restored = { n = select("#", ...), ... }
        return sleep:restore(...)
    end
    providers.suspend_requester = function(mode)
        sleep_trace[#sleep_trace + 1] = "suspend_requester:" .. mode
        return true
    end
    providers.wake_source_capture = function()
        sleep_trace[#sleep_trace + 1] = "wake_source_capture"
        return "fake-wake"
    end
    local coordinator = coordinator_module.new(capabilities_module.new(providers))
    check(coordinator:suspend("mem") and restored.n == 1 and restored[1] == token
        and table.concat(sleep_trace, ",") == table.concat({
            "checkpoint", "ebc_sleep_frame_barrier", "idlewasher_pause", "input_quarantine", "frontlight_off",
            "wifi_quiesce", "storage_flush", "durable_state_commit", "suspend_requester:mem", "wake_source_capture",
            "ebc_resume_full_refresh", "input_restore", "frontlight_restore", "idlewasher_resume", "wifi_restore", "wake_reader",
        }, ",") and table.concat(provider_trace, ",") == "paint,force,fsync,barrier,restore,force,fsync,barrier",
        "actual capabilities/coordinator preserve one sleep token through fake transaction")
end

do
    local deps, trace = dependencies()
    local provider = module.new(deps)
    check(provider:prepare("extra") == false and #trace == 0, "prepare rejects arguments without dependencies")
    for _, paint in ipairs({ function() end, function() return {}, "extra" end }) do
        local invalid = dependencies()
        invalid.paint_show = paint
        local instance = module.new(invalid)
        check(instance:prepare() == false and instance:status().state == "POISONED",
            "paint requires exactly one nonnil payload")
    end
end

do
    local deps, trace = dependencies()
    local provider, nested
    deps.paint_show = function()
        trace[#trace + 1] = "paint"
        nested = provider:prepare()
        return {}
    end
    provider = module.new(deps)
    local token = provider:prepare()
    check(type(token) == "table", "reentrant prepare setup succeeds")
    check(nested == false, "PREPARING rejects reentrant prepare")
    check(table.concat(trace, ",") == "paint,force,fsync:9,barrier", "reentrant prepare invokes no dependencies")
end

do
    local deps, trace = dependencies()
    local provider, token, nested
    deps.restore = function()
        trace[#trace + 1] = "restore"
        nested = provider:restore(token)
        return true
    end
    provider = module.new(deps)
    token = provider:prepare()
    check(provider:restore(token), "reentrant restore setup succeeds")
    check(nested == false, "RESTORING consumes token before reentrant restore")
end

do
    local deps, trace = dependencies()
    local provider, other = module.new(deps), module.new(select(1, dependencies()))
    local token = provider:prepare()
    local before = #trace
    check(not other:restore(token) and not provider:restore({}) and not provider:restore(nil)
        and not provider:restore(token, "extra") and #trace == before and provider:restore(token)
        and not provider:restore(token), "foreign copied stale nil and extra tokens invoke nothing")
end

for _, stage in ipairs({ "paint_show", "force_repaint", "fsync", "barrier" }) do
    for _, outcome in ipairs({ "false", "throw" }) do
        local deps, trace = dependencies()
        local failure = outcome == "false" and function() return false end or function() error("boom") end
        if stage == "barrier" then deps.barrier.submit_and_wait = failure
        elseif stage == "fsync" then deps.fsync = outcome == "false" and function() return 1 end or failure
        else deps[stage] = failure end
        local provider = module.new(deps)
        check(provider:prepare() == false and provider:status().state == "POISONED", "prepare " .. stage .. " " .. outcome)
        local before = #trace
        check(provider:prepare() == false and #trace == before, "poisoned prepare has no dependencies")
    end
end

for _, stage in ipairs({ "restore", "force_repaint", "fsync", "barrier" }) do
    local deps, trace = dependencies()
    local restoring = false
    if stage == "barrier" then deps.barrier.submit_and_wait = function()
        if restoring then return false end
        trace[#trace + 1] = "barrier"
        return true, {}
    end
    elseif stage == "fsync" then
        deps.fsync = function(fd)
            trace[#trace + 1] = "fsync:" .. fd
            return restoring and 2 or 0
        end
    elseif stage == "force_repaint" then
        deps.force_repaint = function()
            trace[#trace + 1] = "force"
            return not restoring
        end
    else
        deps.restore = function() return false end
    end
    local provider = module.new(deps)
    local token = provider:prepare()
    restoring = true
    check(token and provider:restore(token) == false and provider:status().state == "POISONED", "restore " .. stage .. " poisons")
    local before = #trace
    check(provider:restore(token) == false and #trace == before, "poisoned restore has no dependencies")
end

for _, malformed in ipairs({ function() return true end, function() return true, nil end, function() return true, {}, "extra" end }) do
    local deps = dependencies()
    deps.barrier.submit_and_wait = malformed
    local provider = module.new(deps)
    check(provider:prepare() == false and provider:status().state == "POISONED", "malformed barrier result poisons")
end

do
    local deps = dependencies()
    check(not pcall(module.new, setmetatable({}, { __index = deps })), "metatable dependencies rejected")
    for _, fd in ipairs({ -1, 1.5 }) do
        local invalid = dependencies()
        invalid.framebuffer_fd = fd
        check(not pcall(module.new, invalid), "invalid framebuffer fd rejected")
    end
    local inherited = dependencies()
    inherited.barrier = setmetatable({}, { __index = { submit_and_wait = function() return true, {} end } })
    check(not pcall(module.new, inherited), "inherited barrier method rejected")
end

do
    local source = assert(io.open(path, "r")):read("*a")
    for _, forbidden in ipairs({ "require", "ffi", "io", "os", "loadfile", "package", "/sys", "/proc", "/dev", "subprocess" }) do
        local found = forbidden:sub(1, 1) == "/" and source:find(forbidden, 1, true)
            or source:find("%f[%a]" .. forbidden .. "%f[^%a]")
        check(not found, "source excludes " .. forbidden)
    end
    local device = assert(io.open("../../packages/koreader-device/frontend/device/pinenote/device.lua", "r")):read("*a")
    local policy = assert(io.open("../../packages/koreader-device/frontend/device/pinenote/suspend_policy.lua", "r")):read("*a")
    check(not device:find("ebc_barrier", 1, true) and not device:find("ebc_sleep_frame", 1, true)
        and not device:find("power_coordinator", 1, true) and not device:find("power_capabilities", 1, true), "production stays unimported")
    check(policy == "return false\n", "policy remains byte exact")
end

if failures > 0 then print("RESULT: failed"); os.exit(1) end
print("RESULT: ok")
