-- Pure host checks for the callback source, under the pinned bundle's LuaJIT.
local plugin_dir = assert(arg[1], "arg1: fixture plugin directory")
local Source = dofile(plugin_dir .. "/interaction_source.lua")

local function check(ok, message)
    if not ok then error(message, 2) end
end

local invalid_limits = {
    false,
    "1",
    0,
    -1,
    1.5,
    math.huge,
    -math.huge,
    0 / 0,
}
for _, limit in ipairs(invalid_limits) do
    local ok = pcall(function()
        Source:new{ max_queued = limit, receive = function() end }
    end)
    check(not ok, "invalid max_queued accepted: " .. tostring(limit))
end
for _, limit in ipairs({ 1, 2, 1024 }) do
    local source = Source:new{
        max_queued = limit,
        receive = function() end,
    }
    check(source.max_queued == limit,
        "valid max_queued rejected: " .. tostring(limit))
end
print("PASS: max_queued is a finite positive integer")

local callbacks = 0
local recursive
recursive = Source:new{
    max_queued = 1,
    receive = function()
        callbacks = callbacks + 1
        if callbacks < 3 then
            check(recursive:enqueue("replacement"),
                "recursive callback could not enqueue replacement")
            recursive:waitEvent()
        end
    end,
}
check(recursive:enqueue("initial"), "could not enqueue initial message")
recursive:waitEvent()
check(callbacks == 1 and recursive.callback_count == 1,
    "one outer waitEvent performed more than one callback")
check(#recursive.queue == 1 and recursive.reentrant_wait_count == 1,
    "reentrant wait was not rejected with replacement still queued")
recursive:waitEvent()
check(callbacks == 2 and recursive.callback_count == 2,
    "second outer waitEvent did not perform exactly one callback")
recursive:waitEvent()
check(callbacks == 3 and recursive.callback_count == 3
        and #recursive.queue == 0 and not recursive.in_wait,
    "recursive fixture did not drain one callback per outer poll")
print("PASS: recursive receive cannot re-enter waitEvent")

local reported_error
local failing = Source:new{
    max_queued = 2,
    receive = function()
        error("expected recursive fixture error")
    end,
    on_error = function(err)
        reported_error = err
    end,
}
check(failing:enqueue("error"), "could not enqueue error message")
check(failing:enqueue("drop"), "could not enqueue drop message")
failing:waitEvent()
check(failing.closed and not failing.in_wait and failing.stop_count == 1,
    "callback error did not clear guard and stop exactly once")
check(#failing.queue == 0 and failing.dropped_count == 1,
    "callback error did not empty queued work")
check(tostring(reported_error):find("expected recursive fixture error", 1, true),
    "callback error was not reported")
local count = failing.callback_count
failing:waitEvent()
check(failing.callback_count == count,
    "closed error source invoked another callback")
print("PASS: callback error clears guard, queue, and source")
print("RESULT: ok")
