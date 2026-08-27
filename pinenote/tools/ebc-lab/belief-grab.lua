--[[--
belief-grab.lua: dump the direct driver's per-pixel belief via
EXTRACT_FBS -- packed (inner, outer, next<<4|prev) tuples, the hints
buffer, and the prelim/target buffer -- to files for the
intent-vs-belief-vs-glass three-way join (the DDR-era strategy,
revived on the direct driver 2026-08-27; doc/status.md part 15).
The 2026-08-27 verdict from its first run: in settled ghost regions
the belief is exactly right (next=white, prev=black, idle, complete)
-- the residue is ANALOG, not bookkeeping.

Usage: belief-grab.lua [--out-prefix PATH] [--sys-root DIR]
                       [--dev-root DIR]
Writes PREFIX-packed.bin (3 B/px), PREFIX-hints.bin, PREFIX-prelim.bin.
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

local opt = { prefix = "/root/belief", sys_root = "/sys", dev_root = "/dev" }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--out-prefix" then i = i + 1; opt.prefix = arg[i]
        elseif a == "--sys-root" then i = i + 1; opt.sys_root = arg[i]
        elseif a == "--dev-root" then i = i + 1; opt.dev_root = arg[i]
        end
        i = i + 1
    end
end

local w, h = lib.fb_geometry(opt.sys_root)
local N = (w or 1872) * (h or 1404)

local packed = ffi.new("uint8_t[?]", 3 * N)
local hints  = ffi.new("uint8_t[?]", N)
local prelim = ffi.new("uint8_t[?]", N)
local args = ffi.new("uint64_t[5]")
args[0] = ffi.cast("uint64_t", ffi.cast("uintptr_t", packed))
args[1] = ffi.cast("uint64_t", ffi.cast("uintptr_t", hints))
args[2] = ffi.cast("uint64_t", ffi.cast("uintptr_t", prelim))
args[3] = 0
args[4] = 0

local card = lib.find_ebc_card(opt.sys_root)
if not card then io.stderr:write("no EBC card\n"); os.exit(1) end
local fd = ffi.C.open(opt.dev_root .. "/dri/card" .. card, 2)
if fd < 0 then io.stderr:write("cannot open card (root?)\n"); os.exit(1) end
local r = ffi.C.ioctl(fd, lib.EXTRACT_FBS_IOCTL, args)
ffi.C.close(fd)
if r ~= 0 then
    io.stderr:write("EXTRACT_FBS failed (" .. tostring(r) .. ")\n")
    os.exit(1)
end

local function dump(suffix, buf, len)
    local f = io.open(opt.prefix .. suffix, "wb")
    f:write(ffi.string(buf, len))
    f:close()
end
dump("-packed.bin", packed, 3 * N)
dump("-hints.bin", hints, N)
dump("-prelim.bin", prelim, N)
print(("belief dumped: %s-{packed,hints,prelim}.bin (%d px)")
    :format(opt.prefix, N))
