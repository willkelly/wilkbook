-- Live host check: loss of the required orientation-style evdev node must be
-- fatal so reader-session respawns KOReader and re-enumerates its replacement.
local koreader_dir = assert(arg[1], "arg1: koreader bundle dir")
local backend_path = assert(arg[2], "arg2: repo input_evdev.lua")
local node = assert(arg[3], "arg3: evdev node")
local ready_path = assert(arg[4], "arg4: readiness file")

package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

local input = dofile(backend_path)
input.open(node, "required-device lifecycle test")
input.setRequiredDevice(node)
local ready = assert(io.open(ready_path, "w"))
ready:write("ready\n")
ready:close()

local ok, err = input.waitForEvent(nil)
if ok == nil and err == "required input device lost" then
    print("PASS: required evdev loss is fatal")
    print("RESULT: ok")
else
    print(string.format("FAIL: required evdev loss returned %s, %s",
                        tostring(ok), tostring(err)))
    print("RESULT: failed")
    os.exit(1)
end
