--[[--
Pure-LuaJIT evdev input backend.

Speaks the same protocol as the compiled input module
(`libs/libkoreader-input.so`) that desktop release bundles do not ship:
`open()`/`close()`/`closeAll()`/`waitForEvent()` as documented in
frontend/device/input.lua. Reads `struct input_event` from
/dev/input/event* nodes with poll(2). No device grabbing.

Also exposes `absinfo()` so device targets can query digitizer axis
ranges (EVIOCGABS) for coordinate scaling.
--]]

local ffi = require("ffi")
local bit = require("bit")
local C = ffi.C

require("ffi/posix_h")
require("ffi/linux_input_h")

ffi.cdef[[
struct input_absinfo {
    int32_t value;
    int32_t minimum;
    int32_t maximum;
    int32_t fuzz;
    int32_t flat;
    int32_t resolution;
};
]]

-- poll(2) event bits (asm-generic, same on arm64 & x86_64)
local POLLIN  = 0x0001
local POLLERR = 0x0008
local POLLHUP = 0x0010
local POLLNVAL = 0x0020

-- open(2) flags (same value on arm64 & x86_64)
local O_NONBLOCK = 0x0800

-- Linux errno values (asm-generic)
local ETIME = 62
local ENODEV = 19

-- EVIOCGABS(abs): _IOR('E', 0x40 + abs, struct input_absinfo)
-- dir=READ(2)<<30 | size(24)<<16 | 'E'(0x45)<<8 | (0x40+abs)
local function EVIOCGABS(abs)
    return 0x80184540 + abs
end

local input = {
    is_ffi = true,
}

local open_fds = {}   -- path -> fd
local poll_fds = nil  -- struct pollfd[n], rebuilt when the set changes
local poll_paths = {} -- pollfd index -> path
local poll_n = 0

local function rebuildPollSet()
    local paths = {}
    for path in pairs(open_fds) do
        table.insert(paths, path)
    end
    table.sort(paths)
    poll_n = #paths
    poll_paths = paths
    poll_fds = ffi.new("struct pollfd[?]", poll_n)
    for i, path in ipairs(paths) do
        poll_fds[i - 1].fd = open_fds[path]
        poll_fds[i - 1].events = POLLIN
    end
end

function input.open(path, name)
    if open_fds[path] then
        return open_fds[path]
    end
    local fd = C.open(path, bit.bor(C.O_RDONLY, O_NONBLOCK, C.O_CLOEXEC))
    if fd == -1 then
        error(string.format("cannot open input device %s (%s): errno %d",
                            path, name or "?", ffi.errno()))
    end
    open_fds[path] = fd
    rebuildPollSet()
    return fd
end

function input.close(path)
    local fd = open_fds[path]
    if fd then
        C.close(fd)
        open_fds[path] = nil
        rebuildPollSet()
    end
    return true
end

function input.closeAll()
    for path in pairs(open_fds) do
        C.close(open_fds[path])
        open_fds[path] = nil
    end
    rebuildPollSet()
    return true
end

--- Query an absolute axis range; returns min, max (or nil on failure).
function input.absinfo(path, abs_code)
    local fd = open_fds[path]
    local transient = false
    if not fd then
        fd = C.open(path, bit.bor(C.O_RDONLY, C.O_CLOEXEC))
        if fd == -1 then
            return nil
        end
        transient = true
    end
    local info = ffi.new("struct input_absinfo")
    local ret = C.ioctl(fd, EVIOCGABS(abs_code), info)
    if transient then
        C.close(fd)
    end
    if ret ~= 0 then
        return nil
    end
    return info.minimum, info.maximum
end

-- Read buffer, shared across calls (64 events per read is plenty)
local EV_BUF_LEN = 64
local ev_buf = ffi.new("struct input_event[?]", EV_BUF_LEN)
local ev_size = ffi.sizeof("struct input_event")

local function drainFd(fd, events)
    while true do
        local len = tonumber(C.read(fd, ev_buf, EV_BUF_LEN * ev_size))
        if len <= 0 then
            break
        end
        for i = 0, math.floor(len / ev_size) - 1 do
            table.insert(events, {
                type = ev_buf[i].type,
                code = ev_buf[i].code,
                value = ev_buf[i].value,
                time = {
                    sec = tonumber(ev_buf[i].time.tv_sec),
                    usec = tonumber(ev_buf[i].time.tv_usec),
                },
            })
        end
        if len < EV_BUF_LEN * ev_size then
            break
        end
    end
end

--- Poll-once for input, per the contract in frontend/device/input.lua:
-- returns `true, {ev, ...}` on events, `false, errno` on timeout/benign
-- errors, `nil` on fatal ones.
function input.waitForEvent(sec, usec)
    if poll_n == 0 then
        return nil, "no input devices open"
    end
    local timeout_ms
    if sec == nil then
        timeout_ms = -1
    else
        timeout_ms = math.floor(sec * 1000 + (usec or 0) / 1000)
    end
    local ret = C.poll(poll_fds, poll_n, timeout_ms)
    if ret == 0 then
        return false, ETIME
    end
    if ret < 0 then
        return false, ffi.errno()
    end
    local events = {}
    local lost_device = false
    for i = 0, poll_n - 1 do
        local revents = poll_fds[i].revents
        if bit.band(revents, POLLIN) ~= 0 then
            drainFd(poll_fds[i].fd, events)
        elseif bit.band(revents, bit.bor(POLLERR, POLLHUP, POLLNVAL)) ~= 0 then
            C.close(poll_fds[i].fd)
            open_fds[poll_paths[i + 1]] = nil
            lost_device = true
        end
    end
    if lost_device then
        rebuildPollSet()
        if poll_n == 0 then
            return false, ENODEV
        end
    end
    if #events > 0 then
        return true, events
    end
    return false, ETIME
end

return input
