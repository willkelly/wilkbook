-- Publish-on-call seam assertion (doc/refresh-policy.md).
--
-- The PineNote device target implements its whole refresh policy by
-- assigning `self.screen.refresh*Imp` closures.  That seam is upstream's
-- documented extension point ("the ...Imp methods may be overridden to
-- implement refresh", ffi/framebuffer.lua), but nothing would fail at
-- build time if a KOReader bump renamed or removed an Imp: our
-- assignments would become dead keys and every refresh would silently
-- fall back to the generic defaults -- no publish fsync, no global
-- refresh, diagnosable only on hardware.
--
-- So: load the bundle's VERBATIM ffi/framebuffer.lua under the bundle's
-- own luajit and assert, by execution rather than by grep, that every
-- Imp our device.lua assigns still exists as a base method there.  Then
-- hold our own side to the publish-on-call contract: every assigned Imp
-- body must call publish() before returning (checked textually against
-- our file -- we own its formatting).
local koreader_dir = assert(arg[1], "arg1: koreader bundle dir")
local device_lua = assert(arg[2], "arg2: repo device.lua")

package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

local fail = false
local function check(ok, msg)
    if ok then
        print("PASS: " .. msg)
    else
        print("FAIL: " .. msg)
        fail = true
    end
end

-- 1. Collect the Imps our device target assigns.
local src do
    local f = assert(io.open(device_lua, "r"))
    src = f:read("*a")
    f:close()
end
local seen, ours = {}, {}
-- %w, not %a: refreshA2Imp has a digit in it.
for name in src:gmatch("self%.screen%.(refresh%w+Imp)%s*=") do
    if not seen[name] then
        seen[name] = true
        ours[#ours + 1] = name
    end
end
table.sort(ours)
check(#ours >= 7, string.format(
    "device.lua assigns %d refresh*Imp overrides (>= 7 expected)", #ours))

-- 2. Load the verbatim base framebuffer and assert each is a real method.
local fb = require("ffi/framebuffer")
for _, name in ipairs(ours) do
    check(type(fb[name]) == "function",
        string.format("bundle ffi/framebuffer.lua still defines %s", name))
end

-- 3. The paint-batching hooks our overrides ride alongside must survive
-- too (UIManager calls them around every paint cycle).
for _, name in ipairs({ "beforePaint", "afterPaint" }) do
    check(type(fb[name]) == "function",
        string.format("bundle ffi/framebuffer.lua still defines %s", name))
end

-- 4. Publish-on-call, per Imp -- an aggregate count would let one Imp
-- drop publish() while another gains a call.  We own device.lua's
-- formatting, so hold each assignment to its exact shape:
--   * PARTIAL Imps are trace-then-publish, nothing between:
--       self.screen.refreshXImp = function(...)
--           trace(...)
--           publish()
--   * flash_policy-valued Imps route through flash_policy.
for _, name in ipairs(ours) do
    local fn_shape = "self%.screen%." .. name ..
        "%s*=%s*function[^\n]*\n%s*trace%([^\n]*\n%s*publish%(%)"
    local policy_shape = "self%.screen%." .. name ..
        "%s*=%s*flash_policy%("
    -- refreshFullImp is a global path and is asserted separately below;
    -- it must NOT publish.
    if name ~= "refreshFullImp" then
        check(src:find(fn_shape) ~= nil or src:find(policy_shape) ~= nil,
            string.format("%s publishes on call (or routes via flash_policy)",
                name))
    end
end

-- 5. The GLOBAL paths must NOT publish first.
--
-- This inverts what this test asserted before 2026-08-04.  An fsync ahead
-- of the wash runs the deferred-io flush, which makes the driver
-- partial-refresh the damage -- a full visible paint -- and then the wash
-- paints the same content a second time.  On glass that was the "render,
-- flash, render again" double update on rotation and on opening the menu.
-- The ioctl drains deferred-io into ctx->final itself
-- (flush_delayed_work + flush_work in ioctl_trigger_global_refresh), so
-- the wash still provably paints what userspace had written.
check(src:find("self%.screen%.refreshFullImp%s*=%s*function[^\n]*\n" ..
        "%s*trace%([^\n]*\n[^\n]*\n[^\n]*\n%s*global_refresh%(%)") ~= nil
      or src:find("self%.screen%.refreshFullImp%s*=%s*function[^\n]*\n" ..
        "%s*trace%([^\n]*\n%s*global_refresh%(%)") ~= nil,
    "refreshFullImp reaches global_refresh without an intervening publish()")

-- Structural guard: no publish() call anywhere between a global trace and
-- its global_refresh().  Comments may sit between them; a call may not.
local function strip_comments(seg)
    -- The explanation of WHY there is no publish() here naturally contains
    -- the string "publish()", so a raw find would match the comment that
    -- documents the fix.  Only executable lines count.
    local out = {}
    for line in (seg .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*%-%-") then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end

local function no_publish_between(pattern, label)
    local seg = src:match(pattern)
    check(seg ~= nil, label .. ": segment found")
    if seg then
        check(strip_comments(seg):find("publish%(%)") == nil,
            label .. ": no publish() call before the wash")
    end
end
no_publish_between('trace%(intent, "global"(.-)global_refresh%(%)',
    "flash_policy global branch")
no_publish_between('trace%("full", "global"(.-)global_refresh%(%)',
    "refreshFullImp")

-- The partial branch still publishes -- that is the whole point of
-- publish-on-call for pen strokes and page turns.
check(src:find('trace%(intent, "partial"[^\n]*\n%s*publish%(%)') ~= nil,
    "flash_policy partial branch is trace/publish")

if fail then
    print("RESULT: failed")
    os.exit(1)
end
print("RESULT: ok")
