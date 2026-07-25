-- Live host check: loss of either registered virtual evdev node is fatal, while
-- loss of an optional node remains nonfatal so reader-session only respawns for
-- lifecycle-critical devices.
local koreader_dir = assert(arg[1], "arg1: koreader bundle dir")
local backend_path = assert(arg[2], "arg2: repo input_evdev.lua")
local first_required = assert(arg[3], "arg3: first required evdev node")
local second_required = assert(arg[4], "arg4: second required evdev node")
local optional = assert(arg[5], "arg5: optional evdev node")
local lost = assert(arg[6], "arg6: evdev node to lose")
local expected = assert(arg[7], "arg7: fatal or nonfatal")
local ready_path = assert(arg[8], "arg8: readiness file")

package.path = table.concat({
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    koreader_dir .. "/common/?.lua",
    package.path,
}, ";")
package.cpath = koreader_dir .. "/?.so;" .. package.cpath

local input = dofile(backend_path)
input.open(first_required, "first required-device lifecycle test")
input.open(second_required, "second required-device lifecycle test")
input.open(optional, "optional-device lifecycle test")
input.setRequiredDevice(first_required)
input.setRequiredDevice(second_required)
local ready = assert(io.open(ready_path, "w"))
ready:write("ready\n")
ready:close()

local ok, err = input.waitForEvent(nil)
if expected == "fatal" and ok == nil and err == "required input device lost" then
    print("PASS: required evdev loss is fatal")
    print("RESULT: ok")
elseif expected == "nonfatal" and ok == false and err ~= "required input device lost" then
    print("PASS: optional evdev loss is nonfatal")
    print("RESULT: ok")
else
    print(string.format("FAIL: %s evdev loss returned %s, %s",
                        expected, tostring(ok), tostring(err)))
    print("RESULT: failed")
    os.exit(1)
end
