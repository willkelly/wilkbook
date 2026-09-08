local ffi = require("ffi")

ffi.cdef[[
int socketpair(int domain, int type, int protocol, int sockets[2]);
int close(int fd);
]]

local plugin_dir = assert(arg[1], "fixture plugin directory required")
package.path = plugin_dir .. "/?.lua;" .. package.path
local StateChannel = require("state_channel")

local function check(condition, message)
    if not condition then error(message, 2) end
end

local command_count = 0
for _ in pairs(StateChannel.commandKinds) do command_count = command_count + 1 end
local event_count = 0
for _ in pairs(StateChannel.eventKinds) do event_count = event_count + 1 end
check(command_count == 11, "closed command enumeration changed")
check(event_count == 9, "closed event enumeration changed")

local parsed = assert(StateChannel.parseCommandLine("load-value|7|c3a96c616e20cebb"))
check(parsed.kind == "load-value" and parsed.generation == 7
        and parsed.value == "élan λ", "multilingual command did not decode")
local encoded = assert(StateChannel.encodeEventLine("submit", 7, "東京"))
check(encoded == "submit|7|e69db1e4baac\n", "event did not encode canonically")

for _, line in ipairs({
    "future|1|",
    "open|01|",
    "open|1|C3A9",
    "load-value|1|c0af",
    "load-value|1|00",
}) do
    check(StateChannel.parseCommandLine(line) == nil,
        "invalid command line was accepted: " .. line)
end
check(StateChannel.validText(string.rep("x", 4096)),
    "exact 4096-byte value was rejected")
check(not StateChannel.validText(string.rep("x", 4097)),
    "4097-byte value was accepted")
check(not StateChannel.validText("a\0b"), "U+0000 was accepted")
check(not StateChannel.validText("\237\160\128"), "UTF-8 surrogate was accepted")

local sockets = ffi.new("int[2]")
check(ffi.C.socketpair(1, 1, 0, sockets) == 0, "socketpair failed")
local callbacks = 0
local callback_message
local callback_error
local channel = StateChannel:new{
    fd = sockets[0],
    receive = function(message)
        callbacks = callbacks + 1
        callback_message = message
    end,
    on_error = function(err) callback_error = err end,
}

channel:waitEvent()
check(channel.read_would_block_count == 1 and callbacks == 0
        and callback_error == nil, "empty channel poll did not return through EAGAIN")

local command = "edit|4|c3a96c616e20cebb\n"
check(ffi.C.write(sockets[1], command, #command) == #command,
    "could not write test command")
channel:waitEvent()
check(callbacks == 1 and callback_message.kind == "edit"
        and callback_message.generation == 4
        and callback_message.value == "élan λ",
    "channel did not deliver exact decoded command")

check(channel:send("applied", 4, "東京"), "could not send exact event")
local buffer = ffi.new("uint8_t[128]")
local received = ffi.C.read(sockets[1], buffer, 128)
check(received > 0 and ffi.string(buffer, received) == "applied|4|e69db1e4baac\n",
    "peer did not receive canonical event")

channel:stop()
ffi.C.close(sockets[1])
print("PASS: exact-runtime state channel framing and nonblocking delivery")
