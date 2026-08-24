--[[--
PineNote time sync: step the system clock from SNTP when — and only when
— a network happens to be there, then hand the correction to the RTC so
it survives a cold boot.

WHY THIS EXISTS (issue #27).  Nothing on this device sets the clock.  The
RTC is the only source, and this project reconstructs sessions from
timestamps: dated doc/status.md entries, the auto-suspend daemon's
per-resume charge_now series (a whole soak result is that series divided
by its own intervals), and the `[pn-refresh]` traces whose entire
analysis is inter-arrival times.  A skewed clock does not announce
itself.  It makes all of that read PLAUSIBLY wrong, which is worse than
reading obviously wrong.

WHAT IT IS NOT.  It is not an NTP daemon.  It does not discipline the
clock, keep a drift file, or hold a connection.  At a measured ~1.5 %
awake duty cycle (2026-08-24: uptime 831901 s against a newest printk
timestamp of 12619 s — printk stops across suspend, so the difference is
awake time) disciplining a clock is meaningless: the thing being
disciplined is asleep 98.5 % of the time and its oscillator is the RTC's
anyway.  What this does is STEP an unanchored clock to a plausible value
whenever the opportunity is free, and say loudly that it did.

THE POWER CONTRACT, which is the part that constrains the design.
Ultra suspend measures 5.47 mA idle and the hourly RTC backstop alone
costs ~0.83 mA of that (doc/power-management.md), so anything that
forces an extra wake is spending real budget.  This daemon therefore:

  * never arms a timer that can wake the device.  Every wait is
    poll(NULL, 0, ms), whose timeout runs on CLOCK_MONOTONIC — it does
    not advance across suspend and it is not a wakeup source.  The
    daemon is frozen with everything else and resumes mid-wait.
  * never opens a socket unless /proc/net/route already shows a
    non-loopback route.  With no Wi-Fi — the common case for this
    device — a poll is two file reads and a sleep, forever, in silence.
  * backs off exponentially on failure (poll -> 2x -> ... -> cap), so a
    configured server that is unreachable costs less and less rather
    than turning into a retry loop that holds the CPU up.

Because the waits are monotonic, the poll interval is in AWAKE seconds:
at a 1.5 % duty cycle a 120 s poll is roughly one check every two hours
of wall time, and several checks per session in which the device is
actually being read.  That is the right shape — it looks for the network
when the device is in use, and costs nothing when it is not.

Usage:
  timesync.lua --server HOST[:PORT] [--server ...] [options]

    --poll SECONDS        awake seconds between checks (default 120)
    --refresh SECONDS     wall seconds between successful syncs (21600)
    --timeout SECONDS     per-server SNTP timeout (default 5)
    --max-backoff SECONDS cap for the failure backoff (default 3600)
    --not-before EPOCH    reject any answer before this (sanity window)
    --horizon SECONDS     reject any answer after not-before + horizon
    --hwclock PATH        hwclock(8) to write the RTC with ("" disables)
    --rtc PATH            RTC sysfs directory (default /sys/class/rtc/rtc0)
    --route PATH          route table to read (default /proc/net/route)
    --kmsg PATH           where to announce a step ("" disables)
    --once                one pass, then exit (diagnostics and tests)
    --dry-run             print the answer, set nothing
    --skip-route-check    query even with no route (diagnostics and tests)
    --quiet               no log output
--]]

local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
int socket(int domain, int type, int protocol);
int close(int fd);
int poll(struct ts_pollfd *fds, unsigned long nfds, int timeout);
long sendto(int fd, const void *buf, unsigned long len, int flags,
            const struct ts_sockaddr_in *dest, unsigned int addrlen);
long recv(int fd, void *buf, unsigned long len, int flags);
int settimeofday(const struct ts_timeval *tv, const void *tz);
int clock_gettime(int clk_id, struct ts_timespec *tp);
int inet_pton(int af, const char *src, void *dst);
int getaddrinfo(const char *node, const char *service,
                const struct ts_addrinfo *hints, struct ts_addrinfo **res);
void freeaddrinfo(struct ts_addrinfo *res);
const char *gai_strerror(int errcode);

struct ts_pollfd  { int fd; short events; short revents; };
struct ts_timeval { long tv_sec; long tv_usec; };
struct ts_timespec { long tv_sec; long tv_nsec; };

/* sockaddr_in.  Declared flat rather than as sockaddr + cast: we only
   ever speak IPv4 UDP here, and a flat struct is one thing LuaJIT can
   lay out without any opinion about sockaddr_storage. */
struct ts_sockaddr_in {
    unsigned short sin_family;
    unsigned short sin_port;      /* network byte order */
    unsigned int   sin_addr;      /* network byte order */
    unsigned char  sin_zero[8];
};

/* glibc's struct addrinfo.  NOTE the field order: glibc puts ai_addr
   BEFORE ai_canonname, musl the other way round.  We run glibc, and the
   host test proves the layout by resolving a name whose answer it knows
   (a wrong layout yields a wrong address, not a crash). */
struct ts_addrinfo {
    int ai_flags;
    int ai_family;
    int ai_socktype;
    int ai_protocol;
    unsigned int ai_addrlen;
    struct ts_sockaddr_in *ai_addr;
    char *ai_canonname;
    struct ts_addrinfo *ai_next;
};
]]

local AF_INET, SOCK_DGRAM = 2, 2
local POLLIN = 1
local CLOCK_MONOTONIC = 1
local NTP_PORT = 123
local NTP_PACKET_BYTES = 48

-- Seconds from the NTP epoch (1900-01-01) to the Unix epoch, and the
-- span of one NTP era.
local NTP_UNIX_DELTA = 2208988800
local NTP_ERA_SECONDS = 4294967296

local opt = {
    servers = {},
    poll = 120,
    refresh = 21600,
    timeout = 5,
    max_backoff = 3600,
    -- 2026-01-01T00:00:00Z.  A FLOOR, not authentication: SNTP is
    -- unauthenticated and anything on the path can answer, so this only
    -- rejects the answers that are obviously junk (a 1970 or a 2106).
    -- It is a constant rather than the build date because a build-stamped
    -- default would make the derivation unreproducible; it therefore ages,
    -- and the service field exists so an operator can move it.
    not_before = 1767225600,
    horizon = 630720000,            -- 20 years
    hwclock = "hwclock",
    rtc = "/sys/class/rtc/rtc0",
    route = "/proc/net/route",
    kmsg = "/dev/kmsg",
    once = false,
    dry = false,
    skip_route_check = false,
    verbose = true,
}

local function log(fmt, ...)
    if not opt.verbose then return end
    io.stderr:write(("[timesync %s] " .. fmt .. "\n")
        :format(os.date("!%Y-%m-%dT%H:%M:%SZ"), ...))
    io.stderr:flush()
end

local function write_file(path, value)
    if not path or path == "" then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(value)
    local ok = f:close()
    return ok and true or false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*a")
    f:close()
    return v
end

local function read_number(path)
    local v = read_file(path)
    return v and tonumber(v:match("-?%d+") or "") or nil
end

-- ---------------------------------------------------------------------
-- Pure logic.  Everything below to the end of the section is a top-level
-- `local function' with no I/O in it, because the host suite
-- (test-timesync.lua) extracts these VERBATIM and drives them with
-- synthetic packets.  Same contract as the EBC and auto-suspend tools:
-- the shipped source is what the tests execute, never a paraphrase.
-- ---------------------------------------------------------------------

local function u32be(s, off)
    -- off is a 0-based byte offset into the 48-byte NTP packet.
    local a, b, c, d = s:byte(off + 1, off + 4)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function put32be(t, off, v)
    -- t is a 1-based array of byte values; off is 0-based, as above.
    t[off + 1] = bit.band(bit.rshift(v, 24), 0xff)
    t[off + 2] = bit.band(bit.rshift(v, 16), 0xff)
    t[off + 3] = bit.band(bit.rshift(v, 8), 0xff)
    t[off + 4] = bit.band(v, 0xff)
end

local function ntp_to_unix(ntp_secs)
    -- NTP's seconds field is 32 bits and wraps on 2036-02-07.  RFC 4330
    -- resolves the ambiguity by era: with the high bit SET the value is
    -- era 0 (1968-2036), with it clear it is era 1 (2036-2104).  Getting
    -- this wrong is not a rounding error, it is a 136-year jump, and it
    -- starts mattering to a device that is meant to still be readable in
    -- ten years -- which is the entire premise of this repo.
    if ntp_secs >= 2147483648 then
        return ntp_secs - NTP_UNIX_DELTA
    end
    return ntp_secs + (NTP_ERA_SECONDS - NTP_UNIX_DELTA)
end

local function build_request(nonce_hi, nonce_lo)
    -- LI = 0, VN = 4, Mode = 3 (client) -> 0x23.  Everything else zero.
    local b = {}
    for i = 1, NTP_PACKET_BYTES do b[i] = 0 end
    b[1] = 0x23
    -- The Transmit Timestamp field (offset 40) carries a NONCE, not our
    -- clock.  Our clock is the thing that may be wrong, so sending it
    -- would be sending noise; and the server echoes these eight bytes
    -- back in the Originate Timestamp, which is the only thing that ties
    -- a reply to this request.  A stale or spoofed packet that does not
    -- echo the nonce is dropped.
    put32be(b, 40, nonce_hi)
    put32be(b, 44, nonce_lo)
    local out = {}
    for i = 1, NTP_PACKET_BYTES do out[i] = string.char(b[i]) end
    return table.concat(out)
end

local function parse_response(reply, nonce_hi, nonce_lo)
    if type(reply) ~= "string" or #reply < NTP_PACKET_BYTES then
        return nil, ("short reply (%d bytes)"):format(reply and #reply or 0)
    end
    local b0 = reply:byte(1)
    local li = bit.rshift(b0, 6)
    local vn = bit.band(bit.rshift(b0, 3), 7)
    local mode = bit.band(b0, 7)
    if mode ~= 4 then return nil, ("mode %d is not a server reply"):format(mode) end
    if vn < 3 or vn > 4 then return nil, ("NTP version %d unsupported"):format(vn) end
    -- LI = 3 is the server saying "my own clock is not synchronised".
    -- Believing it is how a device ends up confidently wrong.
    if li == 3 then return nil, "server reports itself unsynchronised (LI=3)" end
    local stratum = reply:byte(2)
    if stratum < 1 or stratum > 15 then
        return nil, ("stratum %d unusable"):format(stratum)
    end
    if u32be(reply, 24) ~= nonce_hi or u32be(reply, 28) ~= nonce_lo then
        return nil, "originate timestamp does not echo our nonce"
    end
    local secs = u32be(reply, 40)
    local frac = u32be(reply, 44)
    if secs == 0 then return nil, "zero transmit timestamp" end
    return ntp_to_unix(secs), frac / NTP_ERA_SECONDS
end

local function plausible(unix_secs, not_before, horizon)
    if type(unix_secs) ~= "number" then return false, "not a number" end
    if unix_secs < not_before then
        return false, ("%d is before the sanity floor %d"):format(unix_secs, not_before)
    end
    if unix_secs > not_before + horizon then
        return false, ("%d is beyond the sanity horizon %d"):format(unix_secs,
            not_before + horizon)
    end
    return true
end

local function next_backoff(current, base, cap)
    -- First failure waits one poll interval; each further failure
    -- doubles, capped.  This is the whole of "must not retry-loop itself
    -- awake": an unreachable server costs less and less, never more.
    if not current or current <= 0 then return base end
    local doubled = current * 2
    if doubled > cap then return cap end
    return doubled
end

local function have_network(route_text)
    -- /proc/net/route: a header line, then one line per route.  ANY route
    -- on a non-loopback interface counts -- a default route is not
    -- required, because the sensible server for this device is one on the
    -- LAN it just joined.  Reading a proc file costs nothing and touches
    -- no radio, so this is the check that keeps a device with no Wi-Fi
    -- from ever opening a socket.
    if type(route_text) ~= "string" then return false end
    local header = true
    for line in route_text:gmatch("[^\r\n]+") do
        if header then
            header = false
        else
            local iface = line:match("^(%S+)")
            if iface and iface ~= "" and iface ~= "lo" then return true end
        end
    end
    return false
end

local function rearm_alarm_value(alarm, rtc_before, rtc_after)
    -- THE RTC-BACKSTOP FOOT-GUN, and the whole reason this function
    -- exists.  autosuspend.lua arms the backstop as an ABSOLUTE value in
    -- the RTC's own seconds (`since_epoch` + N), so stepping the RTC
    -- moves the alarm relative to real time: step forward past it and the
    -- compare never matches, so the alarm silently never fires; step
    -- backward and it fires that much later.  What the backstop MEANS is
    -- an interval -- "wake within an hour if nothing else does" -- so
    -- preserve the interval across the step rather than the instant.
    --
    -- Returns nil when there is nothing to preserve: no alarm, or one
    -- that had already expired (the kernel disables a fired one-shot
    -- alarm, so a pending value in the past is not ours to resurrect).
    if type(alarm) ~= "number" or alarm <= 0 then return nil end
    if type(rtc_before) ~= "number" or type(rtc_after) ~= "number" then return nil end
    local remaining = alarm - rtc_before
    if remaining <= 0 then return nil end
    return rtc_after + remaining
end

-- ---------------------------------------------------------------------
-- Argument parsing
-- ---------------------------------------------------------------------

local function parse_args(argv)
    local i = 1
    local function value(name)
        i = i + 1
        local v = argv[i]
        if v == nil then
            io.stderr:write(("timesync: %s needs a value\n"):format(name))
            os.exit(2)
        end
        return v
    end
    while argv[i] do
        local a = argv[i]
        if a == "--server" then opt.servers[#opt.servers + 1] = value(a)
        elseif a == "--poll" then opt.poll = tonumber(value(a)) or opt.poll
        elseif a == "--refresh" then opt.refresh = tonumber(value(a)) or opt.refresh
        elseif a == "--timeout" then opt.timeout = tonumber(value(a)) or opt.timeout
        elseif a == "--max-backoff" then opt.max_backoff = tonumber(value(a)) or opt.max_backoff
        elseif a == "--not-before" then opt.not_before = tonumber(value(a)) or opt.not_before
        elseif a == "--horizon" then opt.horizon = tonumber(value(a)) or opt.horizon
        elseif a == "--hwclock" then opt.hwclock = value(a)
        elseif a == "--rtc" then opt.rtc = value(a)
        elseif a == "--route" then opt.route = value(a)
        elseif a == "--kmsg" then opt.kmsg = value(a)
        elseif a == "--once" then opt.once = true
        elseif a == "--dry-run" then opt.dry = true
        elseif a == "--skip-route-check" then opt.skip_route_check = true
        elseif a == "--quiet" then opt.verbose = false
        else
            io.stderr:write(("timesync: unknown option %s\n"):format(tostring(a)))
            os.exit(2)
        end
        i = i + 1
    end
end

parse_args(arg or {})

-- ---------------------------------------------------------------------
-- Transport
-- ---------------------------------------------------------------------

local function monotonic()
    local ts = ffi.new("struct ts_timespec")
    if ffi.C.clock_gettime(CLOCK_MONOTONIC, ts) ~= 0 then return nil end
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end

-- Seed from the MONOTONIC clock, not os.time(): the wall clock is the
-- quantity this daemon exists to distrust, and on a device whose RTC has
-- reset it is the same value on every boot.
math.randomseed(math.floor(((monotonic() or 0) * 1e6) % 2147483647))

-- Sleep on CLOCK_MONOTONIC with no fd and no timer that could ever be a
-- wakeup source.  Frozen across suspend, by construction.
local function nap(seconds)
    local left = math.floor(seconds * 1000 + 0.5)
    while left > 0 do
        local chunk = left > 2000000000 and 2000000000 or left
        local before = monotonic()
        ffi.C.poll(nil, 0, chunk)
        local after = monotonic()
        if not before or not after then return end
        local done = math.floor((after - before) * 1000 + 0.5)
        if done <= 0 then done = chunk end   -- no usable clock: do not spin
        left = left - done
    end
end

local function split_host_port(spec)
    local host, port = spec:match("^(.*):(%d+)$")
    if host and host ~= "" and not host:find(":") then
        return host, tonumber(port)
    end
    return spec, NTP_PORT
end

-- Resolve to a single IPv4 address in network byte order.  Literals go
-- through inet_pton (no resolver, no /etc/resolv.conf, no DNS traffic);
-- names go through getaddrinfo, which is the only place this daemon can
-- generate a second kind of outbound packet -- worth knowing when you
-- choose what to put in the `servers' field.
local function resolve(host)
    local addr = ffi.new("unsigned int[1]")
    if ffi.C.inet_pton(AF_INET, host, addr) == 1 then
        return addr[0]
    end
    local hints = ffi.new("struct ts_addrinfo")
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    local res = ffi.new("struct ts_addrinfo*[1]")
    local rc = ffi.C.getaddrinfo(host, nil, hints, res)
    if rc ~= 0 then
        return nil, ("resolve %s: %s"):format(host, ffi.string(ffi.C.gai_strerror(rc)))
    end
    local out, err = nil, ("resolve %s: no IPv4 answer"):format(host)
    local node = res[0]
    while node ~= nil do
        if node.ai_family == AF_INET and node.ai_addr ~= nil then
            out, err = node.ai_addr.sin_addr, nil
            break
        end
        node = node.ai_next
    end
    ffi.C.freeaddrinfo(res[0])
    return out, err
end

local function htons(v)
    return bit.bor(bit.band(bit.lshift(v, 8), 0xff00), bit.band(bit.rshift(v, 8), 0xff))
end

-- One SNTP exchange.  Returns unix seconds (float, half-RTT corrected)
-- or nil plus a reason.
local function query(host, port, timeout)
    local addr, err = resolve(host)
    if not addr then return nil, err end
    local fd = ffi.C.socket(AF_INET, SOCK_DGRAM, 0)
    if fd < 0 then return nil, "socket() failed" end

    local sa = ffi.new("struct ts_sockaddr_in")
    sa.sin_family = AF_INET
    sa.sin_port = htons(port)
    sa.sin_addr = addr

    -- The nonce is deliberately NOT derived from the wall clock, which is
    -- the quantity under suspicion.  Monotonic time plus math.random is
    -- enough: this is replay rejection, not authentication.
    -- Unsigned 32-bit, because that is what u32be() reads back out of the
    -- reply: a bit.band() result is SIGNED in LuaJIT and would never
    -- compare equal to the echo.
    local hi = math.floor(math.random() * 4294967296)
    local lo = math.floor(math.random() * 4294967296)
    local request = build_request(hi, lo)

    local sent = tonumber(ffi.C.sendto(fd, request, #request, 0, sa, ffi.sizeof(sa)))
    if sent ~= #request then
        ffi.C.close(fd)
        return nil, "sendto() failed"
    end

    local t0 = monotonic()
    local pfd = ffi.new("struct ts_pollfd[1]")
    pfd[0].fd = fd
    pfd[0].events = POLLIN
    local n = tonumber(ffi.C.poll(pfd, 1, math.floor(timeout * 1000)))
    if n == nil or n <= 0 then
        ffi.C.close(fd)
        return nil, ("no reply within %ss"):format(tostring(timeout))
    end
    local buf = ffi.new("unsigned char[?]", 512)
    local got = tonumber(ffi.C.recv(fd, buf, 512, 0))
    local t1 = monotonic()
    ffi.C.close(fd)
    if not got or got <= 0 then return nil, "recv() failed" end

    local reply = ffi.string(buf, got)
    local secs, frac = parse_response(reply, hi, lo)
    if not secs then return nil, frac end   -- frac carries the reason here
    -- Half the round trip, measured monotonically so a wrong wall clock
    -- cannot corrupt it.  It is sub-second noise against a clock that may
    -- be years out, but it costs three lines and it is what makes the
    -- answer honest at the scale the refresh traces care about.
    local rtt = (t0 and t1) and (t1 - t0) or 0
    return secs + frac + rtt / 2
end

-- ---------------------------------------------------------------------
-- Applying the answer
-- ---------------------------------------------------------------------

local function set_system_clock(unix_float)
    local tv = ffi.new("struct ts_timeval")
    tv.tv_sec = math.floor(unix_float)
    tv.tv_usec = math.floor((unix_float - math.floor(unix_float)) * 1e6)
    return ffi.C.settimeofday(tv, nil) == 0
end

-- Write the corrected time back to the RTC so it survives a cold boot,
-- preserving any pending backstop alarm as an INTERVAL (see
-- rearm_alarm_value above for why that is not optional).
local function set_rtc()
    if not opt.hwclock or opt.hwclock == "" then return false, "disabled" end
    local alarm = read_number(opt.rtc .. "/wakealarm")
    local before = read_number(opt.rtc .. "/since_epoch")
    -- --noadjfile keeps this off /etc/adjtime: there is no drift model
    -- here to maintain, and a read-only or absent /etc must not turn a
    -- clock correction into a failure.  --utc because Guix keeps the
    -- hardware clock in UTC, which is also what the kernel assumes.
    local ok = os.execute(("%s --systohc --utc --noadjfile >/dev/null 2>&1")
        :format(opt.hwclock))
    -- Lua 5.1/LuaJIT: os.execute returns the raw exit status.
    if ok ~= 0 and ok ~= true then return false, ("hwclock exit %s"):format(tostring(ok)) end
    local after = read_number(opt.rtc .. "/since_epoch")
    local rearm = rearm_alarm_value(alarm, before, after)
    if rearm then
        -- Clearing first is required: the kernel refuses a new alarm over
        -- an armed one.  autosuspend.lua does the same dance.
        write_file(opt.rtc .. "/wakealarm", "0")
        write_file(opt.rtc .. "/wakealarm", tostring(math.floor(rearm)))
        log("re-armed the pending RTC alarm %d -> %d (interval preserved)",
            alarm, math.floor(rearm))
    end
    return true
end

local function announce(before, after)
    local delta = after - before
    local line = ("timesync stepped the clock by %+.3f s: %s -> %s")
        :format(delta,
            os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(before)),
            os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(after)))
    log("%s", line)
    -- Into the kernel ring too.  Every trace this repo reads back --
    -- [pn-refresh] inter-arrival times, the autosuspend charge_now series
    -- -- is discontinuous across a step, and whoever reconstructs the
    -- session later needs to SEE the discontinuity rather than infer it.
    write_file(opt.kmsg, ("<0>WILKBOOK: %s"):format(line))
end

-- One full attempt over the configured servers.  Returns true once any
-- of them answered plausibly.
local function sync_once()
    for _, spec in ipairs(opt.servers) do
        local host, port = split_host_port(spec)
        local answer, why = query(host, port, opt.timeout)
        if answer then
            local ok, reason = plausible(answer, opt.not_before, opt.horizon)
            if not ok then
                log("%s answered implausibly: %s -- ignored", spec, reason)
            else
                local before = os.time()
                if opt.dry then
                    print(("WOULD-SET %d"):format(math.floor(answer)))
                    log("dry run: %s answered %d (delta %+.3f s)", spec,
                        math.floor(answer), answer - before)
                    return true
                end
                if not set_system_clock(answer) then
                    log("settimeofday() refused (not root?) -- giving up this pass")
                    return false
                end
                announce(before, answer)
                local rtc_ok, rtc_why = set_rtc()
                if rtc_ok then
                    log("RTC updated from the system clock")
                else
                    log("RTC not updated (%s) -- the correction will not survive a cold boot",
                        tostring(rtc_why))
                end
                return true
            end
        else
            log("%s: %s", spec, tostring(why))
        end
    end
    return false
end

-- ---------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------

if #opt.servers == 0 then
    -- The shipped default.  Reaching a time server is an outbound
    -- connection on a device that otherwise makes none, so it is opt-in
    -- by construction: no server, no socket, no packet, ever.  Exiting
    -- (rather than idling) is why the shepherd service sets respawn? #f.
    log("no --server configured: the clock stays whatever the RTC holds")
    os.exit(0)
end

local last_sync = nil        -- wall seconds of the last successful sync
local backoff = 0            -- 0 while we are on the plain poll interval

while true do
    local due = (last_sync == nil) or ((os.time() - last_sync) >= opt.refresh)
        or ((os.time() - last_sync) < 0)
    local wait = opt.poll
    if due then
        local routes = read_file(opt.route)
        if not opt.skip_route_check and not have_network(routes) then
            -- The common case for this device.  No socket, no log spam,
            -- no backoff growth: there is nothing wrong, there is just no
            -- network, and the next poll is as cheap as this one.
            backoff = 0
        elseif sync_once() then
            last_sync = os.time()
            backoff = 0
        else
            backoff = next_backoff(backoff, opt.poll, opt.max_backoff)
            wait = backoff
        end
    end
    if opt.once then break end
    nap(wait)
end
