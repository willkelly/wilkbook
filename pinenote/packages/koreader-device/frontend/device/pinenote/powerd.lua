--[[--
Power/frontlight management for the PineNote.

Frontlight: two PWM backlights (cool + warm) under /sys/class/backlight.
KOReader's intensity slider drives the cool channel, the warmth slider
cross-fades toward the warm channel.

Battery: rk817 fuel gauge under /sys/class/power_supply.
--]]

local BasePowerD = require("device/generic/powerd")
local logger = require("logger")

local COOL = "/sys/class/backlight/backlight_cool"
local WARM = "/sys/class/backlight/backlight_warm"

local function readNumber(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local val = tonumber(f:read("*line"))
    f:close()
    return val
end

local function writeNumber(path, val)
    local f = io.open(path, "w")
    if not f then
        return false
    end
    f:write(tostring(val))
    f:close()
    return true
end

local PineNotePowerD = BasePowerD:new{
    fl_min = 0,
    fl_max = 100,
    fl_warmth_min = 0,
    fl_warmth_max = 100,

    hw_cool_max = 255,
    hw_warm_max = 255,
    hw_intensity = 0,
    fl_warmth = 0,
}

function PineNotePowerD:init()
    self.hw_cool_max = readNumber(COOL .. "/max_brightness") or 255
    self.hw_warm_max = readNumber(WARM .. "/max_brightness") or 255
    -- Reconstruct the aggregate level and warmth from both PWM strings.  A
    -- mixed light may have a low cool value while still being at full overall
    -- intensity, so neither channel alone is an intensity reading.
    local cool = readNumber(COOL .. "/actual_brightness")
        or readNumber(COOL .. "/brightness") or 0
    local warm = readNumber(WARM .. "/actual_brightness")
        or readNumber(WARM .. "/brightness") or 0
    local cool_level = cool / self.hw_cool_max
    local warm_level = warm / self.hw_warm_max
    local total = cool_level + warm_level
    self.hw_intensity = math.floor(math.min(total, 1) * self.fl_max + 0.5)
    self.fl_intensity = self.hw_intensity
    self.fl_warmth = total > 0
        and math.floor(warm_level / total * self.fl_warmth_max + 0.5)
        or self.fl_warmth_min
end

function PineNotePowerD:frontlightIntensityHW()
    return self.hw_intensity
end

function PineNotePowerD:isFrontlightOnHW()
    return self.hw_intensity > self.fl_min
end

function PineNotePowerD:frontlightWarmthHW()
    return self.fl_warmth
end

function PineNotePowerD:_applyLight(intensity)
    -- Warmth cross-fades between the two strings: at warmth 0 only the
    -- cool string is lit, at 100 only the warm one.
    local level = intensity / self.fl_max
    local warmth = (self.fl_warmth or 0) / self.fl_warmth_max
    local cool = math.floor(level * (1 - warmth) * self.hw_cool_max + 0.5)
    local warm = math.floor(level * warmth * self.hw_warm_max + 0.5)
    if not writeNumber(COOL .. "/brightness", cool) then
        logger.warn("PineNote: cannot write", COOL)
    end
    writeNumber(WARM .. "/brightness", warm)
end

function PineNotePowerD:setIntensityHW(intensity)
    -- BasePowerD keeps fl_intensity as the last requested nonzero level when
    -- toggling off, so that the next toggle can restore it.  Track the level
    -- actually written to hardware separately instead of destroying that
    -- remembered value with the temporary zero.
    self.hw_intensity = intensity or self.fl_intensity
    self:_applyLight(self.hw_intensity)
    self:_decideFrontlightState()
end

function PineNotePowerD:setWarmthHW(warmth)
    self.fl_warmth = warmth or self.fl_warmth
    self:_applyLight(self.hw_intensity)
end

function PineNotePowerD:getCapacityHW()
    local sysfs = self.device.battery_sysfs
    if not sysfs then
        return 100
    end
    return readNumber(sysfs .. "/capacity") or 100
end

function PineNotePowerD:isChargingHW()
    local sysfs = self.device.battery_sysfs
    if not sysfs then
        return false
    end
    local f = io.open(sysfs .. "/status", "r")
    if not f then
        return false
    end
    local status = f:read("*line")
    f:close()
    return status == "Charging"
end

function PineNotePowerD:beforeSuspend()
    -- The broker owns the physical light save/off/restore transaction.  Here
    -- KOReader checkpoints, broadcasts Suspend, and quarantines input before
    -- PineNote:suspend writes its `ready ID` acknowledgement.
    self.device:_beforeSuspend()
end

function PineNotePowerD:afterResume()
    self:invalidateCapacityCache()
    self.device:_afterResume()
end

return PineNotePowerD
