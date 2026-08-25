-- Persistent SC7A20 buffered-IIO -> standard-uinput orientation bridge.
local script_dir = (arg[0] or ""):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local core = require("orientation_core")
local scan = require("orientation_scan")
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
int open(const char *pathname, int flags);
long read(int fd, void *buf, unsigned long count);
long write(int fd, const void *buf, unsigned long count);
int close(int fd);
int ioctl(int fd, unsigned long request, ...);
struct pollfd { int fd; short events, revents; };
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
int getpid(void);
struct timespec { long tv_sec, tv_nsec; };
int clock_gettime(int clockid, struct timespec *tp);
struct input_id { unsigned short bustype, vendor, product, version; };
struct uinput_user_dev { char name[80]; struct input_id id; unsigned int ff_effects_max;
  int absmax[64]; int absmin[64]; int absfuzz[64]; int absflat[64]; };
struct input_event { long tv_sec, tv_usec; unsigned short type, code; int value; };
typedef struct { unsigned long __val[16]; } sigset_t;
int sigemptyset(sigset_t *set);
int sigaddset(sigset_t *set, int signum);
int sigprocmask(int how, const sigset_t *set, sigset_t *oldset);
typedef void (*sighandler_t)(int);
sighandler_t signal(int signum, sighandler_t handler);
unsigned int alarm(unsigned int seconds);
int kill(int pid, int sig);
int fork(void);
int waitpid(int pid, int *status, int options);
]]
local C = ffi.C
local O_RDONLY, O_WRONLY, O_NONBLOCK = 0, 1, 0x800
local POLLIN, POLLERR, POLLHUP, POLLNVAL = 0x0001, 0x0008, 0x0010, 0x0020
local EV_SYN, EV_MSC, SYN_REPORT, MSC_RAW = 0, 4, 0, 3
local BUS_VIRTUAL = 0x06
local UI_SET_EVBIT, UI_SET_MSCBIT = 0x40045564, 0x40045568
local UI_DEV_CREATE, UI_DEV_DESTROY = 0x00005501, 0x00005502
local DEVICE_NAME = "wilkbook-orientation"
local SIG_BLOCK, SIG_UNBLOCK = 0, 1
local SIGINT, SIGKILL, SIGALRM, SIGTERM = 2, 9, 14, 15
local SIG_DFL = ffi.cast("sighandler_t", 0)

-- `herd stop orientation-bridge` wedged on glass (2026-08-25,
-- doc/status.md): the stop hook's `--cleanup` invocation ignored SIGTERM
-- and shepherd sat "being stopped" until SIGKILL.  An ignored disposition
-- survives exec and a blocked signal mask survives fork+exec, so a child
-- spawned from shepherd's stop hook can inherit a SIGTERM-proof state
-- through either channel.  Restore both to defaults on entry, so every
-- mode of this script dies on SIGTERM again.  (A D-state hang would still
-- be immune; nothing in userspace can fix that.)
local function restore_termination_signals()
    local set = ffi.new("sigset_t")
    C.sigemptyset(set)
    C.sigaddset(set, SIGTERM)
    C.sigaddset(set, SIGINT)
    C.sigaddset(set, SIGALRM)
    C.sigprocmask(SIG_UNBLOCK, set, nil)
    C.signal(SIGTERM, SIG_DFL)
    C.signal(SIGINT, SIG_DFL)
    C.signal(SIGALRM, SIG_DFL)
end
restore_termination_signals()

local READY = arg[1] or "/run/wilkbook-orientation.ready"
local CONSUMER_READY = "/run/wilkbook-orientation.consumer"
local STATE = "/run/wilkbook-orientation.state"

local function read_line(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local value = f:read("*l")
    f:close()
    return value
end

local function write_value(path, value)
    local f = io.open(path, "w")
    if not f then return false end
    local wrote = f:write(value)
    local closed = f:close()
    return wrote and closed
end

local function sensor()
    for n = 0, 63 do
        local base = "/sys/bus/iio/devices/iio:device" .. n
        if read_line(base .. "/name") == "sc7a20" then
            return base, "/dev/iio:device" .. n
        end
    end
end

local function scan_layout(base)
    local scan_elements = base .. "/scan_elements/"
    local metadata = {}
    for _, axis in ipairs({ "x", "y", "z" }) do
        metadata[axis .. "_index"] = read_line(scan_elements .. "in_accel_" .. axis .. "_index")
        metadata[axis .. "_type"] = read_line(scan_elements .. "in_accel_" .. axis .. "_type")
    end
    metadata.timestamp_index = read_line(scan_elements .. "in_timestamp_index")
    metadata.timestamp_type = read_line(scan_elements .. "in_timestamp_type")
    return scan.layout(metadata)
end

local function setup_sensor(base)
    local layout = scan_layout(base)
    -- The kernel's sc7a20-trigger is already selected by the driver.  Do not
    -- replace it; buffered samples are coherent only while that trigger runs.
    if not layout or not read_line(base .. "/trigger/current_trigger") then return nil end
    local scan = base .. "/scan_elements/"
    if not write_value(base .. "/buffer/enable", "0") then return nil end
    for _, axis in ipairs({ "x", "y", "z" }) do
        if not write_value(scan .. "in_accel_" .. axis .. "_en", "1") then return nil end
    end
    if not write_value(scan .. "in_timestamp_en", "1")
       or not write_value(base .. "/buffer/enable", "1") then
        write_value(base .. "/buffer/enable", "0")
        return nil
    end
    return layout
end

local function teardown_sensor(base)
    if base then
        local scan_elements = base .. "/scan_elements/"
        write_value(base .. "/buffer/enable", "0")
        for _, axis in ipairs({ "x", "y", "z" }) do
            write_value(scan_elements .. "in_accel_" .. axis .. "_en", "0")
        end
        write_value(scan_elements .. "in_timestamp_en", "0")
    end
end

if arg[1] == "--cleanup" then
    -- Watchdog: teardown is milliseconds of sysfs writes.  If any of them
    -- wedges, die by SIGALRM instead of hanging `herd stop` forever --
    -- nobody automatically sends the cleanup child a SIGTERM.
    C.alarm(15)
    local base = sensor()
    teardown_sensor(base)
    os.remove("/run/wilkbook-orientation.ready")
    os.remove(CONSUMER_READY)
    os.remove(STATE)
    os.exit(0)
end

local function exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

local function find_evdev_path(excluded)
    for n = 0, 63 do
        local name = read_line("/sys/class/input/event" .. n .. "/device/name")
        local path = "/dev/input/event" .. n
        if name == DEVICE_NAME and not (excluded and excluded[path]) then return path end
    end
end

local function find_evdev()
    return find_evdev_path() ~= nil
end

local function create_uinput()
    local fd = C.open("/dev/uinput", O_WRONLY)
    if fd < 0 then return nil end
    if C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_SYN)) ~= 0
       or C.ioctl(fd, UI_SET_EVBIT, ffi.cast("int", EV_MSC)) ~= 0
       or C.ioctl(fd, UI_SET_MSCBIT, ffi.cast("int", MSC_RAW)) ~= 0 then
        C.close(fd)
        return nil
    end
    local dev = ffi.new("struct uinput_user_dev")
    ffi.copy(dev.name, DEVICE_NAME)
    dev.id.bustype, dev.id.vendor, dev.id.product, dev.id.version = BUS_VIRTUAL, 0x1209, 0x0002, 1
    if C.write(fd, dev, ffi.sizeof(dev)) ~= ffi.sizeof(dev) or C.ioctl(fd, UI_DEV_CREATE) ~= 0 then
        C.close(fd)
        return nil
    end
    return fd
end

local function emit(fd, mode)
    local ev = ffi.new("struct input_event")
    ev.type, ev.code, ev.value = EV_MSC, MSC_RAW, mode
    assert(C.write(fd, ev, ffi.sizeof(ev)) == ffi.sizeof(ev))
    ev.type, ev.code, ev.value = EV_SYN, SYN_REPORT, 0
    assert(C.write(fd, ev, ffi.sizeof(ev)) == ffi.sizeof(ev))
end

local function self_test()
    local probe = io.open("/dev/uinput", "w")
    if not probe then
        print("SKIP: uinput-self-test (no writable /dev/uinput)")
        return
    end
    probe:close()

    local existing = {}
    for n = 0, 63 do
        local path = "/dev/input/event" .. n
        if read_line("/sys/class/input/event" .. n .. "/device/name") == DEVICE_NAME then
            existing[path] = true
        end
    end
    local fd = assert(create_uinput(), "uinput-self-test: create_uinput failed")
    local event_path
    local evfd = -1
    local ok, err = xpcall(function()
        for _ = 1, 50 do
            event_path = find_evdev_path(existing)
            if event_path then break end
            C.poll(nil, 0, 20)
        end
        assert(event_path, "uinput-self-test: named evdev node did not appear")

        local sysfs = "/sys/class/input/" .. event_path:match("[^/]+$") .. "/device/"
        assert(read_line(sysfs .. "id/bustype") == "0006"
            and read_line(sysfs .. "id/vendor") == "1209"
            and read_line(sysfs .. "id/product") == "0002"
            and read_line(sysfs .. "id/version") == "0001",
            "uinput-self-test: virtual identity mismatch")
        assert(read_line(sysfs .. "capabilities/ev") == "11"
            and read_line(sysfs .. "capabilities/msc") == "8",
            "uinput-self-test: capability mismatch")
        print("PASS: uinput-self-test: wilkbook-orientation identity and EV_SYN|EV_MSC/MSC_RAW capabilities")

        evfd = C.open(event_path, bit.bor(O_RDONLY, O_NONBLOCK))
        if evfd < 0 then
            print("SKIP: uinput-self-test (created evdev node is not readable on this host)")
            return
        end
        emit(fd, 2)
        local events = ffi.new("struct input_event[2]")
        assert(C.poll(ffi.new("struct pollfd[1]", { { fd = evfd, events = POLLIN } }), 1, 1000) > 0,
               "uinput-self-test: emitted events did not arrive")
        assert(C.read(evfd, events, ffi.sizeof(events)) == ffi.sizeof(events),
               "uinput-self-test: incomplete evdev event read")
        assert(events[0].type == EV_MSC and events[0].code == MSC_RAW and events[0].value == 2
            and events[1].type == EV_SYN and events[1].code == SYN_REPORT and events[1].value == 0,
            "uinput-self-test: wrong emitted event sequence")
        print("PASS: uinput-self-test: MSC_RAW mode 2 plus SYN_REPORT delivery")
    end, debug.traceback)
    if evfd >= 0 then C.close(evfd) end
    C.ioctl(fd, UI_DEV_DESTROY)
    C.close(fd)
    if not ok then error(err) end
end

-- Behavioural check for restore_termination_signals(): simulate the
-- shepherd stop-hook environment (SIGTERM blocked in the parent,
-- inherited across fork) and prove the restore makes SIGTERM lethal
-- again.  Runs on any host; needs no device, no root, no /dev/uinput.
local function signal_self_test()
    local WNOHANG = 1
    local function reap(pid, timeout_ms)
        local status = ffi.new("int[1]")
        local waited = 0
        while true do
            local r = C.waitpid(pid, status, WNOHANG)
            assert(r == pid or r == 0, "signal-self-test: waitpid failed")
            if r == pid then return status[0] end
            if waited >= timeout_ms then return nil end
            C.poll(nil, 0, 20)
            waited = waited + 20
        end
    end
    local function spawn_and_term(restore)
        local pid = C.fork()
        assert(pid >= 0, "signal-self-test: fork failed")
        if pid == 0 then
            if restore then restore_termination_signals() end
            C.poll(nil, 0, 30000)
            os.exit(86) -- reached only if SIGTERM never lands
        end
        -- Blocked-then-pending or delivered live: either way SIGTERM must
        -- kill a restored child, and must not kill an unrestored one.
        C.kill(pid, SIGTERM)
        return pid
    end

    local set = ffi.new("sigset_t")
    C.sigemptyset(set)
    C.sigaddset(set, SIGTERM)
    assert(C.sigprocmask(SIG_BLOCK, set, nil) == 0,
           "signal-self-test: cannot block SIGTERM")

    -- Positive control first: WITHOUT the restore, the inherited blocked
    -- mask must make the child shrug off SIGTERM.  If this control fails,
    -- the harness does not actually produce the shepherd-like state and a
    -- pass below would be vacuous.
    local pid = spawn_and_term(false)
    assert(reap(pid, 600) == nil,
           "signal-self-test: control child died despite inherited blocked SIGTERM")
    C.kill(pid, SIGKILL)
    assert(reap(pid, 2000), "signal-self-test: control child survived SIGKILL")
    print("PASS: signal-self-test: inherited blocked mask makes SIGTERM inert (control)")

    -- The fix: the same child, same blocked inheritance, same SIGTERM --
    -- but restore_termination_signals() runs first, so it must die, and
    -- die BY SIGTERM rather than by falling off the 30 s sleep.
    pid = spawn_and_term(true)
    local status = reap(pid, 2000)
    assert(status, "signal-self-test: restored child ignored SIGTERM")
    assert(bit.band(status, 0x7f) == SIGTERM,
           "signal-self-test: restored child died, but not by SIGTERM (status "
           .. tostring(status) .. ")")
    print("PASS: signal-self-test: restore_termination_signals makes SIGTERM lethal again")
end

if arg[1] == "--uinput-self-test" then
    self_test()
    os.exit(0)
end

if arg[1] == "--signal-self-test" then
    signal_self_test()
    os.exit(0)
end

local function save_state(mode)
    local tmp = STATE .. ".tmp"
    local f = assert(io.open(tmp, "w"))
    assert(f:write(tostring(mode), "\n"))
    assert(f:close())
    assert(os.rename(tmp, STATE))
end

local uinput = create_uinput()
if not uinput then error("wilkbook-orientation: cannot create /dev/uinput device") end
-- A marker from an older KOReader cannot refer to this newly-created evdev
-- node. The current reader recreates it only after opening the node.
os.remove(CONSUMER_READY)
os.remove(STATE)
for _ = 1, 50 do
    if find_evdev() then break end
    C.poll(nil, 0, 100)
end
if not find_evdev() then
    C.ioctl(uinput, UI_DEV_DESTROY)
    C.close(uinput)
    error("wilkbook-orientation: named evdev node did not appear")
end
local ready = assert(io.open(READY, "w")); ready:write(tostring(C.getpid())); ready:close()

local monotonic = ffi.new("struct timespec")
local function now_ms()
    assert(C.clock_gettime(1, monotonic) == 0) -- CLOCK_MONOTONIC
    return tonumber(monotonic.tv_sec) * 1000 + math.floor(tonumber(monotonic.tv_nsec) / 1000000)
end
while true do
    if not exists(CONSUMER_READY) then
        C.poll(nil, 0, 100)
        goto continue
    end
    -- A new consumer needs a fresh initial orientation even when the tablet
    -- has not moved since the previous KOReader instance.
    local state = core.new()
    local base, node = sensor()
    if not base then C.poll(nil, 0, 500); goto continue end
    local layout = setup_sensor(base)
    if not layout then C.poll(nil, 0, 500); goto continue end
    local fd = C.open(node, O_RDONLY)
    if fd < 0 then teardown_sensor(base); C.poll(nil, 0, 500); goto continue end
    local buf = ffi.new("uint8_t[?]", layout.bytes)
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd, pfd[0].events = fd, POLLIN
    while exists(CONSUMER_READY) do
        pfd[0].revents = 0
        local polled = C.poll(pfd, 1, 250)
        if polled < 0 then break end
        if polled > 0 then
            if bit.band(pfd[0].revents, bit.bor(POLLERR, POLLHUP, POLLNVAL)) ~= 0 then
                break
            end
            if bit.band(pfd[0].revents, POLLIN) ~= 0 then
                local count = tonumber(C.read(fd, buf, layout.bytes))
                if count ~= layout.bytes then break end
                local now = now_ms()
                local x, y, z = scan.decode(ffi.string(buf, layout.bytes), layout)
                if not x then break end
                local mode = core.feed(state, x, y, z, now)
                if mode ~= nil then
                    save_state(mode)
                    emit(uinput, mode)
                end
            end
        end
    end
    C.close(fd)
    teardown_sensor(base)
    ::continue::
end
