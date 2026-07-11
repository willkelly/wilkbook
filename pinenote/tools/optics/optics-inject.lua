--[[--
optics-inject.lua -- persistent uinput page-turn injector for the optics
harness (PLAN task 1, OL3/KR2).

Runs ON THE DEVICE under the koreader bundle's own luajit (it ships ffi;
same style as reader-session.scm's %panel-blank-lua).  driver.py's
KOReaderBackend pushes this file, creates the FIFO, and starts it
(setsid, backgrounded) BEFORE relaunching KOReader, because KOReader
enumerates input devices exactly once, at init: the uinput device must
already exist at that moment and must persist afterwards -- so this is a
daemon that holds the uinput fd for its whole lifetime, not a one-shot
create/emit/exit helper (the device would vanish the instant the fd
closed).

What it creates: a keyboard device named exactly "wilkbook-optics"
(device.lua's findInputDevices whitelists that name and opens it) with
EV_KEY capabilities KEY_BACK=158, KEY_FORWARD=159, KEY_MENU=139 -- the
same 158/159 codes the ws8100 pen buttons feed into device.lua's
event_map (RPgBack/RPgFwd); 139 is declared now so the future UI-action
path (PLAN task 20) needs no device re-create.  EV_SYN is declared
explicitly (the input core would add it anyway).

Protocol, one line per command on the FIFO /run/optics-inject.fifo:
    KEY <code>   emit press + SYN_REPORT + release + SYN_REPORT
    QUIT         destroy the uinput device and exit
Anything else is logged and ignored.  The pid file
/run/optics-inject.pid is written only AFTER UI_DEV_CREATE succeeds, so
it doubles as the readiness marker driver.py's hard check waits on.
--]]

local ffi = require("ffi")

ffi.cdef[[
int open(const char *pathname, int flags);
long write(int fd, const void *buf, unsigned long count);
int close(int fd);
int ioctl(int fd, unsigned long request, ...);
int poll(void *fds, unsigned long nfds, int timeout);
int mkfifo(const char *pathname, unsigned int mode);
int getpid(void);

struct input_id {
    unsigned short bustype;
    unsigned short vendor;
    unsigned short product;
    unsigned short version;
};
/* include/uapi/linux/uinput.h: name[80] + input_id + ff_effects_max +
   4 x int[64] abs tables = 1116 bytes; the legacy write()+UI_DEV_CREATE
   setup path, stable across every kernel we run. */
struct uinput_user_dev {
    char name[80];
    struct input_id id;
    unsigned int ff_effects_max;
    int absmax[64];
    int absmin[64];
    int absfuzz[64];
    int absflat[64];
};
/* 64-bit struct input_event: struct timeval flattened to two longs. */
struct input_event {
    long tv_sec;
    long tv_usec;
    unsigned short type;
    unsigned short code;
    int value;
};
]]

local C = ffi.C

-- Stable kernel ABI constants (asm-generic; identical on aarch64/x86_64).
local O_WRONLY       = 1
local EV_SYN, EV_KEY = 0, 1
local SYN_REPORT     = 0
local KEY_MENU       = 139
local KEY_BACK       = 158
local KEY_FORWARD    = 159
local BUS_VIRTUAL    = 0x06
local UI_SET_EVBIT   = 0x40045564  -- _IOW('U', 100, int)
local UI_SET_KEYBIT  = 0x40045565  -- _IOW('U', 101, int)
local UI_DEV_CREATE  = 0x00005501  -- _IO('U', 1)
local UI_DEV_DESTROY = 0x00005502  -- _IO('U', 2)

local DEVICE_NAME = "wilkbook-optics"
-- Paths overridable via argv for the HOST harness only (it runs the
-- daemon against the workstation's /dev/uinput with a scratch FIFO);
-- driver.py starts the daemon with no arguments -> the /run defaults.
local FIFO        = arg and arg[1] or "/run/optics-inject.fifo"
local PIDFILE     = arg and arg[2] or "/run/optics-inject.pid"

local KEYBITS = { [KEY_MENU] = true, [KEY_BACK] = true, [KEY_FORWARD] = true }

io.stdout:setvbuf("line")

local function die(msg)
    io.stderr:write("optics-inject: " .. msg .. "\n")
    os.exit(1)
end

-- driver.py mkfifos first; this covers manual/standalone runs (EEXIST is
-- fine and mkfifo's failure surfaces at io.open below anyway).
C.mkfifo(FIFO, 438)  -- 0666

local fd = C.open("/dev/uinput", O_WRONLY)
if fd < 0 then die("cannot open /dev/uinput") end

-- LuaJIT promotes plain Lua numbers to double through `...`; the int
-- casts keep the varargs ABI-correct for ioctl's int argument.
if C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_SYN)) ~= 0 then
    die("UI_SET_EVBIT EV_SYN failed")
end
if C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_KEY)) ~= 0 then
    die("UI_SET_EVBIT EV_KEY failed")
end
for code in pairs(KEYBITS) do
    if C.ioctl(fd, UI_SET_KEYBIT, ffi.cast("int", code)) ~= 0 then
        die("UI_SET_KEYBIT " .. code .. " failed")
    end
end

local dev = ffi.new("struct uinput_user_dev")
ffi.copy(dev.name, DEVICE_NAME)
dev.id.bustype = BUS_VIRTUAL
dev.id.vendor  = 0x1209   -- pid.codes open-source VID; identity only
dev.id.product = 0x0001
dev.id.version = 1
if C.write(fd, dev, ffi.sizeof(dev)) ~= ffi.sizeof(dev) then
    die("uinput_user_dev setup write failed")
end
if C.ioctl(fd, UI_DEV_CREATE) ~= 0 then die("UI_DEV_CREATE failed") end

-- Ready: the pid file is the readiness marker driver.py polls for.
local pf = io.open(PIDFILE, "w")
if pf then pf:write(tostring(C.getpid())); pf:close() end
print(string.format("optics-inject: created uinput device '%s'; reading %s",
                    DEVICE_NAME, FIFO))

local ev = ffi.new("struct input_event")
local function emit(etype, code, value)
    ev.tv_sec, ev.tv_usec = 0, 0   -- the input core timestamps delivery
    ev.type, ev.code, ev.value = etype, code, value
    if C.write(fd, ev, ffi.sizeof(ev)) ~= ffi.sizeof(ev) then
        io.stderr:write("optics-inject: event write failed\n")
    end
end

local function tap(code)
    emit(EV_KEY, code, 1)
    emit(EV_SYN, SYN_REPORT, 0)
    C.poll(nil, 0, 15)             -- a beat between press and release
    emit(EV_KEY, code, 0)
    emit(EV_SYN, SYN_REPORT, 0)
end

-- FIFO client loop: open blocks until a writer appears; the line
-- iterator ends when the writer closes (EOF), so reopen and keep going.
local quit = false
while not quit do
    local f = io.open(FIFO, "r")
    if not f then die("cannot open FIFO " .. FIFO) end
    for line in f:lines() do
        local code = line:match("^KEY%s+(%d+)%s*$")
        if code then
            code = tonumber(code)
            if KEYBITS[code] then
                tap(code)
            else
                print("optics-inject: ignoring undeclared key " .. code)
            end
        elseif line == "QUIT" then
            quit = true
            break
        elseif line ~= "" then
            print("optics-inject: ignoring '" .. line .. "'")
        end
    end
    f:close()
end

os.remove(PIDFILE)
C.ioctl(fd, UI_DEV_DESTROY)
C.close(fd)
print("optics-inject: destroyed device, exiting")
