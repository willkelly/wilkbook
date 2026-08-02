-- Minimal damage probe over the production path: mmap + fsync publish.
-- Prints IRQ delta for (a) mmap write + fsync, (b) mmap write + timer only.
local ffi=require("ffi")
ffi.cdef[[
int open(const char*,int,...); int close(int); int fsync(int);
void* mmap(void*,unsigned long,int,int,int,long);
int usleep(unsigned int);
]]
local W,H,STRIDE=1872,1404,7488
local LEN=STRIDE*H
local fd=ffi.C.open("/dev/fb0",2); assert(fd>=0,"open /dev/fb0 failed")
local p=ffi.C.mmap(nil,LEN,3,1,fd,0); assert(p~=nil,"mmap failed")
local fb=ffi.cast("uint8_t*",p)
local function irqs()
  local f=io.open("/proc/interrupts","r")
  for line in f:lines() do
    if line:find("fdec0000.ebc",1,true) then f:close()
      return tonumber(line:match("^%s*%d+:%s+(%d+)")) end
  end
  f:close(); return -1
end
local function band(row,n,val)
  for y=row,row+n-1 do
    local base=y*STRIDE
    for x=0,STRIDE-1 do fb[base+x]=val end
  end
end
local mode=arg[1] or "fsync"
local row=tonumber(arg[2] or 400)
local b=irqs()
band(row,120,0x00)
if mode=="fsync" then ffi.C.fsync(fd) end
ffi.C.usleep(3000000)
local a=irqs()
print(string.format("mmap-%s row=%d: irq %d -> %d (delta %d)",mode,row,b,a,a-b))
