-- Syntax-only loader for the package's monolithic LuaJIT command, which does
-- not provide the optional standalone `-b` command.
if #arg ~= 2 then
    error("usage: check-lua-syntax.lua META MAIN")
end
for _, path in ipairs(arg) do
    local chunk, message = loadfile(path)
    if not chunk then
        error(message)
    end
end
print("JOIN-LUA-SYNTAX: 2/2")
