-- Closed private UI schema. No executable serialization. The authority alone
-- writes this socket; authored Book Protocol messages never reach it directly.
local JSON = require("rapidjson")
local M = { MAX_SEQUENCE = 2147483647, MAX_LINE = 131104 }
local function integer(n) return type(n) == "number" and n >= 1 and n <= M.MAX_SEQUENCE and n % 1 == 0 end
local function safe(n) return type(n) == "number" and n >= 1 and n <= 9007199254740991 and n % 1 == 0 end
local function text(s, limit)
    if type(s) ~= "string" or #s > limit or s:find("\0", 1, true) then return false end
    local i = 1
    while i <= #s do
        local b, n = s:byte(i), 1
        if b < 128 then n = 1
        elseif b >= 194 and b <= 223 then n = 2
        elseif b >= 224 and b <= 239 then n = 3
        elseif b >= 240 and b <= 244 then n = 4
        else return false end
        if i + n - 1 > #s then return false end
        for j = 1, n - 1 do local c = s:byte(i+j); if c < 128 or c > 191 then return false end end
        local second = s:byte(i+1)
        if n == 3 and ((b == 224 and second < 160) or (b == 237 and second > 159)) then return false end
        if n == 4 and ((b == 240 and second < 144) or (b == 244 and second > 143)) then return false end
        i = i + n
    end
    return true
end
local function object(v)
    return type(v) == "table" and not (getmetatable(v) and getmetatable(v).__jsontype == "array")
end
local function fields(v, names)
    if not object(v) then return false end
    local allowed, count = {}, 0
    for _, k in ipairs(names) do allowed[k] = true; if v[k] == nil then return false end end
    for k in pairs(v) do if not allowed[k] then return false end; count = count+1 end
    return count == #names
end
local function id(s) return text(s,64) and #s > 0 and not s:find("[^A-Za-z0-9_-]") end
local function handle(s) return text(s,128) and #s > 0 end
local function actions(a)
    if type(a) ~= "table" or not getmetatable(a) or getmetatable(a).__jsontype ~= "array" or #a > 8 then return false end
    local seen, count = {}, 0
    for k, item in pairs(a) do
        if not integer(k) or k > #a then return false end
        count = count + 1
        if not fields(item,{"id","label","enabled"}) or not id(item.id) or item.id == "open"
                or seen[item.id] or not text(item.label,128) or #item.label == 0
                or type(item.enabled) ~= "boolean" then return false end
        seen[item.id] = true
    end
    return count == #a
end
local function form(v)
    return fields(v,{"type","protocol_version","request_id","action_id","surface_handle",
        "surface_generation","sequence","title","text","status","actions"})
        and v.type == "editor-present" and v.protocol_version == 1
        and safe(v.request_id) and safe(v.sequence) and safe(v.surface_generation)
        and id(v.action_id) and handle(v.surface_handle)
        and text(v.title,128) and text(v.text,8192) and text(v.status,2048) and actions(v.actions)
end
local commands = {
    hello = {"op","protocol_version"}, open = {"op","view","text"},
    action = {"op","view","surface_handle","surface_generation","action_id","text"},
    close = {"op","view"}, decision = {"op","view","token","accept"},
    ["preview-action"] = {"op","view","token","surface_handle","surface_generation","action_id","text"},
    ["preview-finish"] = {"op","view","token","accept"},
}
local function command(v)
    if not object(v) or not commands[v.op] or not fields(v,commands[v.op]) then return false end
    if v.op == "hello" then return v.protocol_version == 1 end
    if not integer(v.view) then return false end
    if v.op == "open" then return text(v.text,8192) end
    if v.op == "preview-action" and not handle(v.token) then return false end
    if v.op == "action" or v.op == "preview-action" then return handle(v.surface_handle) and safe(v.surface_generation)
        and id(v.action_id) and v.action_id ~= "open" and text(v.text,8192) end
    if v.op == "decision" or v.op == "preview-finish" then return handle(v.token) and type(v.accept) == "boolean" end
    return true
end
local function reply(v)
    if not object(v) then return false end
    if v.op == "ready" then return fields(v,{"op","protocol_version","max_text_bytes","max_actions"})
        and v.protocol_version == 1 and v.max_text_bytes == 8192 and v.max_actions == 8 end
    if not integer(v.view) then return false end
    if v.op == "present" then return fields(v,{"op","view","form"}) and form(v.form) end
    if v.op == "preview" then return fields(v,{"op","view","preview_view","token","form"})
        and integer(v.preview_view) and handle(v.token) and form(v.form) end
    if v.op == "preview-failure" then return fields(v,{"op","view","token","error"})
        and handle(v.token) and text(v.error,2048) end
    if v.op == "failure" then return fields(v,{"op","view","error"}) and text(v.error,2048) end
    if v.op == "confirmation" then return fields(v,{"op","view","token","kind","summary"})
        and handle(v.token) and (v.kind == "install" or v.kind == "recovery") and text(v.summary,2048) end
    return false
end

-- Validate structure and raw integer spelling before rapidjson loses evidence.
-- Arrays are bounded, objects reject decoded duplicate keys (including escapes).
local function checked_json(s)
    local function ws(p) return s:find("[^ \t\r\n]",p) or #s+1 end
    local function string_end(p)
        local i = p+1
        while i <= #s do
            local c = s:sub(i,i)
            if c == '"' then return i+1 end
            i = i + (c == "\\" and 2 or 1)
        end
        error("unterminated string")
    end
    local value
    value = function(p,depth)
        if depth > 5 then error("nesting limit") end
        p = ws(p)
        local first = s:sub(p,p)
        if first == '"' then return string_end(p) end
        if first ~= "{" and first ~= "[" then
            local ending = s:find("[ \t\r\n,}%]]",p) or #s+1
            local token = s:sub(p,ending-1)
            if token ~= "true" and token ~= "false" and token ~= "null"
                    and not token:match("^[1-9][0-9]*$") and token ~= "0" then error("noninteger scalar") end
            return ending
        end
        local array, ending = first == "[", first == "[" and "]" or "}"
        local seen, count = {}, 0
        p = ws(p+1)
        if s:sub(p,p) == ending then return p+1 end
        while true do
            count = count+1
            if count > (array and 8 or 16) then error("container limit") end
            if not array then
                if s:sub(p,p) ~= '"' then error("object key required") end
                local finish = string_end(p)
                local key = JSON.decode(s:sub(p,finish-1))
                if type(key) ~= "string" or seen[key] then error("duplicate key") end
                seen[key] = true
                p = ws(finish)
                if s:sub(p,p) ~= ":" then error("colon required") end
                p = p+1
            end
            p = ws(value(p,depth+1))
            if s:sub(p,p) == ending then return p+1 end
            if s:sub(p,p) ~= "," then error("separator required") end
            p = ws(p+1)
        end
    end
    if s:sub(ws(1),ws(1)) ~= "{" or ws(value(1,1)) ~= #s+1 then error("not one JSON object") end
    local result, err = JSON.decode(s)
    if not result then error(err or "invalid JSON") end
    return result
end
local function hex(s) return (s:gsub(".",function(c) return string.format("%02x",c:byte()) end)) end
function M.encodeCommand(sequence,v)
    if not integer(sequence) or not command(v) then return nil,"invalid editor command" end
    local ok,s = pcall(JSON.encode,v)
    if not ok or type(s) ~= "string" then return nil,"JSON encoding failed" end
    local line = "command|"..sequence.."|"..hex(s).."\n"
    if #line > M.MAX_LINE+1 then return nil,"frame exceeds bound" end
    return line
end
function M.parseReply(line)
    if #line > M.MAX_LINE then return nil,"oversized reply" end
    local seq,encoded = line:match("^reply|([1-9][0-9]*)|([0-9a-f]*)$")
    local n = seq and tonumber(seq)
    if not integer(n) or tostring(n) ~= seq or #encoded % 2 ~= 0 then return nil,"invalid reply frame" end
    local s = encoded:gsub("..",function(pair) return string.char(tonumber(pair,16)) end)
    if not text(s,65536) then return nil,"invalid JSON bytes" end
    local ok,v = pcall(checked_json,s)
    if not ok or not reply(v) then return nil,"invalid reply schema" end
    return {sequence=n,payload=v}
end
M.validText, M.validCommand, M.validReply, M.validForm = text,command,reply,form
return M
