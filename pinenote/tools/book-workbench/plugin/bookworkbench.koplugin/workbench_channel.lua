-- Offline trusted-native UI transport. The donated socket belongs to the
-- authority, not an authored program. JSON is data; source is never loaded here.
local bit = require("bit")
local ffi = require("ffi")
local JSON = require("rapidjson")

ffi.cdef[[
int fcntl(int fd, int command, ...);
int close(int fd);
long recv(int fd, void *buffer, unsigned long count, int flags);
long send(int fd, const void *buffer, unsigned long count, int flags);
int getsockopt(int fd, int level, int option, void *value, unsigned int *length);
int getpeername(int fd, void *address, unsigned int *length);
]]

local C = ffi.C
local F_GETFD, F_SETFD, FD_CLOEXEC = 1, 2, 1
local F_GETFL, F_SETFL, O_NONBLOCK = 3, 4, 2048
local EINTR, EAGAIN, MSG_NOSIGNAL = 4, 11, 16384
local MAX_SEQUENCE, MAX_INTEGER = 2147483647, 2147483647
local MAX_SOURCE, MAX_INPUT, MAX_TEXT = 8192, 2048, 4096
-- Match the authority's existing 65536-byte JSON codec plus hex/header framing.
local MAX_ARTIFACT, MAX_LINE, IO_BUDGET = 6 * MAX_SOURCE + 1024, 2 * 65536 + 32, 16384
local MAX_QUEUE = 2

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
        and value % 1 == 0
end

local function valid_text(text, maximum)
    if type(text) ~= "string" or #text > maximum or text:find("\0", 1, true) then
        return false
    end
    local index = 1
    while index <= #text do
        local first, count = text:byte(index), 1
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
        local second = text:byte(index + 1)
        if count == 3 and ((first == 0xE0 and second < 0xA0)
                or (first == 0xED and second > 0x9F)) then return false end
        if count == 4 and ((first == 0xF0 and second < 0x90)
                or (first == 0xF4 and second > 0x8F)) then return false end
        index = index + count
    end
    return true
end

local function object(value)
    if type(value) ~= "table" then return false end
    local meta = getmetatable(value)
    return not meta or meta.__jsontype ~= "array"
end

local function exact_fields(value, fields)
    if not object(value) then return false end
    local allowed, count = {}, 0
    for _, key in ipairs(fields) do
        allowed[key] = true
        if value[key] == nil then return false end
    end
    for key in pairs(value) do
        if not allowed[key] then return false end
        count = count + 1
    end
    return count == #fields
end

local request_fields = {
    open = {"op"}, save = {"op", "expected_version", "source"},
    preview = {"op", "expected_version", "text"},
    run = {"op", "text"},
    activate = {"op", "expected_version", "expected_activation"},
    rollback = {"op", "expected_activation"}, export = {"op"}, close = {"op"},
}

local function valid_command(value)
    local fields = object(value) and request_fields[value.op]
    if not fields or not exact_fields(value, fields) then return false end
    if value.expected_version ~= nil
            and not integer(value.expected_version, 0, MAX_INTEGER) then return false end
    if value.expected_activation ~= nil
            and not integer(value.expected_activation, 0, MAX_INTEGER) then return false end
    if value.op == "save" and not valid_text(value.source, MAX_SOURCE) then return false end
    if (value.op == "preview" or value.op == "run")
            and (not valid_text(value.text, MAX_INPUT) or #value.text == 0) then return false end
    return true
end

local function valid_id(value)
    return valid_text(value, 256) and #value > 0
end

local function valid_snapshot(value)
    return exact_fields(value, {"workspace_version", "source", "source_digest",
            "active_revision", "previous_revision", "activation_generation"})
        and integer(value.workspace_version, 0, MAX_INTEGER)
        and integer(value.activation_generation, 0, MAX_INTEGER)
        and valid_text(value.source, MAX_SOURCE)
        and type(value.source_digest) == "string" and #value.source_digest == 64
        and not value.source_digest:find("[^0-9a-f]")
        and valid_id(value.active_revision)
        and (value.previous_revision == false or valid_id(value.previous_revision))
end

local function valid_reply(value)
    if not object(value) or not request_fields[value.op] then return false end
    if value.ok == false then
        local fields = {"ok", "op", "error"}
        if value.diagnostic ~= nil then
            fields[#fields + 1] = "diagnostic"
            if not valid_text(value.diagnostic, MAX_TEXT) then return false end
        end
        return exact_fields(value, fields) and valid_text(value.error, MAX_TEXT)
    end
    if value.ok ~= true then return false end
    local fields
    if value.op == "preview" or value.op == "run" or value.op == "export" then
        fields = {"ok", "op", "workspace_version", "source_digest", "activation_generation"}
        if not integer(value.workspace_version, 0, MAX_INTEGER)
                or not integer(value.activation_generation, 0, MAX_INTEGER)
                or type(value.source_digest) ~= "string" or #value.source_digest ~= 64
                or value.source_digest:find("[^0-9a-f]") then return false end
    else
        fields = {"ok", "op", "snapshot"}
        if not valid_snapshot(value.snapshot) then return false end
    end
    if value.op == "preview" or value.op == "run" then
        fields[#fields + 1], fields[#fields + 2] = "text", "diagnostic"
        if not valid_text(value.text, MAX_TEXT) or #value.text == 0
                or not valid_text(value.diagnostic, MAX_TEXT) then return false end
    elseif value.op == "export" then
        fields[#fields + 1] = "artifact"
        if not valid_text(value.artifact, MAX_ARTIFACT) then return false end
    end
    return exact_fields(value, fields)
end

-- rapidjson rejects invalid JSON and trailing data, but accepts duplicate keys.
-- Check the small object-only grammar first, including escaped duplicate keys
-- and depth, before asking the native decoder to allocate nested values.
local function checked_json(text)
    local function whitespace(pos)
        return (text:find("[^ \t\r\n]", pos) or (#text + 1))
    end
    local function string_end(pos)
        local cursor = pos + 1
        while true do
            local found = text:find('["\\]', cursor)
            if not found then error("unterminated JSON string") end
            if text:sub(found, found) == '"' then return found + 1 end
            cursor = found + 2
        end
    end
    local value_end
    value_end = function(pos, depth)
        if depth > 3 then error("JSON nesting exceeds bound") end
        pos = whitespace(pos)
        local first = text:sub(pos, pos)
        if first == '"' then return string_end(pos) end
        if first == "[" then error("arrays are not Workbench messages") end
        if first ~= "{" then
            local ending = text:find("[ \t\r\n,}]", pos) or (#text + 1)
            if ending == pos then error("missing JSON value") end
            return ending
        end
        local keys, count = {}, 0
        pos = whitespace(pos + 1)
        if text:sub(pos, pos) == "}" then return pos + 1 end
        while true do
            if text:sub(pos, pos) ~= '"' then error("JSON object key required") end
            local ending = string_end(pos)
            local key = JSON.decode(text:sub(pos, ending - 1))
            if type(key) ~= "string" or keys[key] then error("invalid or duplicate JSON key") end
            keys[key], count = true, count + 1
            if count > 16 then error("too many JSON fields") end
            pos = whitespace(ending)
            if text:sub(pos, pos) ~= ":" then error("missing JSON colon") end
            pos = whitespace(value_end(pos + 1, depth + 1))
            local separator = text:sub(pos, pos)
            if separator == "}" then return pos + 1 end
            if separator ~= "," then error("missing JSON field separator") end
            pos = whitespace(pos + 1)
        end
    end
    if text:sub(whitespace(1), whitespace(1)) ~= "{" then
        error("JSON message must be an object")
    end
    if whitespace(value_end(1, 1)) ~= #text + 1 then error("trailing JSON data") end
    local value, err = JSON.decode(text)
    if not value then error(err or "invalid JSON") end
    return value
end

local function hex_encode(text)
    return (text:gsub(".", function(char) return string.format("%02x", char:byte()) end))
end

local function encode_command(sequence, value)
    if not integer(sequence, 1, MAX_SEQUENCE) or not valid_command(value) then
        return nil, "invalid Workbench command"
    end
    local ok, text = pcall(JSON.encode, value)
    if not ok or type(text) ~= "string" then return nil, "could not encode command" end
    local line = string.format("command|%d|%s\n", sequence, hex_encode(text))
    if #line > MAX_LINE + 1 then return nil, "encoded command exceeds frame limit" end
    return line
end

local function parse_reply(line)
    if #line > MAX_LINE then return nil, "oversized Workbench reply" end
    local sequence_text, encoded = line:match("^reply|([1-9][0-9]*)|([0-9a-f]*)$")
    local sequence = sequence_text and tonumber(sequence_text)
    if not integer(sequence, 1, MAX_SEQUENCE) or tostring(sequence) ~= sequence_text
            or #encoded % 2 ~= 0 then return nil, "invalid Workbench frame header" end
    local text = encoded:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end)
    if not valid_text(text, 65536) then return nil, "invalid Workbench JSON text" end
    local ok, value = pcall(checked_json, text)
    if not ok or not valid_reply(value) then return nil, "invalid Workbench reply schema" end
    return { sequence = sequence, payload = value }
end

local function prepare_fd(fd)
    if not integer(fd, 3, 1048575) then return nil, "invalid donated UI descriptor" end
    local kind, length = ffi.new("int[1]"), ffi.new("unsigned int[1]", 4)
    local address, address_length = ffi.new("uint8_t[128]"), ffi.new("unsigned int[1]", 128)
    if C.getsockopt(fd, 1, 3, kind, length) ~= 0 or kind[0] ~= 1
            or C.getpeername(fd, address, address_length) ~= 0
            or ffi.cast("unsigned short *", address)[0] ~= 1 then
        C.close(fd)
        return nil, "donated UI descriptor is not a connected Unix stream"
    end
    local flags, descriptor_flags = C.fcntl(fd, F_GETFL), C.fcntl(fd, F_GETFD)
    if flags < 0 or descriptor_flags < 0
            or C.fcntl(fd, F_SETFL, ffi.cast("int", bit.bor(flags, O_NONBLOCK))) ~= 0
            or C.fcntl(fd, F_SETFD, ffi.cast("int", bit.bor(descriptor_flags, FD_CLOEXEC))) ~= 0 then
        C.close(fd)
        return nil, "could not protect donated UI descriptor"
    end
    return true
end

local Channel = {}
Channel.__index = Channel

function Channel:new(options)
    local ok, err = prepare_fd(options.fd)
    if not ok then return nil, err end
    return setmetatable({ fd = options.fd, receive = assert(options.receive),
        on_error = options.on_error, input = "", output = {}, output_bytes = 0,
        read_buffer = ffi.new("uint8_t[?]", IO_BUDGET),
        closed = false, in_wait = false }, self)
end

function Channel:_fail(reason)
    if self.closed then return end
    self:stop()
    if self.on_error then self.on_error(reason) end
end

function Channel:_pump_output()
    local remaining = IO_BUDGET
    while not self.closed and self.output[1] and remaining > 0 do
        local head = self.output[1]
        local count = math.min(#head.text - head.offset, remaining)
        local written = C.send(self.fd, ffi.cast("const uint8_t *", head.text) + head.offset,
            count, MSG_NOSIGNAL)
        if written > 0 then
            written = tonumber(written)
            head.offset, remaining = head.offset + written, remaining - written
            self.output_bytes = self.output_bytes - written
            if head.offset == #head.text then table.remove(self.output, 1) end
        elseif written < 0 and (ffi.errno() == EINTR or ffi.errno() == EAGAIN) then return
        else self:_fail("Workbench authority write failed"); return end
    end
end

function Channel:send(sequence, value)
    if self.closed then return false, "Workbench authority disconnected" end
    local line, err = encode_command(sequence, value)
    if not line then return false, err end
    if #self.output >= MAX_QUEUE or self.output_bytes + #line > MAX_QUEUE * (MAX_LINE + 1) then
        return false, "Workbench output queue is full"
    end
    self.output[#self.output + 1] = { text = line, offset = 0 }
    self.output_bytes = self.output_bytes + #line
    self:_pump_output()
    return not self.closed, self.closed and "Workbench authority disconnected" or nil
end

function Channel:waitEvent()
    if self.closed or self.in_wait then return nil end
    self.in_wait = true
    local ok, err = pcall(function()
        self:_pump_output()
        if self.closed then return end
        local newline = self.input:find("\n", 1, true)
        if not newline then
            local received = C.recv(self.fd, self.read_buffer, IO_BUDGET, 0)
            if received > 0 then
                self.input = self.input .. ffi.string(self.read_buffer, received)
                if #self.input > MAX_LINE + IO_BUDGET then error("Workbench input exceeds bound") end
                newline = self.input:find("\n", 1, true)
            elseif received == 0 then error("Workbench authority disconnected")
            elseif ffi.errno() ~= EINTR and ffi.errno() ~= EAGAIN then error("Workbench read failed") end
        end
        if newline then
            local message, reason = parse_reply(self.input:sub(1, newline - 1))
            self.input = self.input:sub(newline + 1)
            if not message then error(reason) end
            self.receive(message)
        elseif #self.input > MAX_LINE then error("oversized Workbench reply") end
    end)
    self.in_wait = false
    if not ok then self:_fail(tostring(err):sub(1, 512)) end
end

function Channel:stop()
    if self.closed then return false end
    self.closed, self.input, self.output, self.output_bytes = true, "", {}, 0
    self.read_buffer = nil
    C.close(self.fd)
    return true
end

Channel.validText, Channel.validCommand, Channel.validReply = valid_text, valid_command, valid_reply
Channel.encodeCommand, Channel.parseReply = encode_command, parse_reply
Channel.prepareFD = prepare_fd
Channel.MAX_SOURCE, Channel.MAX_INPUT, Channel.MAX_LINE = MAX_SOURCE, MAX_INPUT, MAX_LINE
Channel.MAX_SEQUENCE = MAX_SEQUENCE
return Channel
