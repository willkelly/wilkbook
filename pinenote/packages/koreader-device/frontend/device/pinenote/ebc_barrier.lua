local ffi = require("ffi")

ffi.cdef[[
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef int int32_t;
struct drm_rockchip_ebc_refresh_barrier {
    uint32_t version;
    uint32_t op;
    uint64_t request_id;
    uint32_t timeout_ms;
    int32_t result;
    uint32_t reserved[4];
};
int open(const char *pathname, int flags, ...);
int close(int fd);
int ioctl(int fd, unsigned long request, ...);
]]

local barrier_type = "struct drm_rockchip_ebc_refresh_barrier"
assert(ffi.sizeof(barrier_type) == 40, "unexpected EBC barrier ABI size")
assert(ffi.offsetof(barrier_type, "version") == 0, "unexpected EBC barrier version offset")
assert(ffi.offsetof(barrier_type, "op") == 4, "unexpected EBC barrier op offset")
assert(ffi.offsetof(barrier_type, "request_id") == 8, "unexpected EBC barrier request_id offset")
assert(ffi.offsetof(barrier_type, "timeout_ms") == 16, "unexpected EBC barrier timeout_ms offset")
assert(ffi.offsetof(barrier_type, "result") == 20, "unexpected EBC barrier result offset")
assert(ffi.offsetof(barrier_type, "reserved") == 24, "unexpected EBC barrier reserved offset")

local REQUEST = 0xC0286443
local VERSION = 1
local SUBMIT = 1
local WAIT = 2
local EINPROGRESS = -115
local DEFAULT_TIMEOUT_MS = 10000
local O_RDWR_CLOEXEC = 0x80002
local private = setmetatable({}, { __mode = "k" })

local function exact_keys(value, allowed)
    for key in pairs(value) do
        if not allowed[key] then
            error("unsupported EBC barrier option: " .. tostring(key))
        end
    end
end

local function valid_timeout(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
        and value <= 0xffffffff
end

local function fields_are_zero(barrier)
    return barrier.request_id == 0 and barrier.result == 0
        and barrier.reserved[0] == 0 and barrier.reserved[1] == 0
        and barrier.reserved[2] == 0 and barrier.reserved[3] == 0
end

local function unchanged(barrier, op, timeout)
    return barrier.version == VERSION and barrier.op == op and barrier.timeout_ms == timeout
        and barrier.reserved[0] == 0 and barrier.reserved[1] == 0
        and barrier.reserved[2] == 0 and barrier.reserved[3] == 0
end

local function pack(...)
    return { n = select("#", ...), ... }
end

local function invoke(fn, ...)
    local result = pack(pcall(fn, ...))
    if not result[1] then
        return false, tostring(result[2])
    end
    return true, result[2], result.n
end

local function syscall_error(data, stage, result)
    local called, errno_value = invoke(data.errno)
    if not called then return stage .. " errno threw: " .. errno_value end
    return stage .. " ioctl returned " .. tostring(result) .. " (errno " .. tostring(errno_value) .. ")"
end

local function close_fd(data, fd)
    local invoked, result = invoke(data.close, fd)
    if not invoked then
        return false, "close threw: " .. result
    end
    if result ~= 0 then
        return false, "close returned " .. tostring(result)
    end
    return true
end

local function fail(data, primary, fd)
    local detail = primary
    if fd ~= nil then
        local closed, close_error = close_fd(data, fd)
        if not closed then
            detail = detail .. "; " .. close_error
        end
    end
    data.state = "POISONED"
    data.failure = detail
    return false, detail
end

local Adapter = {}
Adapter.__index = Adapter

function Adapter:submit_and_wait(...)
    local data = private[self]
    if data.state == "POISONED" then
        return false, data.failure
    end
    if data.state == "ACTIVE" then
        return false, "EBC barrier transaction already active"
    end
    if select("#", ...) ~= 0 then
        return false, "submit_and_wait accepts no arguments"
    end
    data.state = "ACTIVE"

    local opened, fd_or_error = invoke(data.open, data.card, O_RDWR_CLOEXEC)
    if not opened then
        return fail(data, "open threw: " .. fd_or_error)
    end
    local fd = fd_or_error
    if type(fd) ~= "number" or fd < 0 or fd ~= math.floor(fd) then
        return fail(data, "open returned invalid fd: " .. tostring(fd))
    end

    local submit = ffi.new(barrier_type .. "[1]")
    submit[0].version = VERSION
    submit[0].op = SUBMIT
    submit[0].timeout_ms = 0
    if not fields_are_zero(submit[0]) then
        return fail(data, "SUBMIT input was not zero initialized", fd)
    end
    local called, result = invoke(data.ioctl, fd, REQUEST, submit)
    if not called then
        return fail(data, "SUBMIT ioctl threw: " .. result, fd)
    end
    if result ~= 0 then
        return fail(data, syscall_error(data, "SUBMIT", result), fd)
    end
    if not unchanged(submit[0], SUBMIT, 0) then
        return fail(data, "malformed SUBMIT response", fd)
    end
    if submit[0].result < 0 and submit[0].result ~= EINPROGRESS then
        if submit[0].request_id ~= 0 then return fail(data, "malformed SUBMIT rejection", fd) end
        return fail(data, "SUBMIT rejected (" .. tostring(submit[0].result) .. ")", fd)
    end
    if submit[0].request_id == 0 or submit[0].result ~= EINPROGRESS then
        return fail(data, "unexpected SUBMIT result " .. tostring(submit[0].result), fd)
    end

    local request_id = submit[0].request_id
    local wait = ffi.new(barrier_type .. "[1]")
    wait[0].version = VERSION
    wait[0].op = WAIT
    wait[0].request_id = request_id
    wait[0].timeout_ms = data.timeout_ms
    if wait[0].result ~= 0 or wait[0].reserved[0] ~= 0 or wait[0].reserved[1] ~= 0
        or wait[0].reserved[2] ~= 0 or wait[0].reserved[3] ~= 0 then
        return fail(data, "WAIT input was not zero initialized", fd)
    end
    called, result = invoke(data.ioctl, fd, REQUEST, wait)
    if not called then
        return fail(data, "WAIT ioctl threw: " .. result, fd)
    end
    if result ~= 0 then
        return fail(data, syscall_error(data, "WAIT", result), fd)
    end
    if not unchanged(wait[0], WAIT, data.timeout_ms) or wait[0].request_id ~= request_id then
        return fail(data, "malformed WAIT response", fd)
    end
    if wait[0].result == EINPROGRESS then
        return fail(data, "WAIT timed out (-EINPROGRESS)", fd)
    end
    if wait[0].result < 0 then
        return fail(data, "WAIT failed (" .. tostring(wait[0].result) .. ")", fd)
    end
    if wait[0].result ~= 0 then
        return fail(data, "unexpected WAIT result " .. tostring(wait[0].result), fd)
    end
    local closed, close_error = close_fd(data, fd)
    if not closed then
        data.state = "POISONED"
        data.failure = close_error
        return false, close_error
    end
    data.state = "IDLE"
    return true, request_id
end

function Adapter:status()
    local data = private[self]
    return { state = data.state, failure = data.failure }
end

local function new(options)
    if type(options) ~= "table" then error("EBC barrier requires an options table") end
    exact_keys(options, {
        C = true, open = true, ioctl = true, close = true, errno = true,
        card = true, timeout_ms = true,
    })
    local C = options.C ~= nil and options.C or ffi.C
    local data = {
        open = options.open ~= nil and options.open or C.open,
        ioctl = options.ioctl ~= nil and options.ioctl or C.ioctl,
        close = options.close ~= nil and options.close or C.close,
        errno = options.errno ~= nil and options.errno or ffi.errno,
        -- No default: the EBC's DRM card index is not stable across
        -- images (panfrost takes card0 on the direct-mode image), so a
        -- literal default here is a landmine.  The caller must resolve
        -- the node -- device.lua's findEbcCard is the reference probe.
        card = options.card,
        timeout_ms = options.timeout_ms ~= nil and options.timeout_ms or DEFAULT_TIMEOUT_MS,
        state = "IDLE",
    }
    for _, name in ipairs({ "open", "ioctl", "close", "errno" }) do
        if type(data[name]) ~= "function" and type(data[name]) ~= "cdata" then
            error("malformed EBC barrier option: " .. name)
        end
    end
    if type(data.card) ~= "string" or data.card == "" then error("malformed EBC barrier option: card") end
    if not valid_timeout(data.timeout_ms) then error("invalid EBC barrier timeout_ms") end
    local instance = setmetatable({}, Adapter)
    instance.submit_and_wait = function(...)
        if select(1, ...) == instance then
            return Adapter.submit_and_wait(instance, select(2, ...))
        end
        return Adapter.submit_and_wait(instance, ...)
    end
    instance.status = function()
        return Adapter.status(instance)
    end
    private[instance] = data
    return instance
end

return { new = new }
