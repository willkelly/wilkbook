-- Host check of the production statx/open/read marker validator.
local ffi = require("ffi")
ffi.cdef[[
unsigned int getuid(void);
int chmod(const char *path, unsigned int mode);
int link(const char *oldpath, const char *newpath);
int symlink(const char *target, const char *linkpath);
int unlink(const char *path);
]]
local C = ffi.C
local plugin_dir = assert(arg[1], "plugin directory required")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Activation = require("activation")
local path = os.tmpname()
local hardlink, symlink = path .. ".hard", path .. ".sym"
local function write(value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value))
    assert(file:close())
end
local function enabled(candidate)
    return Activation.enabled(candidate or path, tonumber(C.getuid()))
end

write("enabled\n")
assert(C.chmod(path, tonumber("600", 8)) == 0)
assert(enabled())
assert(C.chmod(path, tonumber("644", 8)) == 0)
assert(not enabled())
assert(C.chmod(path, tonumber("600", 8)) == 0)
write("disabled")
assert(not enabled())
write("enabled\n")
assert(C.chmod(path, tonumber("600", 8)) == 0)
assert(C.link(path, hardlink) == 0)
assert(not enabled())
assert(C.unlink(hardlink) == 0)
assert(C.symlink(path, symlink) == 0)
assert(not enabled(symlink))
assert(C.unlink(symlink) == 0)
assert(C.unlink(path) == 0)
assert(not enabled())
print("PASS: plugin activation requires an exact stable 0600 single-link marker")
