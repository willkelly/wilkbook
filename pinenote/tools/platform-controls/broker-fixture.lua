-- Load the production helper definitions without starting device discovery or
-- the daemon. Tests replace only OS boundaries, not the renderer/transaction.
return function(path, deps, exports)
    local f = assert(io.open(path)); local source = f:read("*a"); f:close()
    local prefix = assert(source:match("^(.-)local function create_uinput%(%)"))
    local env = setmetatable(deps, { __index = _G })
    env.arg = { [0] = path }
    local chunk = assert(loadstring(prefix .. "\nreturn " .. exports, "@" .. path))
    setfenv(chunk, env)
    return chunk(), source, env
end
