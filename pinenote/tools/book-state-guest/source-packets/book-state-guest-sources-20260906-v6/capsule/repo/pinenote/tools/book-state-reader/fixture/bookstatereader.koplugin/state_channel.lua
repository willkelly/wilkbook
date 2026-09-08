-- Bounded private channel for the persistent-note UI fixture.  This preserves
-- the accepted lowercase-hex/UTF-8 frame shape but has its own closed successor
-- vocabulary.  It is never Book Protocol and is never donated to a book.

local bit = require("bit")
local ffi = require("ffi")

ffi.cdef[[
typedef long ssize_t;
typedef unsigned long size_t;
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int close(int fd);
int fcntl(int fd, int command, ...);
]]

local C = ffi.C
assert(ffi.os == "Linux", "private state-reader channel requires Linux")
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048
local EINTR = 4
local EAGAIN = 11
local MAX_GENERATION = 1000000
local MAX_VALUE_BYTES = 4096
local MAX_LINE_BYTES = 8224
local MAX_INPUT_BYTES = MAX_LINE_BYTES + 4096
local MAX_QUEUE_FRAMES = 8
local MAX_QUEUE_BYTES = MAX_QUEUE_FRAMES * (MAX_LINE_BYTES + 1)
local READ_BUDGET = 4096
local WRITE_BUDGET = 4096

local command_kinds = {
    open = true,
    ["load-absent"] = true,
    ["load-value"] = true,
    edit = true,
    save = true,
    ["commit-ok"] = true,
    ["commit-failed"] = true,
    present = true,
    navigate = true,
    close = true,
    finish = true,
}

local event_kinds = {
    ["channel-ready"] = true,
    ready = true,
    status = true,
    submit = true,
    applied = true,
    ignored = true,
    navigated = true,
    closed = true,
    done = true,
}

local function valid_text(text)
    if type(text) ~= "string" or #text > MAX_VALUE_BYTES
            or text:find("\0", 1, true) then
        return false
    end
    local index = 1
    while index <= #text do
        local first = text:byte(index)
        local needed, minimum, value
        if first > 0 and first < 0x80 then
            needed, minimum, value = 0, 0, first
        elseif first >= 0xc2 and first <= 0xdf then
            needed, minimum, value = 1, 0x80, bit.band(first, 0x1f)
        elseif first >= 0xe0 and first <= 0xef then
            needed, minimum, value = 2, 0x800, bit.band(first, 0x0f)
        elseif first >= 0xf0 and first <= 0xf4 then
            needed, minimum, value = 3, 0x10000, bit.band(first, 0x07)
        else
            return false
        end
        if index + needed > #text then return false end
        for offset = 1, needed do
            local continuation = text:byte(index + offset)
            if continuation < 0x80 or continuation > 0xbf then return false end
            value = bit.bor(bit.lshift(value, 6), bit.band(continuation, 0x3f))
        end
        if value < minimum or value > 0x10ffff
                or (value >= 0xd800 and value <= 0xdfff) then
            return false
        end
        index = index + needed + 1
    end
    return true
end

local function hex_encode(value)
    return (value:gsub(".", function(character)
        return string.format("%02x", character:byte())
    end))
end

local function hex_decode(value)
    if #value % 2 ~= 0 or value:find("[^0-9a-f]") then
        return nil, "private control value is not lowercase even-length hex"
    end
    local result = value:gsub("..", function(pair)
        return string.char(tonumber(pair, 16))
    end)
    if not valid_text(result) then
        return nil, "private control value is not ordinary bounded UTF-8 text"
    end
    return result
end

local function parse_line(line)
    if type(line) ~= "string" or #line > MAX_LINE_BYTES then
        return nil, "private control line exceeds its byte limit"
    end
    local kind, generation_text, encoded =
        line:match("^([^|]+)|([^|]+)|([^|]*)$")
    if not kind or not command_kinds[kind] then
        return nil, "private control command kind is invalid"
    end
    if not generation_text:match("^[1-9][0-9]*$") then
        return nil, "private control generation is not canonical"
    end
    local generation = tonumber(generation_text)
    if not generation or generation > MAX_GENERATION
            or tostring(generation) ~= generation_text then
        return nil, "private control generation is outside its range"
    end
    local value, err = hex_decode(encoded)
    if value == nil then return nil, err end
    return { kind = kind, generation = generation, value = value }
end

local function encode_line(kind, generation, value)
    if not event_kinds[kind] then
        return nil, "private control event kind is invalid"
    end
    if type(generation) ~= "number" or generation < 1
            or generation > MAX_GENERATION
            or generation ~= math.floor(generation) then
        return nil, "private control generation is outside its range"
    end
    if not valid_text(value) then
        return nil, "private control event value is not ordinary bounded UTF-8 text"
    end
    local line = string.format("%s|%d|%s\n",
        kind, generation, hex_encode(value))
    if #line > MAX_LINE_BYTES + 1 then
        return nil, "private control line exceeds its byte limit"
    end
    return line
end

local StateChannel = {}
StateChannel.__index = StateChannel

function StateChannel:new(options)
    assert(type(options) == "table", "options table required")
    assert(type(options.fd) == "number", "numeric fd required")
    assert(type(options.receive) == "function", "receive callback required")
    local flags = C.fcntl(options.fd, F_GETFL)
    if flags < 0 then error("could not inspect private channel flags") end
    local requested_flags = ffi.cast("int", bit.bor(flags, O_NONBLOCK))
    local set_result = C.fcntl(options.fd, F_SETFL, requested_flags)
    if set_result ~= 0 then
        error("could not make private channel nonblocking")
    end
    local effective_flags = C.fcntl(options.fd, F_GETFL)
    if effective_flags < 0
            or bit.band(effective_flags, O_NONBLOCK) ~= O_NONBLOCK then
        error("private channel O_NONBLOCK verification failed")
    end
    return setmetatable({
        fd = options.fd,
        receive = options.receive,
        on_error = options.on_error,
        input = "",
        output = {},
        output_bytes = 0,
        closed = false,
        in_wait = false,
        read_would_block_count = 0,
        write_would_block_count = 0,
    }, self)
end

function StateChannel:_report_error(message)
    if self.closed then return end
    if self.on_error then self.on_error(message) end
end

function StateChannel:_pump_output()
    local spent = 0
    local completed = 0
    while not self.closed and self.output[1] and spent < WRITE_BUDGET
            and completed < 4 do
        local head = self.output[1]
        local remaining = #head.data - head.offset
        local allowance = math.min(remaining, WRITE_BUDGET - spent)
        local pointer = ffi.cast("const uint8_t *", head.data) + head.offset
        local written = C.write(self.fd, pointer, allowance)
        if written > 0 then
            head.offset = head.offset + tonumber(written)
            spent = spent + tonumber(written)
            self.output_bytes = self.output_bytes - tonumber(written)
            if head.offset == #head.data then
                table.remove(self.output, 1)
                completed = completed + 1
            end
        elseif written < 0 and ffi.errno() == EINTR then
            return
        elseif written < 0 and ffi.errno() == EAGAIN then
            self.write_would_block_count = self.write_would_block_count + 1
            return
        else
            self:_report_error("private control write failed")
            return
        end
    end
end

function StateChannel:send(kind, generation, value)
    if self.closed then return false, "closed" end
    local line, err = encode_line(kind, generation, value)
    if not line then return false, err end
    if #self.output >= MAX_QUEUE_FRAMES
            or self.output_bytes + #line > MAX_QUEUE_BYTES then
        return false, "private control output queue is full"
    end
    self.output[#self.output + 1] = { data = line, offset = 0 }
    self.output_bytes = self.output_bytes + #line
    self:_pump_output()
    return true
end

function StateChannel:waitEvent()
    if self.closed or self.in_wait then return nil end
    self.in_wait = true
    local ok, err = xpcall(function()
        self:_pump_output()
        local newline = self.input:find("\n", 1, true)
        if not newline then
            local buffer = ffi.new("uint8_t[?]", READ_BUDGET)
            local received = C.read(self.fd, buffer, READ_BUDGET)
            if received > 0 then
                self.input = self.input .. ffi.string(buffer, received)
                if #self.input > MAX_INPUT_BYTES then
                    error("private control input buffer exceeds its bound")
                end
                newline = self.input:find("\n", 1, true)
            elseif received == 0 then
                error("private control host closed unexpectedly")
            elseif ffi.errno() == EAGAIN then
                self.read_would_block_count =
                    self.read_would_block_count + 1
            elseif ffi.errno() ~= EINTR then
                error("private control read failed")
            end
        end
        if newline then
            local line = self.input:sub(1, newline - 1)
            self.input = self.input:sub(newline + 1)
            local message, parse_err = parse_line(line)
            if not message then error(parse_err) end
            self.receive(message)
        elseif #self.input > MAX_LINE_BYTES then
            error("private control line exceeds its byte limit")
        end
    end, debug.traceback)
    self.in_wait = false
    if not ok then self:_report_error(err) end
    return nil
end

function StateChannel:stop()
    if self.closed then return false end
    self.closed = true
    self.input = ""
    self.output = {}
    self.output_bytes = 0
    C.close(self.fd)
    return true
end

-- Exact-runtime codec tests use these without constructing a second decoder.
StateChannel.parseCommandLine = parse_line
StateChannel.encodeEventLine = encode_line
StateChannel.validText = valid_text
StateChannel.commandKinds = command_kinds
StateChannel.eventKinds = event_kinds

return StateChannel
