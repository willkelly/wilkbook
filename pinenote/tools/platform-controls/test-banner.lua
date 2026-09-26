local path = arg[1] or "../../packages/platform-controls/pinenote-power-broker.lua"
local ffi = require("ffi")
local C, writes, logs, closed, slept = {}, {}, {}, 0, 0
local info, fix, memory, size, fault, calls
local fake_ffi = setmetatable({ C = C }, { __index = ffi })
local fake_io = {
    stderr = { write = function(_, s) logs[#logs + 1] = s end, flush = function() end },
    open = function(name, mode)
        if mode == "r" then
            local value = ({ ["/sys/class/rtc/rtc0/since_epoch"] = "10000",
                ["/sys/power/mem_sleep"] = "[deep]" })[name]
            if not value then return nil end
            return { read = function() return value end, close = function() return true end }
        end
        return { write = function(_, value)
            writes[name] = value
            if name == "/sys/power/state" then slept = slept + 1 end
            return true
        end, close = function() return true end }
    end,
}
function C.open(name) assert(name == "/dev/fb0"); return fault == "open" and -1 or 42 end
function C.ioctl(fd, request, dest)
    assert(fd == 42)
    if fault == "ioctl" then return -1 end
    local value = request == 0x4600 and info or fix
    ffi.copy(dest, value, ffi.sizeof(value)); return 0
end
function C.pwrite(fd, data, len, offset)
    assert(fd == 42 and offset >= 0 and offset + len <= size)
    calls = calls + 1
    if fault == "write" then ffi.errno(5); return -1 end
    if fault == "zero" then return 0 end
    if fault == "partial" then
        if calls == 1 then ffi.errno(4); return -1 end
        len = math.min(len, 7)
    end
    ffi.copy(memory + offset, data, len); return len
end
function C.fsync(fd) assert(fd == 42); return fault == "sync" and -1 or 0 end
function C.close(fd) assert(fd == 42); closed = closed + 1; return fault == "close" and -1 or 0 end
function C.poll() return 0 end
function C.clock_gettime(_, value) value[0].tv_sec, value[0].tv_nsec = 100, 0; return 0 end
local helpers = dofile("broker-fixture.lua")(path, {
    io = fake_io,
    os = setmetatable({ execute = function(cmd) return cmd:find(" status ", 1, true) and 1 or 0 end }, { __index = os }),
    require = function(name)
        if name == "ffi" then return fake_ffi end
        if name == "broker_quiesce" then return { new = function() return { wait = function() return true end } end } end
        return require(name)
    end,
}, "{ banner = fallback_banner, suspend = suspend_transaction }")

local function setup(bpp, w, h)
    info, fix = ffi.new("struct broker_fb_var"), ffi.new("struct broker_fb_fix")
    info.xres, info.yres, info.xres_virtual, info.yres_virtual = w, h, w + 9, h + 7
    info.xoffset, info.yoffset, info.bits_per_pixel = 3, 2, bpp * 8
    info.red.offset, info.red.length = bpp == 2 and 11 or 16, bpp == 2 and 5 or 8
    info.green.offset, info.green.length = bpp == 2 and 5 or 8, bpp == 2 and 6 or 8
    info.blue.length = bpp == 2 and 5 or 8
    fix.visual, fix.line_length = 2, (w + 9) * bpp + 16
    size = tonumber(fix.line_length) * (h + 7) + 31
    fix.smem_len = size - 31
    memory = ffi.new("uint8_t[?]", size); ffi.fill(memory, size, 0x5a)
    writes, logs, closed, slept, calls, fault = {}, {}, 0, 0, 0, nil
end
-- Independent whole-word mask, then check EVERY byte: virtual margins,
-- padding, rows below the banner and guard bytes must keep their sentinel.
local mask = {
    "1111 1001 1111 1110 1111 1001 1110",
    "1000 1001 1000 1001 1000 1101 1001",
    "1000 1001 1000 1001 1000 1101 1001",
    "1111 1001 1111 1110 1110 1011 1001",
    "0001 1001 0001 1000 1000 1011 1001",
    "0001 1001 0001 1000 1000 1001 1001",
    "1111 1111 1111 1000 1111 1001 1110",
}
local function pixels_match(bpp, w, h)
    local stride = tonumber(fix.line_length)
    for offset = 0, size - 1 do
        local y = math.floor(offset / stride) - 2
        local x = math.floor((offset % stride) / bpp) - 3
        local expected = 0x5a
        if y >= 0 and y < math.min(h, 96) and x >= 0 and x < w then
            expected = 255
            if y >= 92 then expected = 0
            elseif y >= 16 and y < 72 and x >= 32 and x < 304 then
                local row, col = math.floor((y - 16) / 8) + 1, math.floor((x - 32) / 8) + 1
                if mask[row]:sub(col, col) == "1" then expected = 0 end
            end
        end
        assert(memory[offset] == expected, ("pixel mismatch byte=%d actual=%d expected=%d"):format(offset, memory[offset], expected))
    end
end
for _, bpp in ipairs({ 2, 4 }) do
    for _, dims in ipairs({ {400, 110}, {35, 18}, {1, 1} }) do
        setup(bpp, unpack(dims)); helpers.banner(); pixels_match(bpp, unpack(dims))
        assert(closed == 1 and #logs == 0)
    end
end
print("PASS: actual RGB565/XRGB8888 banner bytes, padded stride, offsets, clipping and untouched memory")

local bad = {
    function() info.bits_per_pixel = 24 end,
    function() info.red.offset = 0 end,
    function() info.blue.msb_right = 1 end,
    function() info.transp.length = 8 end,
    function() info.grayscale = 1 end,
    function() info.nonstd = 1 end,
    function() info.rotate = 1 end,
    function() info.vmode = 256 end,
    function() fix.type = 1 end,
    function() fix.visual = 3 end,
    function() info.xres = 0 end,
    function() info.yres = 0 end,
    function() info.xres_virtual = 16385 end,
    function() info.yres_virtual = 16385 end,
    function() info.xoffset = 99 end,
    function() info.yoffset = 99 end,
    function() fix.line_length = 1 end,
    function() fix.smem_len = 1 end,
}
for _, mutate in ipairs(bad) do
    setup(2, 35, 18); mutate(); helpers.banner()
    assert(calls == 0 and closed == 1 and #logs > 0)
    assert(ffi.string(memory, size) == string.rep(string.char(0x5a), size))
end
print("PASS: malformed geometry and unsupported formats skip every write")
setup(2, 35, 18); fault = "partial"; helpers.banner(); pixels_match(2, 35, 18)
assert(closed == 1 and #logs == 0)
print("PASS: interrupted and short pwrite complete the exact banner")
for _, failure in ipairs({ "open", "ioctl", "write", "zero", "sync", "close" }) do
    setup(2, 35, 18); fault = failure
    assert(helpers.suspend(true))
    assert(slept == 1 and #logs > 1 and closed == (failure == "open" and 0 or 1))
end
print("PASS: banner I/O failures are logged and still run the fallback suspend transaction")
