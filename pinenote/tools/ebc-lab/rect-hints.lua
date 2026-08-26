--[[--
Per-region hint control: the routing experiment's hand tool.

The hint byte's bit-depth field indexes the CLUT slot at drive time
((hint >> 4) & 3: 0=DU 1=DU4 2=GL16 3=GC16), so per-rect hints ARE
per-region waveform routing -- menus to the DU slot, turns to GL16 --
without touching the driver.  This tool speaks that mechanism directly
so the mapping can be felt on glass before KOReader learns it.

Usage: rect-hints.lua [--default N] [--rect X,Y,W,H:HINT]...
                      [--sys-root DIR] [--dev-root DIR]
Hints: depth (0=Y1/DU 16=Y2/DU4 32=Y4/GL16 48=GC16) + 64 dither
       + 128 redraw; e.g. 0 = fast mono ink, 32 = grayscale partial.
--]]

package.path = (arg[0] or ""):match("^(.*)/") and
    ((arg[0]):match("^(.*)/") .. "/?.lua;" .. package.path) or package.path
local lib = require("ebclib")
local ffi = require("ffi")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
int ioctl(int fd, unsigned long req, void *arg);
]]

local O_RDWR = 2

local opt = { default_hint = nil, rects = {}, sys_root = "/sys",
              dev_root = "/dev" }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--default" then i = i + 1; opt.default_hint = tonumber(arg[i])
        elseif a == "--rect" then
            i = i + 1
            local x, y, w, h, hint =
                arg[i]:match("^(%d+),(%d+),(%d+),(%d+):(%d+)$")
            if not x then
                io.stderr:write("bad --rect '" .. tostring(arg[i])
                    .. "' (want X,Y,W,H:HINT)\n")
                os.exit(2)
            end
            opt.rects[#opt.rects + 1] = { x = tonumber(x), y = tonumber(y),
                w = tonumber(w), h = tonumber(h), hint = tonumber(hint) }
        elseif a == "--sys-root" then i = i + 1; opt.sys_root = arg[i]
        elseif a == "--dev-root" then i = i + 1; opt.dev_root = arg[i]
        end
        i = i + 1
    end
end

if not opt.default_hint and #opt.rects == 0 then
    io.stderr:write("nothing to do: give --default and/or --rect\n")
    os.exit(2)
end

local card = lib.find_ebc_card(opt.sys_root)
if not card then
    io.stderr:write("no DRM card with DRIVER=rockchip-ebc\n")
    os.exit(1)
end
local fd = ffi.C.open(opt.dev_root .. "/dri/card" .. card, O_RDWR)
if fd < 0 then
    io.stderr:write("cannot open card" .. card .. " (root?)\n")
    os.exit(1)
end

local rect_blob = {}
for _, r in ipairs(opt.rects) do
    rect_blob[#rect_blob + 1] = lib.pack_rect_hint(r.hint, r.x, r.y, r.w, r.h)
end
local rects_s = table.concat(rect_blob)
local rects_buf = ffi.new("uint8_t[?]", #rects_s > 0 and #rects_s or 1)
if #rects_s > 0 then ffi.copy(rects_buf, rects_s, #rects_s) end

local header = lib.pack_rect_hints_header(opt.default_hint ~= nil,
                                          opt.default_hint or 0,
                                          #opt.rects)
local buf = ffi.new("uint8_t[16]")
ffi.copy(buf, header, 16)
-- patch the rect_hints pointer (u64 LE at offset 8)
ffi.cast("uint64_t *", buf + 8)[0] = ffi.cast("uint64_t",
    ffi.cast("uintptr_t", rects_buf))

local ret = ffi.C.ioctl(fd, lib.RECT_HINTS_IOCTL, buf)
ffi.C.close(fd)
if ret ~= 0 then
    io.stderr:write("RECT_HINTS ioctl failed (ret=" .. tostring(ret) .. ")\n")
    os.exit(1)
end
print(("hints applied: default=%s rects=%d")
    :format(tostring(opt.default_hint), #opt.rects))
