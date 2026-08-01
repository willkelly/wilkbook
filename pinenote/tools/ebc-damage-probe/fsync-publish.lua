-- fsync-publish: validate publish-on-call's kernel half on the CURRENT
-- kernel (vanilla fb_deferred_io_fsync; defio_delay_ms not yet deployed).
-- Run with reader-session stopped, fbcon unbound, EBC idle.
--
--  1. no-op cost: nothing dirty -> fsync(fb_fd) duration
--  2. publish latency: full write then fsync -> write-end to first EBC
--     IRQ, versus the pure timer path
--  3. non-blocking: fsync issued while a 596 ms pass is active must
--     return in ms, not wait out the pass
--  4. accounting: write+fsync still costs exactly one pass (~38 frames)
local ffi=require("ffi")
ffi.cdef[[
int open(const char*,int,...); int close(int); int fsync(int);
void* mmap(void*,unsigned long,int,int,int,long); int munmap(void*,unsigned long);
int usleep(unsigned int);
int clock_gettime(int,void*);
typedef struct { long tv_sec; long tv_nsec; } fp_ts;
]]
local CLOCK_MONOTONIC=1
local W,H,STRIDE=1872,1404,7488
local LEN=STRIDE*H
local fd=ffi.C.open("/dev/fb0",2); assert(fd>=0,"open /dev/fb0")
local p=ffi.C.mmap(nil,LEN,3,1,fd,0); assert(p~=nil,"mmap")
local fb=ffi.cast("uint8_t*",p)
local ts=ffi.new("fp_ts")
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
-- wait (poll ~1ms) until the IRQ count exceeds base; return latency s
local function first_irq_after(base,t0,limit_s)
  limit_s=limit_s or 3
  while true do
    local t=now()
    if t-t0>limit_s then return nil end
    if irqs()>base then return t-t0 end
    ffi.C.usleep(1000)
  end
end

print("fsync-publish: kernel-half validation of publish-on-call\n")

-- 1. no-op fsync cost (5 reps)
settle()
io.write("  [1] no-op fsync:")
for i=1,5 do
  local t0=now(); ffi.C.fsync(fd); io.write(string.format(" %.2fms",(now()-t0)*1000))
end
print("")

-- 2. publish latency, alternating values, 3 pairs
print("  [2] write-end -> first IRQ latency (full-screen write):")
-- every write must flip against CURRENT content or diff_mode masks it
local cur=0x20
local function flip() cur=(cur==0x20) and 0xd0 or 0x20; return cur end
ffi.fill(fb,LEN,cur); ffi.C.fsync(fd); settle()  -- known starting state
for rep=1,3 do
  -- timer path
  local a=irqs()
  ffi.fill(fb,LEN,flip())
  local t0=now()
  local lt=first_irq_after(a,t0)
  settle()
  -- fsync path
  local a2=irqs()
  ffi.fill(fb,LEN,flip())
  local t1=now()
  local tf0=now(); ffi.C.fsync(fd); local fdur=(now()-tf0)*1000
  local lf=first_irq_after(a2,t1)
  settle()
  print(string.format("      timer %7.1f ms   fsync %7.1f ms (fsync call %.2f ms)",
    (lt or -1)*1000,(lf or -1)*1000,fdur))
end

-- 3. fsync during an active pass must not block
settle()
do
  ffi.fill(fb,LEN,0x20)
  ffi.C.fsync(fd)          -- starts a pass (~596 ms of drive)
  ffi.C.usleep(100*1000)   -- pass active
  ffi.fill(fb,LEN,0xd0)
  local t0=now(); ffi.C.fsync(fd); local d=(now()-t0)*1000
  print(string.format("  [3] fsync during active pass: %.2f ms (must be ms-scale, not ~500)",d))
  settle()
end

-- 4. pass accounting: write+fsync = one pass
settle()
do
  local a=irqs()
  ffi.fill(fb,LEN,0x20)
  ffi.C.fsync(fd)
  settle()
  local n=irqs()-a
  print(string.format("  [4] write+fsync frames: %d (~38 = one pass)",n))
end

ffi.C.munmap(p,LEN); ffi.C.close(fd)
print("\ndone")
