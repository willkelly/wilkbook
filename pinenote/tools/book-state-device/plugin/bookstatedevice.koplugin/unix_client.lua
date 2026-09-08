-- Connect only to the compile-fixed, root-owned Book State authority socket.
local bit = require("bit")
local ffi = require("ffi")

ffi.cdef[[
typedef unsigned short sa_family_t;
typedef unsigned int socklen_t;
struct sockaddr_un { sa_family_t sun_family; char sun_path[108]; };
int socket(int domain, int type, int protocol);
int connect(int fd, const struct sockaddr *address, socklen_t length);
int close(int fd);
int fcntl(int fd, int command, ...);
]]

local C = ffi.C
local AF_UNIX = 1
local SOCK_STREAM = 1
local F_GETFD = 1
local F_SETFD = 2
local FD_CLOEXEC = 1
local SOCKET_PATH = "/run/wilkbook-book-state/control.sock"

local UnixClient = {}

function UnixClient.connect()
    local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 then return nil, "could not create authority socket" end
    local flags = C.fcntl(fd, F_GETFD)
    if flags < 0 or C.fcntl(fd, F_SETFD, bit.bor(flags, FD_CLOEXEC)) ~= 0 then
        C.close(fd)
        return nil, "could not protect authority socket descriptor"
    end
    local address = ffi.new("struct sockaddr_un")
    address.sun_family = AF_UNIX
    if #SOCKET_PATH >= ffi.sizeof(address.sun_path) then
        C.close(fd)
        return nil, "authority socket path is too long"
    end
    ffi.copy(address.sun_path, SOCKET_PATH, #SOCKET_PATH)
    local length = ffi.offsetof("struct sockaddr_un", "sun_path")
        + #SOCKET_PATH + 1
    if C.connect(fd, ffi.cast("const struct sockaddr *", address), length) ~= 0 then
        C.close(fd)
        return nil, "Book State authority is not running"
    end
    return tonumber(fd)
end

return UnixClient
