--[[--
Device abstraction for the Pine64 PineNote running wilkbook
(mainline-ish kernel, rockchip-ebc DRM driver).

Runs directly on the fbdev emulation (/dev/fb0, 32bpp XR24) with evdev
input — no compositor, no SDL. Partial screen updates reach the e-ink
panel through the fbdev deferred-io path, published explicitly at each
refresh call via fsync on the fb fd (publish-on-call) with the deferred-io
timer as fallback; full refreshes use the driver's global-refresh ioctl.
--]]

local Generic = require("device/generic/device")
local logger = require("logger")
local suspend_qualified = require("device/pinenote/suspend_policy")

local ffi = require("ffi")
local bit = require("bit")
local C = ffi.C
local EV_MSC = 4

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
            elseif name == "wilkbook-orientation" then
                local id_base = string.format("%s/event%d/device/id/", sysfs_base, n)
                local function id(field)
                    local id_file = io.open(id_base .. field, "r")
                    if not id_file then return nil end
                    local value = id_file:read("*line")
                    id_file:close()
                    return value
                end
                -- A name alone is spoofable. Require the immutable identity
                -- assigned by our uinput bridge as defense in depth.
                if id("bustype") == "0006" and id("vendor") == "1209"
                   and id("product") == "0002" and id("version") == "0001" then
                    found.gsensor = node
                end
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

-- Both virtual devices are owned by services outside KOReader. Their loss
-- means the process must restart and enumerate their replacement nodes.
local function registerRequiredInputDevices(input_backend, devs)
    if devs.optics_inject then
        input_backend.setRequiredDevice(devs.optics_inject)
    end
    if devs.gsensor then
        input_backend.setRequiredDevice(devs.gsensor)
    end
end

-- DRM_IOCTL_ROCKCHIP_EBC_GLOBAL_REFRESH:
-- _IOWR('d', 0x40, struct { bool }) = 0xC0016440
local DRM_GLOBAL_REFRESH = 0xC0016440

-- The EBC's DRM card index is not stable across images: whichever DRM
-- driver probes first takes card0, and on the direct-mode image that is
-- the panfrost GPU -- there every wash this file aimed at card0 became a
-- malformed GPU job (dmesg JOB_CONFIG_FAULT) and the panel was never
-- washed (2026-08-25 glass session).  Resolve the node by driver name
-- instead: /sys/class/drm/cardN/device/uevent carries
-- DRIVER=rockchip-ebc (both the shipping and the direct-mode driver
-- register that platform-driver name), it is readable without root, and
-- reading it is side-effect-free -- probing by open()ing candidate
-- nodes would make this process DRM master of whatever it touched
-- first (the first open of a card node is drm_master_open()).  The
-- match is exact-line, so a hypothetical rockchip-ebc-foo cannot
-- false-positive.  DRM reserves minors 0..63 for card nodes, hence the
-- scan bound.
--
-- sysfs_base is only ever passed by the koreader-input host harness
-- (a fake /sys/class/drm tree); on the device it defaults.
local function findEbcCard(sysfs_base)
    sysfs_base = sysfs_base or "/sys/class/drm"
    for n = 0, 63 do
        local f = io.open(string.format(
            "%s/card%d/device/uevent", sysfs_base, n), "r")
        if f then
            for line in f:lines() do
                if line == "DRIVER=rockchip-ebc" then
                    f:close()
                    return string.format("/dev/dri/card%d", n)
                end
            end
            f:close()
        end
    end
end

local function firstExistingDir(candidates)
    for _, path in ipairs(candidates) do
        local f = io.open(path .. "/uevent", "r")
        if f then
            f:close()
            return path
        end
    end
end

local ORIENTATION_STATE = "/run/wilkbook-orientation.state"

local function syncGyroState(input, path)
    local f = io.open(path or ORIENTATION_STATE, "r")
    if not f then return nil end
    local mode = tonumber(f:read("*line"))
    f:close()
    if not mode or mode < 0 or mode > 3 or mode ~= math.floor(mode) then
        return nil
    end
    return input:handleGyroEv({ value = mode })
end

-- Keep the private KOReader protocol at this boundary.  The kernel-facing
-- bridge is deliberately standard EV_MSC/MSC_RAW only.
local function translateGyroEvent(ev, gsensor)
    local MSC_RAW, MSC_GYRO = 3, 71
    if gsensor and ev.src == gsensor and ev.type == 4 and ev.code == MSC_RAW then
        if ev.value >= 0 and ev.value <= 3 then
            ev.code = MSC_GYRO
            ev.wilkbook_gsensor = true
            return true
        end
        ev.code, ev.value = 0, 0
    end
    return false
end

-- cyttsp5 reports its multitouch axes inverted relative to the PineNote's
-- physical TOP orientation.  Keep this source-gated and range-driven: the
-- input node is dynamic and panel ranges belong to the device, not the image.
local function mirrorTouchMTPosition(ev, touch, min_x, max_x, min_y, max_y)
    if ev.src ~= touch or ev.type ~= C.EV_ABS then return false end
    if ev.code == C.ABS_MT_POSITION_X and min_x ~= nil and max_x ~= nil then
        ev.value = min_x + max_x - ev.value
        return true
    elseif ev.code == C.ABS_MT_POSITION_Y and min_y ~= nil and max_y ~= nil then
        ev.value = min_y + max_y - ev.value
        return true
    end
    return false
end

local function adjustTouchEvent(ev, touch, min_x, max_x, min_y, max_y)
    if ev.src ~= touch then return false end
    if ev.type == C.EV_KEY and ev.code == C.BTN_TOUCH then
        ev.type = EV_MSC -- handleMiscEv is a no-op here
        return true
    elseif ev.type == C.EV_ABS then
        local adjusted = mirrorTouchMTPosition(ev, touch, min_x, max_x, min_y, max_y)
        if ev.code == C.ABS_X or ev.code == C.ABS_Y or ev.code == C.ABS_PRESSURE then
            ev.type = EV_MSC -- keep legacy aliases out of the pen slot
            return true
        end
        return adjusted
    end
    return false
end

-- Keep one coordinate space for the lifetime of a touch or pen contact.
-- Rotation while a contact is down is deferred until the gesture detector
-- has consumed the lift; only the newest pending orientation matters.
-- Pen hover does not increment contact_count, so it cannot pin rotation.
local function installGyroHandler(input)
    local pending_rotation
    local misc_handler = input.handleMiscEv
    input.handleMiscEv = function(this, ev)
        if ev.wilkbook_gsensor and ev.code == 71 then
            if this.gesture_detector.contact_count > 0 then
                pending_rotation = ev.value
                return nil
            end
            return this:handleGyroEv(ev)
        end
        return misc_handler(this, ev)
    end

    local touch_handler = input.handleTouchEv
    input.handleTouchEv = function(this, ev)
        local events = touch_handler(this, ev)
        if pending_rotation ~= nil and this.gesture_detector.contact_count == 0 then
            local rotation = this:handleGyroEv({ value = pending_rotation })
            pending_rotation = nil
            if rotation then
                events = events or {}
                events[#events + 1] = rotation
            end
        end
        return events
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
    hasGSensor = yes,
    canHWInvert = no,
    hasColorScreen = no,
    canReboot = yes,
    canPowerOff = yes,
    canSuspend = suspend_qualified and yes or no, -- not validated on this kernel yet
    hasOTAUpdates = no,
    hasWifiManager = no,
    display_dpi = 227,
    -- Not a duplicate of the seeded home_dir setting.  This is what
    -- filemanagerutil.getDefaultDir() returns, and what
    -- FileChooser:goHome() falls back to when the setting does not
    -- stat as a directory.  "/root" put the Home button in the Guix
    -- root account's dotfiles.
    home_dir = "/data/books",
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
    local ebc_card = findEbcCard()
    local drm_fd = -1
    if not ebc_card then
        logger.warn("PineNote: no DRM card with DRIVER=rockchip-ebc; full refresh disabled")
    else
        drm_fd = C.open(ebc_card, bit.bor(C.O_RDWR, C.O_CLOEXEC))
        if drm_fd == -1 then
            logger.warn("PineNote: cannot open " .. ebc_card .. "; full refresh disabled")
        end
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
    -- Publish-on-call (doc/refresh-policy.md): fsync on the fbdev fd is
    -- fb_deferred_io_fsync -> flush_delayed_work, i.e. "run the pending
    -- deferred-io flush now".  It does not wait for the e-ink pass --
    -- the flush ends at a schedule_work() of the helper's damage
    -- worker, whose atomic commit is what actually lands the pixels in
    -- the driver -- and with nothing pending flush_delayed_work returns
    -- immediately, so we bias toward calling it and skip any per-tick
    -- latch.  Every refresh intent below publishes its damage at the
    -- moment of the call instead of waiting out the deferred-io timer:
    -- repaint duration stops racing the flush period (the measured
    -- cause of the portrait double-refresh), and pen strokes stop
    -- waiting 0-50 ms for the timer.
    --
    -- Note what this does NOT order: the commit blit runs on a kworker
    -- after fsync returns.  "The wash paints the new page" is
    -- guaranteed by the DRIVER, not here -- the global-refresh ioctl
    -- drains the deferred-io flush and the damage worker into
    -- ctx->final before arming the wash (see the forward-port patch's
    -- ioctl_trigger_global_refresh).
    --
    -- So publish() belongs ONLY on the partial paths.  It was originally
    -- also called before every global refresh, on the reasoning that it
    -- starts the flush earlier and covers kernels without the drain.  That
    -- was wrong on glass (2026-08-04): the deferred-io flush makes the
    -- driver partial-refresh the damage, which is a full visible paint, and
    -- the wash then paints the same content again -- "render, flash, render
    -- again" on rotation and on opening the menu.  The drain is part of the
    -- forward-port patch, which this image always carries, so relying on it
    -- costs nothing and saves an entire pass.
    local function publish()
        if self.screen and self.screen.fd and self.screen.fd ~= -1 then
            C.fsync(self.screen.fd)
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
                -- Deliberately NO publish() here.  fsync runs the
                -- deferred-io flush, which makes the driver partial-refresh
                -- the damage -- i.e. it PAINTS the new content -- and the
                -- wash that follows then paints it a second time.  On glass
                -- that is the "render, flash, render again" double update
                -- reported for rotation and for opening the menu
                -- (2026-08-04).  The ioctl already drains deferred-io all
                -- the way into ctx->final itself (flush_delayed_work +
                -- flush_work in ioctl_trigger_global_refresh), so the wash
                -- provably paints what userspace had written when it
                -- called.  One intent, one visible pass.
                global_refresh()
            else
                trace(intent, "partial", x, y, w, h, d)
                publish()
            end
        end
    end
    self.screen.refreshPartialImp = function(_, x, y, w, h, d)
        trace("partial", "partial", x, y, w, h, d)
        publish()
    end
    self.screen.refreshUIImp = function(_, x, y, w, h, d)
        trace("ui", "partial", x, y, w, h, d)
        publish()
    end
    self.screen.refreshFastImp = function(_, x, y, w, h, d)
        trace("fast", "partial", x, y, w, h, d)
        publish()
    end
    self.screen.refreshA2Imp = function(_, x, y, w, h, d)
        trace("a2", "partial", x, y, w, h, d)
        publish()
    end
    self.screen.refreshFlashUIImp = flash_policy("flashui")
    self.screen.refreshFlashPartialImp = flash_policy("flashpartial")
    self.screen.refreshFullImp = function(_, x, y, w, h, d)
        trace("full", "global", x, y, w, h, d)
        -- Same reason as flash_policy's global branch: the ioctl publishes
        -- for us, and an fsync first costs a whole extra visible pass.
        global_refresh()
    end

    self.powerd = require("device/pinenote/powerd"):new{
        device = self,
    }

    self.input = require("device/input"):new{
        device = self,
        event_map = {
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
    -- The power key belongs to the autosuspend daemon; KOReader must not
    -- open it (2026-08-06).  Upstream UIManager registers a Power handler
    -- unconditionally (onPowerEvent ignores canSuspend), so every press
    -- fired a full-screen refreshFull that raced the daemon's
    -- press-to-suspend into a mid-refresh suspend — parking the EBC and
    -- desyncing the driver's glass cache, which GL16 washes never heal
    -- for agreeing pixels.  devs.pwrkey stays discovered but unopened;
    -- the koreader-input harness pins the name→slot mapping.
    if devs.gpiokeys then self.input:open(devs.gpiokeys, "gpio-keys") end
    if devs.penbtn then self.input:open(devs.penbtn, "ws8100 pen buttons") end
    -- The optics injector is opened unconditionally when present: it
    -- only exists while a capture session's daemon holds it, and its
    -- KEY_BACK/KEY_FORWARD events use the pen buttons' event_map
    -- entries above (proven offline on the koreader-input harness).
    if devs.optics_inject then
        self.input:open(devs.optics_inject, "wilkbook-optics injector")
    end
    local evdev = require("ffi/input_evdev")
    if devs.gsensor then
        self.input:open(devs.gsensor, "wilkbook-orientation")
        -- The bridge emits nothing until KOReader has opened this node,
        -- otherwise the initial orientation could be lost before an evdev
        -- client exists and then suppressed as a duplicate.
        local ready = io.open("/run/wilkbook-orientation.consumer", "w")
        if ready then
            ready:write("ready\n")
            ready:close()
        else
            logger.warn("PineNote: cannot signal orientation consumer readiness")
        end
    else
        logger.warn("PineNote: wilkbook-orientation input device not found")
    end
    registerRequiredInputDevices(evdev, devs)
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
    --  * touchscreen: mirror its inverted MT axes, then neutralize its legacy
    --    single-touch aliases —
    --    BTN_TOUCH would poison the wacom contact gate while the pen
    --    hovers (ghost pen taps from a resting palm), and the
    --    pointer-emulation ABS_X/ABS_Y/ABS_PRESSURE would be honored
    --    as PEN coordinates whenever cur_slot sits on the pen slot;
    --    the MT events carry all the real finger state;
    --  * ws8100 pen buttons: neutralize the BTN_TOOL_PEN/RUBBER
    --    wrappers the driver emits around every button event — they
    --    would fight the digitizer's true proximity state; the KEY_*
    --    events pass through to event_map.
    local BTN_TOOL_RUBBER = 0x141
    local evdev = require("ffi/input_evdev")
    local pen_scale_x, pen_scale_y
    local touch_min_x, touch_max_x, touch_min_y, touch_max_y
    if devs.touch then
        touch_min_x, touch_max_x = evdev.absinfo(devs.touch, C.ABS_MT_POSITION_X)
        touch_min_y, touch_max_y = evdev.absinfo(devs.touch, C.ABS_MT_POSITION_Y)
        if touch_min_x ~= nil and touch_max_x ~= nil
           and touch_min_y ~= nil and touch_max_y ~= nil
           and touch_max_x >= touch_min_x and touch_max_y >= touch_min_y then
            logger.info(string.format(
                "PineNote: touch MT axes X=%d..%d Y=%d..%d (mirrored)",
                touch_min_x, touch_max_x, touch_min_y, touch_max_y))
        else
            touch_min_x, touch_max_x, touch_min_y, touch_max_y = nil, nil, nil, nil
            logger.warn("PineNote: could not query touch MT axis ranges; touch coordinates unmirrored")
        end
    end
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
            adjustTouchEvent(ev, devs.touch,
                touch_min_x, touch_max_x, touch_min_y, touch_max_y)
        elseif ev.src == devs.penbtn then
            if ev.type == C.EV_KEY and
               (ev.code == C.BTN_TOOL_PEN or ev.code == BTN_TOOL_RUBBER) then
                ev.type = EV_MSC
            end
        end
    end)

    Generic.init(self)
    -- Linux MSC_RAW is intentionally translated only for this virtual source.
    -- KOReader's private MSC_GYRO (71) reaches the upstream gyro handler here.
    self.input:registerEventAdjustHook(function(_, ev)
        translateGyroEvent(ev, devs.gsensor)
    end)
    installGyroHandler(self.input)
end


function PineNote:toggleGSensor(toggle)
    Generic.toggleGSensor(self, toggle)
    if toggle == true then
        local rotation = syncGyroState(self.input)
        if rotation then
            require("ui/uimanager"):broadcastEvent(rotation)
        end
    end
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
PineNote._findEbcCard = findEbcCard
PineNote._registerRequiredInputDevices = registerRequiredInputDevices
PineNote._translateGyroEvent = translateGyroEvent
PineNote._installGyroHandler = installGyroHandler
PineNote._syncGyroState = syncGyroState
PineNote._mirrorTouchMTPosition = mirrorTouchMTPosition
PineNote._adjustTouchEvent = adjustTouchEvent

return PineNote
