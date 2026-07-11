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

-- Input devices are resolved by name: event numbering shuffles across
-- kernels (adding the cyttsp5 touchscreen moved the pen from event2 to
-- event3).  "Stylus" matches the w9013's pen interface only (its second
-- interface, "w9013 2D1F:0095", is not opened).
--
-- sysfs_base is only ever passed by the koreader-input host harness
-- (a fake /sys/class/input tree); on the device it defaults.
local function findInputDevices(sysfs_base)
    sysfs_base = sysfs_base or "/sys/class/input"
    local found = {}
    for n = 0, 31 do
        local f = io.open(string.format(
            "%s/event%d/device/name", sysfs_base, n), "r")
        if f then
            local name = f:read("*line") or ""
            f:close()
            local node = string.format("/dev/input/event%d", n)
            if name:find("Stylus") then
                found.pen = node
            elseif name == "cyttsp5" then
                found.touch = node
            elseif name == "rk805 pwrkey" then
                found.pwrkey = node
            elseif name == "gpio-keys" then
                found.gpiokeys = node
            elseif name == "ws8100_pen" then
                found.penbtn = node
            -- The optics harness's uinput page-turn injector
            -- (pinenote/tools/optics/optics-inject.lua): a persistent
            -- keyboard device with KEY_BACK/KEY_FORWARD/KEY_MENU, only
            -- ever present when a capture session created it.  Its
            -- 158/159 ride the same event_map as the pen buttons.
            elseif name == "wilkbook-optics" then
                found.optics_inject = node
            -- QEMU virt visual loop (offline testing ladder): scripted
            -- input arrives via virtio-input devices.  Only ever present
            -- inside the VM; harmless to look for on hardware.
            elseif name:find("QEMU Virtio Tablet") then
                found.virt_tablet = node
            elseif name:find("QEMU Virtio Keyboard") then
                found.virt_keyboard = node
            end
        end
    end
    return found
end

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

    -- e-ink refresh wiring.  Deferred-io already publishes damage for
    -- every paint, so anything mapped to "partial" needs no explicit
    -- kick (the driver partial-refreshes each damage clip with its
    -- default_waveform); "global" fires the driver's global-refresh
    -- ioctl (a full-panel wash with its refresh_waveform).
    --
    -- Policy v1 (2026-07-05): only 'full' always washes.  The flash
    -- intents (flashui/flashpartial — menu open/close, dialogs) wash
    -- only when the damage covers most of the panel; small overlays
    -- stay partial so summoning a menu no longer blinks the whole
    -- screen.  Ghosting from un-flashed overlays is cleared by the
    -- every-N-pages full refresh (KOReader's full_refresh_count).
    -- Every decision is traced to the session log as one
    -- "[pn-refresh]" line: the capture side of the offline
    -- refresh-policy workbench (doc/testing.md).
    local drm_fd = C.open("/dev/dri/card0", bit.bor(C.O_RDWR, C.O_CLOEXEC))
    if drm_fd == -1 then
        logger.warn("PineNote: cannot open /dev/dri/card0; full refresh disabled")
    end
    local refresh_arg = ffi.new("uint8_t[1]", 1)
    local screen_area = nil -- computed lazily; screen size is known post-init
    local gettime = require("ffi/util").gettime
    local function trace(intent, decision, x, y, w, h, d)
        local sec, usec = gettime()
        logger.info(string.format(
            "[pn-refresh] %s %s rect=%s,%s,%s,%s dither=%s t=%d.%06d",
            intent, decision,
            tostring(x), tostring(y), tostring(w), tostring(h),
            tostring(d), sec, usec))
    end
    local function global_refresh()
        if drm_fd ~= -1 then
            C.ioctl(drm_fd, DRM_GLOBAL_REFRESH, refresh_arg)
        end
    end
    -- Flash intents wash the panel only when they cover at least this
    -- fraction of it.  Tunable via the G_reader_settings key
    -- "pinenote_flash_area_fraction" so the optics harness can sweep it
    -- per capture run (driver.py seeds it into the dedicated KO_HOME's
    -- settings.reader.lua).  G_reader_settings is initialized in
    -- reader.lua before the device module loads (reader.lua:39 vs the
    -- device require), but nil-guard anyway: host harnesses stub it.
    local flash_area_fraction = 0.60
    do
        local ok, v = pcall(function()
            return G_reader_settings and G_reader_settings.readSetting
                and G_reader_settings:readSetting("pinenote_flash_area_fraction")
        end)
        if ok and type(v) == "number" and v > 0 and v <= 1 then
            flash_area_fraction = v
        end
    end
    logger.info(string.format(
        "PineNote: flash_area_fraction=%.2f", flash_area_fraction))
    local function flash_policy(intent)
        return function(_, x, y, w, h, d)
            if not screen_area then
                local size = self.screen:getRawSize()
                screen_area = size.w * size.h
            end
            local rect_area = (tonumber(w) or 0) * (tonumber(h) or 0)
            if rect_area >= flash_area_fraction * screen_area then
                trace(intent, "global", x, y, w, h, d)
                global_refresh()
            else
                trace(intent, "partial", x, y, w, h, d)
            end
        end
    end
    self.screen.refreshPartialImp = function(_, x, y, w, h, d)
        trace("partial", "partial", x, y, w, h, d)
    end
    self.screen.refreshUIImp = function(_, x, y, w, h, d)
        trace("ui", "partial", x, y, w, h, d)
    end
    self.screen.refreshFastImp = function(_, x, y, w, h, d)
        trace("fast", "partial", x, y, w, h, d)
    end
    self.screen.refreshA2Imp = function(_, x, y, w, h, d)
        trace("a2", "partial", x, y, w, h, d)
    end
    self.screen.refreshFlashUIImp = flash_policy("flashui")
    self.screen.refreshFlashPartialImp = flash_policy("flashpartial")
    self.screen.refreshFullImp = function(_, x, y, w, h, d)
        trace("full", "global", x, y, w, h, d)
        global_refresh()
    end

    self.powerd = require("device/pinenote/powerd"):new{
        device = self,
    }

    self.input = require("device/input"):new{
        device = self,
        event_map = {
            [116] = "Power",   -- KEY_POWER (rk805 pwrkey)
            -- ws8100 BLE pen buttons (long presses; see the driver's
            -- input_status map in the forward-port patch): page turns
            -- from the pen barrel.
            [158] = "RPgBack", -- KEY_BACK  (eraser-side long press)
            [159] = "RPgFwd",  -- KEY_FORWARD (pen-side long press)
        },
        wacom_protocol = true,
        -- Pure-LuaJIT evdev backend (the desktop release bundle does not
        -- ship libs/libkoreader-input.so); pre-setting it here makes
        -- Input:init() skip its default backend require.
        input = require("ffi/input_evdev"),
    }

    local devs = findInputDevices()
    if devs.pen then self.input:open(devs.pen, "w9013 pen digitizer") end
    if devs.touch then self.input:open(devs.touch, "cyttsp5 touchscreen") end
    if devs.pwrkey then self.input:open(devs.pwrkey, "rk805 pwrkey") end
    if devs.gpiokeys then self.input:open(devs.gpiokeys, "gpio-keys") end
    if devs.penbtn then self.input:open(devs.penbtn, "ws8100 pen buttons") end
    -- The optics injector is opened unconditionally when present: it
    -- only exists while a capture session's daemon holds it, and its
    -- KEY_BACK/KEY_FORWARD events use the pen buttons' event_map
    -- entries above (proven offline on the koreader-input harness).
    if devs.optics_inject then
        self.input:open(devs.optics_inject, "wilkbook-optics injector")
    end
    if not (devs.pen or devs.touch) then
        -- Offline visual loop on qemu-virt: no PineNote input hardware
        -- exists, but the harness attaches virtio tablet/keyboard.
        -- Opening at least one device matters beyond input itself:
        -- with zero devices, input_evdev.waitForEvent has nothing to
        -- poll and KOReader aborts into a respawn loop.
        if devs.virt_tablet then
            self.input:open(devs.virt_tablet, "qemu virtio tablet")
            local evdev_ffi = require("ffi/input_evdev")
            local _min, tab_max_x = evdev_ffi.absinfo(devs.virt_tablet, C.ABS_X)
            local tab_max_y
            _min, tab_max_y = evdev_ffi.absinfo(devs.virt_tablet, C.ABS_Y)
            local size = self.screen:getRawSize()
            -- Synthesize an MT protocol-B stream from the tablet's
            -- single-touch events: BTN_LEFT becomes the tracking id
            -- (contact down/up), ABS_X/Y become MT positions.  A
            -- BTN_TOUCH rewrite is NOT enough: with wacom_protocol,
            -- Input:handleKeyBoardEv swallows BTN_TOUCH outside the
            -- pen slot, so no contact ever forms (rung 4v caught
            -- this — the tap changed nothing).
            local BTN_LEFT = 0x110
            local ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 0x35, 0x36
            local ABS_MT_TRACKING_ID = 0x39
            if tab_max_x and tab_max_x > 0 and tab_max_y and tab_max_y > 0 then
                local sx, sy = size.w / tab_max_x, size.h / tab_max_y
                self.input:registerEventAdjustHook(function(_, ev)
                    if ev.src ~= devs.virt_tablet then return end
                    if ev.type == C.EV_KEY and ev.code == BTN_LEFT then
                        ev.type = C.EV_ABS
                        ev.code = ABS_MT_TRACKING_ID
                        ev.value = ev.value ~= 0 and 1 or -1
                    elseif ev.type == C.EV_ABS then
                        if ev.code == C.ABS_X then
                            ev.code = ABS_MT_POSITION_X
                            ev.value = math.floor(ev.value * sx + 0.5)
                        elseif ev.code == C.ABS_Y then
                            ev.code = ABS_MT_POSITION_Y
                            ev.value = math.floor(ev.value * sy + 0.5)
                        end
                    end
                end)
                logger.info(string.format(
                    "PineNote(virt): tablet %dx%d -> screen %dx%d (MT synthesis)",
                    tab_max_x, tab_max_y, size.w, size.h))
            end
        end
        if devs.virt_keyboard then
            self.input:open(devs.virt_keyboard, "qemu virtio keyboard")
        end
        if not (devs.virt_tablet or devs.virt_keyboard) then
            logger.warn("PineNote: no pen or touchscreen input device found")
        end
    end

    -- Pen + touchscreen coexistence — the reMarkable-on-mainline recipe
    -- (input.lua handleMixedTouchEv): the touchscreen's MT protocol is
    -- the sole source of truth for fingers; plain ABS_X/Y are honored
    -- only inside the pen's slot.  Without this, the cyttsp5's legacy
    -- single-touch aliases are misread as slot coordinates — corrupting
    -- the second finger of every two-finger frame (pinch was
    -- structurally broken) — and collide with pen coordinate scaling.
    --
    -- On top of it, mixedrouter fixes upstream's src-blind cur_slot:
    -- with the pen in hover range, finger taps were swallowed into the
    -- pen slot and re-classified as swipes (the TOC-tap bug, found on
    -- the 2026-07-05 A.2 boot; mechanism in mixedrouter.lua).
    if devs.pen and devs.touch then
        self.input.handleTouchEv = self.input.handleMixedTouchEv
        require("device/pinenote/mixedrouter").install(
            self.input, devs.pen, devs.touch)
    end

    -- Per-source event conditioning.  Our evdev backend tags every
    -- event with src = originating device node, so no cross-device
    -- state (like the old pen-proximity boolean) is needed:
    --  * pen: scale digitizer units (20966x15725) to screen pixels,
    --    unconditionally — the mixed handler only consumes plain ABS
    --    in the pen slot, so touch is unaffected;
    --  * touchscreen: neutralize its legacy single-touch aliases —
    --    BTN_TOUCH would poison the wacom contact gate while the pen
    --    hovers (ghost pen taps from a resting palm), and the
    --    pointer-emulation ABS_X/ABS_Y/ABS_PRESSURE would be honored
    --    as PEN coordinates whenever cur_slot sits on the pen slot;
    --    the MT events carry all the real finger state;
    --  * ws8100 pen buttons: neutralize the BTN_TOOL_PEN/RUBBER
    --    wrappers the driver emits around every button event — they
    --    would fight the digitizer's true proximity state; the KEY_*
    --    events pass through to event_map.
    local EV_MSC = 4
    local BTN_TOOL_RUBBER = 0x141
    local evdev = require("ffi/input_evdev")
    local pen_scale_x, pen_scale_y
    if devs.pen then
        local _min, max_x = evdev.absinfo(devs.pen, C.ABS_X)
        local _min2, max_y = evdev.absinfo(devs.pen, C.ABS_Y)
        local screen_w = self.screen:getRawSize().w
        local screen_h = self.screen:getRawSize().h
        if max_x and max_x > 0 and max_y and max_y > 0 then
            pen_scale_x = screen_w / max_x
            pen_scale_y = screen_h / max_y
            logger.info(string.format(
                "PineNote: pen axes %dx%d -> screen %dx%d (scale %.4f/%.4f)",
                max_x, max_y, screen_w, screen_h, pen_scale_x, pen_scale_y))
        else
            logger.warn("PineNote: could not query pen axis ranges; pen coordinates unscaled")
        end
    end
    self.input:registerEventAdjustHook(function(_, ev)
        if ev.src == devs.pen then
            if pen_scale_x and ev.type == C.EV_ABS then
                if ev.code == C.ABS_X then
                    ev.value = math.floor(ev.value * pen_scale_x + 0.5)
                elseif ev.code == C.ABS_Y then
                    ev.value = math.floor(ev.value * pen_scale_y + 0.5)
                end
            end
        elseif ev.src == devs.touch then
            if ev.type == C.EV_KEY and ev.code == C.BTN_TOUCH then
                ev.type = EV_MSC -- handleMiscEv is a no-op here
            elseif ev.type == C.EV_ABS and
                   (ev.code == C.ABS_X or ev.code == C.ABS_Y or
                    ev.code == C.ABS_PRESSURE) then
                ev.type = EV_MSC
            end
        elseif ev.src == devs.penbtn then
            if ev.type == C.EV_KEY and
               (ev.code == C.BTN_TOOL_PEN or ev.code == BTN_TOOL_RUBBER) then
                ev.type = EV_MSC
            end
        end
    end)

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

-- Exposed for the koreader-input host harness ONLY (it proves the
-- name->slot mapping against a fake sysfs tree, offline); nothing on
-- the device calls this.
PineNote._findInputDevices = findInputDevices

return PineNote
