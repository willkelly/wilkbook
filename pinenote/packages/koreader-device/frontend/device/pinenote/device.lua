--[[--
Device abstraction for the Pine64 PineNote running wilkbook
(mainline-ish kernel, rockchip-ebc DRM driver).

Runs directly on the fbdev emulation (/dev/fb0; the format is discovered at
runtime -- RGB565 on the direct-mode driver, XR24 on the retired one) with evdev
input — no compositor, no SDL. Partial screen updates reach the e-ink
panel through the fbdev deferred-io path, published explicitly at each
refresh call via fsync on the fb fd (publish-on-call) with the deferred-io
timer as fallback; full refreshes use the driver's global-refresh ioctl.
--]]

local Generic = require("device/generic/device")
local logger = require("logger")
-- The acknowledged broker path completed its hardware acceptance matrix on
-- 2026-08-31.  The broker is now a required, supervised boot service, so the
-- packaged driver can expose suspend without a runtime validation overlay.
local suspend_qualified = true

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
            elseif name == "wilkbook-power-control" then
                local id_base = string.format("%s/event%d/device/id/", sysfs_base, n)
                local function id(field)
                    local id_file = io.open(id_base .. field, "r")
                    if not id_file then return nil end
                    local value = id_file:read("*line")
                    id_file:close()
                    return value
                end
                if id("bustype") == "0006" and id("vendor") == "1209"
                   and id("product") == "0003" and id("version") == "0001" then
                    found.power_control = node
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

-- These virtual devices are owned by services outside KOReader. Their loss
-- means the process must restart and enumerate their replacement nodes.
local function registerRequiredInputDevices(input_backend, devs)
    if devs.optics_inject then
        input_backend.setRequiredDevice(devs.optics_inject)
    end
    if devs.gsensor then
        input_backend.setRequiredDevice(devs.gsensor)
    end
    if devs.power_control then
        input_backend.setRequiredDevice(devs.power_control)
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

-- The two rockchip_ebc drivers share the platform-driver name and the
-- GLOBAL_REFRESH number but not DRM command 0x03: hrdl's direct driver
-- registers RECT_HINTS there, wilkbook's shipping driver REFRESH_BARRIER,
-- and DRM dispatches on the command number alone (issue #42).  The
-- direct driver's fingerprint is `default_hint`, the module default of
-- the hint plane RECT_HINTS writes; the shipping driver never registers
-- it.  The suspend broker's barrier probe is the mirror image
-- (`refresh_waveform`, shipping only).  `make ebc-ioctl-roster-check`
-- pins both against each driver's module_param registrations.
--
-- path is only ever passed by the koreader-input host harness.
local DEFAULT_HINT_PATH = "/sys/module/rockchip_ebc/parameters/default_hint"
local function isDirectEbc(path)
    local f = io.open(path or DEFAULT_HINT_PATH, "r")
    if not f then return false end
    f:close()
    return true
end

-- DRM_IOCTL_ROCKCHIP_EBC_RECT_HINTS on the direct driver only:
-- _IOW('d', 0x43, struct drm_rockchip_ebc_rect_hints /* 16 bytes */).
local DRM_RECT_HINTS = 0x40106443
-- The plane default reading renders through, and what every owner call
-- restores, is the module's default_hint as the running system set it
-- (pinenote-ebc-direct-params writes it before reader-session starts),
-- read once at init.  Every owner call writes that same value back as the
-- default, so neither an arm nor a KOReader that died armed can change
-- what the next start reads, and a value the service or a lab set before
-- KOReader started is kept rather than overwritten (one set under a
-- running KOReader lasts until its next owner call).  Unreadable, it
-- falls back to the service's own value: Y4 -> GL16, no REDRAW.
local HINT_READING_FALLBACK = 32

-- The module parameter as a hint byte, or nil when it is absent or not
-- one.  path is only ever passed by the koreader-input host harness.
local function readDefaultHint(path)
    local f = io.open(path or DEFAULT_HINT_PATH, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    local v = tonumber(s and s:match("^%s*(%d+)%s*$"))
    if v and v <= 255 then return v end
    return nil
end

local function u32le(v)
    v = v % 2^32
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256,
                       math.floor(v / 16777216) % 256)
end

-- The RECT_HINTS byte layout, kept byte-identical to the ebc-lab's
-- pinned packers (pinenote/tools/ebc-lab/ebclib.lua): the koreader-input
-- harness compares the two over a set of vectors.
--   struct drm_rockchip_ebc_rect_hints (16 bytes): u8 set_default_hint,
--     u8 default_hint, u8 pad[2], u32 num_rects, u64 rect_hints (the
--     caller patches the pointer in; it is zero here);
--   struct drm_rockchip_ebc_rect_hint (24 bytes): u8 hints, u8 pad[7],
--     then a drm_mode_rect of s32 x1, y1, x2, y2 with x2/y2 EXCLUSIVE.
local function packRectHintsHeader(set_default, default_hint, num_rects)
    return string.char(set_default and 1 or 0, (default_hint or 0) % 256, 0, 0)
        .. u32le(num_rects)
        .. string.rep("\0", 8)
end

local function packRectHint(hint, x, y, w, h)
    return string.char(hint % 256) .. string.rep("\0", 7)
        .. u32le(x) .. u32le(y) .. u32le(x + w) .. u32le(y + h)
end

-- The owner of the direct driver's hint plane: the one place that arms the
-- notebook's DU rectangle and the one place that takes it away again.
--
-- Hints are copied when the fbdev damage worker blits, on a kworker after
-- the fsync that published the damage has returned, so a hint governs
-- whichever paint is blitted while it is set, not the paint that asked
-- for it.  Paint that does not know about the rectangle (dialogs, the
-- screensaver, washes) would render thresholded inside it, so every
-- refresh*Imp calls guard() before it publishes, and guard() returns the
-- plane to the reading hint when the refresh reaches an armed rectangle.
-- Ink is exempt because it publishes through PineNote:publishNow(), not
-- through a refresh*Imp.
--
-- Every call sets the plane default as well (set_default_hint memsets the
-- whole plane and rewrites the module's default_hint), so the plane never
-- depends on what an earlier arm left behind, and a KOReader that dies
-- armed leaves nothing a later reset() cannot clear.
--
-- A no-op unless the driver is the direct one: on the shipping driver
-- command 0x03 is REFRESH_BARRIER.
--
-- opts: ioctl = function(request, arg) -> ret[, errno] (nil: no card),
--       is_direct = bool, bb = function() -> Screen.bb (read per call:
--       the framebuffer may replace its bb, never cache it),
--       reading_hint = the plane default (nil: HINT_READING_FALLBACK).
local HintOwner = {}
HintOwner.__index = HintOwner

-- What a failed reset leaves recorded: the plane is unknown (a crashed
-- KOReader may have left DU on it), so the whole panel counts as armed.
local PLANE_UNKNOWN = { { x = 0, y = 0, w = 2^31 - 1, h = 2^31 - 1, hint = 0 } }

-- NaN and the infinities pass a type check but not string.char, and an
-- arm runs inside the input hook, where an error takes KOReader down.
local function finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function newHintOwner(opts)
    return setmetatable({
        _ioctl = opts.ioctl,
        _bb = opts.bb,
        _reading = opts.reading_hint or HINT_READING_FALLBACK,
        _live = opts.is_direct == true and opts.ioctl ~= nil,
        _armed = nil,       -- the rects as armed, or nil
        _refused = false,   -- a failed arm stops arming until reset()
        _failing = false,   -- log one line per streak of failed calls
    }, HintOwner)
end

function HintOwner:_submit(rects, label)
    local n = rects and #rects or 0
    -- uint64_t[2]: 8-aligned, so the pointer is a plain store into [1].
    local arg = ffi.new("uint64_t[2]")
    ffi.copy(arg, packRectHintsHeader(true, self._reading, n), 16)
    if n > 0 then
        local parts = {}
        for i = 1, n do
            local r = rects[i]
            parts[i] = packRectHint(r.hint, r.x, r.y, r.w, r.h)
        end
        local blob = table.concat(parts)
        -- Anchored on the owner: the header holds only its address, which
        -- the garbage collector cannot see.
        self._rect_buf = ffi.new("uint8_t[?]", #blob)
        ffi.copy(self._rect_buf, blob, #blob)
        arg[1] = ffi.cast("uintptr_t", self._rect_buf)
    end
    local ret, errno = self._ioctl(DRM_RECT_HINTS, arg)
    self._rect_buf = nil
    ret = tonumber(ret) or -1
    if ret < 0 then
        if not self._failing then
            logger.warn(string.format("[pn-hint] %s failed: ret=%d errno=%s",
                label, ret, tostring(errno)))
        end
        self._failing = true
        return false
    end
    self._failing = false
    return true
end

--- Arm physical rects {x, y, w, h, hint}, applied in order over a plane
-- reset to the reading hint (a later rect wins where two overlap).  Returns
-- true when the driver took them.
function HintOwner:arm(rects)
    if not self._live or self._refused then return false end
    local armed = {}
    for i, r in ipairs(rects or {}) do
        if type(r) ~= "table" or not (finite(r.x) and finite(r.y)
           and finite(r.w) and finite(r.h) and finite(r.hint)) then
            logger.warn("[pn-hint] arm refused: malformed rect " .. i)
            return false
        end
        local x1, y1 = math.floor(r.x), math.floor(r.y)
        armed[i] = { x = x1, y = y1, hint = r.hint % 256,
                     w = math.ceil(r.x + r.w) - x1,
                     h = math.ceil(r.y + r.h) - y1 }
    end
    if #armed == 0 then return self:disarm() end
    if not self:_submit(armed, "arm") then
        -- The plane may hold part of the request; keep guarding it as if
        -- armed, and refuse to arm again until reset(), so a caller that
        -- retries per pen report cannot turn one failure into 360 ioctls
        -- a second.  Ink then publishes at the plane default: GL16,
        -- slower but correct.
        self._armed = armed
        self._refused = true
        return false
    end
    self._armed = armed
    logger.info(string.format("[pn-hint] arm %d rect(s), first %d,%d,%d,%d:0x%02x",
        #armed, armed[1].x, armed[1].y, armed[1].w, armed[1].h, armed[1].hint))
    return true
end

function HintOwner:_restore()
    if not self:_submit(nil, "disarm") then
        -- Still armed as far as anyone knows, so guards retry.
        self._armed = self._armed or PLANE_UNKNOWN
        return false
    end
    self._armed = nil
    logger.info("[pn-hint] disarm")
    return true
end

--- Return the plane to the reading hint if anything is armed.
function HintOwner:disarm()
    if not self._live or not self._armed then return true end
    return self:_restore()
end

--- Return the plane to the reading hint unconditionally, and allow arming
-- again after a failed arm.  The notebook calls it once per process,
-- which clears a rectangle a crashed KOReader left armed.
function HintOwner:reset()
    if not self._live then return true end
    if not self:_restore() then return false end
    self._refused = false
    return true
end

--- True while the plane may hold anything but the reading hint: after an arm,
-- and after a failed arm or disarm, until a disarm succeeds.
function HintOwner:is_armed()
    return self._armed ~= nil
end

--- The refresh-layer guard.  x, y, w, h are LOGICAL and unbounded, as a
-- refresh*Imp receives them.  Disarms when the refresh reaches any armed
-- rect whose hint is not the plane default (the notebook arms 0x00 over
-- the canvas and 0x20, the shipped default, over its panel; with another
-- default a refresh over the panel disarms too, which is the safe side).
-- Returns true when the refresh reached one, and so a disarm was
-- attempted.
function HintOwner:guard(x, y, w, h)
    local armed = self._armed
    if not armed then return false end
    local bb = self._bb and self._bb()
    -- Geometry it cannot place counts as a hit: disarming is always safe,
    -- while a missed disarm renders dialog text thresholded.
    if bb and x and y and w and h then
        x, y, w, h = bb:getBoundedRect(x, y, w, h)
        if w <= 0 or h <= 0 then return false end
        local px, py, pw, ph = bb:getPhysicalRect(x, y, w, h)
        local hit = false
        for _, r in ipairs(armed) do
            if r.hint ~= self._reading
               and px < r.x + r.w and r.x < px + pw
               and py < r.y + r.h and r.y < py + ph then
                hit = true
                break
            end
        end
        if not hit then return false end
    end
    self:disarm()
    return true
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

-- The w9013's grid is 11.2x the panel's, and the notebook shapes pressure
-- and speed from the unrounded position, so the digitizer value stays on
-- the event as raw_value.  The clamp keeps the last digitizer unit on the
-- panel: 20966 * 1872/20966 rounds to 1872, one past the last pixel.
local function adjustPenEvent(ev, sx, sy, w, h)
    if ev.type ~= C.EV_ABS then return false end
    local scale, last
    if ev.code == C.ABS_X then
        scale, last = sx, w - 1
    elseif ev.code == C.ABS_Y then
        scale, last = sy, h - 1
    else
        return false
    end
    ev.raw_value = ev.value
    local v = math.floor(ev.value * scale + 0.5)
    ev.value = v < 0 and 0 or (v > last and last or v)
    return true
end

-- Keep one coordinate space for the lifetime of a touch or pen contact.
-- Rotation while a contact is down is deferred until the gesture detector
-- has consumed the lift; only the newest pending orientation matters.
-- Pen hover does not increment contact_count, so it cannot pin rotation.
--
-- A consumer that takes pen and touch away from the gesture detector (the
-- notebook) never raises contact_count, so it holds rotation through
-- input.wilkbook_hold_rotation instead, and collects what arrived meanwhile
-- with input:takePendingRotation() when its hold ends: while it consumes,
-- no touch event reaches the flush below.
local function installGyroHandler(input)
    local pending_rotation
    local function held(this)
        if this.gesture_detector.contact_count > 0 then return true end
        local hold = this.wilkbook_hold_rotation
        return hold ~= nil and hold(this) == true
    end
    local misc_handler = input.handleMiscEv
    input.handleMiscEv = function(this, ev)
        if ev.wilkbook_gsensor and ev.code == 71 then
            if held(this) then
                pending_rotation = ev.value
                return nil
            end
            return this:handleGyroEv(ev)
        end
        return misc_handler(this, ev)
    end

    -- The raw orientation (0..3), not an Event: the caller runs it through
    -- handleGyroEv, which also honours the sensor lock and inhibitInput.
    input.takePendingRotation = function()
        local rotation = pending_rotation
        pending_rotation = nil
        return rotation
    end

    local touch_handler = input.handleTouchEv
    input.handleTouchEv = function(this, ev)
        local events = touch_handler(this, ev)
        if pending_rotation ~= nil and not held(this) then
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

-- The notebook's input seam: registered once, last in the chain, so a
-- consumer sees pen X/Y scaled (raw_value kept), touch mirrored and the
-- gyro translated.  Input has no way to unregister an adjust hook, and a
-- plugin is instantiated per ReaderUI and per FileManager, so a hook
-- registered by a plugin would stack another closure on every book open.
-- Plugins set and clear input.wilkbook_consumer instead.
local function consumerHook(input, ev)
    local consumer = input.wilkbook_consumer
    if consumer then consumer(input, ev) end
end

local PineNote = Generic:extend{
    model = "PineNote",
    -- Generic waits 15 seconds before invoking Device:suspend, while the
    -- broker's physical-trigger preparation deadline is intentionally 10.
    -- EBC completion is enforced separately by the barrier, so three seconds
    -- is enough for KOReader's forced screensaver repaint and leaves ample
    -- time to deliver the ready acknowledgement.
    suspend_wait_timeout = 3,
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
    canSuspend = suspend_qualified and yes or no, -- accepted broker path, 2026-08-31
    hasOTAUpdates = no,
    -- The Guix KOReader bundle intentionally omits lj-wpaclient.  We provide
    -- a radio toggle and restore path, but not KOReader's AP-list manager,
    -- whose wpa_supplicant backend would require that optional Lua module.
    hasWifiManager = no,
    hasWifiRestore = yes,
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
        return drm_fd ~= -1 and C.ioctl(drm_fd, DRM_GLOBAL_REFRESH, refresh_arg) == 0
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
    -- waiting up to defio_delay_ms (250 ms) for the timer.
    --
    -- Note what this does NOT order: the commit blit runs on a kworker
    -- after fsync returns.  On the old shipping driver "the wash paints
    -- the new page" was guaranteed by the DRIVER, not here: its
    -- global-refresh ioctl drained the deferred-io flush and the damage
    -- worker into ctx->final before arming the wash (the forward-port
    -- patch's ioctl_trigger_global_refresh).  hrdl's direct driver, which
    -- the reader flavor now ships, does not drain: its
    -- ioctl_trigger_global_refresh only sets the GLOBAL_REFRESH work item
    -- and wakes the refresh thread, so damage still waiting out
    -- defio_delay_ms can reach the panel after the wash, as a partial
    -- pass.  That is an unregistered driver finding (doc/notebook.md,
    -- "Housekeeping"); whether it shows on glass is unchecked.
    --
    -- So publish() belongs ONLY on the partial paths.  It was originally
    -- also called before every global refresh, on the reasoning that it
    -- starts the flush earlier and covers kernels without the drain.  That
    -- was wrong on glass (2026-08-04, the old driver): the deferred-io
    -- flush makes the driver partial-refresh the damage, which is a full
    -- visible paint, and the wash then paints the same content again --
    -- "render, flash, render again" on rotation and on opening the menu.
    local function publish()
        self:publishNow()
    end
    -- The notebook's DU rectangle (HintOwner above).  Each refresh*Imp
    -- below guards BEFORE it publishes or washes: the blit that samples the
    -- hints runs after the fsync, so a disarm after it could come too late.
    local hint_ioctl
    if drm_fd ~= -1 then
        hint_ioctl = function(request, arg)
            local ret = C.ioctl(drm_fd, request, arg)
            if ret < 0 then return ret, ffi.errno() end
            return ret
        end
    end
    local is_direct = isDirectEbc()
    local reading_hint = is_direct and readDefaultHint() or nil
    logger.info("PineNote: hint plane " .. (not is_direct
        and "absent (not the direct driver); RECT_HINTS refused"
        or (hint_ioctl and "owned" or "unreachable (no card)")))
    if is_direct then
        logger.info(string.format("PineNote: reading hint %d%s",
            reading_hint or HINT_READING_FALLBACK,
            reading_hint and "" or " (default_hint unreadable; fallback)"))
    end
    local hint_owner = newHintOwner{
        ioctl = hint_ioctl,
        is_direct = is_direct,
        bb = function() return self.screen.bb end,
        reading_hint = reading_hint,
    }
    self.hint_owner = hint_owner
    -- Flash intents wash the panel only when they cover at least this
    -- fraction of it.  Tunable via the G_reader_settings key
    -- "pinenote_flash_area_fraction" so the optics harness can sweep it
    -- per capture run (driver.py seeds it into the dedicated KO_HOME's
    -- settings.reader.lua).  G_reader_settings is initialized in
    -- reader.lua before the device module loads (reader.lua:39 vs the
    -- device require), but nil-guard anyway: host harnesses stub it.
    local flash_area_fraction = 0.98
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
            hint_owner:guard(x, y, w, h)
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
                -- (2026-08-04, old driver). The direct driver does not
                -- guarantee that damage drain; see the caveat above.
                global_refresh()
            else
                trace(intent, "partial", x, y, w, h, d)
                publish()
            end
        end
    end
    self.screen.refreshPartialImp = function(_, x, y, w, h, d)
        hint_owner:guard(x, y, w, h)
        trace("partial", "partial", x, y, w, h, d)
        publish()
    end
    self.screen.refreshUIImp = function(_, x, y, w, h, d)
        hint_owner:guard(x, y, w, h)
        trace("ui", "partial", x, y, w, h, d)
        publish()
    end
    self.screen.refreshFastImp = function(_, x, y, w, h, d)
        hint_owner:guard(x, y, w, h)
        trace("fast", "partial", x, y, w, h, d)
        publish()
    end
    self.screen.refreshA2Imp = function(_, x, y, w, h, d)
        hint_owner:guard(x, y, w, h)
        trace("a2", "partial", x, y, w, h, d)
        publish()
    end
    self.screen.refreshFlashUIImp = flash_policy("flashui")
    self.screen.refreshFlashPartialImp = flash_policy("flashpartial")
    self.screen.refreshFullImp = function(_, x, y, w, h, d)
        hint_owner:guard(x, y, w, h)
        trace("full", "global", x, y, w, h, d)
        -- Same no-publish policy as flash_policy's global branch.
        local success = global_refresh()
        -- Acknowledges ioctl acceptance, not physical wash completion.
        -- The notebook owns this optional one-shot and its timeout/cleanup.
        local done = self.wilkbook_full_refresh_done
        if done then done(success) end
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
            [142] = "BrokerSleep", -- KEY_SLEEP from the production broker
            [143] = "BrokerWake",  -- KEY_WAKEUP from the production broker
        },
        -- Direct power-management events must bypass ordinary KeyPress/
        -- KeyRelease wrapping while awake.  The inhibited-input handler also
        -- runs this adapter, so the same mapping handles broker wakeup.
        event_map_adapter = {
            BrokerSleep = function(ev)
                if ev.value == 1 then return "Suspend" end
            end,
            BrokerWake = function(ev)
                if ev.value == 1 then return "Resume" end
            end,
        },
        wacom_protocol = true,
        -- Pure-LuaJIT evdev backend (the desktop release bundle does not
        -- ship libs/libkoreader-input.so); pre-setting it here makes
        -- Input:init() skip its default backend require.
        input = require("ffi/input_evdev"),
    }

    local devs = findInputDevices()
    -- Every ev.src is one of these paths, so a consumer tells sources apart
    -- by comparing against them.
    self.input_devices = devs
    if devs.pen then self.input:open(devs.pen, "w9013 pen digitizer") end
    if devs.touch then self.input:open(devs.touch, "cyttsp5 touchscreen") end
    -- The power key belongs to the platform-controls broker; KOReader must not
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
    if not devs.power_control then
        error("PineNote: supervised wilkbook-power-control input device is required")
    end
    self.input:open(devs.power_control, "wilkbook power control")
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
    -- On top of both: never feed the gesture detector a slot it cannot
    -- identify.  Upstream's Input:resetState() (run by inhibitInput(true)
    -- as every crengine re-render starts, i.e. on every pinch-to-font-size)
    -- forgets a finger that is still on the glass; its first delta-only
    -- frame after inhibitInput(false) restores input would otherwise
    -- become a ghost contact that crashes the next
    -- two-finger pan (glass, 2026-09-02; mechanism and offline repro in
    -- slotguard.lua / test-slotguard.lua).
    if devs.touch then
        require("device/pinenote/slotguard").install(self.input)
    end

    -- Per-source event conditioning.  Our evdev backend tags every
    -- event with src = originating device node, so no cross-device
    -- state (like the old pen-proximity boolean) is needed:
    --  * pen: scale digitizer units (20966x15725) to screen pixels,
    --    keeping the digitizer value as raw_value (adjustPenEvent),
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
    local pen_scale_x, pen_scale_y, pen_w, pen_h
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
            pen_w, pen_h = screen_w, screen_h
            logger.info(string.format(
                "PineNote: pen axes %dx%d -> screen %dx%d (scale %.4f/%.4f)",
                max_x, max_y, screen_w, screen_h, pen_scale_x, pen_scale_y))
        else
            logger.warn("PineNote: could not query pen axis ranges; pen coordinates unscaled")
        end
    end
    self.input:registerEventAdjustHook(function(_, ev)
        if ev.src == devs.pen then
            if pen_scale_x then
                adjustPenEvent(ev, pen_scale_x, pen_scale_y, pen_w, pen_h)
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
    -- Keep this the last hook registered (consumerHook above).
    self.input:registerEventAdjustHook(consumerHook)
end

--- Publish pending fbdev damage now: the fsync every refresh*Imp's
-- publish() runs, untraced and unguarded.  For ink, which publishes once
-- per pen report (~360 Hz; a trace line each would flood the log) and is
-- the one paint the armed DU rectangle exists for.  Returns true when the
-- fsync ran and succeeded.
function PineNote:publishNow()
    local screen = self.screen
    if screen and screen.fd and screen.fd ~= -1 then
        return C.fsync(screen.fd) == 0
    end
    return false
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
    -- GNU Shepherd's halt powers off by default and does not implement the
    -- util-linux/systemd-compatible -p option.
    os.execute("/run/current-system/profile/sbin/halt")
end

function PineNote:reboot()
    os.execute("/run/current-system/profile/sbin/reboot")
end

function PineNote:supportsScreensaver()
    return true
end

local suspend_sequence = 0
function PineNote:suspend()
    suspend_sequence = suspend_sequence + 1
    local request_id = string.format("%d-%d", os.time(), suspend_sequence)
    local path = "/run/wilkbook-power/request"
    local fd = C.open(path, bit.bor(C.O_WRONLY, C.O_NONBLOCK, C.O_CLOEXEC))
    if fd == -1 then
        logger.warn("PineNote: suspend broker unavailable; cancelling suspend")
        require("ui/uimanager"):nextTick(function() self:onPowerEvent("Resume") end)
        return false
    end
    local line = "ready " .. request_id .. "\n"
    local written = C.write(fd, line, #line)
    C.close(fd)
    if tonumber(written) ~= #line then
        logger.warn("PineNote: incomplete suspend broker request; cancelling suspend")
        require("ui/uimanager"):nextTick(function() self:onPowerEvent("Resume") end)
        return false
    end
    return true
end

-- Present while the user has turned Wi-Fi off from the menu (see
-- initNetworkManager); /run, so a reboot -- where the service brings the
-- radio up regardless -- starts clean.
local USER_OFF_MARKER = "/run/wilkbook-power/wifi.user-off"

function PineNote:initNetworkManager(NetworkMgr)
    local helper = "/run/current-system/profile/bin/pinenote-wifi-control"
    -- Keep the archived Phase 1 overlay usable for historical recovery;
    -- production images always take the packaged path above.
    local packaged = io.open(helper, "r")
    if packaged then
        packaged:close()
    else
        helper = "/data/wilkbook/validation/platform-controls-v1/bin/pinenote-wifi-control"
    end
    local function run(action)
        return os.execute(helper .. " " .. action) == 0
    end
    function NetworkMgr:turnOffWifi(complete_callback)
        local ok = run("off")
        if ok and complete_callback then complete_callback() end
        return ok
    end
    function NetworkMgr:turnOnWifi(complete_callback)
        local ok = run("on")
        if ok and complete_callback then complete_callback() end
        return ok
    end
    function NetworkMgr:restoreWifiAsync()
        self:turnOnWifi()
    end
    function NetworkMgr:getNetworkInterfaceName() return "wlan0" end
    function NetworkMgr:isWifiOn() return run("status") end
    NetworkMgr.isConnected = NetworkMgr.ifHasAnAddress
    -- KOReader restores Wi-Fi on resume only when its own memory of having
    -- brought the radio up (`wifi_was_on`) is true, and it clears that
    -- memory whenever a restore's connectivity check times out (manager.lua
    -- _abortWifiConnection).  Our radio is brought up by the pinenote-wifi
    -- service, not by KOReader, so the memory is seeded once and never
    -- re-earned: one slow resume clears it for good and every idle sleep
    -- after that leaves the reader offline until the menu (glass,
    -- 2026-09-03: a whole evening).  If the service has the radio on when
    -- KOReader starts, that IS the fact the memory encodes.  Policy stays
    -- KOReader's: auto_restore_wifi still gates the restore.
    if G_reader_settings and run("status") then
        G_reader_settings:makeTrue("wifi_was_on")
    end
    -- The control script cannot tell a sleep's radio-off from the user's:
    -- both reach turnOffWifi.  KOReader knows (disableWifi's `interactive`),
    -- so remember it here: a marker while the user has the radio off, gone
    -- when they turn it on again.  restoreWifiMemory() honours it, so a menu
    -- choice survives a sleep -- the half of the flag KOReader reserves for
    -- direct user interaction stays the user's.
    local disableWifi, enableWifi = NetworkMgr.disableWifi, NetworkMgr.enableWifi
    function NetworkMgr:disableWifi(cb, interactive)
        if interactive then
            local f = io.open(USER_OFF_MARKER, "w"); if f then f:close() end
        end
        return disableWifi(self, cb, interactive)
    end
    function NetworkMgr:enableWifi(cb, interactive)
        if interactive then os.remove(USER_OFF_MARKER) end
        return enableWifi(self, cb, interactive)
    end
end

-- The control script records, when it takes the radio down for a sleep,
-- whether a validated supplicant was running: /run/wilkbook-power/wifi.state
-- reads "on" exactly when the radio was on before this sleep.  Reassert
-- KOReader's memory from that record before its NetworkListener decides.
function PineNote:restoreWifiMemory()
    local marker = io.open(USER_OFF_MARKER, "r")
    if marker then marker:close(); return end  -- the user turned it off; leave it off
    local f = io.open("/run/wilkbook-power/wifi.state", "r")
    if not f then return end
    local state = f:read("*l"); f:close()
    if state ~= "on" then return end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr then NetworkMgr.wifi_was_on = true end
    if G_reader_settings then G_reader_settings:makeTrue("wifi_was_on") end
end

function PineNote:setEventHandlers(uimgr)
    -- NetworkListener observes these ordinary Suspend/Resume broadcasts and
    -- honors KOReader's auto_restore_wifi preference.  Do not impose a
    -- platform-specific restore policy here.
    uimgr.event_handlers.Suspend = function() self:onPowerEvent("Suspend") end
    uimgr.event_handlers.Resume = function()
        self:restoreWifiMemory()
        self:onPowerEvent("Resume")
    end
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
PineNote._adjustPenEvent = adjustPenEvent
PineNote._consumerHook = consumerHook
PineNote._isDirectEbc = isDirectEbc
PineNote._readDefaultHint = readDefaultHint
PineNote._newHintOwner = newHintOwner
PineNote._packRectHintsHeader = packRectHintsHeader
PineNote._packRectHint = packRectHint

return PineNote
