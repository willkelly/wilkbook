-- Measure the page-dirtying window exactly as deferred-io sees it: defio
-- write-protects the framebuffer pages after each flush, so every first touch
-- of a page by KOReader is a MINOR PAGE FAULT.  Sampling min_flt on KOReader's
-- own process at high rate gives the wall-clock span over which it dirties the
-- framebuffer -- the quantity that decides whether a repaint fits inside the
-- 50 ms deferred-io period.  Value-sampling the framebuffer cannot do this:
-- most of a page is white-on-white, written but unchanged.
local ffi=require("ffi")
ffi.cdef[[ int usleep(unsigned int); int gettimeofday(void*,void*);
typedef struct { long tv_sec; long tv_usec; } probe_tv; ]]
local tv=ffi.new("probe_tv")
local function now() ffi.C.gettimeofday(tv,nil); return tonumber(tv.tv_sec)+tonumber(tv.tv_usec)/1e6 end
local pid=nil
pid = arg and arg[1]
assert(pid and #pid>0,"pass the reader.lua pid as argv[1]")
local statpath="/proc/"..pid.."/stat"
local function minflt()
  local f=io.open(statpath,"r"); if not f then return nil end
  local l=f:read("*l"); f:close()
  -- field 10 after the (comm) field
  local rest=l:match("%)%s+(.*)")
  local i=0
  for tok in rest:gmatch("%S+") do i=i+1; if i==8 then return tonumber(tok) end end
end
local function irqs()
  local f=io.open("/proc/interrupts","r")
  for line in f:lines() do
    if line:find("fdec0000.ebc",1,true) then f:close()
      return tonumber(line:match("^%s*%d+:%s+(%d+)")) end end
  f:close()
end
print("faults: framebuffer page-dirtying window, KOReader pid "..pid)
print("  (defio period 50 ms; a full-screen repaint dirties ~2566 pages)\n")
for n=1,6 do
  -- settle
  local last,stable=irqs(),0
  while stable<500 do ffi.C.usleep(50000)
    local x=irqs(); if x==last then stable=stable+50 else stable=0; last=x end end
  local f0,i0=minflt(),irqs()
  local f=io.open("/run/optics-inject.fifo","w"); f:write("KEY 159\n"); f:close()
  local t0=now()
  local firstt,lastt,prev=nil,nil,f0
  local deadline=t0+3.0
  while now()<deadline do
    local m=minflt()
    if m and m>prev then
      local t=now()
      if not firstt then firstt=t end
      lastt=t; prev=m
    end
    ffi.C.usleep(1000)
  end
  ffi.C.usleep(2000000)
  local total,frames=minflt()-f0,irqs()-i0
  if firstt then
    print(string.format("  turn %d: %5d faults over %6.1f ms   (first at +%5.1f ms)   %3d frames %.1f passes",
      n,total,(lastt-firstt)*1000,(firstt-t0)*1000,frames,frames/38))
  else
    print(string.format("  turn %d: no faults observed (%d frames)",n,frames))
  end
  io.stdout:flush()
end
