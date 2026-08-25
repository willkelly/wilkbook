local ffi = require("ffi")
local path = arg[1] or "pinenote/packages/koreader-device/frontend/device/pinenote/ebc_barrier.lua"
local module = assert(loadfile(path))()
local failures = 0

local function check(ok, label)
    print((ok and "PASS: " or "FAIL: ") .. label)
    if not ok then failures = failures + 1 end
end

local function high_id(delta)
    return ffi.new("uint64_t", 0x200000) * ffi.new("uint64_t", 0x100000000) + (delta or 1)
end

local function fake(options)
    options = options or {}
    local calls, id = {}, high_id()
    -- Deliberately NOT card0: the adapter must use the injected card
    -- verbatim (the EBC's card index is not stable across images), and
    -- an injected card0 could not tell "uses the option" from a hidden
    -- hardcode.
    local ops = {
        card = "/dev/dri/card9",
        timeout_ms = options.timeout_ms,
        errno = options.errno or function() return 5 end,
    }
    ops.open = options.open or function(card, flags)
        calls[#calls + 1] = "open:" .. card .. ":" .. flags
        return 17
    end
    ops.ioctl = options.ioctl or function(fd, request, arg)
        local barrier = arg[0]
        calls[#calls + 1] = "ioctl:" .. barrier.op
        check(fd == 17 and request == 0xC0286443, "ioctl uses exact fd and request")
        check(barrier.version == 1 and barrier.result == 0 and barrier.reserved[0] == 0
            and barrier.reserved[1] == 0 and barrier.reserved[2] == 0 and barrier.reserved[3] == 0,
            "ioctl input zeroes output and reserved fields")
        if barrier.op == 1 then
            check(barrier.timeout_ms == 0 and barrier.request_id == 0, "SUBMIT has kernel-compatible zero timeout and ID")
            barrier.request_id, barrier.result = id, -115
        else
            check(barrier.timeout_ms == (options.timeout_ms or 10000) and barrier.request_id == id,
                "WAIT has configured timeout and exact cdata ID")
            barrier.result = 0
        end
        return 0
    end
    ops.close = options.close or function(fd) calls[#calls + 1] = "close:" .. fd; return 0 end
    return ops, calls, id
end

do
    local ops, calls, id = fake()
    local adapter = module.new(ops)
    local ok, returned, extra = adapter:submit_and_wait()
    check(ok == true and type(returned) == "cdata" and returned == id and extra == nil
        and table.concat(calls, ",") == "open:/dev/dri/card9:524290,ioctl:1,ioctl:2,close:17"
        and adapter:status().state == "IDLE", "successful transaction returns exact high cdata ID after close")
    check(adapter:submit_and_wait() and #calls == 8, "sequential successful transactions")
end

do
    local ops, calls, id = fake()
    local adapter, nested, active_state
    ops.open = function(card, flags)
        calls[#calls + 1] = "open:" .. card .. ":" .. flags
        nested = { adapter:submit_and_wait("extra") }
        active_state = adapter:status().state
        return 17
    end
    adapter = module.new(ops)
    check(adapter:submit_and_wait("extra") == false and #calls == 0 and adapter:status().state == "IDLE",
        "IDLE extra arguments are side-effect-free and non-poisoning")
    local ok, returned = adapter:submit_and_wait()
    check(ok and returned == id and nested[1] == false and active_state == "ACTIVE" and #calls == 4
        and adapter:status().state == "IDLE", "ACTIVE reentry invokes zero nested operations")
end

do
    local ops = fake({ timeout_ms = 77 })
    local adapter = module.new(ops)
    check(adapter:submit_and_wait(), "configured finite WAIT timeout succeeds")
end

local function poisoned(label, configure, expected)
    local ops, calls = fake()
    configure(ops, calls)
    local adapter = module.new(ops)
    local ok, err = adapter:submit_and_wait()
    local before = #calls
    check(not ok and tostring(err):find(expected, 1, true) and adapter:status().state == "POISONED"
        and not adapter:submit_and_wait() and #calls == before, label)
end

poisoned("open failure has no close", function(ops) ops.open = function() return -1 end end, "invalid fd")
poisoned("open throw poisons", function(ops) ops.open = function() error("boom") end end, "open threw")
poisoned("SUBMIT syscall failure reports errno", function(ops) ops.ioctl = function() return -1 end end, "errno 5")
poisoned("SUBMIT throw closes", function(ops) ops.ioctl = function() error("boom") end end, "SUBMIT ioctl threw")
poisoned("WAIT syscall failure reports errno", function(ops)
    local base = ops.ioctl
    ops.ioctl = function(fd, request, arg)
        if arg[0].op == 2 then return -1 end
        return base(fd, request, arg)
    end
end, "WAIT ioctl returned -1 (errno 5)")
poisoned("WAIT EINPROGRESS is the finite timeout", function(ops)
    local base = ops.ioctl
    ops.ioctl = function(fd, request, arg)
        local result = base(fd, request, arg)
        if arg[0].op == 2 then arg[0].result = -115 end
        return result
    end
end, "WAIT timed out (-EINPROGRESS)")
poisoned("SUBMIT kernel rejection preserves result", function(ops)
    ops.ioctl = function(_, _, arg) arg[0].result = -19; return 0 end
end, "SUBMIT rejected (-19)")
poisoned("WAIT kernel failure preserves result", function(ops)
    local base = ops.ioctl
    ops.ioctl = function(fd, request, arg)
        local result = base(fd, request, arg)
        if arg[0].op == 2 then arg[0].result = -5 end
        return result
    end
end, "WAIT failed (-5)")
poisoned("close failure poisons", function(ops) ops.close = function() return -1 end end, "close returned")

for _, case in ipairs({
    { "version", function(b) b.version = 2 end }, { "op", function(b) b.op = 2 end },
    { "timeout", function(b) b.timeout_ms = 1 end }, { "reserved", function(b) b.reserved[0] = 1 end },
    { "id", function(b) b.request_id = 0 end }, { "result", function(b) b.result = 0 end },
}) do
    poisoned("malformed SUBMIT " .. case[1], function(ops)
        ops.ioctl = function(_, _, arg)
            arg[0].request_id, arg[0].result = high_id(), -115
            case[2](arg[0])
            return 0
        end
    end, (case[1] == "id" or case[1] == "result") and "unexpected SUBMIT result" or "malformed SUBMIT response")
end

for _, case in ipairs({
    { "version", function(b) b.version = 2 end }, { "op", function(b) b.op = 1 end },
    { "timeout", function(b) b.timeout_ms = 1 end }, { "reserved", function(b) b.reserved[2] = 1 end },
    { "id", function(b) b.request_id = high_id(2) end }, { "result", function(b) b.result = 1 end },
}) do
    poisoned("malformed WAIT " .. case[1], function(ops)
        local base = ops.ioctl
        ops.ioctl = function(fd, request, arg)
            local result = base(fd, request, arg)
            if arg[0].op == 2 then case[2](arg[0]) end
            return result
        end
    end, case[1] == "result" and "unexpected WAIT result 1" or "malformed WAIT response")
end

for _, value in ipairs({ 0, -1, 1.5, 0x100000000 }) do
    -- card is present so the rejection can only come from the timeout.
    local ok = pcall(module.new, { card = "/dev/dri/card9", timeout_ms = value })
    check(not ok, "invalid timeout " .. tostring(value) .. " rejected")
end
check(not pcall(module.new, { card = "/dev/dri/card9", unexpected = true }),
    "unknown option rejected")
-- card has NO default: the EBC's DRM card index is not stable across
-- images, so the caller must resolve it (device.lua's findEbcCard).
check(not pcall(module.new, {}), "missing card rejected")
check(pcall(module.new, { card = "/dev/dri/card9" }), "explicit card accepted")

do
    local source = assert(io.open(path, "r")):read("*a")
    check(source:find("0xC0286443", 1, true) and source:find("O_RDWR_CLOEXEC", 1, true)
        and not source:find("tonumber", 1, true), "source pins ABI and preserves cdata IDs")
end

if failures > 0 then print("RESULT: failed"); os.exit(1) end
print("RESULT: ok")
