local path = arg[1] or "../../packages/platform-controls/pinenote-power-broker.lua"
local ffi = require("ffi")
local alarm = "/sys/class/rtc/rtc0/wakealarm"
local gadget = "/sys/kernel/config/usb_gadget/pinenote-acm/UDC"
local cool = "/sys/class/backlight/backlight_cool/brightness"
local warm = "/sys/class/backlight/backlight_warm/brightness"
local display = "/sys/module/rockchip_ebc/parameters/no_off_screen"
local state, trace, logs, wifi, mode, fail_clear
local function record(event) trace[#trace + 1] = event end
local transaction = dofile("broker-fixture.lua")(path, {
    io = {
        stderr = { write = function(_, value) logs[#logs + 1] = value end, flush = function() end },
        open = function(name, access)
            if access == "r" then
                local value = state[name]
                if name == "/sys/power/mem_sleep" then value = mode end
                if not value then return nil end
                return { read = function() return value end, close = function() return true end }
            end
            return { write = function(_, value)
                assert(name ~= "/sys/power/state", "deep refusal must not attempt suspend")
                record(name .. "=" .. value)
                if fail_clear and name == alarm and value == "0" and state[alarm] == "13600" then
                    return nil
                end
                state[name] = value; return true
            end, close = function() return true end }
        end,
    },
    os = setmetatable({ execute = function(command)
        if command:find(" status ", 1, true) then return wifi and 0 or 1 end
        if command:match(" off$") then wifi = false; record("wifi off")
        elseif command:match(" on$") then wifi = true; record("wifi on")
        else assert(command:find("pinenote-ebc-refresh", 1, true), "unexpected command: " .. command) end
        return 0
    end }, { __index = os }),
    require = function(name)
        if name == "ffi" then return setmetatable({ C = {
            open = function(name) assert(name == "/dev/fb0"); return -1 end,
        } }, { __index = ffi }) end
        if name == "broker_quiesce" then return { new = function() return { wait = function() return true end } end } end
        return require(name)
    end,
}, "suspend_transaction")

for _, fallback in ipairs({ false, true }) do
    for _, readback in ipairs({ "[s2idle] deep", false }) do
        for _, failed in ipairs({ false, true }) do
            state = { [alarm] = "0", [gadget] = "controller", [cool] = "23", [warm] = "41",
                      ["/sys/class/rtc/rtc0/since_epoch"] = "10000" }
            trace, logs, wifi, mode, fail_clear = {}, {}, true, readback, failed
            local ok, reason = transaction(fallback)
            assert(not ok and reason == "deep suspend unavailable")
            local alarms, clear_index, restore_index = {}, nil, nil
            for index, event in ipairs(trace) do
                if event:sub(1, #alarm + 1) == alarm .. "=" then
                    alarms[#alarms + 1] = event:sub(#alarm + 2)
                    if #alarms == 3 then clear_index = index end
                end
                if event == gadget .. "=controller" then restore_index = index end
            end
            assert(table.concat(alarms, ",") == "0,13600,0", "deep refusal must clear the armed backstop")
            assert(clear_index < restore_index, "cancel the backstop before restoring peripherals")
            assert(state[alarm] == (failed and "13600" or "0"))
            assert(wifi and state[gadget] == "controller" and state[cool] == "23" and state[warm] == "41")
            assert(state[display] == "0")
            if failed then
                assert(table.concat(logs):find("RTC backstop clear failed after deep suspend refusal", 1, true))
            end
        end
    end
end
print("PASS: actual acknowledged/fallback transaction clears its armed RTC alarm on unavailable/unreadable deep mode")
print("PASS: deep refusal restores peripherals without suspending, including when alarm cancellation fails visibly")
