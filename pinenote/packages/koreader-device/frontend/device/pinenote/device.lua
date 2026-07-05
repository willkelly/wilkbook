--[[--
Device abstraction for the Pine64 PineNote running wilkbook
(mainline-ish kernel, rockchip-ebc DRM driver).

Runs directly on the fbdev emulation (/dev/fb0, 32bpp XR24) with evdev
input — no compositor, no SDL. Partial screen updates reach the e-ink
panel through the fbdev deferred-io path automatically; full refreshes
use the driver's global-refresh ioctl.
--]]

local Generic = require("device/generic/device")
local logger = require("logger")

local ffi = require("ffi")
local bit = require("bit")
local C = ffi.C

require("ffi/posix_h")
require("ffi/linux_input_h")

local function yes() return true end
local function no() return false end

-- Input device nodes (see /proc/bus/input/devices; stable on this kernel).
local PEN_DEVICE = "/dev/input/event2"     -- w9013 EMR digitizer
local PWRKEY_DEVICE = "/dev/input/event0"  -- rk805 pwrkey
local GPIOKEYS_DEVICE = "/dev/input/event1"
local PENBTN_DEVICE = "/dev/input/event5"  -- ws8100 BT pen buttons

-- DRM_IOCTL_ROCKCHIP_EBC_GLOBAL_REFRESH:
-- _IOWR('d', 0x40, struct { bool }) = 0xC0016440
local DRM_GLOBAL_REFRESH = 0xC0016440

local function firstExistingDir(candidates)
    for _, path in ipairs(candidates) do
        local f = io.open(path .. "/uevent", "r")
        if f then
            f:close()
            return path
        end
    end
end

local PineNote = Generic:extend{
    model = "PineNote",
    isPineNote = yes,
    isTouchDevice = yes, -- the pen drives the touch input path (wacom protocol)
    hasKeys = yes,
    hasEinkScreen = yes,
    hasFrontlight = yes,
    hasNaturalLight = yes,
    canHWInvert = no,
    hasColorScreen = no,
    canReboot = yes,
    canPowerOff = yes,
    canSuspend = no, -- not validated on this kernel yet
    hasOTAUpdates = no,
    hasWifiManager = no,
    display_dpi = 227,
    home_dir = "/root",
}

function PineNote:init()
    self.screen = require("ffi/framebuffer_linux"):new{
        device = self,
        debug = logger.dbg,
    }

    -- e-ink refresh wiring: deferred-io already publishes damage for
    -- every paint, so partial refreshes need no explicit kick; a full
    -- refresh maps to the driver's global-refresh (GC16 wash) ioctl.
    local drm_fd = C.open("/dev/dri/card0", bit.bor(C.O_RDWR, C.O_CLOEXEC))
    if drm_fd == -1 then
        logger.warn("PineNote: cannot open /dev/dri/card0; full refresh disabled")
    end
    local refresh_arg = ffi.new("uint8_t[1]", 1)
    self.screen.refreshPartialImp = function() end
    self.screen.refreshFullImp = function()
        if drm_fd ~= -1 then
            C.ioctl(drm_fd, DRM_GLOBAL_REFRESH, refresh_arg)
        end
    end

    self.powerd = require("device/pinenote/powerd"):new{
        device = self,
    }

    self.input = require("device/input"):new{
        device = self,
        event_map = {
            [116] = "Power", -- KEY_POWER (rk805 pwrkey)
        },
        wacom_protocol = true,
        -- Pure-LuaJIT evdev backend (the desktop release bundle does not
        -- ship libs/libkoreader-input.so); pre-setting it here makes
        -- Input:init() skip its default backend require.
        input = require("ffi/input_evdev"),
    }

    self.input:open(PEN_DEVICE, "w9013 pen digitizer")
    self.input:open(PWRKEY_DEVICE, "rk805 pwrkey")
    self.input:open(GPIOKEYS_DEVICE, "gpio-keys")
    self.input:open(PENBTN_DEVICE, "ws8100 pen buttons")

    -- Scale pen coordinates to the framebuffer.
    local evdev = require("ffi/input_evdev")
    local _, max_x = evdev.absinfo(PEN_DEVICE, C.ABS_X)
    local _, max_y = evdev.absinfo(PEN_DEVICE, C.ABS_Y)
    local screen_w = self.screen:getRawSize().w
    local screen_h = self.screen:getRawSize().h
    if max_x and max_x > 0 and max_y and max_y > 0 then
        local scale_x = screen_w / max_x
        local scale_y = screen_h / max_y
        logger.info(string.format(
            "PineNote: pen axes %dx%d -> screen %dx%d (scale %.4f/%.4f)",
            max_x, max_y, screen_w, screen_h, scale_x, scale_y))
        self.input:registerEventAdjustHook(function(_, ev)
            if ev.type == C.EV_ABS then
                if ev.code == C.ABS_X then
                    ev.value = math.floor(ev.value * scale_x + 0.5)
                elseif ev.code == C.ABS_Y then
                    ev.value = math.floor(ev.value * scale_y + 0.5)
                end
            end
        end)
    else
        logger.warn("PineNote: could not query pen axis ranges; pen coordinates unscaled")
    end

    Generic.init(self)
end

function PineNote:powerOff()
    os.execute("poweroff")
end

function PineNote:reboot()
    os.execute("reboot")
end

-- Battery sysfs node differs between kernels; probe once.
PineNote.battery_sysfs = firstExistingDir{
    "/sys/class/power_supply/rk817-battery",
    "/sys/class/power_supply/battery",
}

return PineNote
