-- Damage probe over the production path: mmap + optional fsync publish.
--
-- usage: mmap-probe2.lua <fsync|timer> <row> [fill]
--   fill: "black" (0x00, the historical probe), "white" (0xff),
--         "checker" (alternating blocks), or a decimal byte value.
--
-- The fill matters: rockchip_ebc_plane_atomic_update() DROPS any damage
-- area whose blit reports no change, silently.  Every probe run before
-- 2026-08-02 wrote black, which is exactly the content a stale or zeroed
-- comparison baseline would swallow invisibly.  Always run at least one
-- distinctive fill before concluding "damage does not paint".
local ffi = require("ffi")
ffi.cdef[[
int open(const char*,int,...); int close(int); int fsync(int);
void* mmap(void*,unsigned long,int,int,int,long);
int usleep(unsigned int);
]]
local W, H, STRIDE = 1872, 1404, 7488
local LEN = STRIDE * H
local fd = ffi.C.open("/dev/fb0", 2); assert(fd >= 0, "open /dev/fb0 failed")
local p = ffi.C.mmap(nil, LEN, 3, 1, fd, 0); assert(p ~= nil, "mmap failed")
local fb = ffi.cast("uint8_t*", p)

local function irqs()
  local f = io.open("/proc/interrupts", "r")
  for line in f:lines() do
    if line:find("fdec0000.ebc", 1, true) then
      f:close(); return tonumber(line:match("^%s*%d+:%s+(%d+)"))
    end
  end
  f:close(); return -1
end

local mode = arg[1] or "fsync"
local row  = tonumber(arg[2] or 400)
local fill = arg[3] or "black"
local plain = tonumber(fill)

-- Self-check: capture the region before writing.  A probe that reports
-- "no frames" is ambiguous unless we also know the framebuffer actually
-- changed -- writing a value that already matches the underlying content
-- is a genuine no-op, and the driver correctly drops it.  That ambiguity
-- is exactly what produced the phantom "post-resume dead-write window"
-- of 2026-08-01/02: every probe wrote black onto a black console
-- background.  Never report a zero without this line.
local before = {}
for y = row, row + 119 do
  local base = y * STRIDE
  local acc = 0
  for x = 0, STRIDE - 1, 97 do acc = (acc * 31 + fb[base + x]) % 4294967296 end
  before[y] = acc
end

local b = irqs()
for y = row, row + 119 do
  local base = y * STRIDE
  if fill == "checker" then
    for x = 0, STRIDE - 1 do
      local on = ((math.floor(x / 64) + math.floor(y / 16)) % 2) == 0
      fb[base + x] = on and 0x00 or 0xff
    end
  else
    local v = 0x00
    if fill == "white" then v = 0xff
    elseif plain then v = plain end
    for x = 0, STRIDE - 1 do fb[base + x] = v end
  end
end
if mode == "fsync" then ffi.C.fsync(fd) end
ffi.C.usleep(3000000)
local a = irqs()
local changed = 0
for y = row, row + 119 do
  local base = y * STRIDE
  local acc = 0
  for x = 0, STRIDE - 1, 97 do acc = (acc * 31 + fb[base + x]) % 4294967296 end
  if acc ~= before[y] then changed = changed + 1 end
end
print(string.format("mmap-%s row=%d fill=%s: irq %d -> %d (delta %d) fb-rows-changed=%d/120%s",
                    mode, row, fill, b, a, a - b, changed,
                    (changed == 0) and "  [NO-OP WRITE -- a zero delta here means nothing]" or ""))
