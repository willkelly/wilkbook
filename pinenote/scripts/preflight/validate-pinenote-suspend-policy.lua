local function fail(message)
    io.stderr:write("FAIL: ", message, "\n")
    os.exit(1)
end

if #arg ~= 1 then
    fail("usage: validate-pinenote-suspend-policy.lua KOREADER_DEVICE_LUA")
end

local device_path = arg[1]
local device_file, open_error = io.open(device_path, "rb")
if not device_file then
    fail("cannot read device source: " .. tostring(open_error))
end
local device_source = device_file:read("*a")
device_file:close()

local function evaluate(policy_value)
    local policy_requires = 0
    local Generic = {}

    function Generic:extend(definition)
        return definition
    end

    local function restricted_require(name)
        if name == "device/pinenote/suspend_policy" then
            policy_requires = policy_requires + 1
            return policy_value
        end
        if name == "device/generic/device" then
            return Generic
        end
        if name == "logger" then
            return {}
        end
        if name == "ffi" then
            return { C = {} }
        end
        if name == "bit" then
            return {}
        end
        if name == "ffi/posix_h" or name == "ffi/linux_input_h" then
            return true
        end
        error("unapproved module requested: " .. tostring(name))
    end

    local environment = {
        assert = assert,
        error = error,
        ipairs = ipairs,
        math = math,
        next = next,
        pairs = pairs,
        pcall = pcall,
        require = restricted_require,
        select = select,
        string = string,
        table = table,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        unpack = unpack,
        io = {
            open = function()
                return nil
            end,
        },
    }

    local chunk, load_error = loadstring(device_source, "@" .. device_path)
    if not chunk then
        fail("cannot compile device source: " .. tostring(load_error))
    end
    setfenv(chunk, environment)

    local loaded, class_or_error = pcall(chunk)
    if not loaded then
        fail("restricted device evaluation failed: " .. tostring(class_or_error))
    end
    if policy_requires ~= 1 then
        fail("device source requested suspend policy " .. policy_requires .. " times")
    end
    if type(class_or_error) ~= "table" then
        fail("device source did not return a table")
    end
    if type(class_or_error.canSuspend) ~= "function" then
        fail("returned PineNote class has no canSuspend function")
    end

    local called, value = pcall(class_or_error.canSuspend, class_or_error)
    if not called then
        fail("returned canSuspend function failed: " .. tostring(value))
    end
    if value ~= policy_value then
        fail("returned canSuspend does not follow injected suspend policy")
    end
end

evaluate(false)
evaluate(true)
print("PASS: restricted PineNote suspend policy evaluation follows both injected values")
