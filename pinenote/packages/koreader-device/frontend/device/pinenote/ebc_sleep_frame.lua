local private = setmetatable({}, { __mode = "k" })
local tokens = setmetatable({}, { __mode = "k" })

local required = {
    "paint_show", "force_repaint", "framebuffer_fd", "fsync", "barrier", "restore",
}
local allowed = {}
for _, name in ipairs(required) do allowed[name] = true end

local function pack(...)
    return { n = select("#", ...), ... }
end

local function call(name, fn, ...)
    local result = pack(pcall(fn, ...))
    if not result[1] then return false, name .. " threw: " .. tostring(result[2]) end
    if result[2] == false then return false, name .. " returned false" end
    return true, result
end

local function poison(data, error_text)
    data.state = "POISONED"
    data.failure = error_text
    return false, error_text
end

local Provider = {}
Provider.__index = Provider

function Provider:prepare(...)
    local data = private[self]
    if data.state == "POISONED" then return false, data.failure end
    if data.state ~= "IDLE" then return false, "sleep frame is not idle" end
    if select("#", ...) ~= 0 then return false, "prepare accepts no arguments" end

    data.state = "PREPARING"
    local ok, result = call("paint_show", data.paint_show)
    if not ok then return poison(data, result) end
    if result.n ~= 2 or result[2] == nil then return poison(data, "paint_show returned absent or malformed payload") end
    local payload = result[2]
    ok, result = call("force_repaint", data.force_repaint)
    if not ok then return poison(data, result) end
    ok, result = call("fsync", data.fsync, data.framebuffer_fd)
    if not ok then return poison(data, result) end
    if result.n ~= 2 or result[2] ~= 0 then return poison(data, "fsync returned nonzero or malformed result") end
    ok, result = call("barrier", data.barrier_submit)
    if not ok then return poison(data, result) end
    if result.n ~= 3 or result[2] ~= true or result[3] == nil then
        return poison(data, "barrier returned malformed result")
    end

    local token = {}
    tokens[token] = { owner = self, generation = result[3], payload = payload, consumed = false }
    data.state = "PREPARED"
    return token
end

function Provider:restore(token, ...)
    local data = private[self]
    if data.state == "POISONED" then return false, data.failure end
    if select("#", ...) ~= 0 or type(token) ~= "table" then return false, "invalid sleep frame token" end
    local record = tokens[token]
    if not record or record.owner ~= self or record.consumed or data.state ~= "PREPARED" then
        return false, "invalid sleep frame token"
    end
    record.consumed = true
    data.state = "RESTORING"
    local ok, detail = call("restore", data.restore, record.payload)
    if not ok then return poison(data, detail) end
    ok, detail = call("force_repaint", data.force_repaint)
    if not ok then return poison(data, detail) end
    local fsync_ok, fsync_result = call("fsync", data.fsync, data.framebuffer_fd)
    if not fsync_ok then return poison(data, fsync_result) end
    if fsync_result.n ~= 2 or fsync_result[2] ~= 0 then return poison(data, "fsync returned nonzero or malformed result") end
    local barrier_ok, barrier_result = call("barrier", data.barrier_submit)
    if not barrier_ok then return poison(data, barrier_result) end
    if barrier_result.n ~= 3 or barrier_result[2] ~= true or barrier_result[3] == nil then
        return poison(data, "barrier returned malformed result")
    end
    data.state = "IDLE"
    return true
end

function Provider:status()
    local data = private[self]
    return { state = data.state, failure = data.failure }
end

local function new(dependencies)
    if type(dependencies) ~= "table" then error("sleep frame requires a dependencies table") end
    for _, name in ipairs(required) do
        if rawget(dependencies, name) == nil then error("missing sleep frame dependency: " .. name) end
    end
    for name in pairs(dependencies) do
        if not allowed[name] then error("unsupported sleep frame dependency: " .. tostring(name)) end
    end
    for _, name in ipairs({ "paint_show", "force_repaint", "fsync", "restore" }) do
        if type(rawget(dependencies, name)) ~= "function" then error("malformed sleep frame dependency: " .. name) end
    end
    local framebuffer_fd = rawget(dependencies, "framebuffer_fd")
    if type(framebuffer_fd) ~= "number" or framebuffer_fd < 0 or framebuffer_fd ~= math.floor(framebuffer_fd) then
        error("malformed sleep frame dependency: framebuffer_fd")
    end
    local barrier = rawget(dependencies, "barrier")
    if type(barrier) ~= "table" or type(rawget(barrier, "submit_and_wait")) ~= "function" then
        error("malformed sleep frame dependency: barrier")
    end
    local instance = setmetatable({}, Provider)
    private[instance] = {
        paint_show = rawget(dependencies, "paint_show"),
        force_repaint = rawget(dependencies, "force_repaint"),
        framebuffer_fd = framebuffer_fd,
        fsync = rawget(dependencies, "fsync"),
        barrier_submit = rawget(barrier, "submit_and_wait"),
        restore = rawget(dependencies, "restore"),
        state = "IDLE",
    }
    return instance
end

return { new = new }
