-- Small-band A/B: a write far shorter than the 50 ms timer window is
-- where publish-on-call's latency win must appear (the pen-stroke case).
local ffi=require("ffi")
ffi.cdef[[
int open(const char*,int,...); int close(int); int fsync(int);
void* mmap(void*,unsigned long,int,int,int,long); int munmap(void*,unsigned long);
int usleep(unsigned int); int clock_gettime(int,void*);
typedef struct { long tv_sec; long tv_nsec; } fb_ts;
]]
local W,H,STRIDE=1872,1404,7488
local LEN=STRIDE*H
local fd=ffi.C.open("/dev/fb0",2); assert(fd>=0)
local p=ffi.C.mmap(nil,LEN,3,1,fd,0); assert(p~=nil)
local fb=ffi.cast("uint8_t*",p)
local ts=ffi.new("fb_ts")
local function now() ffi.C.clock_gettime(1,ts) return tonumber(ts.tv_sec)+tonumber(ts.tv_nsec)/1e9 end
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
local function first_irq_after(base,t0)
  while true do
    local t=now()
    if t-t0>3 then return nil end
    if irqs()>base then return t-t0 end
    ffi.C.usleep(1000)
  end
end
-- 100-row band at y=600, alternating value; ~0.75 MB, ~1 ms to write
local cur=0x20
local function band(v) ffi.fill(fb+600*STRIDE,100*STRIDE,v) end
band(cur); ffi.C.fsync(fd); settle()
print("band write (100 rows) -> first IRQ:")
for rep=1,4 do
  cur=(cur==0x20) and 0xd0 or 0x20
  local a=irqs(); band(cur); local t0=now()
  local lt=first_irq_after(a,t0); settle()
  cur=(cur==0x20) and 0xd0 or 0x20
  local a2=irqs(); band(cur); local t1=now()
  ffi.C.fsync(fd)
  local lf=first_irq_after(a2,t1); settle()
  print(string.format("  timer %7.1f ms   fsync %7.1f ms",(lt or -1)*1000,(lf or -1)*1000))
end
ffi.C.munmap(p,LEN); ffi.C.close(fd)
