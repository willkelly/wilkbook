-- fbtime: how long does a full-screen framebuffer write take, contiguous
-- (landscape order) vs strided (the rotated-view order KOReader uses in
-- portrait)?  The deferred-io flush period is 50 ms (drm_fbdev_shmem.c:184,
-- fbdefio.delay = HZ/20), and fbprobe showed that each flush costs one whole
-- refresh pass.  So the question that decides the portrait 2x is simply
-- whether a repaint's writes fit inside 50 ms.
--
-- Same byte count in every case; only the access order differs.

local ffi = require("ffi")
ffi.cdef [[
int open(const char*, int, ...);
int close(int);
void* mmap(void*, unsigned long, int, int, int, long);
int munmap(void*, unsigned long);
int usleep(unsigned int);
int gettimeofday(void*, void*);
typedef struct { long tv_sec; long tv_usec; } probe_tv;
]]

local W, H, STRIDE = 1872, 1404, 7488
local LEN = STRIDE * H
local fd = ffi.C.open("/dev/fb0", 2)
assert(fd >= 0, "open /dev/fb0")
local p = ffi.C.mmap(nil, LEN, 3, 1, fd, 0)
assert(p ~= nil, "mmap")
local fb = ffi.cast("uint8_t*", p)
local u32 = ffi.cast("uint32_t*", p)

local tv = ffi.new("probe_tv")
local function now()
  ffi.C.gettimeofday(tv, nil)
  return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
end

local function timeit(name, reps, fn)
  local best = math.huge
  local vals = {}
  for i = 1, reps do
    local v = (i % 2 == 0) and 0x20 or 0xd0
    local t0 = now(); fn(v); local dt = (now() - t0) * 1000
    vals[#vals + 1] = dt
    if dt < best then best = dt end
    ffi.C.usleep(900 * 1000)   -- let the EBC finish between reps
  end
  table.sort(vals)
  local med = vals[math.ceil(#vals / 2)]
  print(string.format("  %-44s med %7.1f ms   min %7.1f ms   %s",
    name, med, best, med > 50 and "  >50ms  ==> TWO flushes" or "  <50ms  ==> one flush"))
  io.stdout:flush()
  return med
end

print("fbtime: full-screen write cost by access order")
print(string.format("  %d bytes per pass, defio period 50 ms\n", LEN))

-- (a) contiguous: what a landscape repaint's memory traffic looks like
local c = timeit("contiguous fill (landscape order)", 5, function(v)
  ffi.fill(fb, LEN, v)
end)

-- (b) row-by-row contiguous, same order, per-row calls
local r = timeit("row-by-row fill (still contiguous)", 5, function(v)
  for y = 0, H - 1 do ffi.fill(fb + y * STRIDE, W * 4, v) end
end)

-- (c) strided/transposed: walk COLUMNS, touching every row per column.
-- This is the access order a rotated blitbuffer view produces.
local s = timeit("column-order write (portrait/rotated order)", 3, function(v)
  local word = v * 0x01010101ULL
  for x = 0, W - 1 do
    local col = x
    for y = 0, H - 1 do u32[y * (STRIDE / 4) + col] = word end
  end
end)

print("")
print(string.format("  strided / contiguous  = %.1fx", s / c))
print("")
print("  A repaint must fit inside one 50 ms deferred-io period to cost a")
print("  single refresh pass.  Anything slower is flushed mid-write and pays")
print("  a second full pass (fbprobe: each flush = one pass, no pipelining).")

ffi.C.munmap(p, LEN)
ffi.C.close(fd)
