local root = arg[1] or "../../packages/koreader-device/frontend/device/pinenote"

local values = {
    ["/sys/class/backlight/backlight_cool/max_brightness"] = 255,
    ["/sys/class/backlight/backlight_warm/max_brightness"] = 255,
    ["/sys/class/backlight/backlight_cool/actual_brightness"] = 128,
    ["/sys/class/backlight/backlight_warm/actual_brightness"] = 128,
    ["/sys/class/backlight/backlight_cool/brightness"] = 128,
    ["/sys/class/backlight/backlight_warm/brightness"] = 128,
}

local real_open = io.open
io.open = function(path, mode)
    if values[path] == nil then
        return real_open(path, mode)
    end
    if mode == "r" then
        return {
            read = function() return tostring(values[path]) end,
            close = function() end,
        }
    end
    if mode == "w" then
        return {
            write = function(_, value) values[path] = assert(tonumber(value)) end,
            close = function() end,
        }
    end
end

local BasePowerD = {
    fl_min = 0,
    fl_max = 10,
    fl_intensity = nil,
    is_fl_on = false,
}

function BasePowerD:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if o.init then o:init() end
    if o.device and o.device:hasFrontlight() then
        o.fl_intensity = o:frontlightIntensityHW()
        o:_decideFrontlightState()
    end
    return o
end

function BasePowerD:_decideFrontlightState()
    self.is_fl_on = self:isFrontlightOnHW()
end

function BasePowerD:isFrontlightOn()
    return self.is_fl_on
end

function BasePowerD:turnOffFrontlightHW()
    self:setIntensityHW(self.fl_min)
end

function BasePowerD:turnOnFrontlightHW()
    self:setIntensityHW(self.fl_intensity)
end

function BasePowerD:turnOffFrontlight()
    if not self:isFrontlightOn() then return false end
    self:turnOffFrontlightHW()
    self.is_fl_on = false
    return true
end

function BasePowerD:turnOnFrontlight()
    if self:isFrontlightOn() or self.fl_intensity == self.fl_min then return false end
    self:turnOnFrontlightHW()
    self.is_fl_on = true
    return true
end

function BasePowerD:toggleFrontlight()
    if self:isFrontlightOn() then
        return self:turnOffFrontlight()
    end
    return self:turnOnFrontlight()
end

package.preload["device/generic/powerd"] = function() return BasePowerD end
package.preload.logger = function() return { warn = function() end } end

local PowerD = assert(loadfile(root .. "/powerd.lua"))()
local powerd = PowerD:new{
    device = { hasFrontlight = function() return true end },
}

assert(powerd:isFrontlightOn(), "initial nonzero hardware state should be on")
local remembered = powerd.fl_intensity
assert(remembered > 0, "initial intensity should be nonzero")

assert(powerd:toggleFrontlight(), "first toggle should turn the frontlight off")
assert(not powerd:isFrontlightOn(), "frontlight state should be off")
assert(powerd.hw_intensity == 0, "applied hardware intensity should be zero")
assert(powerd.fl_intensity == remembered, "off toggle must preserve the restore intensity")
assert(values["/sys/class/backlight/backlight_cool/brightness"] == 0
    and values["/sys/class/backlight/backlight_warm/brightness"] == 0,
    "off toggle should clear both PWM channels")

assert(powerd:toggleFrontlight(), "second toggle should restore the frontlight")
assert(powerd:isFrontlightOn(), "frontlight state should be on again")
assert(powerd.hw_intensity == remembered, "hardware should restore the remembered intensity")
assert(values["/sys/class/backlight/backlight_cool/brightness"] > 0
    and values["/sys/class/backlight/backlight_warm/brightness"] > 0,
    "restored mixed light should drive both PWM channels")

print("PASS: frontlight toggle preserves and restores the nonzero intensity")
