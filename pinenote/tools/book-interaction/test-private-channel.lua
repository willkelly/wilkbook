-- Exact-runtime nonblocking regression for the trusted LuaJIT private channel.
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
int socketpair(int domain, int type, int protocol, int sockets[2]);
int setsockopt(int fd, int level, int option, const void *value,
    unsigned int length);
int close(int fd);
int fcntl(int fd, int command, ...);
]]

local AF_UNIX = 1
local SOCK_STREAM = 1
local SOL_SOCKET = 1
local SO_SNDBUF = 7
local F_GETFL = 3
local O_NONBLOCK = 2048
local MAX_QUEUE_FRAMES = 8
local MAX_QUEUE_BYTES = 65800

assert(ffi.os == "Linux", "test requires the reviewed Linux ABI")
local fixture = assert(arg[1], "fixture directory required")
package.path = fixture .. "/?.lua;" .. package.path
local PrivateChannel = require("private_channel")

local sockets = ffi.new("int[2]")
assert(ffi.C.socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0,
    "socketpair failed")
local send_buffer = ffi.new("int[1]", 4096)
assert(ffi.C.setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF,
    send_buffer, ffi.sizeof(send_buffer)) == 0, "SO_SNDBUF failed")

local callback_count = 0
local callback_error
local channel = PrivateChannel:new{
    fd = sockets[0],
    receive = function() callback_count = callback_count + 1 end,
    on_error = function(err) callback_error = err end,
}

local flags = ffi.C.fcntl(sockets[0], F_GETFL)
assert(flags >= 0 and bit.band(flags, O_NONBLOCK) == O_NONBLOCK,
    "O_NONBLOCK was not effective after construction")

-- The peer sends nothing. This exact waitEvent call must return through
-- EAGAIN rather than block in read(2).
channel:waitEvent()
assert(channel.read_would_block_count == 1,
    "empty waitEvent did not observe bounded EAGAIN")
assert(callback_count == 0 and callback_error == nil,
    "empty waitEvent invoked a callback or error")

local payload = string.rep("x", 4096)
local queue_full = false
for _ = 1, 256 do
    local ok, err = channel:send("tick", 1, payload)
    assert(#channel.output <= MAX_QUEUE_FRAMES,
        "output frame queue exceeded its bound")
    assert(channel.output_bytes <= MAX_QUEUE_BYTES,
        "output byte queue exceeded its bound")
    if not ok then
        assert(err == "private control output queue is full",
            "never-read peer produced the wrong backpressure result")
        queue_full = true
        break
    end
end

assert(queue_full, "never-read peer did not reach queue backpressure")
assert(channel.write_would_block_count > 0,
    "never-read peer did not return EAGAIN from write(2)")
assert(#channel.output > 0 and channel.output_bytes > 0,
    "backpressure did not retain pending bounded output")

local frames_before = #channel.output
local bytes_before = channel.output_bytes
local ok, err = channel:send("tick", 1, payload)
assert(not ok and err == "private control output queue is full",
    "queue-full retry was not rejected")
assert(#channel.output == frames_before
        and channel.output_bytes == bytes_before,
    "queue-full retry changed pending output")

-- Output remains blocked and the peer still sends nothing. The combined pump
-- must return without invoking callbacks or exceeding either queue bound.
channel:waitEvent()
assert(channel.write_would_block_count > 1
        and channel.read_would_block_count > 1,
    "backpressured waitEvent did not return through EAGAIN")
assert(#channel.output <= MAX_QUEUE_FRAMES
        and channel.output_bytes <= MAX_QUEUE_BYTES,
    "backpressured waitEvent exceeded pending bounds")
assert(callback_count == 0 and callback_error == nil,
    "backpressured waitEvent invoked a callback or error")

channel:stop()
ffi.C.close(sockets[1])
print("PASS: typed fcntl and never-read private channel remain nonblocking")
