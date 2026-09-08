-- Three controlled stream socketpairs for the native KOReader UI fixture. The
-- production plugin owns each client endpoint through its real StateChannel;
-- the fixture controller owns only the authority-side test endpoints.
local bit = require("bit")
local ffi = require("ffi")

ffi.cdef[[
int socketpair(int domain, int type, int protocol, int descriptors[2]);
long read(int fd, void *buffer, unsigned long count);
long write(int fd, const void *buffer, unsigned long count);
int close(int fd);
int fcntl(int fd, int command, ...);
]]

local C = ffi.C
local AF_UNIX, SOCK_STREAM = 1, 1
local F_GETFL, F_SETFL, O_NONBLOCK = 3, 4, 2048
local EINTR, EAGAIN = 4, 11
local pairs = {}

for index = 1, 3 do
    local descriptors = ffi.new("int[2]")
    assert(C.socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0,
        "real-UI socketpair creation failed")
    local server = tonumber(descriptors[1])
    local flags = C.fcntl(server, F_GETFL)
    assert(flags >= 0 and C.fcntl(server, F_SETFL,
        ffi.cast("int", bit.bor(flags, O_NONBLOCK))) == 0,
        "real-UI authority endpoint could not become nonblocking")
    pairs[index] = {
        client = tonumber(descriptors[0]),
        server = server,
        input = "",
        client_taken = false,
        server_closed = false,
    }
end

local function valid_text(value)
    return type(value) == "string" and #value <= 4096
        and not value:find("\0", 1, true)
end

local function hex_encode(value)
    return (value:gsub(".", function(character)
        return string.format("%02x", character:byte())
    end))
end

local function hex_decode(value)
    if #value % 2 ~= 0 or value:find("[^0-9a-f]") then return nil end
    return (value:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local connection_index = 0
local Fixture = { client = {} }

function Fixture.client.connect()
    connection_index = connection_index + 1
    local pair = pairs[connection_index]
    if not pair or pair.client_taken then
        return nil, "real-UI fixture has no fresh socketpair"
    end
    pair.client_taken = true
    return pair.client
end

function Fixture.send(index, kind, value)
    local pair = assert(pairs[index], "unknown real-UI socketpair")
    value = value or ""
    assert(valid_text(value), "invalid real-UI command value")
    local frame = string.format("%s|1|%s\n", kind, hex_encode(value))
    local written = C.write(pair.server, frame, #frame)
    assert(written == #frame, "short real-UI authority write")
end

function Fixture.take(index)
    local pair = assert(pairs[index], "unknown real-UI socketpair")
    local newline = pair.input:find("\n", 1, true)
    while not newline and not pair.server_closed do
        local buffer = ffi.new("uint8_t[4096]")
        local received = C.read(pair.server, buffer, 4096)
        if received > 0 then
            pair.input = pair.input .. ffi.string(buffer, received)
            assert(#pair.input <= 12288, "real-UI event input exceeded bound")
            newline = pair.input:find("\n", 1, true)
        elseif received == 0 then
            pair.server_closed = true
        elseif ffi.errno() == EINTR then
            -- Retry the interrupted read within this bounded pump.
        elseif ffi.errno() == EAGAIN then
            break
        else
            error("real-UI authority read failed: " .. ffi.errno())
        end
    end
    if not newline then return nil end
    local line = pair.input:sub(1, newline - 1)
    pair.input = pair.input:sub(newline + 1)
    local kind, generation_text, encoded = line:match("^([^|]+)|([^|]+)|(.*)$")
    local value = encoded and hex_decode(encoded)
    assert(kind and generation_text == "1" and value and valid_text(value),
        "invalid real-UI event frame: " .. line)
    return { kind = kind, generation = 1, value = value }
end

function Fixture.peerClosed(index)
    Fixture.take(index)
    return pairs[index].server_closed
end

function Fixture.closeServers()
    for _, pair in ipairs(pairs) do
        if pair.server >= 0 then
            C.close(pair.server)
            pair.server = -1
        end
    end
end

return Fixture
