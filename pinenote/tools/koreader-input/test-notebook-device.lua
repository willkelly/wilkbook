--[[--
Host harness for device.lua's notebook support (offline ladder, rung 1).

What the notebook plugin leans on in the PineNote device target and its
evdev backend, exercised under the koreader-bin bundle's own luajit:

 1. the RECT_HINTS packers, byte for byte against the ebc-lab's pinned
    ones (pinenote/tools/ebc-lab/ebclib.lua), including what the hint
    owner hands the ioctl: the request number, the 16-byte header with
    its pointer, and the rect array behind that pointer;
 2. the hint owner's state: arm / disarm / reset, the refusal after a
    failed arm, and that it issues nothing at all off the direct driver
    (command 0x03 is REFRESH_BARRIER on the shipping one);
 3. the refresh-layer guard in all four rotations, on the bundle's real
    Blitbuffer: logical rects are bounded and converted to physical, and
    only a refresh that reaches a non-default hint disarms.  The expected
    logical rects are derived from the rotation table in the notebook's
    contract, not from Blitbuffer, so the two are checked against each
    other;
 4. the rest of the seam: the direct-driver probe, publishNow, the one
    consumer hook (N consumer set/clear cycles still call it once per
    event), the rotation hold with takePendingRotation, and the evdev
    backend's EVIOCGKEY constant and key-bit decoding;
 5. edges: the pen scaling over the whole digitizer range, arms that
    must be refused rather than thrown (NaN, infinities, non-tables), a
    failed reset, shared edges and the last logical pixel in every
    rotation, rotation 1 against 3, and the chain as init builds it
    driven through the bundle's real Input:waitEvent (pen and touch
    consumed, SYN_DROPPED and a tool switch mid-stroke, a held rotation,
    then close and a tap from a sparse kernel slot).

init() cannot run on a host, so everything here goes through the
PineNote._* exports; test-refresh-seam.lua pins how init wires them.
Section 5's chain loads mixedrouter.lua and slotguard.lua from
device.lua's own directory.

Usage: luajit test-notebook-device.lua /path/to/bundle/lib/koreader \
           /path/to/repo/.../device/pinenote/device.lua \
           /path/to/repo/pinenote/tools/ebc-lab/ebclib.lua \
           /path/to/repo/pinenote/packages/koreader-device/ffi/input_evdev.lua
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local device_lua_path = assert(arg[2], "arg2: path to pinenote device.lua")
local ebclib_path = assert(arg[3], "arg3: path to ebc-lab ebclib.lua")
local input_evdev_path = assert(arg[4], "arg4: path to repo ffi/input_evdev.lua")

package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

local noop = function() end
-- Captured, so the owner's warn-once behaviour can be counted.
local log_lines = {}
local function log_capture(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    log_lines[#log_lines + 1] = table.concat(parts, " ")
end
local function log_count(needle)
    local n = 0
    for _, line in ipairs(log_lines) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end
package.preload["logger"] = function()
    return setmetatable({
        dbg = noop, info = log_capture, warn = log_capture, err = log_capture,
        LvDEBUG = noop, setLevel = noop,
    }, { __call = noop })
end
package.preload["dbg"] = function()
    local dbg = { is_on = false, ev_log = noop }
    function dbg:guard() end
    function dbg:dassert(check) return check end
    return setmetatable(dbg, { __call = noop })
end
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/nonexistent/koreader-settings" end,
        getDataDir = function() return "/nonexistent/koreader-data" end,
    }
end
package.preload["gettext"] = function()
    local identity = function(_, s) return s end
    return setmetatable({
        ngettext = function(_, s) return s end,
        pgettext = function(_, _, s) return s end,
    }, { __call = identity })
end
package.preload["util"] = function()
    return { tableDeepCopy = function(t) return t end }
end
package.preload["ffi/framebuffer"] = function()
    return {
        DEVICE_ROTATED_UPRIGHT = 0,
        DEVICE_ROTATED_CLOCKWISE = 1,
        DEVICE_ROTATED_UPSIDE_DOWN = 2,
        DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
    }
end
package.preload["ffi/archiver"] = function() return {} end
G_reader_settings = {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    isFalse = function() return false end,
    nilOrTrue = function() return true end,
    has = function() return false end,
}

local ffi = require("ffi")
local PineNote = dofile(device_lua_path)
local lib = dofile(ebclib_path)
local evdev = dofile(input_evdev_path)
local BB = require("ffi/blitbuffer")
local Input = require("device/input")

local device_src do
    local f = assert(io.open(device_lua_path, "r"))
    device_src = f:read("*a")
    f:close()
end
local evdev_src do
    local f = assert(io.open(input_evdev_path, "r"))
    evdev_src = f:read("*a")
    f:close()
end

local fail = 0
local function report(ok, label, msg)
    print(string.format("%s: %s: %s", ok and "PASS" or "FAIL", label, msg or ""))
    if not ok then fail = fail + 1 end
end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local W, H = 1872, 1404

------------------------------------------------------------------------
-- 1. Packers against ebclib.
------------------------------------------------------------------------

local header_vectors = {
    { true, 32, 0 }, { true, 32, 1 }, { true, 32, 2 }, { true, 0, 0 },
    { false, 0, 0 }, { true, 160, 5 }, { true, 32, 4096 },
}
for _, v in ipairs(header_vectors) do
    local ours = PineNote._packRectHintsHeader(v[1], v[2], v[3])
    local theirs = lib.pack_rect_hints_header(v[1], v[2], v[3])
    report(#ours == 16 and ours == theirs,
           string.format("header(%s,%d,%d) matches ebclib", tostring(v[1]), v[2], v[3]),
           hex(ours))
end

local rect_vectors = {
    { 0x00, 0, 0, W, H },           -- the whole panel
    { 0x20, 400, 300, 640, 480 },   -- a panel-sized rect at the default
    { 0x00, 0, 0, 1, 1 },           -- one pixel: x2/y2 exclusive
    { 0xff, W - 1, H - 1, 1, 1 },   -- the last pixel
    { 0x40, 10, 20, 30, 40 },
    { 0x00, -5, -7, 20, 30 },       -- negative origin: s32 two's complement
}
for _, v in ipairs(rect_vectors) do
    local ours = PineNote._packRectHint(v[1], v[2], v[3], v[4], v[5])
    local theirs = lib.pack_rect_hint(v[1], v[2], v[3], v[4], v[5])
    report(#ours == 24 and ours == theirs,
           string.format("rect(0x%02x,%d,%d,%d,%d) matches ebclib",
                         v[1], v[2], v[3], v[4], v[5]),
           hex(ours))
end

------------------------------------------------------------------------
-- 2. The hint owner, through a recording ioctl.
------------------------------------------------------------------------

-- What the driver would read: the header as passed, the pointer in it,
-- and the rect array read back THROUGH that pointer.
local function recorder()
    local rec = { calls = {}, ret = 0, errno = nil }
    rec.ioctl = function(request, arg)
        local raw = ffi.string(ffi.cast("const uint8_t *", arg), 16)
        local ptr = ffi.cast("const uint64_t *", arg)[1]
        local n = raw:byte(5) + raw:byte(6) * 256 + raw:byte(7) * 65536
            + raw:byte(8) * 16777216
        local rects = ""
        if ptr ~= 0 and n > 0 then
            rects = ffi.string(ffi.cast("const uint8_t *", ptr), 24 * n)
        end
        rec.calls[#rec.calls + 1] = {
            request = request,
            header = raw:sub(1, 8) .. string.rep("\0", 8),
            has_ptr = ptr ~= 0,
            n = n,
            rects = rects,
        }
        if rec.ret < 0 then return rec.ret, rec.errno end
        return rec.ret
    end
    return rec
end

local function new_owner(rec, is_direct, bb_fn)
    return PineNote._newHintOwner{
        ioctl = rec and rec.ioctl, is_direct = is_direct, bb = bb_fn,
    }
end

local CANVAS = { x = 0, y = 0, w = W, h = H, hint = 0x00 }
local PANEL = { x = 1400, y = 100, w = 300, h = 400, hint = 0x20 }

do
    local rec = recorder()
    local owner = new_owner(rec, true)
    report(owner:is_armed() == false and #rec.calls == 0,
           "owner starts disarmed and silent", "")
    report(owner:arm({ CANVAS, PANEL }) == true and owner:is_armed(),
           "arm canvas 0x00 + panel 0x20 succeeds", "")
    local c = rec.calls[1]
    report(#rec.calls == 1 and c.request == lib.RECT_HINTS_IOCTL
           and c.request == 0x40106443,
           "arm issues ONE ioctl with ebclib's RECT_HINTS number",
           string.format("0x%08X", c and c.request or 0))
    report(c and c.header == lib.pack_rect_hints_header(true, 32, 2),
           "arm header is {set_default=1, default=32, num_rects=2}",
           c and hex(c.header) or "")
    report(c and c.has_ptr and c.rects == lib.pack_rect_hint(0x00, 0, 0, W, H)
           .. lib.pack_rect_hint(0x20, PANEL.x, PANEL.y, PANEL.w, PANEL.h),
           "arm rects behind the pointer match ebclib, in order", "48 bytes")

    report(owner:disarm() == true and not owner:is_armed() and #rec.calls == 2,
           "disarm issues one ioctl", "")
    c = rec.calls[2]
    report(c.header == lib.pack_rect_hints_header(true, 32, 0) and not c.has_ptr,
           "disarm is {set_default=1, default=32, num_rects=0}, null pointer",
           hex(c.header))
    report(owner:disarm() == true and #rec.calls == 2,
           "disarm with nothing armed issues nothing", "")
    report(owner:reset() == true and #rec.calls == 3
           and rec.calls[3].header == lib.pack_rect_hints_header(true, 32, 0),
           "reset disarms unconditionally", "")

    -- Fractional input is widened to whole pixels, never narrowed.
    owner:arm({ { x = 10.5, y = 20.2, w = 5, h = 5, hint = 0 } })
    report(rec.calls[4].rects == lib.pack_rect_hint(0, 10, 20, 6, 6),
           "arm floors the origin and ceils the far edge", "10,20 -> 16,26")
    owner:disarm()
    local before = #rec.calls
    report(owner:arm({}) == true and #rec.calls == before and not owner:is_armed(),
           "arm of no rects is a disarm (nothing armed: no ioctl)", "")
    report(owner:arm({ { x = 1, y = 2, w = 3, hint = 0 } }) == false
           and #rec.calls == before and not owner:is_armed(),
           "arm refuses a malformed rect without an ioctl", "")
end

-- The reading hint is the running system's, not a copy of the service's
-- value: an owner built on another default restores that one, and a
-- refresh over a rect armed at it is no hit.
do
    local function hint_file(s)
        local path = os.tmpname()
        local f = assert(io.open(path, "w"))
        f:write(s)
        f:close()
        return path
    end
    local got = {}
    for _, case in ipairs({ { "32\n", 32 }, { "160\n", 160 }, { " 64 \n", 64 },
                            { "256\n", nil }, { "-1\n", nil }, { "0x20\n", nil },
                            { "", nil } }) do
        local path = hint_file(case[1])
        local v = PineNote._readDefaultHint(path)
        os.remove(path)
        if v ~= case[2] then got[#got + 1] = string.format("%q->%s", case[1], tostring(v)) end
    end
    report(#got == 0, "readDefaultHint: a hint byte, or nil for anything else",
           table.concat(got, " "))
    local absent = os.tmpname()
    os.remove(absent)
    report(PineNote._readDefaultHint(absent) == nil,
           "readDefaultHint: an absent parameter is nil", "")

    local rec = recorder()
    local owner = PineNote._newHintOwner{ ioctl = rec.ioctl, is_direct = true,
                                          reading_hint = 64,
                                          bb = function() return nil end }
    owner:arm({ CANVAS, { x = 1400, y = 100, w = 300, h = 400, hint = 64 } })
    owner:disarm()
    report(rec.calls[1].header == lib.pack_rect_hints_header(true, 64, 2)
           and rec.calls[2].header == lib.pack_rect_hints_header(true, 64, 0),
           "arm and disarm write the owner's reading hint as the default",
           hex(rec.calls[2].header))
    local sbb = BB.new(W, H, BB.TYPE_BB8)
    local guarded = PineNote._newHintOwner{ ioctl = rec.ioctl, is_direct = true,
                                            reading_hint = 64,
                                            bb = function() return sbb end }
    guarded:arm({ { x = 0, y = 0, w = 100, h = 100, hint = 0x00 },
                  { x = 1000, y = 1000, w = 100, h = 100, hint = 64 } })
    report(guarded:guard(1000, 1000, 50, 50) == false and guarded:is_armed(),
           "a refresh over a rect at the reading hint is no hit", "")
    guarded:disarm()
    guarded:arm({ { x = 1000, y = 1000, w = 100, h = 100, hint = 32 } })
    report(guarded:guard(1000, 1000, 50, 50) == true and not guarded:is_armed(),
           "with reading hint 64, a rect at 32 is a hit and disarms", "")
    sbb:free()
end

-- Off the direct driver the owner never reaches the ioctl.
do
    local rec = recorder()
    local owner = new_owner(rec, false)
    local results = {
        owner:arm({ CANVAS }), owner:disarm(), owner:reset(),
        owner:guard(0, 0, W, H), owner:is_armed(),
    }
    report(results[1] == false and results[2] == true and results[3] == true
           and results[4] == false and results[5] == false and #rec.calls == 0,
           "not direct: arm refused, disarm/reset/guard inert, no ioctl", "0 calls")
    local inert = new_owner(nil, true)
    report(inert:arm({ CANVAS }) == false and inert:reset() == true
           and not inert:is_armed(),
           "direct but no card: inert", "")
end

-- A failed call: warn once per streak, keep guarding, refuse to re-arm
-- until reset().
do
    local rec = recorder()
    local owner = new_owner(rec, true, function() return nil end)
    rec.ret, rec.errno = -1, 22
    local warns = log_count("[pn-hint] arm failed")
    report(owner:arm({ CANVAS }) == false and owner:is_armed() and #rec.calls == 1,
           "failed arm returns false and still counts as armed", "")
    report(log_count("[pn-hint] arm failed") == warns + 1,
           "failed arm logs one warning with the errno",
           log_lines[#log_lines])
    report(owner:arm({ CANVAS }) == false and #rec.calls == 1,
           "after a failed arm, arm is refused without an ioctl", "")
    local disarm_warns = log_count("[pn-hint] disarm failed")
    report(owner:guard(0, 0, 10, 10) == true and #rec.calls == 2
           and owner:is_armed()
           and log_count("[pn-hint] disarm failed") == disarm_warns,
           "a failing disarm keeps it armed; the streak logs no second warning", "")
    rec.ret = 0
    report(owner:disarm() == true and not owner:is_armed() and #rec.calls == 3,
           "the next disarm that succeeds clears it", "")
    report(owner:arm({ CANVAS }) == false and #rec.calls == 3,
           "arming stays refused after a successful disarm", "")
    report(owner:reset() == true and owner:arm({ CANVAS }) == true
           and #rec.calls == 5,
           "reset() lifts the refusal", "")
end

------------------------------------------------------------------------
-- 3. The guard in all four rotations, on the bundle's Blitbuffer.
------------------------------------------------------------------------

-- The notebook contract's physical -> logical table, per pixel.
local function to_logical(r, px, py)
    if r == 0 then return px, py
    elseif r == 1 then return py, W - 1 - px
    elseif r == 2 then return W - 1 - px, H - 1 - py
    else return H - 1 - py, px end
end
-- The logical rect whose physical footprint is exactly (px, py, pw, ph).
local function logical_rect(r, px, py, pw, ph)
    local ax, ay = to_logical(r, px, py)
    local bx, by = to_logical(r, px + pw - 1, py + ph - 1)
    local x0, y0 = math.min(ax, bx), math.min(ay, by)
    return x0, y0, math.max(ax, bx) - x0 + 1, math.max(ay, by) - y0 + 1
end

local DU = { x = 600, y = 400, w = 300, h = 200, hint = 0x00 }
local screen_bb = BB.new(W, H, BB.TYPE_BB8)
local bb_fn = function() return screen_bb end

for r = 0, 3 do
    screen_bb:setRotation(r)
    local lw, lh = screen_bb:getWidth(), screen_bb:getHeight()
    local cases = {
        { "adjacent right of the DU rect", false,
          { logical_rect(r, DU.x + DU.w, DU.y, 50, 50) } },
        { "adjacent below the DU rect", false,
          { logical_rect(r, DU.x, DU.y + DU.h, 50, 50) } },
        { "overlapping its last pixel", true,
          { logical_rect(r, DU.x + DU.w - 1, DU.y + DU.h - 1, 50, 50) } },
        { "inside the 0x20 panel rect only", false,
          { logical_rect(r, PANEL.x + 10, PANEL.y + 10, 50, 50) } },
        { "entirely off-screen (bounds to nothing)", false,
          { lw + 10, 0, 100, 100 } },
        { "unbounded, negative origin, covering the screen", true,
          { -50, -50, lw + 100, lh + 100 } },
    }
    for _, case in ipairs(cases) do
        local label, want, rect = case[1], case[2], case[3]
        local rec = recorder()
        local owner = new_owner(rec, true, bb_fn)
        owner:arm({ DU, PANEL })
        local hit = owner:guard(rect[1], rect[2], rect[3], rect[4])
        local disarmed = #rec.calls == 2
        report(hit == want and disarmed == want and owner:is_armed() == not want,
               string.format("guard r=%d: %s", r, label),
               string.format("logical %d,%d,%d,%d -> %s", rect[1], rect[2],
                             rect[3], rect[4], want and "disarm" or "stays armed"))
    end
    -- The contract's table and Blitbuffer agree on this rotation.
    local x, y, w, h = logical_rect(r, DU.x, DU.y, DU.w, DU.h)
    local px, py, pw, ph = screen_bb:getPhysicalRect(x, y, w, h)
    report(px == DU.x and py == DU.y and pw == DU.w and ph == DU.h,
           string.format("r=%d: the contract's rotation table matches getPhysicalRect", r),
           string.format("%d,%d,%d,%d", px, py, pw, ph))
end

do
    local rec = recorder()
    local owner = new_owner(rec, true, bb_fn)
    report(owner:guard(0, 0, W, H) == false and #rec.calls == 0,
           "guard with nothing armed issues nothing", "")
    owner:arm({ DU })
    report(owner:guard(nil, nil, nil, nil) == true and not owner:is_armed(),
           "guard with no rect while armed disarms (the safe direction)", "")
    local blind = new_owner(rec, true, function() return nil end)
    blind:arm({ DU })
    report(blind:guard(0, 0, 1, 1) == true and not blind:is_armed(),
           "guard with no screen bb while armed disarms", "")
    screen_bb:setRotation(0)
    local only_default = new_owner(rec, true, bb_fn)
    only_default:arm({ PANEL })
    report(only_default:guard(0, 0, W, H) == false and only_default:is_armed(),
           "a rect at the plane default (0x20) never needs a disarm", "")
end
screen_bb:free()

------------------------------------------------------------------------
-- 4. The rest of the seam.
------------------------------------------------------------------------

-- The direct-driver probe (an injected path; the real one is a module
-- parameter only the direct driver registers).
do
    local present = os.tmpname()
    report(PineNote._isDirectEbc(present) == true,
           "isDirectEbc: the fingerprint parameter present -> direct", "")
    os.remove(present)
    report(PineNote._isDirectEbc(present) == false,
           "isDirectEbc: absent -> not direct", "")
    report(device_src:find('"/sys/module/rockchip_ebc/parameters/default_hint"', 1, true) ~= nil,
           "isDirectEbc probes the direct driver's default_hint by default", "")
end

-- publishNow: fsync on the framebuffer fd when there is one.
do
    local C = ffi.C
    local path = os.tmpname()
    local fd = C.open(path, C.O_RDONLY)
    report(PineNote.publishNow({ screen = { fd = fd } }) == true,
           "publishNow fsyncs an open fd", "")
    C.close(fd)
    os.remove(path)
    report(PineNote.publishNow({ screen = { fd = -1 } }) == false
           and PineNote.publishNow({}) == false,
           "publishNow without a framebuffer fd does nothing", "")
end

-- The consumer hook, through the bundle's own hook chaining.
do
    local host = { eventAdjustHook = Input.eventAdjustHook }
    -- Stands in for device.lua's earlier hooks (pen scaling etc.).
    Input.registerEventAdjustHook(host, function(_, ev) ev.value = ev.value + 1 end)
    Input.registerEventAdjustHook(host, PineNote._consumerHook)
    local seen = {}
    local consumer = function(input, ev)
        seen[#seen + 1] = { input = input, value = ev.value }
    end
    host:eventAdjustHook({ value = 10 })
    report(#seen == 0, "consumer hook with no consumer set does nothing", "")
    for _ = 1, 3 do
        host.wilkbook_consumer = consumer
        host.wilkbook_consumer = nil
    end
    host.wilkbook_consumer = consumer
    host:eventAdjustHook({ value = 20 })
    report(#seen == 1 and seen[1].input == host and seen[1].value == 21,
           "after 3 open/close cycles the consumer runs once per event, after the earlier hooks",
           string.format("%d call(s), value %s", #seen, tostring(seen[1] and seen[1].value)))
    -- init: the hook is registered last, after the gyro handler, and the
    -- node table is published.
    local last_reg
    for pos in device_src:gmatch("()registerEventAdjustHook%(") do last_reg = pos end
    local line = last_reg and device_src:sub(last_reg, device_src:find("\n", last_reg) - 1)
    local gyro = device_src:find("installGyroHandler(self.input)", 1, true)
    report(line == "registerEventAdjustHook(consumerHook)" and gyro and gyro < last_reg,
           "init registers consumerHook last, after installGyroHandler", tostring(line))
    report(device_src:find("self.input_devices = devs", 1, true) ~= nil,
           "init publishes the input nodes as input_devices", "")
end

-- The rotation hold (the notebook never raises contact_count).
do
    local applied = {}
    local hold = true
    local input = {
        gesture_detector = { contact_count = 0 },
        handleMiscEv = function() return nil end,
        handleTouchEv = function() return {} end,
        handleGyroEv = function(_, ev)
            applied[#applied + 1] = ev.value
            return { handler = "onSetRotationMode", args = { ev.value } }
        end,
    }
    PineNote._installGyroHandler(input)
    input.wilkbook_hold_rotation = function() return hold end
    input:handleMiscEv({ code = 71, value = 1, wilkbook_gsensor = true })
    input:handleMiscEv({ code = 71, value = 3, wilkbook_gsensor = true })
    local flushed = input:handleTouchEv({})
    report(#applied == 0 and #flushed == 0,
           "hold: rotation waits, and a touch event does not flush it", #applied)
    local taken = input:takePendingRotation()
    report(taken == 3 and input:takePendingRotation() == nil and #applied == 0,
           "takePendingRotation returns the newest value once, raw",
           tostring(taken))
    hold = false
    input:handleMiscEv({ code = 71, value = 2, wilkbook_gsensor = true })
    report(#applied == 1 and applied[1] == 2,
           "released: rotation applies immediately", table.concat(applied, ","))
    hold = true
    input:handleMiscEv({ code = 71, value = 0, wilkbook_gsensor = true })
    hold = false
    flushed = input:handleTouchEv({})
    report(#applied == 2 and applied[2] == 0 and #flushed == 1
           and input:takePendingRotation() == nil,
           "released: the next touch event flushes what the hold kept",
           table.concat(applied, ","))
    input.wilkbook_hold_rotation = function() return 1 end
    input:handleMiscEv({ code = 71, value = 3, wilkbook_gsensor = true })
    report(#applied == 3 and applied[3] == 3,
           "only a predicate returning true holds", table.concat(applied, ","))
end

-- The evdev backend's EVIOCGKEY.
do
    local ioc = 2 * 2^30 + 96 * 2^16 + 0x45 * 2^8 + 0x18
    report(evdev.EVIOCGKEY_96 == 0x80604518 and evdev.EVIOCGKEY_96 == ioc,
           "EVIOCGKEY(96) is _IOC(READ, 'E', 0x18, 96) = 0x80604518",
           string.format("0x%08X", evdev.EVIOCGKEY_96 or 0))
    local bits = ffi.new("uint8_t[96]")
    -- BTN_TOOL_PEN 320 and BTN_TOUCH 330 down.
    bits[40] = 0x01
    bits[41] = 0x04
    local codes = { 320, 321, 330, 331, 332, 800 }
    local s = evdev.decodeKeyState(bits, codes)
    report(s[320] == true and s[321] == false and s[330] == true
           and s[331] == false and s[332] == false and s[800] == nil,
           "decodeKeyState reads the kernel's key bitmap",
           "320,330 down; 321,331,332 up; 800 out of range")
    report(evdev.keystate("/dev/null", codes) == nil,
           "keystate on a non-evdev node fails (ret < 0 checked)", "")
    report(evdev.keystate("/nonexistent/wilkbook-evdev", codes) == nil,
           "keystate on a missing node fails", "")
    local body = evdev_src:match("\nfunction input%.keystate%(path, codes%)\n(.-)\nend\n")
    report(body ~= nil and body:find("C.open(path", 1, true) ~= nil
           and body:find("open_fds", 1, true) == nil
           and body:find("C.close(fd)", 1, true) ~= nil,
           "keystate always uses a transient fd, never the one the backend reads", "")
    report(evdev_src:find("return info.minimum, info.maximum, info.value", 1, true) ~= nil,
           "absinfo also returns the axis's current value", "")
end

------------------------------------------------------------------------
-- 5. Edges: boundaries, degenerate input, unusual event orders.
------------------------------------------------------------------------

-- 5a. The pen scaling over the digitizer's whole range and past both
-- ends: every value lands on the panel, the order is kept, the raw value
-- rides along, and only the values that round past the last pixel clamp.
do
    local MAX_X, MAX_Y = 20966, 15725
    local SX, SY = W / MAX_X, H / MAX_Y
    local function sweep(code, max, scale, last)
        local bad, clamped, prev = 0, 0, 0
        for raw = -3, max + 3 do
            local ev = { type = 3, code = code, value = raw }
            PineNote._adjustPenEvent(ev, SX, SY, W, H)
            local want = math.floor(raw * scale + 0.5)
            if want > last then want, clamped = last, clamped + 1 end
            if want < 0 then want = 0 end
            if ev.value ~= want or ev.raw_value ~= raw or ev.value < prev then
                bad = bad + 1
            end
            prev = ev.value
        end
        return bad, clamped
    end
    local bad_x, clamped_x = sweep(0, MAX_X, SX, W - 1)
    local bad_y, clamped_y = sweep(1, MAX_Y, SY, H - 1)
    report(bad_x == 0 and bad_y == 0,
           "edge: pen scaling from -3 to max+3 stays on the panel, in order, raw kept",
           string.format("clamped x=%d y=%d", clamped_x, clamped_y))
    local function px(code, raw)
        local ev = { type = 3, code = code, value = raw }
        PineNote._adjustPenEvent(ev, SX, SY, W, H)
        return ev.value
    end
    report(px(0, 20949) == 1870 and px(0, 20950) == 1871 and px(0, 20960) == 1871
           and px(0, 20961) == 1871 and px(1, 15708) == 1402
           and px(1, 15709) == 1403 and px(1, 15720) == 1403,
           "edge: the 1870/1871 and 1402/1403 boundaries; 20961 and 15720 are the first clamped",
           "")
    local syn = { type = 0, code = 0, value = 0 }
    local ok = PineNote._adjustPenEvent(syn, SX, SY, W, H)
    report(ok == false and syn.raw_value == nil and syn.value == 0,
           "edge: a pen SYN_REPORT is untouched", "")
end

-- 5b. Degenerate arms: refused, never thrown.  An arm runs inside the
-- input hook, where an error takes KOReader down.
local edge_bb = BB.new(W, H, BB.TYPE_BB8)
local edge_bb_fn = function() return edge_bb end
do
    local function refuses(label, rects)
        local rec = recorder()
        local owner = new_owner(rec, true)
        local ok, ret = pcall(owner.arm, owner, rects)
        report(ok and ret == false and #rec.calls == 0 and not owner:is_armed(),
               "edge: arm refuses " .. label .. " without an ioctl or an error",
               ok and tostring(ret) or "raised an error")
    end
    refuses("a NaN coordinate", { { x = 0 / 0, y = 0, w = 1, h = 1, hint = 0 } })
    refuses("an infinite width", { { x = 0, y = 0, w = math.huge, h = 1, hint = 0 } })
    refuses("a -inf origin", { { x = -math.huge, y = 0, w = 1, h = 1, hint = 0 } })
    refuses("a NaN hint", { { x = 0, y = 0, w = 1, h = 1, hint = 0 / 0 } })
    refuses("a non-table entry", { 5 })
    refuses("a good rect followed by a bad one",
            { CANVAS, { x = 0, y = 0, w = 0 / 0, h = 1, hint = 0 } })

    local rec = recorder()
    local owner = new_owner(rec, true)
    report(owner:arm(nil) == true and #rec.calls == 0 and not owner:is_armed(),
           "edge: arm(nil) is a disarm; nothing armed, so no ioctl", "")
    -- The driver ignores an inverted rect (patch 7.1-rect-hints-bounds), so
    -- the owner sends it as given; the guard may still disarm over it,
    -- which costs one ioctl and is the safe direction.
    local inverted = new_owner(rec, true)
    report(inverted:arm({ { x = 10, y = 10, w = -5, h = 5, hint = 0 } }) == true
           and #rec.calls == 1
           and rec.calls[1].rects == lib.pack_rect_hint(0, 10, 10, -5, 5),
           "edge: an inverted rect is passed to the driver as given", "")
end

-- 5c. A failed reset from a fresh owner.  The plane may still hold what a
-- crashed KOReader armed, so the owner must count as armed and the next
-- refresh must retry the disarm.
do
    local rec = recorder()
    local owner = new_owner(rec, true, edge_bb_fn)
    edge_bb:setRotation(0)
    rec.ret, rec.errno = -1, 19
    report(owner:reset() == false and owner:is_armed(),
           "edge: a failed reset leaves the owner armed (the plane is unknown)", "")
    rec.ret = 0
    report(owner:guard(0, 0, 10, 10) == true and not owner:is_armed()
           and #rec.calls == 2
           and rec.calls[2].header == lib.pack_rect_hints_header(true, 32, 0),
           "edge: the next refresh retries the disarm and clears it", "")
    report(owner:arm({ CANVAS }) == true and #rec.calls == 3,
           "edge: a failed reset does not block arming", "")
end

-- 5d. One warning per failure streak, and a new streak warns again.
do
    local rec = recorder()
    local owner = new_owner(rec, true)
    local w0 = log_count("[pn-hint] ")
    local a0 = log_count("[pn-hint] arm failed")
    rec.ret = -1
    owner:arm({ CANVAS })
    owner:reset()
    owner:reset()
    local w1 = log_count("[pn-hint] ")
    rec.ret = 0
    owner:reset()
    rec.ret = -1
    owner:arm({ CANVAS })
    local a2 = log_count("[pn-hint] arm failed") - a0
    report(w1 == w0 + 1 and a2 == 2,
           "edge: one warning per streak of failures, and one more after a success",
           string.format("%d line(s) in the streak, %d arm warnings", w1 - w0, a2))
end

-- 5e. The guard: a re-arm replaces the set; the canvas underlies the
-- panel; edges shared, not crossed; zero and negative sizes; half-given
-- rects.
do
    edge_bb:setRotation(0)
    local rec = recorder()
    local owner = new_owner(rec, true, edge_bb_fn)
    local OTHER = { x = 1500, y = 1000, w = 100, h = 100, hint = 0x00 }
    owner:arm({ DU })
    owner:arm({ OTHER })
    report(owner:guard(DU.x, DU.y, DU.w, DU.h) == false and owner:is_armed()
           and owner:guard(OTHER.x, OTHER.y, 1, 1) == true,
           "edge: a second arm replaces the first; only the new set is guarded", "")

    owner:arm({ CANVAS, PANEL })
    report(owner:guard(PANEL.x + 10, PANEL.y + 10, 20, 20) == true,
           "edge: with the canvas armed, a refresh inside the panel still disarms (0x00 lies under it)",
           "")

    for r = 0, 3 do
        edge_bb:setRotation(r)
        local results = {}
        local cases = {
            -- label, physical rect, expected hit
            { "left of", DU.x - 50, DU.y, 50, 50, false },
            { "above", DU.x, DU.y - 50, 50, 50, false },
            { "on the first pixel of", DU.x - 49, DU.y - 49, 50, 50, true },
        }
        local good = true
        for _, c in ipairs(cases) do
            local o = new_owner(recorder(), true, edge_bb_fn)
            o:arm({ DU })
            local x, y, w, h = logical_rect(r, c[2], c[3], c[4], c[5])
            local hit = o:guard(x, y, w, h)
            results[#results + 1] = c[1] .. "=" .. tostring(hit)
            if hit ~= c[6] then good = false end
        end
        local o = new_owner(recorder(), true, edge_bb_fn)
        o:arm({ DU })
        local x, y, w, h = logical_rect(r, DU.x, DU.y, DU.w, DU.h)
        local degenerate = o:guard(x, y, 0, h) == false and o:guard(x, y, w, 0) == false
            and o:guard(x, y, -5, h) == false and o:is_armed()
        report(good and degenerate,
               string.format("edge r=%d: shared edges on the near sides do not disarm; zero/negative sizes never do", r),
               table.concat(results, " "))
    end

    -- An armed rect that overhangs the panel: a refresh wholly past the
    -- edge bounds to nothing, so it cannot reach the overhang.
    edge_bb:setRotation(0)
    local over = new_owner(recorder(), true, edge_bb_fn)
    over:arm({ { x = W - 10, y = 0, w = 100, h = H, hint = 0 } })
    report(over:guard(W + 5, 10, 20, 20) == false and over:is_armed()
           and over:guard(W - 1, 10, 20, 20) == true,
           "edge: a refresh past the panel edge never disarms, even over an overhanging arm", "")

    local half = new_owner(recorder(), true, edge_bb_fn)
    half:arm({ DU })
    report(half:guard(0, 0, nil, 10) == true and not half:is_armed(),
           "edge: a rect missing its width disarms (the safe direction)", "")
end

-- 5f. Rotation 1 against 3, and the last logical pixel in each rotation.
do
    for _, pair in ipairs({ { 1, 3 }, { 3, 1 } }) do
        local r, other = pair[1], pair[2]
        local x, y, w, h = logical_rect(r, DU.x, DU.y, DU.w, DU.h)
        local o = new_owner(recorder(), true, edge_bb_fn)
        o:arm({ DU })
        edge_bb:setRotation(other)
        local wrong = o:guard(x, y, w, h)
        edge_bb:setRotation(r)
        local right = o:guard(x, y, w, h)
        report(wrong == false and right == true,
               string.format("edge: a rect over the DU rect at r=%d misses it at r=%d", r, other),
               string.format("logical %d,%d,%d,%d", x, y, w, h))
    end
    -- The contract's logical -> physical table, for one pixel.
    local function to_physical(r, lx, ly)
        if r == 0 then return lx, ly
        elseif r == 1 then return W - 1 - ly, lx
        elseif r == 2 then return W - 1 - lx, H - 1 - ly
        else return ly, H - 1 - lx end
    end
    for r = 0, 3 do
        edge_bb:setRotation(r)
        local lw, lh = edge_bb:getWidth(), edge_bb:getHeight()
        local px, py = to_physical(r, lw - 1, lh - 1)
        local corner = { x = px, y = py, w = 1, h = 1, hint = 0 }
        local qx, qy = to_physical(r, 0, 0)
        local origin = { x = qx, y = qy, w = 1, h = 1, hint = 0 }
        local function hits(target, lx, ly, lwid, lhei)
            local o = new_owner(recorder(), true, edge_bb_fn)
            o:arm({ target })
            return o:guard(lx, ly, lwid, lhei)
        end
        local a = hits(corner, lw - 1, lh - 1, 100, 100)    -- overhangs; bounded
        local b = hits(corner, lw - 1, lh - 2, 100, 1)      -- the row above it
        local c = hits(corner, lw - 2, lh - 1, 1, 100)      -- the column left of it
        local d = hits(origin, -100, -100, 101, 101)        -- bounds to (0,0,1,1)
        local e = hits(origin, -100, -100, 100, 100)        -- bounds to nothing
        report(a and not b and not c and d and not e,
               string.format("edge r=%d: the last logical pixel (%d,%d) is physical (%d,%d); the bound keeps off-by-ones out", r, lw - 1, lh - 1, px, py),
               string.format("%s %s %s %s %s", tostring(a), tostring(b), tostring(c), tostring(d), tostring(e)))
    end
end
edge_bb:free()

-- 5g. The rotation hold: a pending 0 is still a value; a gesture contact
-- holds without the predicate; clearing the predicate releases at the
-- next touch event; only a boolean true holds.
do
    local applied = {}
    local input = {
        gesture_detector = { contact_count = 0 },
        handleMiscEv = function() return nil end,
        handleTouchEv = function() return nil end,
        handleGyroEv = function(_, ev)
            applied[#applied + 1] = ev.value
            return { handler = "onSetRotationMode", args = { ev.value } }
        end,
    }
    PineNote._installGyroHandler(input)
    report(input:takePendingRotation() == nil, "edge: nothing pending -> nil", "")
    input.wilkbook_hold_rotation = function() return true end
    input:handleMiscEv({ code = 71, value = 0, wilkbook_gsensor = true })
    report(input:takePendingRotation() == 0 and #applied == 0,
           "edge: a held rotation to 0 is taken as 0, not lost", "")
    input.wilkbook_hold_rotation = function() return false end
    input.gesture_detector.contact_count = 1
    input:handleMiscEv({ code = 71, value = 2, wilkbook_gsensor = true })
    report(#applied == 0, "edge: a gesture contact holds even when the predicate says no", "")
    input.gesture_detector.contact_count = 0
    input.wilkbook_hold_rotation = nil
    local flushed = input:handleTouchEv({})
    report(#applied == 1 and applied[1] == 2 and flushed and #flushed == 1,
           "edge: with the predicate cleared, the next touch event flushes (nil event list grown)",
           table.concat(applied, ","))
    input.wilkbook_hold_rotation = function() return "yes" end
    input:handleMiscEv({ code = 71, value = 1, wilkbook_gsensor = true })
    report(#applied == 2 and applied[2] == 1,
           "edge: a truthy non-boolean does not hold", table.concat(applied, ","))
    local other = input:handleMiscEv({ code = 71, value = 3 })
    report(other == nil and #applied == 2,
           "edge: code 71 without the gsensor mark is not a rotation", "")
end

-- 5h. The key bitmap at its edges.
do
    local bits = ffi.new("uint8_t[96]")
    bits[0] = 0x01      -- code 0
    bits[95] = 0x80     -- code 767, the last one EVIOCGKEY(96) covers
    local s = evdev.decodeKeyState(bits, { 0, 1, 766, 767, 768, -1 })
    report(s[0] == true and s[1] == false and s[766] == false and s[767] == true
           and s[768] == nil and s[-1] == nil,
           "edge: decodeKeyState at codes 0 and 767; 768 and -1 are out of range", "")
    local empty = evdev.decodeKeyState(bits, {})
    report(next(empty) == nil, "edge: no codes asked, none answered", "")
end

-- 5i. The chain as init builds it, through the bundle's real
-- Input:waitEvent: pen scaling, touch, the gyro translation and handler,
-- mixedrouter and slotguard, then the consumer hook last.  A stub backend
-- returns one batch per call.
do
    local pinenote_dir = device_lua_path:match("^(.*)/[^/]*$") or "."
    local MixedRouter = dofile(pinenote_dir .. "/mixedrouter.lua")
    local SlotGuard = dofile(pinenote_dir .. "/slotguard.lua")
    local Screen = {}
    function Screen:getDPI() return 227 end
    function Screen:scaleByDPI(dp) return math.ceil(dp * 227 / 160) end
    function Screen:getWidth() return W end
    function Screen:getHeight() return H end
    function Screen:getRotationMode() return 0 end
    function Screen:getTouchRotation() return 0 end
    local FakeDevice = { screen = Screen, display_dpi = 227 }
    function FakeDevice:isSDL() return false end
    function FakeDevice:isAndroid() return false end
    function FakeDevice:isPocketBook() return false end
    function FakeDevice:isAlwaysFullscreen() return true end
    function FakeDevice:hasEinkScreen() return true end
    function FakeDevice:isGSensorLocked() return false end

    local PEN, TOUCH, GS = "/dev/input/event3", "/dev/input/event2", "/dev/input/event9"
    local SX, SY = W / 20966, H / 15725
    local queue = {}
    local Backend = { is_ffi = true }
    function Backend.waitForEvent()
        local b = table.remove(queue, 1)
        if b then return true, b end
        return false, 62
    end

    local function build()
        local input = Input:new{ device = FakeDevice, input = Backend,
                                 wacom_protocol = true, disable_double_tap = true,
                                 event_map = {} }
        input.gesture_detector.active_contacts = {}
        input.gesture_detector.previous_tap = {}
        input.gesture_detector.contact_count = 0
        input.handleTouchEv = input.handleMixedTouchEv
        MixedRouter.install(input, PEN, TOUCH)
        SlotGuard.install(input)
        input:registerEventAdjustHook(function(_, ev)
            if ev.src == PEN then
                PineNote._adjustPenEvent(ev, SX, SY, W, H)
            elseif ev.src == TOUCH then
                PineNote._adjustTouchEvent(ev, TOUCH)
            end
        end)
        input:registerEventAdjustHook(function(_, ev)
            PineNote._translateGyroEvent(ev, GS)
        end)
        local rotations = {}
        input.handleGyroEv = function(_, ev)
            rotations[#rotations + 1] = ev.value
            return { handler = "onSetRotationMode", args = { ev.value } }
        end
        PineNote._installGyroHandler(input)
        input:registerEventAdjustHook(PineNote._consumerHook)
        return input, rotations
    end

    local usec = 0
    local function e(src, ty, code, value)
        return { src = src, type = ty, code = code, value = value,
                 time = { sec = 2, usec = usec } }
    end
    local function run(input, batch)
        usec = usec + 2770
        queue[1] = batch
        local out = input:waitEvent(nil, nil) or {}
        local names = {}
        for _, ev in ipairs(out) do
            local g = ev.args and ev.args[1]
            names[#names + 1] = type(g) == "table"
                and string.format("%s@%d,%d", g.ges, g.pos.x, g.pos.y)
                or tostring(ev.handler)
        end
        return names
    end

    -- A consumer that takes pen, touch and nothing else, holding rotation
    -- while the pen is in range (the notebook's shape).
    local input, rotations = build()
    local st = { in_range = false, seen = {}, calls = 0 }
    local function consumer(_, ev)
        st.calls = st.calls + 1
        if ev.src ~= PEN and ev.src ~= TOUCH then return end
        if ev.type == 1 and (ev.code == 320 or ev.code == 321) then
            st.in_range = ev.value == 1
        end
        if ev.src == PEN and ev.type == 3 and ev.code <= 1 then
            st.seen[#st.seen + 1] = string.format("%d:%d/%s", ev.code, ev.value,
                                                  tostring(ev.raw_value))
        end
        ev.type = 4
    end
    input.wilkbook_consumer = consumer
    input.wilkbook_hold_rotation = function() return st.in_range end
    input:resetState()

    local out = {}
    -- The pen arrives at the far corner, touches down BEFORE its first
    -- position of the report (the w9013's order), and a finger lands
    -- while it is in range.
    out[#out + 1] = run(input, { e(PEN, 1, 320, 1), e(PEN, 3, 0, 20966), e(PEN, 3, 1, 15725),
                                 e(PEN, 3, 24, 0), e(PEN, 0, 0, 0) })
    out[#out + 1] = run(input, { e(PEN, 1, 330, 1), e(PEN, 3, 0, 20900), e(PEN, 3, 1, 15700),
                                 e(PEN, 0, 0, 0) })
    out[#out + 1] = run(input, { e(TOUCH, 3, 57, 40), e(TOUCH, 3, 53, 500), e(TOUCH, 3, 54, 500),
                                 e(TOUCH, 0, 0, 0) })
    -- The g-sensor turns while the pen is in range.
    out[#out + 1] = run(input, { e(GS, 4, 3, 1), e(GS, 0, 0, 0) })
    -- SYN_DROPPED from the pen mid-stroke, then a tool switch to the
    -- rubber inside one report, then lift and leave.
    out[#out + 1] = run(input, { e(PEN, 0, 3, 0), e(PEN, 3, 0, 100), e(PEN, 0, 0, 0) })
    out[#out + 1] = run(input, { e(PEN, 1, 330, 0), e(PEN, 1, 320, 0), e(PEN, 1, 321, 1),
                                 e(PEN, 0, 0, 0) })
    out[#out + 1] = run(input, { e(TOUCH, 3, 57, -1), e(TOUCH, 0, 0, 0) })
    local mid_hold = input:takePendingRotation()
    out[#out + 1] = run(input, { e(GS, 4, 3, 2), e(GS, 0, 0, 0) })
    out[#out + 1] = run(input, { e(PEN, 1, 321, 0), e(PEN, 0, 0, 0) })
    local emitted = 0
    for _, names in ipairs(out) do emitted = emitted + #names end
    report(emitted == 0 and input.gesture_detector.contact_count == 0
           and #input.timer_callbacks == 0,
           "chain: everything consumed -> no event, no contact, no timer reaches KOReader",
           string.format("%d event(s), %d contact(s)", emitted,
                         input.gesture_detector.contact_count))
    report(st.seen[1] == "0:1871/20966" and st.seen[2] == "1:1403/15725"
           and st.seen[3] == "0:1866/20900",
           "chain: the consumer sees pen X/Y scaled and clamped, raw_value kept",
           table.concat(st.seen, " ", 1, 3))
    report(#rotations == 0 and mid_hold == 1,
           "chain: a rotation while the pen is in range waits for takePendingRotation",
           tostring(mid_hold))
    local after_leave = input:takePendingRotation()
    report(after_leave == 2 and #rotations == 0,
           "chain: a rotation arriving after takePendingRotation is kept for the next take",
           tostring(after_leave))

    -- Close: the consumer and the hold go, resetState, and the touch slot
    -- is handed back.  The kernel is on slot 5 (sparse slots), so the next
    -- finger arrives with no ABS_MT_SLOT at all.
    local calls_at_close = st.calls
    input.wilkbook_consumer = nil
    input.wilkbook_hold_rotation = nil
    input:resetState()
    input:setTouchSlot(5)
    local tap = {}
    for _, names in ipairs({
        run(input, { e(TOUCH, 3, 57, 41), e(TOUCH, 3, 53, 700), e(TOUCH, 3, 54, 300),
                     e(TOUCH, 0, 0, 0) }),
        run(input, { e(TOUCH, 3, 57, -1), e(TOUCH, 0, 0, 0) }),
    }) do
        for _, n in ipairs(names) do tap[#tap + 1] = n end
    end
    -- "touch" is the detector's contact-down gesture, "tap" the lift.
    report(st.calls == calls_at_close and table.concat(tap, " ") == "touch@700,300 tap@700,300"
           and input.ev_slots[5] ~= nil and input.ev_slots[0].id == nil
           and input.gesture_detector.contact_count == 0,
           "chain: after close KOReader gets a clean tap in kernel slot 5, the consumer nothing",
           table.concat(tap, " "))
    -- With the hold gone, a rotation applies at once.
    local rot = run(input, { e(GS, 4, 3, 3), e(GS, 0, 0, 0) })
    report(#rotations == 1 and rotations[1] == 3 and rot[1] == "onSetRotationMode",
           "chain: after close a rotation applies immediately", table.concat(rot, ","))
end

if fail == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: failed (%d)", fail))
    os.exit(1)
end
