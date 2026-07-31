-- fbprobe: controlled deferred-io / EBC damage-scheduling probe.
--
-- Writes specific patterns straight into the mmapped framebuffer and counts
-- EBC interrupts (one DSP_END per hardware frame) for each.  No KOReader, no
-- rotation, no input -- so the only variable is the shape and timing of the
-- damage.  Run with reader-session stopped and fbcon unbound.
--
-- diff_mode=1 masks pixels whose prev==next, so every pattern must actually
-- CHANGE the pixels it touches or the driver correctly does nothing.

local ffi = require("ffi")
ffi.cdef [[
int open(const char*, int, ...);
int close(int);
void* mmap(void*, unsigned long, int, int, int, long);
int munmap(void*, unsigned long);
int usleep(unsigned int);
]]

local W, H, STRIDE = 1872, 1404, 7488
local LEN = STRIDE * H
local fd = ffi.C.open("/dev/fb0", 2)          -- O_RDWR
assert(fd >= 0, "open /dev/fb0 failed")
local p = ffi.C.mmap(nil, LEN, 3, 1, fd, 0)   -- PROT_READ|WRITE, MAP_SHARED
assert(p ~= nil, "mmap failed")
local fb = ffi.cast("uint8_t*", p)

local function irqs()
  local f = io.open("/proc/interrupts", "r")
  for line in f:lines() do
    if line:find("fdec0000.ebc", 1, true) then
      f:close()
      return tonumber(line:match("^%s*%d+:%s+(%d+)"))
    end
  end
  f:close(); return nil
end

local function ms(n) ffi.C.usleep(n * 1000) end

-- fill rows [y0,y1) with a byte value; contiguous in memory
local function fill_rows(y0, y1, v)
  ffi.fill(fb + y0 * STRIDE, (y1 - y0) * STRIDE, v)
end

-- touch one byte in EVERY row within a column range: the page-dirtying
-- signature of a rotated write, without doing a real rotation
local function stride_touch(x, v)
  for y = 0, H - 1 do fb[y * STRIDE + x * 4] = v end
end

-- settle: wait until the EBC has been quiet for `quiet` ms
local function settle(quiet)
  quiet = quiet or 400
  local last, stable = irqs(), 0
  while stable < quiet do
    ms(50)
    local now = irqs()
    if now == last then stable = stable + 50 else stable = 0; last = now end
  end
  return last
end

local results = {}
local function probe(name, expect, fn)
  settle()
  local a = irqs()
  fn()
  settle()
  local b = irqs()
  local n = b - a
  results[#results + 1] = { name = name, n = n, expect = expect }
  print(string.format("  %-46s %5d frames   (%s)", name, n, expect))
  io.stdout:flush()
end

print("fbprobe: EBC damage-scheduling probe")
print(string.format("  fb %dx%d stride %d  len %d", W, H, STRIDE, LEN))
local base = settle()
print(string.format("  idle baseline IRQ=%d", base))
print("")

-- alternate fill values so every pattern genuinely changes pixels
local A, B = 0x00, 0xff

probe("1 full-screen write", "one area -> ~1 pass", function()
  fill_rows(0, H, A)
end)

probe("2 full-screen writes, 250ms apart", "OVERLAP -> expect ~2 passes", function()
  fill_rows(0, H, B); ms(250); fill_rows(0, H, A)
end)

probe("2 DISJOINT half writes, 250ms apart", "no overlap -> expect < 2 passes", function()
  fill_rows(0, H / 2, B); ms(250); fill_rows(H / 2, H, B)
end)

probe("2 full-screen writes, 10ms apart", "coalesce -> expect ~1 pass", function()
  fill_rows(0, H, A); ms(10); fill_rows(0, H, B)
end)

probe("strided touch (all pages), then full write", "rotation signature", function()
  stride_touch(0, A); ms(250); fill_rows(0, H, A)
end)

probe("3 full-screen writes, 250ms apart", "expect ~3 passes", function()
  fill_rows(0, H, B); ms(250); fill_rows(0, H, A); ms(250); fill_rows(0, H, B)
end)

print("")
print("summary:")
for _, r in ipairs(results) do
  print(string.format("  %-46s %5d", r.name, r.n))
end

ffi.C.munmap(p, LEN)
ffi.C.close(fd)
