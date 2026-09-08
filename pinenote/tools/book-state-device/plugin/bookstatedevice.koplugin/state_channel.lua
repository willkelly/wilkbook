-- Bounded private UI channel. This is trusted UI plumbing, never Book Protocol,
-- and its descriptor is never donated to a sandboxed book.
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
local F_GETFL, F_SETFL, O_NONBLOCK = 3, 4, 2048
local EINTR, EAGAIN = 4, 11
local MAX_GENERATION, MAX_VALUE_BYTES, MAX_LINE_BYTES = 1000000, 4096, 8224
local MAX_INPUT_BYTES, MAX_QUEUE_FRAMES = MAX_LINE_BYTES + 4096, 8
local MAX_QUEUE_BYTES = MAX_QUEUE_FRAMES * (MAX_LINE_BYTES + 1)
local READ_BUDGET, WRITE_BUDGET = 4096, 4096
local command_kinds = {
    ["load-absent"] = true, ["load-value"] = true,
    ["commit-ok"] = true, ["commit-failed"] = true, present = true,
}
local event_kinds = {
    ["channel-ready"] = true, ready = true, status = true, submit = true,
    applied = true, ignored = true, closed = true,
}

local function valid_text(text)
    if type(text) ~= "string" or #text > MAX_VALUE_BYTES
            or text:find("\0", 1, true) then return false end
    local index = 1
    while index <= #text do
        local first = text:byte(index)
        local count
        if first < 0x80 then count = 1
        elseif first >= 0xC2 and first <= 0xDF then count = 2
        elseif first >= 0xE0 and first <= 0xEF then count = 3
        elseif first >= 0xF0 and first <= 0xF4 then count = 4
        else return false end
        if index + count - 1 > #text then return false end
        for offset = 1, count - 1 do
            local byte = text:byte(index + offset)
            if byte < 0x80 or byte > 0xBF then return false end
        end
        if count == 3 then
            local second = text:byte(index + 1)
            if (first == 0xE0 and second < 0xA0)
                    or (first == 0xED and second > 0x9F) then return false end
        elseif count == 4 then
            local second = text:byte(index + 1)
            if (first == 0xF0 and second < 0x90)
                    or (first == 0xF4 and second > 0x8F) then return false end
        end
        index = index + count
    end
    return true
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

local function parse_line(line)
    if #line > MAX_LINE_BYTES then return nil, "oversized authority frame" end
    local kind, generation_text, encoded = line:match("^([^|]+)|([^|]+)|(.*)$")
    local generation = generation_text and tonumber(generation_text)
    if not command_kinds[kind] or not generation
            or generation % 1 ~= 0 or generation < 1
            or generation > MAX_GENERATION
            or tostring(generation) ~= generation_text then
        return nil, "invalid authority frame header"
    end
    local value = hex_decode(encoded)
    if not value or not valid_text(value) then
        return nil, "invalid authority frame value"
    end
    return { kind = kind, generation = generation, value = value }
end

local function encode_line(kind, generation, value)
    if not event_kinds[kind] or type(generation) ~= "number"
            or generation % 1 ~= 0 or generation < 1
            or generation > MAX_GENERATION or not valid_text(value) then
        return nil, "invalid UI event"
    end
    local line = string.format("%s|%d|%s\n", kind, generation, hex_encode(value))
    if #line > MAX_LINE_BYTES + 1 then return nil, "oversized UI event" end
    return line
end

local StateChannel = {}
StateChannel.__index = StateChannel

function StateChannel:new(options)
    assert(type(options) == "table" and type(options.fd) == "number")
    assert(type(options.receive) == "function")
    local flags = C.fcntl(options.fd, F_GETFL)
    if flags < 0 or C.fcntl(options.fd, F_SETFL,
            ffi.cast("int", bit.bor(flags, O_NONBLOCK))) ~= 0 then
        error("could not make authority channel nonblocking")
    end
    return setmetatable({
        fd = options.fd, receive = options.receive, on_error = options.on_error,
        input = "", output = {}, output_bytes = 0, closed = false, in_wait = false,
    }, self)
end

function StateChannel:_report_error(message)
    if not self.closed and self.on_error then self.on_error(message) end
end

function StateChannel:_pump_output()
    local spent, completed = 0, 0
    while not self.closed and self.output[1] and spent < WRITE_BUDGET
            and completed < 4 do
        local head = self.output[1]
        local allowance = math.min(#head.data - head.offset, WRITE_BUDGET - spent)
        local pointer = ffi.cast("const uint8_t *", head.data) + head.offset
        local written = C.write(self.fd, pointer, allowance)
        if written > 0 then
            written = tonumber(written)
            head.offset, spent = head.offset + written, spent + written
            self.output_bytes = self.output_bytes - written
            if head.offset == #head.data then table.remove(self.output, 1); completed = completed + 1 end
        elseif written < 0 and (ffi.errno() == EINTR or ffi.errno() == EAGAIN) then
            return
        else self:_report_error("authority channel write failed"); return end
    end
end

function StateChannel:send(kind, generation, value)
    if self.closed then return false, "closed" end
    local line, err = encode_line(kind, generation, value or "")
    if not line then return false, err end
    if #self.output >= MAX_QUEUE_FRAMES
            or self.output_bytes + #line > MAX_QUEUE_BYTES then
        return false, "authority channel output queue is full"
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
                if #self.input > MAX_INPUT_BYTES then error("authority input exceeded bound") end
                newline = self.input:find("\n", 1, true)
            elseif received == 0 then error("authority disconnected")
            elseif ffi.errno() ~= EINTR and ffi.errno() ~= EAGAIN then
                error("authority channel read failed")
            end
        end
        if newline then
            local message, parse_err = parse_line(self.input:sub(1, newline - 1))
            self.input = self.input:sub(newline + 1)
            if not message then error(parse_err) end
            self.receive(message)
        elseif #self.input > MAX_LINE_BYTES then error("authority line exceeded bound") end
    end, debug.traceback)
    self.in_wait = false
    if not ok then self:_report_error(err) end
end

function StateChannel:stop()
    if self.closed then return false end
    self.closed, self.input, self.output, self.output_bytes = true, "", {}, 0
    C.close(self.fd)
    return true
end

StateChannel.validText = valid_text
return StateChannel
