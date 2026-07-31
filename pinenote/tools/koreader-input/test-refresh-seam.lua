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

-- 4. Publish-on-call: every assigned Imp closure must call publish().
-- The closures are `function(...) ... end` assignments plus the
-- flash_policy-generated pair; count call sites instead of parsing
-- bodies: one per direct Imp, two inside flash_policy (both branches).
local publish_calls = 0
for _ in src:gmatch("\n%s*publish%(%)") do
    publish_calls = publish_calls + 1
end
-- 5 direct Imps + 2 flash_policy branches = 7 call sites minimum.  A
-- call site sits alone on its line; the definition line is
-- `local function publish()` and so never matches this pattern.
check(publish_calls >= 7, string.format(
    "device.lua has %d publish() call sites (>= 7 expected)", publish_calls))

-- 5. Ordering: in every publish+global pairing, the publish comes first
-- (the wash must paint already-published content).
local bad_order = src:find("global_refresh%(%)%s*\n%s*publish%(%)")
check(not bad_order, "publish() always precedes global_refresh()")

if fail then
    print("RESULT: failed")
    os.exit(1)
end
print("RESULT: ok")
