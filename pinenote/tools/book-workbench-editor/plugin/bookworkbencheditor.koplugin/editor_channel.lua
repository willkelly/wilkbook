-- Nonblocking, bounded Unix-stream transport donated by the trusted launcher.
local Codec = require("editor_codec")
local ffi, bit = require("ffi"), require("bit")
ffi.cdef[[
int fcntl(int fd, int command, ...);
int close(int fd);
long recv(int fd, void *buffer, unsigned long count, int flags);
long send(int fd, const void *buffer, unsigned long count, int flags);
int getsockopt(int fd, int level, int option, void *value, unsigned int *length);
int getpeername(int fd, void *address, unsigned int *length);
]]
local C, BUDGET = ffi.C, 16384
local Channel = {}
Channel.__index = Channel
function Channel.prepareFD(fd)
    if type(fd) ~= "number" or fd % 1 ~= 0 or fd < 3 or fd > 1048575 then return nil,"invalid FD" end
    local kind,len = ffi.new("int[1]"),ffi.new("unsigned int[1]",4)
    local addr,alen = ffi.new("uint8_t[128]"),ffi.new("unsigned int[1]",128)
    if C.getsockopt(fd,1,3,kind,len) ~= 0 or kind[0] ~= 1 or C.getpeername(fd,addr,alen) ~= 0
            or ffi.cast("unsigned short *",addr)[0] ~= 1 then C.close(fd); return nil,"not connected Unix stream" end
    local flags,df = C.fcntl(fd,3),C.fcntl(fd,1)
    if flags < 0 or df < 0 or C.fcntl(fd,4,ffi.cast("int",bit.bor(flags,2048))) ~= 0
            or C.fcntl(fd,2,ffi.cast("int",bit.bor(df,1))) ~= 0 then
        C.close(fd); return nil,"cannot protect FD"
    end
    return true
end
function Channel:new(o)
    local ok,err = self.prepareFD(o.fd)
    if not ok then return nil,err end
    return setmetatable({fd=o.fd,receive=assert(o.receive),on_error=o.on_error,on_progress=o.on_progress,
        input="",output={},bytes=0,buffer=ffi.new("uint8_t[?]",BUDGET)},self)
end
function Channel:stop()
    if self.closed then return end
    self.closed,self.input,self.output,self.bytes = true,"",{},0
    C.close(self.fd)
end
function Channel:fail(reason)
    if self.closed then return end
    self:stop()
    if self.on_error then self.on_error(reason) end
end
function Channel:pump()
    local left = BUDGET
    while not self.closed and self.output[1] and left > 0 do
        local head = self.output[1]
        local n = C.send(self.fd,ffi.cast("const uint8_t *",head.text)+head.offset,
            math.min(left,#head.text-head.offset),16384)
        if n > 0 then
            n = tonumber(n); head.offset,left,self.bytes = head.offset+n,left-n,self.bytes-n
            if head.offset == #head.text then table.remove(self.output,1) end
        elseif n < 0 and (ffi.errno() == 4 or ffi.errno() == 11) then return
        else self:fail("authority write failed"); return end
    end
end
function Channel:send(sequence,v)
    if self.closed then return false,"disconnected" end
    local line,err = Codec.encodeCommand(sequence,v)
    if not line then return false,err end
    if #self.output >= 4 or self.bytes+#line > 4*(Codec.MAX_LINE+1) then return false,"output queue full" end
    self.output[#self.output+1] = {text=line,offset=0}; self.bytes=self.bytes+#line
    self:pump()
    return not self.closed,self.closed and "disconnected" or nil
end
function Channel:waitEvent()
    if self.closed or self.in_wait then return end
    self.in_wait = true
    local ok,err = pcall(function()
        self:pump()
        if self.closed then return end
        local newline = self.input:find("\n",1,true)
        if not newline then
            local n = C.recv(self.fd,self.buffer,BUDGET,0)
            if n > 0 then self.input=self.input..ffi.string(self.buffer,n)
            elseif n == 0 then error("authority disconnected")
            elseif ffi.errno() ~= 4 and ffi.errno() ~= 11 then error("authority read failed") end
            newline = self.input:find("\n",1,true)
        end
        if #self.input > Codec.MAX_LINE+BUDGET then error("input bound exceeded") end
        if newline then
            local msg,reason = Codec.parseReply(self.input:sub(1,newline-1))
            self.input = self.input:sub(newline+1)
            if not msg then error(reason) end
            self.receive(msg)
        elseif #self.input > Codec.MAX_LINE then error("frame bound exceeded") end
    end)
    self.in_wait = false
    if not ok then self:fail(tostring(err):sub(1,512))
    elseif not self.closed and self.on_progress then self.on_progress() end
end
return Channel
