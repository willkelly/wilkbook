--[[
ddr-boost -- raise the DDR floor while the user is interacting.

Policy layer over the wilkbook_dmc devfreq driver (capability in the
kernel, policy in userspace, hints via sysfs -- min_freq IS the hint
interface, and any application can hold it without touching this daemon).

Why input-driven rather than a KOReader hook: input precedes rendering,
so full memory bandwidth is in place BEFORE the memory-hungry work
begins, and watching /dev/input covers ANY application, not just the
reader.  Rotation is covered for free: the orientation bridge emits
uinput events.

Behaviour: on any input event, write min_freq = <boost> (the highest
firmware rate) to the dmc devfreq node; after --hold seconds of quiet
(default 10), write min_freq = <floor> (the lowest) and the powersave
governor drops the rate.  Switch-timing safety: the raise fires when the
EBC is essentially always idle (the device was idle -- that is why there
was an input edge), and the drop at ~10 s quiet sits well clear of the
idlewasher (45 s) and auto-suspend (300 s).  Residual mid-scan switch is
a sub-ms DRAM stall against a 25 ms frame budget: transient artifact at
worst, not the poison path (measured 2026-08-06,
doc/artifacts/pinenote-awake-levers-20260806/).

Boost and floor are self-configured from the driver's own
available_frequencies (firmware is the single source of truth); override
with --boost/--floor if an experiment needs it.

Fail-open: if the devfreq node never appears or writes fail, log loudly
and exit 0 -- the governor's 324 floor still stands and a slower reader
beats no reader.  Runtime tunables (re-read before each wait):
    /var/lib/pinenote/ddr-boost.conf
        hold=10       seconds at floor after last input
        enabled=0     pause boosting (min_freq left at floor)

Usage: ddr-boost.lua [--hold S] [--node /sys/class/devfreq/X]
                     [--boost HZ] [--floor HZ] [--config PATH]
--]]

local ffi = require("ffi")

ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
long read(int fd, void *buf, unsigned long n);
int select(int nfds, void *r, void *w, void *e, void *timeout);
struct db_tv { long tv_sec; long tv_usec; };
]]
local C = ffi.C
local bit = require("bit")
local O_RDONLY, O_NONBLOCK = 0, 2048

local opt = {
    hold = 10,
    config = "/var/lib/pinenote/ddr-boost.conf",
    node = nil, boost = nil, floor = nil,
}
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--hold" then i = i + 1; opt.hold = tonumber(arg[i]) or 10
        elseif a == "--node" then i = i + 1; opt.node = arg[i]
        elseif a == "--boost" then i = i + 1; opt.boost = tonumber(arg[i])
        elseif a == "--floor" then i = i + 1; opt.floor = tonumber(arg[i])
        elseif a == "--config" then i = i + 1; opt.config = arg[i]
        end
        i = i + 1
    end
end

local function log(fmt, ...)
    io.stderr:write("[ddr-boost] " .. string.format(fmt, ...) .. "\n")
    io.stderr:flush()
end

local function read_file(p)
    local f = io.open(p, "r"); if not f then return nil end
    local v = f:read("*a"); f:close(); return v
end
local function write_file(p, v)
    local f = io.open(p, "w"); if not f then return false end
    local ok = f:write(v .. "\n"); f:close(); return ok and true or false
end

-- ---- locate the dmc devfreq node (retry: the loader service races us) ----
local node = opt.node
for try = 1, 15 do
    if node then break end
    local pd = io.popen and nil -- no io.popen in this luajit; glob by probe
    for _, cand in ipairs({ "memory-controller", "dmc", "dmc-sip", "wilkbook-dmc" }) do
        local p = "/sys/class/devfreq/" .. cand
        if read_file(p .. "/min_freq") then node = p break end
    end
    if not node then
        -- generic: probe platform-style names via the class dir listing
        -- (no readdir in this ffi surface; probe likely dt node names)
        for _, cand in ipairs({ "soc:dmc", "dmc@0", "fe000000.dmc" }) do
            local p = "/sys/class/devfreq/" .. cand
            if read_file(p .. "/min_freq") then node = p break end
        end
    end
    if not node then
        if try == 1 then log("waiting for devfreq node...") end
        os.execute("sleep 1")
    end
end
if not node then
    -- last resort: ask the shell once for the first class entry
    local tmp = os.tmpname()
    os.execute("ls -d /sys/class/devfreq/* 2>/dev/null | head -1 > " .. tmp)
    local line = read_file(tmp); os.remove(tmp)
    if line and #line > 1 then node = line:gsub("%s+$", "") end
end
if not node or not read_file(node .. "/min_freq") then
    log("no devfreq node found -- boosting unavailable, floor governor stands; exiting 0")
    os.exit(0)
end

-- ---- self-configure boost/floor from the driver's own table ----
local avail = read_file(node .. "/available_frequencies") or ""
local lo, hi
for tok in avail:gmatch("%d+") do
    local v = tonumber(tok)
    lo = (not lo or v < lo) and v or lo
    hi = (not hi or v > hi) and v or hi
end
local FLOOR = opt.floor or lo
local BOOST = opt.boost or hi
if not FLOOR or not BOOST or FLOOR == BOOST then
    log("degenerate frequency table (%s) -- nothing to boost; exiting 0", avail:gsub("%s+", " "))
    os.exit(0)
end
log("node=%s floor=%d boost=%d hold=%ds", node, FLOOR, BOOST, opt.hold)

local runtime = { hold = nil, enabled = true }
local function reload_config()
    runtime.hold, runtime.enabled = nil, true
    local f = io.open(opt.config, "r"); if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)")
        if k == "hold" and tonumber(v) and tonumber(v) >= 1 then
            runtime.hold = math.floor(tonumber(v))
        elseif k == "enabled" then
            runtime.enabled = not (v == "0" or v == "false" or v == "no")
        end
    end
    f:close()
end
local function hold_secs() return runtime.hold or opt.hold end

-- ---- input fds (same probing pattern as autosuspend.lua) ----
local fds, maxfd = {}, 0
for n = 0, 31 do
    local fd = C.open("/dev/input/event" .. n, bit.bor(O_RDONLY, O_NONBLOCK))
    if fd >= 0 then
        fds[#fds + 1] = fd
        if fd > maxfd then maxfd = fd end
    end
end
if #fds == 0 then
    log("no input devices -- exiting 0 (floor stands)")
    os.exit(0)
end
log("watching %d input devices", #fds)

local LONG_BITS = 64
local NWORDS = 1024 / LONG_BITS
local fdset = ffi.new("uint64_t[?]", NWORDS)
local function fd_zero() for i = 0, NWORDS - 1 do fdset[i] = 0 end end
local function fd_set(fd)
    local idx = math.floor(fd / LONG_BITS)
    fdset[idx] = bit.bor(fdset[idx], bit.lshift(1ULL, fd % LONG_BITS))
end
local function fd_isset(fd)
    local idx = math.floor(fd / LONG_BITS)
    return bit.band(fdset[idx], bit.lshift(1ULL, fd % LONG_BITS)) ~= 0
end

local drain = ffi.new("uint8_t[768]")
local tv = ffi.new("struct db_tv")

local boosted = false
local set_fail_logged = false
local function set_min(hz, label)
    if write_file(node .. "/min_freq", tostring(hz)) then
        log("%s: min_freq=%d", label, hz)
        return true
    end
    if not set_fail_logged then
        set_fail_logged = true
        log("min_freq write FAILED -- boosting disabled this run, floor governor stands")
    end
    return false
end

local last_input = os.time()
while true do
    reload_config()
    if boosted and (not runtime.enabled
                    or os.time() - last_input >= hold_secs()) then
        set_min(FLOOR, runtime.enabled and "idle drop" or "paused drop")
        boosted = false
    end
    fd_zero()
    for _, fd in ipairs(fds) do fd_set(fd) end
    if boosted then
        tv.tv_sec = math.max(1, hold_secs() - (os.time() - last_input))
        tv.tv_usec = 0
    else
        tv.tv_sec = 3600; tv.tv_usec = 0   -- idle: nothing to do until input
    end
    local n = C.select(maxfd + 1, fdset, nil, nil, tv)
    if n and n > 0 then
        local saw_input, dead = false, nil
        for i, fd in ipairs(fds) do
            if fd_isset(fd) then
                local got = tonumber(C.read(fd, drain, 768))
                if got and got > 0 then
                    saw_input = true
                    while tonumber(C.read(fd, drain, 768)) > 0 do end
                elseif got == -1 and ffi.errno() ~= 11 then
                    -- Not EAGAIN: the device is gone (ENODEV after a
                    -- uinput destroy, e.g. an orientation-bridge respawn).
                    -- Without eviction select() marks it readable forever
                    -- and the loop spins at 100% CPU -- measured 494
                    -- jiffies/5s on 2026-08-06 before this fix.
                    dead = dead or {}
                    dead[#dead + 1] = i
                end
            end
        end
        if dead then
            for j = #dead, 1, -1 do
                local fd = table.remove(fds, dead[j])
                C.close(fd)
                log("input device vanished (fd %d) -- evicted, %d remain", fd, #fds)
            end
            maxfd = 0
            for _, fd in ipairs(fds) do if fd > maxfd then maxfd = fd end end
            if #fds == 0 then
                log("all input devices gone -- exiting 0 (floor stands)")
                set_min(FLOOR, "exit floor")
                os.exit(0)
            end
        end
        if not saw_input then goto continue end
        last_input = os.time()
        if runtime.enabled and not boosted and not set_fail_logged then
            boosted = set_min(BOOST, "input boost")
        end
    end
    ::continue::
end
