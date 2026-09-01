--[[--
Direct-driver mode and hint switch for pen sessions (D8).

Drives two ioctls on hrdl's rockchip_ebc:

  DRM_IOCTL_ROCKCHIP_EBC_MODE        query/set NORMAL|FAST (+redraw_delay)
  DRM_IOCTL_ROCKCHIP_EBC_RECT_HINTS  set the default pixel hint

Pen work wants FAST with hint byte 0 (Y1 depth + THRESHOLD, REDRAW
off); reading wants NORMAL with the driver default 160 (Y4 + THRESHOLD
+ REDRAW).  Numbers and struct layouts come from the swap patch's
include/uapi/drm/rockchip_ebc_drm.h and are pinned by the harness --
including the generator itself against the hardware-proven
GLOBAL_REFRESH constant 0xC0016440.

The card is resolved by driver name, NEVER by index: whichever DRM
driver probes first takes card0, and on the direct image that is the
panfrost GPU (the 2026-08-25 D4 root cause).

Usage: ebc-mode.lua [--fast | --normal] [--hint N] [--redraw-delay N]
                    [--query] [--sys-root DIR] [--dev-root DIR]
--]]

local ffi = require("ffi")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
int ioctl(int fd, unsigned long req, void *arg);
]]

local O_RDWR = 2

local MODE_NORMAL, MODE_FAST = 0, 1

local opt = {
    mode = nil, hint = nil, redraw_delay = nil, query = false,
    sys_root = "/sys", dev_root = "/dev",
}
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--fast" then opt.mode = MODE_FAST
        elseif a == "--normal" then opt.mode = MODE_NORMAL
        elseif a == "--hint" then i = i + 1; opt.hint = tonumber(arg[i])
        elseif a == "--redraw-delay" then i = i + 1; opt.redraw_delay = tonumber(arg[i])
        elseif a == "--query" then opt.query = true
        elseif a == "--sys-root" then i = i + 1; opt.sys_root = arg[i]
        elseif a == "--dev-root" then i = i + 1; opt.dev_root = arg[i]
        end
        i = i + 1
    end
end

-- DRM ioctl request numbers, computed the way the kernel macros do:
-- _IOC(dir, 'd', DRM_COMMAND_BASE + nr, size).  Pinned by the harness
-- against DRM_IOCTL_ROCKCHIP_EBC_GLOBAL_REFRESH = 0xC0016440, the one
-- constant this repo has already driven on hardware.
local function drm_ioc(dir, nr, size)
    return dir * 2^30 + size * 2^16 + 0x64 * 2^8 + (0x40 + nr)
end
local function drm_iowr(nr, size) return drm_ioc(3, nr, size) end
local function drm_iow(nr, size) return drm_ioc(1, nr, size) end

-- struct drm_rockchip_ebc_mode, 8 bytes:
--   u8 set_driver_mode; u8 driver_mode; u8 set_dither_mode;
--   u8 dither_mode; u16 redraw_delay (LE); u8 set_redraw_delay; u8 pad
local function pack_mode(set_driver, driver_mode, set_redraw, redraw_delay)
    return string.char(
        set_driver and 1 or 0, driver_mode or 0,
        0, 0,
        (redraw_delay or 0) % 256, math.floor((redraw_delay or 0) / 256),
        set_redraw and 1 or 0, 0)
end

local function unpack_mode(s)
    local b = { s:byte(1, 8) }
    return {
        driver_mode = b[2],
        dither_mode = b[4],
        redraw_delay = b[5] + b[6] * 256,
    }
end

-- struct drm_rockchip_ebc_rect_hints, 16 bytes:
--   u8 set_default_hint; u8 default_hint; u8 pad[2];
--   u32 num_rects (LE); u64 rect_hints pointer
-- Setting only the default (num_rects=0, null pointer) repaints every
-- pixel's hint, which is exactly what a mode switch wants.
local function pack_default_hint(hint)
    return string.char(1, hint % 256, 0, 0)
        .. string.rep("\0", 4)      -- num_rects = 0
        .. string.rep("\0", 8)      -- rect_hints = NULL
end

-- Resolve the EBC's DRM node by driver name.  The probe reads
-- /sys/class/drm/cardN/device/uevent looking for DRIVER=rockchip-ebc;
-- an index literal would break on any image where another DRM driver
-- probes first.
local function find_ebc_card(sys_root)
    for n = 0, 7 do
        local f = io.open(sys_root .. "/class/drm/card" .. n
                          .. "/device/uevent", "r")
        if f then
            local body = f:read("*a") or ""
            f:close()
            if body:find("DRIVER=rockchip-ebc", 1, true) then
                return n
            end
        end
    end
    return nil
end

local function fail(msg)
    io.stderr:write("[ebc-mode] " .. msg .. "\n")
    os.exit(1)
end

-- ---------------------------------------------------------------------
-- main

local MODE_IOCTL = drm_iowr(0x04, 8)
local RECT_HINTS_IOCTL = drm_iow(0x03, 16)

local card = find_ebc_card(opt.sys_root)
if not card then fail("no DRM card with DRIVER=rockchip-ebc") end
local path = opt.dev_root .. "/dri/card" .. card
local fd = ffi.C.open(path, O_RDWR)
if fd < 0 then fail("cannot open " .. path .. " (root?)") end

local function mode_ioctl(payload)
    local buf = ffi.new("uint8_t[8]")
    ffi.copy(buf, payload, 8)
    local ret = ffi.C.ioctl(fd, MODE_IOCTL, buf)
    if ret ~= 0 then fail("MODE ioctl failed (ret=" .. tostring(ret) .. ")") end
    return unpack_mode(ffi.string(buf, 8))
end

if opt.hint then
    local payload = pack_default_hint(opt.hint)
    local buf = ffi.new("uint8_t[16]")
    ffi.copy(buf, payload, 16)
    local ret = ffi.C.ioctl(fd, RECT_HINTS_IOCTL, buf)
    if ret ~= 0 then fail("RECT_HINTS ioctl failed (ret=" .. tostring(ret) .. ")") end
    print(("default hint set to %d"):format(opt.hint))
end

if opt.mode ~= nil or opt.redraw_delay ~= nil then
    local m = mode_ioctl(pack_mode(opt.mode ~= nil, opt.mode or 0,
                                   opt.redraw_delay ~= nil,
                                   opt.redraw_delay or 0))
    print(("mode=%d dither=%d redraw_delay=%d")
        :format(m.driver_mode, m.dither_mode, m.redraw_delay))
elseif opt.query or not opt.hint then
    local m = mode_ioctl(pack_mode(false, 0, false, 0))
    print(("mode=%d dither=%d redraw_delay=%d (0=NORMAL 1=FAST)")
        :format(m.driver_mode, m.dither_mode, m.redraw_delay))
end

ffi.C.close(fd)
