-- Draw a 4 px black divider at the fb-native horizontal midpoint
-- (x = 934..937) down every row, then publish with one fsync.  The
-- split test's two halves are x < 936 and x >= 936 in fb coordinates.
local ffi = require("ffi")
ffi.cdef [[
int open(const char *path, int flags);
int close(int fd);
int fsync(int fd);
]]
local function read1(p)
    local f = io.open(p, "r"); if not f then return nil end
    local v = f:read("*l"); f:close(); return v
end
local size = read1("/sys/class/graphics/fb0/virtual_size")
local w, h = size:match("^(%d+),(%d+)")
w, h = tonumber(w), tonumber(h)
local stride = tonumber(read1("/sys/class/graphics/fb0/stride"))
local bypp = math.floor(tonumber(read1("/sys/class/graphics/fb0/bits_per_pixel")) / 8)
local x0 = math.floor(w / 2) - 2
local fh = assert(io.open("/dev/fb0", "r+b"))
local run = string.rep("\0", 4 * bypp)
for y = 0, h - 1 do
    fh:seek("set", y * stride + x0 * bypp)
    fh:write(run)
end
fh:flush()
local fd = ffi.C.open("/dev/fb0", 2)
ffi.C.fsync(fd)
ffi.C.close(fd)
print(("divider at x=%d..%d over %d rows"):format(x0, x0 + 3, h))
