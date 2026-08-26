--[[
Rotation-decision hierarchy pins (rung 4v, 2026-08-25 D5 follow-up).

The glass session left orientation "unresolved, not failed": four remote
mechanisms all produced portrait boots.  The offline rung-4v
instrumentation (qemu-virt, instrumented bundle, screendumps) mapped the
actual decision chain, and this file pins that map so a KOReader upgrade
that moves any link fails loudly instead of silently redrawing D5:

  boot   Generic Device:init applies G-setting `closed_rotation_mode`
         unconditionally -- THE boot orientation decider (the wilkbook
         profile seeds it to 1, hence every remote mechanism "produced"
         a portrait boot: none of them was ever consulted).
  doc    ReaderView:onReadSettings restores sidecar-then-global
         [ck]opt_rotation_mode ONLY under nilOrFalse("lock_rotation").
         The profile seeds lock_rotation=true, so on the shipping image
         this branch is dead: the doc sidecar and copt_rotation_mode are
         NEVER READ (glass mechanisms 2 and 3).
  fm     FileManager:setRotationMode restores fm_rotation_mode under the
         same lock_rotation gate; equally dead under the seed.
  state  /run/wilkbook-orientation.state is read by syncGyroState, which
         is reachable ONLY from PineNote:toggleGSensor -- and upstream
         calls toggleGSensor only from DeviceListener's menu handlers
         (onToggleGSensor / onTempGSensorOn), never at startup (glass
         mechanism 4: never read at boot).
  live   The one lever that always works while KOReader runs: MSC_RAW on
         the gsensor node KOReader has open (proven on qemu-virt:
         emission -> translateGyroEvent -> handleMiscGyroEv -> Event
         SetRotationMode -> fb:setRotationMode, screendumps flipping
         both directions).  Behaviorally covered by test-optics-inject.

These are source pins over the bundle's verbatim files (pattern
anchoring, not execution: the boot path cannot be executed without a
full UI stack).  If one fails after a bundle upgrade, re-run the rung-4v
instrumentation before re-pinning.

Usage: luajit test-rotation-decision.lua <bundle lib/koreader> <repo device.lua>
--]]

local koreader_dir = assert(arg[1], "arg 1: koreader bundle directory")
local device_lua_path = assert(arg[2], "arg 2: repo pinenote device.lua")

local failures = 0
local function report(ok, label, detail)
    if ok then
        print(string.format("PASS: %s (%s)", label, tostring(detail)))
    else
        failures = failures + 1
        print(string.format("FAIL: %s (%s)", label, tostring(detail)))
    end
end

local function slurp(path)
    local f = assert(io.open(path, "r"), "cannot open " .. path)
    local text = f:read("*a")
    f:close()
    return text
end

local generic = slurp(koreader_dir .. "/frontend/device/generic/device.lua")
local readerview = slurp(koreader_dir .. "/frontend/apps/reader/modules/readerview.lua")
local filemanager = slurp(koreader_dir .. "/frontend/apps/filemanager/filemanager.lua")
local devicelistener = slurp(koreader_dir .. "/frontend/device/devicelistener.lua")
local readermain = slurp(koreader_dir .. "/reader.lua")
local device_lua = slurp(device_lua_path)

------------------------------------------------------------------------
-- 1. Boot decider: closed_rotation_mode applied in Generic init.
------------------------------------------------------------------------
local init_body = generic:match("function Device:init%(%)(.-)\nfunction ")
report(init_body ~= nil, "Generic Device:init body found", init_body and #init_body)
local closed_read = init_body and init_body:find(
    'G_reader_settings:readSetting("closed_rotation_mode")', 1, true)
local closed_apply = init_body and init_body:find(
    "self.screen:setRotationMode(rotation_mode)", 1, true)
report(closed_read and closed_apply and closed_read < closed_apply,
    "boot decider: Device:init reads closed_rotation_mode then applies it",
    "read@" .. tostring(closed_read) .. " apply@" .. tostring(closed_apply))

------------------------------------------------------------------------
-- 2. Doc restore gate: ReaderView:onReadSettings under lock_rotation,
--    sidecar consulted before the global setting.
------------------------------------------------------------------------
local ors_body = readerview:match("function ReaderView:onReadSettings%(config%)(.-)\nfunction ")
report(ors_body ~= nil, "ReaderView:onReadSettings body found", ors_body and #ors_body)
local gate = ors_body and ors_body:find(
    'G_reader_settings:nilOrFalse("lock_rotation")', 1, true)
local sidecar_read = ors_body and ors_body:find(
    "config:readSetting(setting_name)", 1, true)
local global_read = ors_body and ors_body:find(
    "G_reader_settings:readSetting(setting_name)", 1, true)
report(gate and sidecar_read and global_read
        and gate < sidecar_read and sidecar_read < global_read,
    "doc restore: lock_rotation gates sidecar-then-global rotation_mode",
    "gate@" .. tostring(gate) .. " sidecar@" .. tostring(sidecar_read)
        .. " global@" .. tostring(global_read))
report(ors_body ~= nil and ors_body:find('"copt_rotation_mode"', 1, true) ~= nil
        and ors_body:find('"kopt_rotation_mode"', 1, true) ~= nil,
    "doc restore: the gated settings are [ck]opt_rotation_mode", "both present")

------------------------------------------------------------------------
-- 3. FM restore gate: same lock_rotation key.
------------------------------------------------------------------------
local fmr_body = filemanager:match("function FileManager:setRotationMode%(%)(.-)\nend")
report(fmr_body ~= nil, "FileManager:setRotationMode body found", fmr_body and #fmr_body)
report(fmr_body ~= nil
        and fmr_body:find('G_reader_settings:isTrue("lock_rotation")', 1, true) ~= nil
        and fmr_body:find('"fm_rotation_mode"', 1, true) ~= nil,
    "fm restore: lock_rotation gates fm_rotation_mode", "gated")

------------------------------------------------------------------------
-- 4. State file reachability: syncGyroState only via toggleGSensor, and
--    nothing on the boot path calls toggleGSensor.
------------------------------------------------------------------------
-- Repo device.lua: exactly one *call* of syncGyroState, inside
-- PineNote:toggleGSensor (definition and _syncGyroState export aside).
local calls = {}
for pos in device_lua:gmatch("()syncGyroState%(") do
    local line_start = device_lua:sub(1, pos):match(".*\n()") or 1
    local line = device_lua:sub(line_start, device_lua:find("\n", pos) or #device_lua)
    if not line:find("local function syncGyroState")
        and not line:find("_syncGyroState") then
        calls[#calls + 1] = line:gsub("^%s+", ""):gsub("%s+$", "")
    end
end
report(#calls == 1 and calls[1]:find("local rotation = syncGyroState(self.input)", 1, true) ~= nil,
    "state file: repo device.lua calls syncGyroState exactly once",
    table.concat(calls, " | "))
local toggle_body = device_lua:match("function PineNote:toggleGSensor%(toggle%)(.-)\nend")
report(toggle_body ~= nil and toggle_body:find("syncGyroState", 1, true) ~= nil
        and toggle_body:find("toggle == true", 1, true) ~= nil,
    "state file: the one call sits in PineNote:toggleGSensor, on enable only",
    "gated on toggle == true")

-- Upstream: the boot path never calls toggleGSensor.  Generic init only
-- assigns the handler; reader.lua, FileManager and ReaderView are
-- toggle-free; DeviceListener remains the only caller (the user-facing
-- menu lever), inside its gsensor handlers.
report(init_body ~= nil and not init_body:find("toggleGSensor", 1, true),
    "boot path: Generic Device:init does not call toggleGSensor", "clean")
report(not readermain:find("toggleGSensor", 1, true),
    "boot path: reader.lua does not call toggleGSensor", "clean")
report(not filemanager:find("toggleGSensor", 1, true),
    "boot path: filemanager.lua does not call toggleGSensor", "clean")
report(not readerview:find("toggleGSensor", 1, true),
    "boot path: readerview.lua does not call toggleGSensor", "clean")
local dl_calls = 0
for _ in devicelistener:gmatch("Device:toggleGSensor%(") do
    dl_calls = dl_calls + 1
end
report(dl_calls >= 2
        and devicelistener:find("function DeviceListener:onToggleGSensor", 1, true) ~= nil
        and devicelistener:find("function DeviceListener:onTempGSensorOn", 1, true) ~= nil,
    "menu lever: DeviceListener still calls toggleGSensor from its handlers",
    dl_calls .. " calls")

------------------------------------------------------------------------

if failures == 0 then
    print("RESULT: ok")
else
    print(string.format("RESULT: %d failure(s)", failures))
    os.exit(1)
end
