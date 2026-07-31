-- Is the portrait 2x about ROTATION, or purely about how long the repaint
-- takes relative to the 50 ms deferred-io period?  Same contiguous access
-- order every time (no transpose at all); only the elapsed duration varies,
-- by spreading the identical full-screen write over a chosen wall-clock time.
local ffi=require("ffi")
ffi.cdef[[
int open(const char*,int,...); int close(int);
void* mmap(void*,unsigned long,int,int,int,long); int munmap(void*,unsigned long);
int usleep(unsigned int);
]]
local W,H,STRIDE=1872,1404,7488
local LEN=STRIDE*H
local fd=ffi.C.open("/dev/fb0",2); assert(fd>=0)
local p=ffi.C.mmap(nil,LEN,3,1,fd,0); assert(p~=nil)
local fb=ffi.cast("uint8_t*",p)
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
-- write the whole screen contiguously, in `chunks` pieces, spread over `total_ms`
local function spread(v,chunks,total_ms)
  local rows=math.floor(H/chunks)
  local per=math.floor(total_ms/chunks)
  for c=0,chunks-1 do
    local y0=c*rows
    local y1=(c==chunks-1) and H or (y0+rows)
    ffi.fill(fb+y0*STRIDE,(y1-y0)*STRIDE,v)
    if c<chunks-1 then ffi.C.usleep(per*1000) end
  end
end
print("fbdur: contiguous write, duration is the only variable\n")
print("  spread over    frames   passes")
local vals={0,40,80,150,250,400}
for i,ms in ipairs(vals) do
  settle(); local a=irqs()
  spread((i%2==0) and 0x20 or 0xd0, ms==0 and 1 or 8, ms)
  settle(); local n=irqs()-a
  print(string.format("  %5d ms      %5d   %5.1f", ms, n, n/38))
  io.stdout:flush()
end
print("\n  If passes track duration with NO transpose involved, rotation is")
print("  merely a way of being slow -- the defect is repaint time vs the")
print("  50 ms deferred-io period.")
ffi.C.munmap(p,LEN); ffi.C.close(fd)
