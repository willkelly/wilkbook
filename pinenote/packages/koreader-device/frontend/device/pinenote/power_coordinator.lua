--[[--
Pure suspend transaction coordinator for the PineNote.

All authority is injected as capabilities so this module is host-testable and
has no knowledge of the platform or KOReader runtime.
--]]

local required_capabilities = {
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

local forward_steps = {
    { name = "checkpoint" },
    { name = "ebc_sleep_frame_barrier", rollback = "ebc_resume_full_refresh" },
    { name = "idlewasher_pause", rollback = "idlewasher_resume" },
    { name = "input_quarantine", rollback = "input_restore" },
    { name = "frontlight_off", rollback = "frontlight_restore" },
    { name = "wifi_quiesce", rollback = "wifi_restore" },
    { name = "storage_flush" },
}

-- Resume restores display health before any visible or input state, then leaves
-- networking as the final non-blocking handoff back to its provider.
local restore_steps = {
    "ebc_sleep_frame_barrier",
    "input_quarantine",
    "frontlight_off",
    "idlewasher_pause",
    "wifi_quiesce",
}

local private = setmetatable({}, { __mode = "k" })

local function capability_error(name, detail)
    if detail == nil then
        return name .. " returned false"
    end
    return name .. ": " .. tostring(detail)
end

local function pack(...)
    return { n = select("#", ...), ... }
end

local function call(self, name, ...)
    local result = pack(pcall(private[self].capabilities[name], ...))
    if not result[1] then
        return false, capability_error(name, result[2])
    end
    if result[2] == false then
        return false, capability_error(name)
    end
    local state = { n = result.n - 1 }
    for index = 1, state.n do
        state[index] = result[index + 1]
    end
    return true, state
end

local function restore(self, completed)
    local errors = {}
    for _, name in ipairs(restore_steps) do
        local step = completed[name]
        if step then
            local ok, err = call(self, step.rollback, unpack(step.state, 1, step.state.n))
            if not ok then
                errors[#errors + 1] = err
            end
        end
    end
    return errors
end

local function poison(self, primary, rollback_errors)
    local failure = {
        state = "failed",
        primary = primary,
        rollback_errors = rollback_errors,
    }
    local recorded, record_error = call(self, "durable_state_commit", failure)
    if not recorded then
        failure.durable_record_error = record_error
    end
    private[self].final_failure = failure
    private[self].state = "POISONED"
    return false, failure
end

local Coordinator = {}
Coordinator.__index = Coordinator

function Coordinator:suspend(mode, ...)
    local data = private[self]
    if data.state == "POISONED" then
        return false, data.final_failure
    end
    if data.state ~= "IDLE" then
        return false, "suspend already in progress"
    end
    if select("#", ...) ~= 0 then
        return false, "suspend accepts exactly one mode"
    end
    if mode == nil then
        return false, "suspend mode is required"
    end
    if mode ~= "mem" then
        return false, "unsupported suspend mode: " .. tostring(mode)
    end

    data.state = "PREPARING"
    local completed = {}
    for _, step in ipairs(forward_steps) do
        local ok, state_or_error = call(self, step.name)
        if not ok then
            return poison(self, state_or_error, restore(self, completed))
        end
        if step.rollback then
            completed[step.name] = {
                rollback = step.rollback,
                state = state_or_error,
            }
        end
    end

    local prepared, prepare_error = call(self, "durable_state_commit", {
        state = "prepared",
    })
    if not prepared then
        return poison(self, prepare_error, restore(self, completed))
    end

    data.state = "REQUESTING"
    local requested, request_error = call(self, "suspend_requester", mode)
    if not requested then
        return poison(self, request_error, restore(self, completed))
    end

    data.state = "ATTRIBUTING"
    local attributed, wake_or_error = call(self, "wake_source_capture")
    if not attributed then
        return poison(self, wake_or_error, restore(self, completed))
    end
    if wake_or_error.n ~= 1 or wake_or_error[1] == nil then
        return poison(self, "wake_source_capture returned absent or ambiguous attribution", restore(self, completed))
    end

    data.state = "RESTORING"
    local rollback_errors = restore(self, completed)
    local woke, wake_error = call(self, "wake_reader", wake_or_error[1])
    if not woke then
        rollback_errors[#rollback_errors + 1] = wake_error
    end
    if #rollback_errors > 0 then
        return poison(self, "resume restoration failed", rollback_errors)
    end

    data.state = "IDLE"
    return true
end

function Coordinator:status()
    local data = private[self]
    return {
        state = data.state,
        failure = data.final_failure,
    }
end

local function new(capabilities)
    if type(capabilities) ~= "table" then
        error("power coordinator requires a capabilities table")
    end
    for _, name in ipairs(required_capabilities) do
        if type(capabilities[name]) ~= "function" then
            error("malformed capability: " .. name)
        end
    end
    local unsupported = {}
    for name in pairs(capabilities) do
        local known = false
        for _, required in ipairs(required_capabilities) do
            if name == required then
                known = true
                break
            end
        end
        if not known then
            unsupported[#unsupported + 1] = tostring(name)
        end
    end
    table.sort(unsupported)
    if #unsupported > 0 then
        error("unsupported capability: " .. unsupported[1])
    end
    local instance = setmetatable({}, Coordinator)
    local closed_capabilities = {}
    for _, name in ipairs(required_capabilities) do
        closed_capabilities[name] = capabilities[name]
    end
    private[instance] = {
        capabilities = closed_capabilities,
        state = "IDLE",
    }
    return instance
end

return {
    new = new,
}
