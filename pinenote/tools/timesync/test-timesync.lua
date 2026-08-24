-- Host-only tests for the PineNote time-sync daemon (issue #27).
--
-- Two layers, on purpose.
--
--   1. The protocol and policy functions are pulled VERBATIM out of
--      timesync.lua and driven with synthetic packets.  Same contract as
--      the EBC and auto-suspend tools: the shipped source is what
--      executes here, never a paraphrase of it, so an edit that changes
--      behaviour turns this red rather than drifting quietly.
--
--   2. A real end-to-end round trip.  The test binds a UDP socket on
--      loopback, launches the ACTUAL daemon against it, answers one SNTP
--      request with a packet whose time it chose, and requires the
--      daemon's --dry-run output to name that time back.  That is what
--      proves the parts a unit test cannot: the ffi.cdef layouts
--      (sockaddr_in, pollfd, and glibc's struct addrinfo field order --
--      glibc puts ai_addr before ai_canonname, musl the other way, and a
--      wrong guess yields a wrong address rather than a crash), the
--      socket calls, and the nonce echo check against a live exchange.
--      The `localhost' round is the one that exercises getaddrinfo; the
--      `127.0.0.1' round exercises inet_pton and no resolver at all.
--
-- Nothing here needs root, a network, or a device: every packet stays on
-- 127.0.0.1 and the daemon runs --dry-run, so no clock is ever set.
--
-- Usage: luajit test-timesync.lua [timesync.lua] [timesync.scm]

local ffi = require("ffi")
local bit = require("bit")

local source_path = arg[1] or "pinenote/tools/timesync/timesync.lua"
local service_path = arg[2] or "pinenote/services/timesync.scm"
local luajit = arg[-1] or "luajit"

local failures = 0

local function report(ok, label, detail)
    if ok then
        print("PASS: " .. label)
    else
        failures = failures + 1
        print("FAIL: " .. label .. (detail and (" - " .. detail) or ""))
    end
end

-- Extraction failures are fatal rather than counted: every later
-- assertion would be vacuous, and a silently-empty suite is worse than
-- no suite at all.
local function fatal(msg)
    print("FAIL: " .. msg)
    os.exit(1)
end

local function read_lines(path)
    local f = io.open(path, "r")
    if not f then fatal("cannot open " .. path) end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    return lines
end

local lines = read_lines(source_path)

-- `local function name(' at column 0, closed by the first `end' at
-- column 0.
local function extract_function(name)
    local first
    for i, line in ipairs(lines) do
        if line:match("^local function " .. name .. "%(") then first = i break end
    end
    if not first then fatal("no `local function " .. name .. "` in " .. source_path) end
    for i = first + 1, #lines do
        if lines[i] == "end" then
            return table.concat(lines, "\n", first, i)
        end
    end
    fatal(name .. " never closes at column 0 in " .. source_path)
end

local function extract_constant(name)
    for _, line in ipairs(lines) do
        local m = line:match("^local " .. name .. " = [^\n]+")
        if m then return m end
    end
    fatal("no `local " .. name .. " = ...` in " .. source_path)
end

local wanted = {
    "u32be", "put32be", "ntp_to_unix", "build_request", "parse_response",
    "plausible", "next_backoff", "have_network", "rearm_alarm_value",
}

local chunk_parts = {
    "local bit = require('bit')",
    extract_constant("NTP_PACKET_BYTES"),
    extract_constant("NTP_UNIX_DELTA"),
    extract_constant("NTP_ERA_SECONDS"),
}
for _, name in ipairs(wanted) do
    chunk_parts[#chunk_parts + 1] = extract_function(name)
end
chunk_parts[#chunk_parts + 1] = "return {"
for _, name in ipairs(wanted) do
    chunk_parts[#chunk_parts + 1] = ("  %s = %s,"):format(name, name)
end
chunk_parts[#chunk_parts + 1] = "}"

local chunk = loadstring(table.concat(chunk_parts, "\n"),
    "@" .. source_path .. ":extracted")
if not chunk then fatal("extracted source does not compile") end
local T = chunk()

-- ---------------------------------------------------------------------
-- 1. NTP era handling
-- ---------------------------------------------------------------------

-- 2026-08-24T00:00:00Z.
local KNOWN_UNIX = 1787529600
local NTP_DELTA = 2208988800

report(T.ntp_to_unix(KNOWN_UNIX + NTP_DELTA) == KNOWN_UNIX,
    "era 0: an NTP second with the high bit set maps to its Unix second")

-- The wrap instant itself: NTP seconds 0 is 2036-02-07T06:28:16Z, i.e.
-- Unix 2085978496.  Reading it as era 0 would give -2208988800, which is
-- 1900 -- a 136-year error, not a rounding one.
report(T.ntp_to_unix(0) == 2085978496,
    "era 1: NTP seconds 0 is 2036-02-07, not 1900")
report(T.ntp_to_unix(2147483647) == 2147483647 + (4294967296 - NTP_DELTA),
    "era 1: the last era-1 second stays in era 1")
report(T.ntp_to_unix(2147483648) == 2147483648 - NTP_DELTA,
    "era 0 begins exactly at the high bit")

-- ---------------------------------------------------------------------
-- 2. Request shape and reply validation
-- ---------------------------------------------------------------------

local NONCE_HI, NONCE_LO = 0xDEADBEEF, 0x01234567

local request = T.build_request(NONCE_HI, NONCE_LO)
report(#request == 48, "the request is exactly 48 bytes",
    ("got %d"):format(#request))
report(request:byte(1) == 0x23,
    "LI=0 VN=4 Mode=3 (client) in the first octet",
    ("got 0x%02x"):format(request:byte(1)))
report(T.u32be(request, 40) == NONCE_HI and T.u32be(request, 44) == NONCE_LO,
    "the transmit-timestamp field carries the nonce, not a clock reading")
do
    -- Everything except the first octet and the nonce must be zero: a
    -- client that leaks its own (wrong) clock into the packet is exactly
    -- what this daemon is trying not to be.
    local nonzero = 0
    for i = 2, 40 do
        if request:byte(i) ~= 0 then nonzero = nonzero + 1 end
    end
    report(nonzero == 0, "no other field is populated",
        ("%d unexpected non-zero octets"):format(nonzero))
end

local function make_reply(o)
    o = o or {}
    local b = {}
    for i = 1, 48 do b[i] = 0 end
    local li = o.li or 0
    local vn = o.vn or 4
    local mode = o.mode or 4
    b[1] = bit.bor(bit.lshift(li, 6), bit.lshift(vn, 3), mode)
    b[2] = o.stratum or 2
    local function put(off, v)
        b[off + 1] = bit.band(bit.rshift(v, 24), 0xff)
        b[off + 2] = bit.band(bit.rshift(v, 16), 0xff)
        b[off + 3] = bit.band(bit.rshift(v, 8), 0xff)
        b[off + 4] = bit.band(v, 0xff)
    end
    put(24, o.orig_hi or NONCE_HI)
    put(28, o.orig_lo or NONCE_LO)
    put(40, o.tx_secs or (KNOWN_UNIX + NTP_DELTA))
    put(44, o.tx_frac or 0)
    local out = {}
    for i = 1, 48 do out[i] = string.char(b[i]) end
    return table.concat(out)
end

do
    local secs, frac = T.parse_response(make_reply(), NONCE_HI, NONCE_LO)
    report(secs == KNOWN_UNIX and frac == 0,
        "a well-formed reply parses to the server's transmit time")
end

do
    local secs, frac = T.parse_response(
        make_reply({ tx_frac = 2147483648 }), NONCE_HI, NONCE_LO)
    report(secs == KNOWN_UNIX and math.abs(frac - 0.5) < 1e-9,
        "the fraction field is a binary fraction of a second")
end

local rejects = {
    { "a client-mode packet",            { mode = 3 } },
    { "LI=3, the server saying it is itself unsynchronised", { li = 3 } },
    { "stratum 0 (kiss-of-death)",       { stratum = 0 } },
    { "stratum 16 (unsynchronised)",     { stratum = 16 } },
    { "NTP version 2",                   { vn = 2 } },
    { "a zero transmit timestamp",       { tx_secs = 0 } },
    { "a reply that does not echo our nonce", { orig_lo = 0x76543210 } },
}
for _, case in ipairs(rejects) do
    local secs, why = T.parse_response(make_reply(case[2]), NONCE_HI, NONCE_LO)
    report(secs == nil and type(why) == "string",
        "rejected: " .. case[1], tostring(secs))
end
do
    local secs = T.parse_response(make_reply():sub(1, 47), NONCE_HI, NONCE_LO)
    report(secs == nil, "rejected: a truncated packet")
    secs = T.parse_response(nil, NONCE_HI, NONCE_LO)
    report(secs == nil, "rejected: no packet at all")
end

-- ---------------------------------------------------------------------
-- 3. The sanity window
-- ---------------------------------------------------------------------

local NOT_BEFORE, HORIZON = 1767225600, 630720000   -- 2026-01-01, 20 years
report(T.plausible(KNOWN_UNIX, NOT_BEFORE, HORIZON) == true,
    "a 2026 answer is inside the sanity window")
report(T.plausible(0, NOT_BEFORE, HORIZON) == false,
    "a 1970 answer is refused (the classic reset-RTC value)")
report(T.plausible(NOT_BEFORE - 1, NOT_BEFORE, HORIZON) == false,
    "the floor is exclusive below")
report(T.plausible(NOT_BEFORE, NOT_BEFORE, HORIZON) == true,
    "the floor itself is accepted")
report(T.plausible(NOT_BEFORE + HORIZON + 1, NOT_BEFORE, HORIZON) == false,
    "an answer past the horizon is refused")
-- Era 1 begins in 2036, which is INSIDE a twenty-year window opened in
-- 2026 -- so the sanity window does not, and cannot, protect against an
-- era misreading.  ntp_to_unix() is the only thing that does.  What the
-- window does catch is the era-0 misreading of the same value, which
-- lands in 1900.
report(T.plausible(T.ntp_to_unix(0), NOT_BEFORE, HORIZON) == true,
    "the window does NOT catch era confusion: 2036 is a plausible date")
report(T.plausible(0 - NTP_DELTA, NOT_BEFORE, HORIZON) == false,
    "the 1900 an era-0 misreading would produce is refused")

-- ---------------------------------------------------------------------
-- 4. Backoff: an unreachable server must cost less over time, not more
-- ---------------------------------------------------------------------

do
    local base, cap = 120, 3600
    local seen = {}
    local b = 0
    for _ = 1, 8 do
        b = T.next_backoff(b, base, cap)
        seen[#seen + 1] = b
    end
    report(seen[1] == 120 and seen[2] == 240 and seen[3] == 480,
        "the first failure waits one poll interval, then doubles")
    report(seen[#seen] == cap, "the backoff saturates at the cap",
        tostring(seen[#seen]))
    local monotone = true
    for i = 2, #seen do
        if seen[i] < seen[i - 1] then monotone = false end
    end
    report(monotone, "the backoff never shrinks while failures continue")
    report(T.next_backoff(3600, 120, 3600) == 3600,
        "a saturated backoff stays saturated rather than overflowing")
end

-- ---------------------------------------------------------------------
-- 5. The no-network path -- the common case, and a power-safety property
-- ---------------------------------------------------------------------

local HEADER = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask"
report(T.have_network(HEADER .. "\n") == false,
    "an empty route table is no network (and the HEADER is not an interface)")
report(T.have_network(HEADER ..
    "\nlo\t0000007F\t00000000\t0001\t0\t0\t0\t000000FF\t0\t0\t0\n") == false,
    "a loopback-only route table is still no network")
report(T.have_network(HEADER ..
    "\nwlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n") == true,
    "a wlan0 route is a network")
report(T.have_network(HEADER ..
    "\nlo\t0000007F\t00000000\t0001\t0\t0\t0\t000000FF\t0\t0\t0" ..
    "\nwlan0\t0001A8C0\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0\n") == true,
    "an on-link LAN route counts: a default route is NOT required")
report(T.have_network(nil) == false,
    "an unreadable route table is no network, not an excuse to send")

-- ---------------------------------------------------------------------
-- 6. The RTC backstop foot-gun
-- ---------------------------------------------------------------------

do
    -- autosuspend.lua arms the backstop as `since_epoch + N', an ABSOLUTE
    -- value in the RTC's own seconds.  Stepping the RTC forward past a
    -- pending alarm makes the compare never match -- the wake silently
    -- never happens -- so the interval, not the instant, is what has to
    -- survive.
    local before, after = 1000000, 1000000 + 86400   -- RTC stepped +1 day
    local alarm = before + 3600                      -- an hour out
    report(T.rearm_alarm_value(alarm, before, after) == after + 3600,
        "a pending alarm keeps its remaining interval across an RTC step")

    local back = before - 86400                      -- RTC stepped -1 day
    report(T.rearm_alarm_value(alarm, before, back) == back + 3600,
        "the same holds for a backward step")

    report(T.rearm_alarm_value(nil, before, after) == nil,
        "no pending alarm, nothing to re-arm")
    report(T.rearm_alarm_value(0, before, after) == nil,
        "a cleared alarm (0) is not re-armed")
    report(T.rearm_alarm_value(before - 5, before, after) == nil,
        "an already-expired alarm is left alone, not resurrected")
    report(T.rearm_alarm_value(alarm, before, nil) == nil,
        "an unreadable RTC means we do not guess at a new alarm")
end

-- ---------------------------------------------------------------------
-- 7. End to end against the real daemon over loopback
-- ---------------------------------------------------------------------

ffi.cdef [[
int socket(int domain, int type, int protocol);
int bind(int fd, const struct tt_sa *addr, unsigned int len);
int close(int fd);
int poll(struct tt_pollfd *fds, unsigned long nfds, int timeout);
long recvfrom(int fd, void *buf, unsigned long len, int flags,
              struct tt_sa *src, unsigned int *srclen);
long sendto(int fd, const void *buf, unsigned long len, int flags,
            const struct tt_sa *dest, unsigned int addrlen);
int inet_pton(int af, const char *src, void *dst);
struct tt_sa {
    unsigned short sin_family;
    unsigned short sin_port;
    unsigned int   sin_addr;
    unsigned char  sin_zero[8];
};
struct tt_pollfd { int fd; short events; short revents; };
]]

local AF_INET, SOCK_DGRAM, POLLIN = 2, 2, 1

local function htons(v)
    return bit.bor(bit.band(bit.lshift(v, 8), 0xff00), bit.band(bit.rshift(v, 8), 0xff))
end

local function loopback_addr()
    local a = ffi.new("unsigned int[1]")
    if ffi.C.inet_pton(AF_INET, "127.0.0.1", a) ~= 1 then
        fatal("inet_pton could not parse 127.0.0.1")
    end
    return a[0]
end

-- Bind a UDP socket somewhere in an unprivileged range; the exact port
-- does not matter, only that we know it.
local function bind_server()
    local fd = ffi.C.socket(AF_INET, SOCK_DGRAM, 0)
    if fd < 0 then fatal("could not create a UDP socket") end
    local sa = ffi.new("struct tt_sa")
    sa.sin_family = AF_INET
    sa.sin_addr = loopback_addr()
    for port = 12300, 12399 do
        sa.sin_port = htons(port)
        if ffi.C.bind(fd, sa, ffi.sizeof(sa)) == 0 then return fd, port end
    end
    ffi.C.close(fd)
    fatal("no free UDP port in 12300-12399")
end

local function slurp(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*a")
    f:close()
    return v
end

local tmp = os.tmpname()

-- Serve exactly one request, replying with `reply_opts', and return what
-- the daemon printed.  `host' is what we tell the daemon to talk to:
-- "127.0.0.1" takes the inet_pton path, "localhost" the getaddrinfo one.
local function round_trip(host, reply_opts, extra_args)
    local fd, port = bind_server()
    local out = tmp .. "." .. tostring(port)
    os.remove(out)
    local cmd = ("%s %s --once --dry-run --skip-route-check --quiet " ..
        "--server %s:%d --not-before %d --horizon %d %s")
        :format(luajit, source_path, host, port, NOT_BEFORE, HORIZON,
            extra_args or "")
    os.execute(("{ %s > %s 2>&1; echo \"EXIT=$?\" >> %s; } &")
        :format(cmd, out, out))

    local pfd = ffi.new("struct tt_pollfd[1]")
    pfd[0].fd = fd
    pfd[0].events = POLLIN
    local got_request, echo_hi, echo_lo = false, nil, nil
    if tonumber(ffi.C.poll(pfd, 1, 20000)) > 0 then
        local buf = ffi.new("unsigned char[?]", 512)
        local src = ffi.new("struct tt_sa")
        local srclen = ffi.new("unsigned int[1]", ffi.sizeof(src))
        local n = tonumber(ffi.C.recvfrom(fd, buf, 512, 0, src, srclen))
        if n and n == 48 then
            got_request = true
            local s = ffi.string(buf, n)
            echo_hi = T.u32be(s, 40)
            echo_lo = T.u32be(s, 44)
            local reply = make_reply(reply_opts)
            -- Echo the daemon's OWN nonce back, which is the whole point
            -- of the field; make_reply's defaults are the unit-test
            -- nonce and would (correctly) be rejected.
            if not (reply_opts and reply_opts.break_nonce) then
                local o = {}
                for k, v in pairs(reply_opts or {}) do o[k] = v end
                o.orig_hi, o.orig_lo = echo_hi, echo_lo
                reply = make_reply(o)
            end
            ffi.C.sendto(fd, reply, #reply, 0, src, srclen[0])
        end
    end
    ffi.C.close(fd)

    -- Wait for the daemon to finish (it appends EXIT= itself).
    local text
    for _ = 1, 200 do
        text = slurp(out) or ""
        if text:find("EXIT=", 1, true) then break end
        os.execute("sleep 0.1")
    end
    os.remove(out)
    return got_request, text or ""
end

do
    local ok, text = round_trip("127.0.0.1", {})
    report(ok, "the daemon sent a 48-byte SNTP request to the configured server")
    report(text:find("WOULD%-SET " .. KNOWN_UNIX) ~= nil,
        "end to end: the daemon reports exactly the time the server sent",
        text)
    report(text:find("EXIT=0", 1, true) ~= nil,
        "the daemon exits 0 after a successful --once pass", text)
end

do
    -- The getaddrinfo path.  If glibc's struct addrinfo were laid out
    -- differently from the ffi.cdef, sin_addr would be garbage and this
    -- packet would never reach the socket we are holding.
    local ok, text = round_trip("localhost", {})
    report(ok, "a hostname resolves and the request arrives (glibc addrinfo layout)")
    report(text:find("WOULD%-SET " .. KNOWN_UNIX) ~= nil,
        "end to end via getaddrinfo: the answer round-trips", text)
end

do
    -- 1970.  A device whose RTC has reset and a server that agrees with
    -- it must not produce a "successful" sync.
    local ok, text = round_trip("127.0.0.1", { tx_secs = NTP_DELTA })
    report(ok, "the daemon queried before judging the answer")
    report(text:find("WOULD%-SET") == nil,
        "an implausible answer sets nothing", text)
    report(text:find("EXIT=0", 1, true) ~= nil,
        "an implausible answer is not a crash: still exit 0", text)
end

do
    -- A packet that does not echo the nonce is a stale or forged reply.
    local ok, text = round_trip("127.0.0.1", { break_nonce = true })
    report(ok, "the daemon queried before judging the echo")
    report(text:find("WOULD%-SET") == nil,
        "a reply that does not echo the nonce sets nothing", text)
end

os.remove(tmp)

-- ---------------------------------------------------------------------
-- 8. The service's defaults are the ones that reach the device
-- ---------------------------------------------------------------------

do
    local scm = slurp(service_path)
    if not scm then
        fatal("cannot open " .. service_path)
    end

    -- A field name here contains a hyphen, which is a Lua pattern
    -- quantifier.  Escaping it is not cosmetic: unescaped, every one of
    -- these matches nothing and the whole cross-check passes vacuously.
    local function esc(s) return (s:gsub("%-", "%%-")) end

    local function scm_default(field)
        return tonumber(scm:match("%(" .. esc(field) ..
            "%s+pinenote%-timesync%-[%w%-?]+%s*%(default%s+(%-?%d+)%)"))
    end

    local function lua_default(field)
        for _, line in ipairs(lines) do
            local v = line:match("^%s+" .. esc(field) .. " = (%-?%d+),")
            if v then return tonumber(v) end
        end
        return nil
    end

    local pairs_to_check = {
        { "poll-seconds", "poll" },
        { "refresh-seconds", "refresh" },
        { "timeout-seconds", "timeout" },
        { "max-backoff-seconds", "max_backoff" },
        { "not-before", "not_before" },
        { "horizon-seconds", "horizon" },
    }
    for _, p in ipairs(pairs_to_check) do
        local s, l = scm_default(p[1]), lua_default(p[2])
        report(s ~= nil and s == l,
            ("service and daemon agree on %s"):format(p[1]),
            ("scm=%s lua=%s"):format(tostring(s), tostring(l)))
    end

    -- The shipped default must make no outbound connection at all.  This
    -- is the decision issue #27 asks to be deliberate about, so it is
    -- pinned rather than left to a comment.
    report(scm:find("%(servers%s+pinenote%-timesync%-servers%s*%(default%s+'%(%)%)%)") ~= nil,
        "the service ships with NO servers configured: opt-in by construction")

    -- quirk: the RTC backstop re-arm must be VERIFIED, not assumed.
    -- Shipped once (2026-08-24) discarding both write_file returns and
    -- logging "re-armed ..." unconditionally, so a failed re-arm left the
    -- device with no timer wake and said it had succeeded.  The backstop
    -- is the self-recovery net (doc/power-management.md), so this is a
    -- safety property, not tidiness.  set_rtc touches real sysfs and
    -- cannot be executed here; pin it structurally instead.
    local daemon_src = slurp(source_path) or ""
    local rearm_block = daemon_src:match("if%s+rearm%s+then(.-)\n%s*end")
    report(rearm_block ~= nil, "set_rtc has a re-arm block to inspect")
    if rearm_block then
        report(rearm_block:find("local%s+armed%s*=%s*write_file") ~= nil,
            "quirk: the re-arm captures write_file's result instead of discarding it")
        report(rearm_block:find("read_number") ~= nil,
            "quirk: the re-arm reads the alarm back")
        report(rearm_block:find("if%s+armed%s+and%s+got%s*==") ~= nil,
            "quirk: success is logged only when the readback matches what was armed")
        report(rearm_block:find("RE%-ARM FAILED") ~= nil,
            "quirk: a failed re-arm is logged loudly")
    end
end

if failures > 0 then
    print(("\n%d check(s) failed"):format(failures))
    os.exit(1)
end
print("\nAll timesync checks passed.")
