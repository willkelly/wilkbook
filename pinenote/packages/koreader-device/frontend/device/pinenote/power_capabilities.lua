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

local supported = {}
for _, name in ipairs(capability_names) do
    supported[name] = true
end

local function new(providers)
    if type(providers) ~= "table" then
        error("power capabilities requires a providers table")
    end

    for _, name in ipairs(capability_names) do
        if type(rawget(providers, name)) ~= "function" then
            error("malformed provider: " .. name)
        end
    end

    local unsupported = {}
    for name in pairs(providers) do
        if not supported[name] then
            unsupported[#unsupported + 1] = tostring(name)
        end
    end
    table.sort(unsupported)
    if #unsupported > 0 then
        error("unsupported provider: " .. unsupported[1])
    end

    local capabilities = {}
    for _, name in ipairs(capability_names) do
        local provider = rawget(providers, name)
        capabilities[name] = function(...)
            return provider(...)
        end
    end
    return capabilities
end

return {
    new = new,
}
