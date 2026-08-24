local ffi = require("ffi")
ffi.cdef[[
int open(const char *pathname, int flags);
long read(int fd, void *buf, unsigned long count);
int close(int fd);
int poll(void *fds, unsigned long nfds, int timeout);
char *strerror(int errnum);
struct pollfd { int fd; short events; short revents; };
struct input_event { long tv_sec; long tv_usec; unsigned short type; unsigned short code; int value; };
]]
local EV_KEY, EV_ABS = 0x01, 0x03
local ABS_MT_SLOT, ABS_MT_TRACKING_ID = 0x2f, 0x39
local ABS_PRESSURE, ABS_DISTANCE, ABS_TILT_X, ABS_TILT_Y = 0x18, 0x19, 0x1a, 0x1b
local KEYNAME = {[320]="BTN_TOOL_PEN",[321]="BTN_TOOL_RUBBER",[330]="BTN_TOUCH",
                 [331]="BTN_STYLUS",[332]="BTN_STYLUS2",[325]="BTN_TOOL_FINGER"}
local secs = tonumber(arg[1]) or 30
local paths = {}
for i = 2, #arg do paths[#paths+1] = arg[i] end
local n = #paths
local fds = ffi.new("struct pollfd[?]", n)
for i = 1, n do
  local fd = ffi.C.open(paths[i], 2048)  -- O_RDONLY|O_NONBLOCK
  fds[i-1].fd, fds[i-1].events = fd, 1
  print(string.format("open %-22s -> fd=%d %s", paths[i], fd,
        fd < 0 and ("ERRNO: " .. ffi.string(ffi.C.strerror(ffi.errno()))) or "OK"))
end
io.flush()
local slot, active, slots_seen, maxsim = 0, {}, {}, 0
local pmin,pmax,tmin,tmax,dmin,dmax
local keys, nev, per = {}, 0, {}
local ev = ffi.new("struct input_event[64]")
local SZ = ffi.sizeof("struct input_event")
local t0, tick = os.time(), os.time()
local function count() local c=0 for _ in pairs(active) do c=c+1 end return c end
local function span(lo,hi,v) if not lo or v<lo then lo=v end if not hi or v>hi then hi=v end return lo,hi end
print("observing for " .. secs .. "s -- TOUCH THE SCREEN NOW"); io.flush()
while os.time() - t0 < secs do
  if ffi.C.poll(fds, n, 200) > 0 then
    for i = 0, n-1 do
      if fds[i].revents ~= 0 then
        local r = ffi.C.read(fds[i].fd, ev, SZ*64)
        if r and tonumber(r) > 0 then
          per[i] = (per[i] or 0) + 1
          for k = 0, math.floor(tonumber(r)/SZ)-1 do
            local e = ev[k]; nev = nev + 1
            if i == 0 then
              if e.type==EV_ABS and e.code==ABS_MT_SLOT then slot=e.value; slots_seen[slot]=true
              elseif e.type==EV_ABS and e.code==ABS_MT_TRACKING_ID then
                slots_seen[slot]=true
                if e.value==-1 then active[slot]=nil else active[slot]=e.value end
                local c=count()
                if c>maxsim then maxsim=c; print("  ** simultaneous contacts: "..c.." (slot "..slot..")"); io.flush() end
              end
            else
              if e.type==EV_ABS then
                if e.code==ABS_PRESSURE then pmin,pmax=span(pmin,pmax,e.value)
                elseif e.code==ABS_DISTANCE then dmin,dmax=span(dmin,dmax,e.value)
                elseif e.code==ABS_TILT_X or e.code==ABS_TILT_Y then tmin,tmax=span(tmin,tmax,e.value) end
              end
            end
            if e.type==EV_KEY and KEYNAME[e.code] then keys[KEYNAME[e.code]]=(keys[KEYNAME[e.code]] or 0)+1 end
          end
        end
      end
    end
  end
  if os.time() - tick >= 10 then tick = os.time()
    print(string.format("  [t+%ds] events=%d maxsim=%d pressure=%s",
      os.time()-t0, nev, maxsim, pmax and (pmin..".."..pmax) or "none")); io.flush() end
end
local ns, lst = 0, {}
for s in pairs(slots_seen) do ns=ns+1; lst[#lst+1]=s end
table.sort(lst)
print("\n===== RESULT =====")
print(string.format("raw events observed        : %d   (reads per device: %s)", nev,
  (function() local t={} for i=0,n-1 do t[#t+1]=paths[i+1]..":"..(per[i] or 0) end return table.concat(t," ") end)()))
print(string.format("MAX SIMULTANEOUS CONTACTS  : %d", maxsim))
print(string.format("distinct MT slots used     : %d -> {%s}", ns, table.concat(lst, ",")))
print(string.format("stylus ABS_PRESSURE emitted: %s", pmax and (pmin..".."..pmax) or "NONE"))
print(string.format("stylus ABS_TILT emitted    : %s", tmax and (tmin..".."..tmax) or "NONE"))
print(string.format("stylus ABS_DISTANCE emitted: %s", dmax and (dmin..".."..dmax) or "NONE"))
io.write("buttons seen               : ")
local any=false; for k,v in pairs(keys) do io.write(k,"=",v,"  "); any=true end
print(any and "" or "(none)")
