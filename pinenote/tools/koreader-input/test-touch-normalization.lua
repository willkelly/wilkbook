-- Host regression coverage for the cyttsp5 MT-axis normalization in the
-- PineNote adapter.  The five points are measured against the static target
-- card in physical TOP mode; no input device or panel is needed here.
local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local device_lua_path = assert(arg[2], "arg2: path to pinenote device.lua")

package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

local noop = function() end
package.preload["logger"] = function()
    return setmetatable({
        dbg = noop, info = noop, warn = noop, err = noop,
        LvDEBUG = noop, setLevel = noop,
    }, { __call = noop })
end
package.preload["dbg"] = function()
    local dbg = { is_on = false, ev_log = noop }
    function dbg:guard() end
    function dbg:dassert(check) return check end
    return setmetatable(dbg, { __call = noop })
end
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/nonexistent/koreader-settings" end,
        getDataDir = function() return "/nonexistent/koreader-data" end,
    }
end
package.preload["gettext"] = function()
    local identity = function(_, s) return s end
    return setmetatable({
        ngettext = function(_, s) return s end,
        pgettext = function(_, _, s) return s end,
    }, { __call = identity })
end
package.preload["util"] = function()
    return { tableDeepCopy = function(t) return t end }
end
package.preload["ffi/framebuffer"] = function()
    return {
        DEVICE_ROTATED_UPRIGHT = 0,
        DEVICE_ROTATED_CLOCKWISE = 1,
        DEVICE_ROTATED_UPSIDE_DOWN = 2,
        DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
    }
end
package.preload["ffi/archiver"] = function() return {} end
G_reader_settings = {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    isFalse = function() return false end,
    nilOrTrue = function() return true end,
    has = function() return false end,
}

local PineNote = dofile(device_lua_path)
local mirror = PineNote._mirrorTouchMTPosition
local adjust = PineNote._adjustTouchEvent
local EV_ABS, EV_KEY = 3, 1
local ABS_X = 0
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 53, 54
local BTN_TOUCH = 330
local TOUCH, PEN = "/dev/input/event2", "/dev/input/event3"
local MIN_X, MAX_X, MIN_Y, MAX_Y = 0, 1871, 0, 1403
local TOP_LOGICAL_HEIGHT = 1404
local TOLERANCE = 25 -- maximum residual observed in the static calibration

local fail = 0
local function report(ok, label, message)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label, message))
    if not ok then fail = fail + 1 end
end

report(type(mirror) == "function", "device.lua exports MT mirror helper",
       tostring(type(mirror)))
report(type(adjust) == "function", "device.lua exports touch adjust helper",
       tostring(type(adjust)))

local points = {
    { "T02", 96, 96, 1757, 102 },
    { "T03", 1308, 96, 1763, 1332 },
    { "T04", 1308, 1776, 113, 1297 },
    { "T05", 96, 1776, 102, 72 },
    { "T01", 702, 936, 926, 693 },
}
for _, point in ipairs(points) do
    local name, target_x, target_y, raw_x, raw_y = unpack(point)
    local x = { src = TOUCH, type = EV_ABS, code = ABS_MT_POSITION_X, value = raw_x }
    local y = { src = TOUCH, type = EV_ABS, code = ABS_MT_POSITION_Y, value = raw_y }
    local adjusted_x = adjust(x, TOUCH, MIN_X, MAX_X, MIN_Y, MAX_Y)
    local adjusted_y = adjust(y, TOUCH, MIN_X, MAX_X, MIN_Y, MAX_Y)
    -- Proven physical TOP mode 1, after normalization.
    local logical_x, logical_y = TOP_LOGICAL_HEIGHT - y.value, x.value
    local residual_x, residual_y = math.abs(logical_x - target_x), math.abs(logical_y - target_y)
    report(adjusted_x and adjusted_y and residual_x <= TOLERANCE and residual_y <= TOLERANCE,
           "TOP calibration " .. name,
           string.format("logical=(%d,%d) target=(%d,%d) residual=(%d,%d)",
               logical_x, logical_y, target_x, target_y, residual_x, residual_y))
end

local offset_range = { src = TOUCH, type = EV_ABS, code = ABS_MT_POSITION_X, value = 12 }
report(mirror(offset_range, TOUCH, 10, 20, 30, 40) and offset_range.value == 18,
       "mirror uses axis minimum plus maximum", offset_range.value)

local irrelevant = {
    { "foreign touch MT", { src = "/dev/input/event9", type = EV_ABS, code = ABS_MT_POSITION_X, value = 1757 } },
    { "pen MT", { src = PEN, type = EV_ABS, code = ABS_MT_POSITION_Y, value = 102 } },
    { "touch key", { src = TOUCH, type = EV_KEY, code = 139, value = 1 } },
}
for _, case in ipairs(irrelevant) do
    local label, ev = case[1], case[2]
    local original_type, original_value = ev.type, ev.value
    report(not adjust(ev, TOUCH, MIN_X, MAX_X, MIN_Y, MAX_Y)
           and ev.type == original_type and ev.value == original_value,
           label .. " is unchanged", tostring(ev.value))
end

local legacy_x = { src = TOUCH, type = EV_ABS, code = ABS_X, value = 321 }
report(adjust(legacy_x, TOUCH, MIN_X, MAX_X, MIN_Y, MAX_Y)
       and legacy_x.type == 4 and legacy_x.value == 321,
       "touch legacy ABS_X remains neutralized", legacy_x.type)

local btn_touch = { src = TOUCH, type = EV_KEY, code = BTN_TOUCH, value = 1 }
report(adjust(btn_touch, TOUCH, MIN_X, MAX_X, MIN_Y, MAX_Y)
       and btn_touch.type == 4 and btn_touch.value == 1,
       "touch BTN_TOUCH remains neutralized", btn_touch.type)

local unavailable = { src = TOUCH, type = EV_ABS, code = ABS_MT_POSITION_X, value = 1757 }
report(not adjust(unavailable, TOUCH, nil, nil, MIN_Y, MAX_Y)
       and unavailable.value == 1757,
       "unavailable X range leaves coordinates unchanged", tostring(unavailable.value))

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
