-- Run from any directory: luajit export-line.lua ROOT ID PAGE TRANSCRIPT.txt
local here = (arg[0] or ""):match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. here .. "/../../packages/koreader-device/plugins/notebook.koplugin/?.lua;" .. package.path
local Sample = require("sample")
local function read(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local text = f:read(64 * 1024 * 1024 + 1) or ""
    f:close()
    assert(#text <= 64 * 1024 * 1024, "input exceeds 64 MiB")
    return text
end
local ok, result = pcall(function()
    assert(#arg == 4, "usage: luajit export-line.lua ROOT ID PAGE TRANSCRIPT.txt > sample.inkml")
    return Sample.export(arg[1], arg[2], assert(tonumber(arg[3]), "invalid page"),
                         assert(read(arg[4])), read)
end)
if not ok then io.stderr:write(tostring(result), "\n"); os.exit(1) end
assert(io.write(result))
assert(io.flush())
