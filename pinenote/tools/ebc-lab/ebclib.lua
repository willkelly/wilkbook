--[[--
Shared core for the EBC live-iteration lab (the "user mode driver"
workbench): DRM ioctl numbers, struct packers, card/framebuffer
discovery.  Everything here is pure -- no ioctl is issued from this
module -- so the harness pins the byte layouts exactly, and the CLI
tools stay thin.

Why this exists (2026-08-26): iterating on display behaviour through
image writes costs a deploy cycle each; hrdl's direct driver exposes
enough ioctl surface (MODE, RECT_HINTS, PHASE_SEQUENCE) to drive every
experiment live over SSH on a running system.  The REGAL-table theory
died in one offline compile the same night this lab was started; the
next theories die (or live) on glass, minutes apart.
--]]

local M = {}

-- DRM ioctl request numbers, the kernel macro arithmetic.  The harness
-- anchors this generator to DRM_IOCTL_ROCKCHIP_EBC_GLOBAL_REFRESH =
-- 0xC0016440, the constant this repo has driven on hardware since
-- 2026-07-04, before trusting anything else it emits.
function M.drm_ioc(dir, nr, size)
    return dir * 2^30 + size * 2^16 + 0x64 * 2^8 + (0x40 + nr)
end
function M.drm_iowr(nr, size) return M.drm_ioc(3, nr, size) end
function M.drm_iow(nr, size) return M.drm_ioc(1, nr, size) end

M.MODE_IOCTL = M.drm_iowr(0x04, 8)
-- EXTRACT_FBS: five u64 userspace pointers (packed inner/outer/nextprev,
-- hints, prelim/target, phase1, phase2); NULLs skipped.  The direct
-- driver ships this live -- the belief half of the
-- intent-vs-belief-vs-glass three-way join (doc/status.md part 15).
M.EXTRACT_FBS_IOCTL = M.drm_iowr(0x02, 40)
M.RECT_HINTS_IOCTL = M.drm_iow(0x03, 16)
M.GLOBAL_REFRESH_IOCTL = M.drm_iowr(0x00, 1)

-- struct drm_rockchip_ebc_phase_sequence:
--   u8 num_seqs, do_init, do_gc16, gc_target, do_force_temperature,
--      force_temperature; u8 _pad[6]; u32 delay_ms;
--   struct elm[96]:
--     u32 delay_ms; u8 num_frames; u8 _pad[3]; u32 num_regions;
--     struct drm_mode_rect rect[8]  (4 x s32 each: x1,y1,x2,y2);
--     u8 phase[8];
M.PS_MAX_SEQS = 96
M.PS_MAX_REGIONS = 8
M.PS_ELM_SIZE = 4 + 1 + 3 + 4 + 8 * 16 + 8   -- 148
M.PS_SIZE = 16 + M.PS_MAX_SEQS * M.PS_ELM_SIZE -- 14224
M.PHASE_SEQUENCE_IOCTL = M.drm_iow(0x06, M.PS_SIZE)

local function u32le(v)
    v = v % 2^32
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256,
                       math.floor(v / 16777216) % 256)
end
M.u32le = u32le

-- struct drm_rockchip_ebc_mode, 8 bytes (see ebc-mode.lua, same layout).
function M.pack_mode(set_driver, driver_mode, set_redraw, redraw_delay)
    return string.char(
        set_driver and 1 or 0, driver_mode or 0,
        0, 0,
        (redraw_delay or 0) % 256, math.floor((redraw_delay or 0) / 256),
        set_redraw and 1 or 0, 0)
end

function M.unpack_mode(s)
    local b = { s:byte(1, 8) }
    return {
        driver_mode = b[2],
        dither_mode = b[4],
        redraw_delay = b[5] + b[6] * 256,
    }
end

-- One struct drm_rockchip_ebc_rect_hint (24 bytes): the hint byte, 7
-- bytes of padding, then a drm_mode_rect x1,y1,x2,y2 (EXCLUSIVE x2/y2,
-- matching drm_rect semantics).
function M.pack_rect_hint(hint, x, y, w, h)
    return string.char(hint % 256) .. string.rep("\0", 7)
        .. u32le(x) .. u32le(y) .. u32le(x + w) .. u32le(y + h)
end

-- struct drm_rockchip_ebc_rect_hints (16 bytes) + the out-of-line rect
-- array it points at.  The pointer is patched in by the caller (ffi
-- address of the rect buffer); pack_rect_hints returns the 16-byte
-- struct with a zero pointer plus the rect blob separately, keeping
-- this module pure.
function M.pack_rect_hints_header(set_default, default_hint, num_rects)
    return string.char(set_default and 1 or 0, (default_hint or 0) % 256,
                       0, 0)
        .. u32le(num_rects)
        .. string.rep("\0", 8)   -- rect_hints pointer, caller patches
end

-- Phase-sequence program builder.  spec = {
--   do_init = bool, do_gc16 = bool, gc_target = 0..15,
--   temperature = nil | bin,  delay_ms = n,
--   elms = { { delay_ms=n, num_frames=n,
--              regions = { {x=,y=,w=,h=,phase=BYTE}, ... <=8 } }, ... <=96 }
-- }
-- The phase is a raw phase-buffer BYTE (4 pixels x 2 bits): 0x00 idle,
-- 0x55 all-darken, 0xAA all-lighten.  This is deliberately the driver's
-- own vocabulary -- the lab exists to speak it.
function M.pack_phase_sequence(spec)
    local elms = spec.elms or {}
    if #elms > M.PS_MAX_SEQS then
        return nil, "too many elements (max " .. M.PS_MAX_SEQS .. ")"
    end
    local parts = {}
    parts[#parts + 1] = string.char(
        #elms,
        spec.do_init and 1 or 0,
        spec.do_gc16 and 1 or 0,
        (spec.gc_target or 0) % 256,
        spec.temperature and 1 or 0,
        (spec.temperature or 0) % 256)
        .. string.rep("\0", 6)
        .. u32le(spec.delay_ms or 0)
    for i = 1, M.PS_MAX_SEQS do
        local e = elms[i]
        if not e then
            parts[#parts + 1] = string.rep("\0", M.PS_ELM_SIZE)
        else
            local regions = e.regions or {}
            if #regions > M.PS_MAX_REGIONS then
                return nil, "element " .. i .. ": too many regions"
            end
            local p = u32le(e.delay_ms or 0)
                .. string.char((e.num_frames or 1) % 256)
                .. string.rep("\0", 3)
                .. u32le(#regions)
            local rects, phases = {}, {}
            for r = 1, M.PS_MAX_REGIONS do
                local reg = regions[r]
                if reg then
                    rects[#rects + 1] = u32le(reg.x) .. u32le(reg.y)
                        .. u32le(reg.x + reg.w) .. u32le(reg.y + reg.h)
                    phases[#phases + 1] = string.char((reg.phase or 0) % 256)
                else
                    rects[#rects + 1] = string.rep("\0", 16)
                    phases[#phases + 1] = "\0"
                end
            end
            parts[#parts + 1] = p .. table.concat(rects)
                .. table.concat(phases)
        end
    end
    local blob = table.concat(parts)
    if #blob ~= M.PS_SIZE then
        return nil, "internal: packed " .. #blob .. " != " .. M.PS_SIZE
    end
    return blob
end

-- Resolve the EBC's DRM node by driver name, NEVER by index (the
-- 2026-08-25 D4 lesson: panfrost takes card0 on the direct image).
function M.find_ebc_card(sys_root)
    for n = 0, 7 do
        local f = io.open((sys_root or "/sys") .. "/class/drm/card" .. n
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

-- Framebuffer geometry from sysfs (the scribbler's RGB565 lesson:
-- never assume; the direct driver is 16 bpp where the shipping one was
-- 32).
function M.fb_geometry(sys_root)
    local function read1(name)
        local f = io.open((sys_root or "/sys") .. "/class/graphics/fb0/"
                          .. name, "r")
        if not f then return nil end
        local v = f:read("*l")
        f:close()
        return v
    end
    local size = read1("virtual_size")
    local stride = tonumber(read1("stride") or "")
    local bpp = tonumber(read1("bits_per_pixel") or "")
    if not (size and stride and bpp) then return nil end
    local w, h = size:match("^(%d+),(%d+)")
    if not w then return nil end
    return tonumber(w), tonumber(h), stride, math.floor(bpp / 8)
end

-- Sum of the per-CPU counts on the EBC's /proc/interrupts line, or nil
-- (the autosuspend daemon's proven parser; a GLOBAL costs 1 IRQ at
-- completion, a partial 1 per frame -- never compare the two units).
function M.ebc_irq_count(proc_root)
    local f = io.open((proc_root or "/proc") .. "/interrupts", "r")
    if not f then return nil end
    local sum
    for line in f:lines() do
        if line:find("fdec0000.ebc", 1, true) then
            sum = 0
            for tok in line:gmatch("%S+") do
                local n = tonumber(tok)
                if n then sum = sum + n end
            end
            break
        end
    end
    f:close()
    return sum
end

return M
