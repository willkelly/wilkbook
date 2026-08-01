-- Is the portrait 2x about ROTATION, or purely about how long the repaint
-- takes relative to the 50 ms deferred-io period?  Same contiguous access
-- order every time (no transpose at all); only the elapsed duration varies,
-- by spreading the identical full-screen write over a chosen wall-clock time.
--
-- 2026-07-31 correction: the original version labelled each row with the
-- NOMINAL spread (the sum of its sleeps) and did not time itself.  The
-- sleeps stack on top of ~29 ms of ffi.fill, so "40 ms" really spanned
-- ~64 ms -- which is why doc/refresh-policy.md's first table showed the
-- pass count doubling "at ~40 ms" when nothing between 29 and 64 ms had
-- been measured at all.  Every row now reports the MEASURED span, and the
-- sleep budget is pre-shrunk by the measured solid-fill cost so nominal
-- and real stay close.
local ffi=require("ffi")
ffi.cdef[[
int open(const char*,int,...); int close(int);
void* mmap(void*,unsigned long,int,int,int,long); int munmap(void*,unsigned long);
int usleep(unsigned int);
int clock_gettime(int,void*);
typedef struct { long tv_sec; long tv_nsec; } dur_ts;
]]
local CLOCK_MONOTONIC = 1
local W,H,STRIDE=1872,1404,7488
local LEN=STRIDE*H
local fd=ffi.C.open("/dev/fb0",2); assert(fd>=0)
local p=ffi.C.mmap(nil,LEN,3,1,fd,0); assert(p~=nil)
local fb=ffi.cast("uint8_t*",p)
-- monotonic: an NTP step mid-row must not corrupt a measured span
local ts=ffi.new("dur_ts")
local function now()
  ffi.C.clock_gettime(CLOCK_MONOTONIC,ts)
  return tonumber(ts.tv_sec)+tonumber(ts.tv_nsec)/1e9
end
local function irqs()
  local f=io.open("/proc/interrupts","r")
  for line in f:lines() do
    if line:find("fdec0000.ebc",1,true) then f:close()
      return tonumber(line:match("^%s*%d+:%s+(%d+)")) end
  end
  f:close()
end
local function settle()
  local last,stable=irqs(),0
  while stable<400 do ffi.C.usleep(50000)
    local n=irqs(); if n==last then stable=stable+50 else stable=0; last=n end end
end
-- write the whole screen contiguously, in `chunks` pieces; sleep only the
-- part of the budget the writes themselves don't consume.  Returns the
-- measured wall-clock span of the whole repaint.
local fill_ms=nil -- measured solid-fill cost, probed below
local function spread(v,chunks,total_ms)
  local rows=math.floor(H/chunks)
  local sleep_budget=math.max(0,total_ms-(fill_ms or 0))
  local per=math.floor(sleep_budget/math.max(1,chunks-1))
  local t0=now()
  for c=0,chunks-1 do
    local y0=c*rows
    local y1=(c==chunks-1) and H or (y0+rows)
    ffi.fill(fb+y0*STRIDE,(y1-y0)*STRIDE,v)
    if c<chunks-1 and per>0 then ffi.C.usleep(per*1000) end
  end
  return (now()-t0)*1000
end
print("fbdur: contiguous write, measured duration is the only variable\n")
-- probe the solid-fill cost first so the sleep budget can be corrected.
-- 0x20, not 0xd0: row 1 writes 0xd0, and diff_mode masks unchanged
-- pixels -- a 0xd0 probe fill would make the baseline row a zero-delta
-- no-op reporting 0 frames.
settle()
do
  local t0=now(); ffi.fill(fb,LEN,0x20); fill_ms=(now()-t0)*1000
end
settle()
print(string.format("  solid-fill cost: %.1f ms (subtracted from each sleep budget)\n",fill_ms))
print("  target      measured   frames   passes")
local vals={0,40,80,150,250,400}
for i,ms in ipairs(vals) do
  settle(); local a=irqs()
  local span=spread((i%2==0) and 0x20 or 0xd0, ms==0 and 1 or 8, ms)
  settle(); local n=irqs()-a
  print(string.format("  %5d ms   %7.1f ms   %5d   %5.1f", ms, span, n, n/38))
  io.stdout:flush()
end
print("\n  If passes track MEASURED duration with NO transpose involved,")
print("  rotation is merely a way of being slow -- the defect is repaint")
print("  time vs the deferred-io period (defio_delay_ms, default 50).")
ffi.C.munmap(p,LEN); ffi.C.close(fd)
