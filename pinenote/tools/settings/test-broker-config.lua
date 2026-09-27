-- Execute only the shipping broker's configuration section in an environment
-- whose io.open serves strings. Never load the FFI/hardware/event-loop code.
-- The Guile audit mutation-tests their values; below we also break each
-- section's extraction boundary (missing, renamed and duplicate declarations).
-- Lua 5.1+ (or LuaJIT); no third-party modules.
local root = arg[1] or "."
local path = root .. "/pinenote/packages/platform-controls/pinenote-power-broker.lua"
local f = assert(io.open(path, "r"))
local source = f:read("*a"); f:close()
local patterns = {}
local function extract(pattern, input)
    local found, count
    for text in (input or source):gmatch(pattern) do found, count = text, (count or 0) + 1 end
    assert(count == 1, "missing/ambiguous broker config extraction: " .. pattern)
    if not input then patterns[#patterns + 1] = pattern end
    return found
end
local chunk = extract("(local CONFIGS = %b{})") .. "\n"
    .. extract("(local BACKSTOP, ACK_TIMEOUT, POWER_GRACE = [^\n]+)") .. "\n"
    .. extract("(local RTC_SETTLE = [^\n]+)") .. "\n"
    .. extract("(local config = %b{})") .. "\n"
    .. extract("(local warned_idle = [^\n]+)") .. "\n"
    .. extract("(local function reload_config%(%)\n.-\nend)")
    .. "\nreturn function() reload_config(); return config end"
local files, logs = {}, {}
local env = {
    ipairs = ipairs, tonumber = tonumber, math = math,
    log = function(...) logs[#logs + 1] = {...} end,
    io = {open = function(name, mode)
        assert(mode == "r", "config attempted a write")
        local text = files[name]; if text == nil then return nil end
        return {lines = function() return (text .. "\n"):gmatch("([^\n]*)\n") end,
                close = function() return true end}
    end},
}
local compile
if _VERSION == "Lua 5.1" then
    compile = assert(loadstring(chunk, "broker-config-fixture")); setfenv(compile, env)
else
    compile = assert(load(chunk, "broker-config-fixture", "t", env))
end
local reload = compile()
local count = 0
local function expect(label, expected)
    local actual = reload()
    for key, value in pairs(expected) do
        assert(actual[key] == value, label .. ": " .. key .. " expected " .. tostring(value)
               .. ", got " .. tostring(actual[key]))
    end
    count = count + 1
end
local data = "/data/wilkbook/autosuspend.conf"
local localfile = "/var/lib/pinenote/autosuspend.conf"
local inhibit = "/run/wilkbook-power/inhibit.conf"
local defaults = {enabled=true, charging=false, backstop=3600, rtc_settle=20}
expect("absent files", defaults)
for _, value in ipairs({"0", "false", "no", "1", "true", "yes", "off", "on", "FALSE", "TRUE", "garbage"}) do
    files[data] = "enabled=" .. value .. "\nsuspend_while_charging=" .. value
    expect("case-sensitive boolean grammar: " .. value, {
        enabled = not (value == "0" or value == "false" or value == "no"),
        charging = value == "1" or value == "true" or value == "yes",
    })
end
for _, case in ipairs({
    {"29", 3600}, {"30", 30}, {"30.9", 30}, {"1e3", 1000},
    {"-1", 3600}, {"bad", 3600}, {"", 3600}, {"1e309", math.huge},
}) do
    files[data] = "backstop=" .. case[1]
    expect("backstop lower bound/floor (no finite upper bound): " .. case[1], {backstop=case[2]})
end
for _, case in ipairs({{"19",20}, {"20",20}, {"20.9",20}, {"3601",3600}, {"bad",20}}) do
    files[data] = "rtc_settle=" .. case[1]
    expect("rtc settle clamp: " .. case[1], {rtc_settle=case[2]})
end
files[data] = "enabled=0\nbackstop=40\nsuspend_while_charging=yes\nrtc_settle=60"
files[localfile] = "enabled=1\nbackstop=50\nrtc_settle=70"
expect("local overrides data key by key", {enabled=true, charging=true, backstop=50, rtc_settle=70})
files[inhibit] = "enabled=0\nbackstop=80\nsuspend_while_charging=no"
expect("run overrides local and data", {enabled=false, charging=false, backstop=80, rtc_settle=70})
files[inhibit] = "enabled=yes"
expect("inhibit file is last-writer, not a veto-only layer", {enabled=true})
files[inhibit] = "backstop=bad\nrtc_settle=1"
expect("invalid upper-layer numbers retain lower-layer values", {backstop=50, rtc_settle=70})
files[localfile], files[inhibit] = nil, nil
files[data] = "  enabled = 0 # comment\nbackstop=33.7\nbackstop=bad\nunknown=7\n=oops"
expect("whitespace, unknown keys, last valid duplicate", {enabled=false, backstop=33})
files[data] = "enabled=0\nenabled=1\nbackstop=40\nbackstop=50"
expect("last valid duplicate wins", {enabled=true, backstop=50})
files[data] = "enabled=0#comment\nsuspend_while_charging=yes#comment"
expect("attached comments remain part of token", {enabled=true, charging=false})
files[data] = "idle=5\npower_key=0\nunknown=1"
expect("obsolete idle and legacy power_key do not control broker", defaults)
reload()
assert(#logs == 1, "obsolete idle should warn once")
files[data] = nil
expect("removing overrides restores all defaults on reload", defaults)
for _, pattern in ipairs(patterns) do
    local first, last = assert(source:find(pattern))
    local section = source:sub(first, last)
    for _, mutant in ipairs({
        source:sub(1, first - 1) .. source:sub(last + 1),
        source:sub(1, first - 1) .. "MUTATED" .. section:sub(6) .. source:sub(last + 1),
        source .. "\n" .. section,
    }) do
        assert(not pcall(extract, pattern, mutant), "vacuous extraction: " .. pattern)
        count = count + 1
    end
end
print(("broker config fixtures: %d passed"):format(count))
