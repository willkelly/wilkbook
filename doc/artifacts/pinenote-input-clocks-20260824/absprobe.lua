local ffi = require("ffi")
ffi.cdef[[
int open(const char *pathname, int flags);
int ioctl(int fd, unsigned long request, ...);
int close(int fd);
struct input_absinfo { int value; int minimum; int maximum; int fuzz; int flat; int resolution; };
]]
local function EVIOCGABS(abs)  -- _IOR('E', 0x40+abs, struct input_absinfo /*24*/)
  return 0x80000000 + 24*0x10000 + 0x45*0x100 + (0x40 + abs)
end
local NAMES = {
  [0x00]="ABS_X",[0x01]="ABS_Y",[0x18]="ABS_PRESSURE",[0x19]="ABS_DISTANCE",
  [0x1a]="ABS_TILT_X",[0x1b]="ABS_TILT_Y",[0x28]="ABS_MISC",
  [0x2f]="ABS_MT_SLOT",[0x30]="ABS_MT_TOUCH_MAJOR",[0x31]="ABS_MT_TOUCH_MINOR",
  [0x35]="ABS_MT_POSITION_X",[0x36]="ABS_MT_POSITION_Y",
  [0x39]="ABS_MT_TRACKING_ID",[0x3a]="ABS_MT_PRESSURE",
}
local ORDER = {0x00,0x01,0x18,0x19,0x1a,0x1b,0x28,0x2f,0x30,0x31,0x35,0x36,0x39,0x3a}
for _, dev in ipairs(arg) do
  print("===== " .. dev .. " =====")
  local fd = ffi.C.open(dev, 0)   -- O_RDONLY
  if fd < 0 then print("  open failed"); goto continue end
  local ai = ffi.new("struct input_absinfo")
  for _, code in ipairs(ORDER) do
    if ffi.C.ioctl(fd, EVIOCGABS(code), ai) == 0 then
      if not (ai.minimum == 0 and ai.maximum == 0 and ai.value == 0 and ai.resolution == 0) then
        print(string.format("  %-22s min=%-8d max=%-8d fuzz=%-5d flat=%-5d res=%-5d value=%d",
          NAMES[code], ai.minimum, ai.maximum, ai.fuzz, ai.flat, ai.resolution, ai.value))
      end
    end
  end
  ffi.C.close(fd)
  ::continue::
end
