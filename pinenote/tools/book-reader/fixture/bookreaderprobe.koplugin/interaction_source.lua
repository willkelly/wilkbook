-- A deliberately small callback-style source for UIManager:insertZMQ().
--
-- This is fixture transport, not a Book Protocol codec. It accepts in-memory
-- Lua values, processes at most one per UIManager poll, and bounds only queue
-- length. Framing, byte/depth limits, authentication, and capabilities belong
-- to the separately owned broker/protocol work.

local InteractionSource = {}
InteractionSource.__index = InteractionSource

function InteractionSource:new(options)
    assert(type(options) == "table", "options table required")
    assert(type(options.receive) == "function", "receive callback required")
    local max_queued = options.max_queued
    if max_queued == nil then max_queued = 8 end
    assert(type(max_queued) == "number",
        "max_queued must be a finite positive integer")
    assert(max_queued == max_queued and max_queued ~= math.huge
            and max_queued ~= -math.huge and max_queued >= 1
            and max_queued == math.floor(max_queued),
        "max_queued must be a finite positive integer")
    local source = {
        receive = options.receive,
        on_error = options.on_error,
        max_queued = max_queued,
        queue = {},
        closed = false,
        in_wait = false,
        callback_count = 0,
        processed_count = 0,
        reentrant_wait_count = 0,
        stop_count = 0,
        dropped_count = 0,
    }
    return setmetatable(source, self)
end

function InteractionSource:enqueue(message)
    if self.closed then return false, "closed" end
    if #self.queue >= self.max_queued then return false, "queue-full" end
    self.queue[#self.queue + 1] = message
    return true
end

-- UIManager invokes this as a Lua iterator. Returning nil after one callback
-- ends that processZMQs() iterator pass and keeps work per UI tick bounded.
function InteractionSource:waitEvent()
    if self.closed or not self.queue[1] then return nil end
    if self.in_wait then
        self.reentrant_wait_count = self.reentrant_wait_count + 1
        return nil
    end

    self.in_wait = true
    local caller = debug.getinfo(2, "n")
    self.last_wait_caller = caller and caller.name
    local ok, err = xpcall(function()
        local message = table.remove(self.queue, 1)
        self.processed_count = self.processed_count + 1
        self.callback_count = self.callback_count + 1
        self.receive(message)
    end, debug.traceback)
    -- Clear this before either stop or on_error: cleanup code is allowed to
    -- inspect or idempotently poll the source and must never inherit "busy".
    self.in_wait = false
    if not ok then
        self:stop()
        if self.on_error then self.on_error(err) end
    end
    return nil
end

function InteractionSource:stop()
    if self.closed then return false end
    self.closed = true
    self.stop_count = self.stop_count + 1
    self.dropped_count = self.dropped_count + #self.queue
    self.queue = {}
    return true
end

return InteractionSource
