--[[--
nb_fs -- the notebook journal's fs interface on real files, through ffi.

nb_journal is pure and does every file operation through an injected fs
table; this is the table main.lua injects on the device.  The host test,
pinenote/tools/koreader-input/test-notebook-fs.lua, runs every function
here in a scratch directory, and runs nb_journal's Store over it.

What the journal relies on (nb_journal.lua, "Durability"):

  * append is ONE write(2) on an fd opened O_APPEND|O_CREAT for the call,
    so a record reaches the file whole or, on a full disk, as one torn
    tail that page_lines repairs; a short write is an error, because the
    journal poisons the page on any append error;
  * fsync opens the file for the call.  A retried fsync on a new fd can
    report success after EIO, which is why the controller treats the
    first failure as final for the session;
  * fsync_dir opens the directory O_DIRECTORY and fsyncs it: a new page
    file, the notebook directory and a renamed prefs.json only survive a
    power cut once their directory entry is synced;
  * write_atomic writes a temporary file, fsyncs it, renames it over the
    target and fsyncs the directory;
  * exists is one access(2): append calls it for every page not yet seen;
  * unlink is one unlink(2), unsynced: only the store's probe file is
    ever removed.

Errors come back as nil and the bare errno name ("EEXIST", "ENOENT"):
the Store compares those names (mkdir_excl's EEXIST, listdir's ENOENT)
and adds the path itself, so every error it surfaces reads
"<ERRNAME> <path>".  A name missing from ERRNO below reads "ERRNO<n>".

The PineNote is aarch64 glibc; the host tests run x86_64 glibc.  Both
share the asm-generic errno numbers and every O_ flag posix_h defines,
but not O_DIRECTORY, so that one is chosen by ffi.arch.  Directory
entries are read with readdir64, whose struct dirent64 has one layout on
every glibc architecture.
--]]

local ffi = require("ffi")
local bit = require("bit")

require("ffi/posix_h")

local C = ffi.C

-- posix_h declares open, read, write, close, fsync and access; the rest
-- is declared here unless another module got there first (a second
-- ffi.cdef of the same function raises).
local function declare(name, decl)
    if not pcall(function() return C[name] end) then ffi.cdef(decl) end
end
declare("mkdir", "int mkdir(const char *, unsigned int);")
declare("rename", "int rename(const char *, const char *);")
declare("unlink", "int unlink(const char *);")
declare("ftruncate64", "int ftruncate64(int, int64_t);")
declare("opendir", "void *opendir(const char *);")
declare("readdir64", "void *readdir64(void *);")
declare("closedir", "int closedir(void *);")
ffi.cdef[[
struct nb_fs_dirent64 {
    uint64_t d_ino;
    int64_t d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[256];
};
]]
local DIRENT_P = ffi.typeof("struct nb_fs_dirent64 *")

local O_RDONLY, O_WRONLY = C.O_RDONLY, C.O_WRONLY
local O_CREAT, O_TRUNC, O_APPEND = C.O_CREAT, C.O_TRUNC, C.O_APPEND
local O_CLOEXEC = C.O_CLOEXEC
-- 040000 on arm and arm64, 0200000 on x86 and x64 (asm/fcntl.h).  On an
-- architecture this table does not know, the flag is left out: open(2)
-- of a directory O_RDONLY still works, it just stops refusing a file.
local O_DIRECTORY = ({ arm = 0x4000, arm64 = 0x4000, arm64be = 0x4000,
                       x86 = 0x10000, x64 = 0x10000 })[ffi.arch] or 0
local F_OK = C.F_OK
local EINTR = C.EINTR

-- open(2) is variadic: a Lua number would be passed as a double.
local MODE_FILE = ffi.cast("int", 420)  -- 0644
local MODE_DIR = 493                     -- 0755, mkdir's fixed parameter

local ERRNO = {
    [1] = "EPERM", [2] = "ENOENT", [4] = "EINTR", [5] = "EIO",
    [9] = "EBADF", [12] = "ENOMEM", [13] = "EACCES", [16] = "EBUSY",
    [17] = "EEXIST", [18] = "EXDEV", [20] = "ENOTDIR", [21] = "EISDIR",
    [22] = "EINVAL", [23] = "ENFILE", [24] = "EMFILE", [27] = "EFBIG",
    [28] = "ENOSPC", [30] = "EROFS", [31] = "EMLINK",
    [36] = "ENAMETOOLONG", [39] = "ENOTEMPTY", [40] = "ELOOP",
    [122] = "EDQUOT",
}

local function errname(e)
    return ERRNO[e] or ("ERRNO" .. tostring(e))
end

-- The errno of the call that just failed, as a name.  Read at once:
-- LuaJIT only keeps errno until the next C call.
local function last_err()
    return nil, errname(ffi.errno())
end

local function parent(path)
    local p = path:match("^(.*)/[^/]*$")
    if p == nil then return "." end
    if p == "" then return "/" end
    return p
end

local Fs = {}

-- Close fd, keeping the first error: an earlier failure (errname) wins
-- over a close failure, and a close failure over success.
local function close_with(fd, ok, err)
    if C.close(fd) ~= 0 and ok then return last_err() end
    if ok then return true end
    return nil, err
end

-- The whole of s, on an fd opened for writing, retrying a partial write
-- and EINTR.  For write_atomic's temporary file only: append makes
-- exactly one write, whatever it returns.
local function write_all(fd, s)
    local off, n = 0, #s
    local p = ffi.cast("const char *", s)
    while off < n do
        local w = tonumber(C.write(fd, p + off, n - off))
        if w < 0 then
            local e = ffi.errno()
            if e ~= EINTR then return nil, errname(e) end
        elseif w == 0 then
            -- No progress and no errno: retrying would spin the UI loop
            -- forever, so it fails as append's short write does.
            return nil, "EIO"
        else
            off = off + w
        end
    end
    return true
end

function Fs.mkdir_excl(path)
    if C.mkdir(path, MODE_DIR) ~= 0 then return last_err() end
    return true
end

function Fs.listdir(path)
    local d = C.opendir(path)
    if d == nil then return last_err() end
    local names = {}
    local err
    while true do
        -- readdir returns NULL both at the end and on error; only errno
        -- tells them apart.
        ffi.errno(0)
        local ent = C.readdir64(d)
        if ent == nil then
            local e = ffi.errno()
            if e ~= 0 then err = errname(e) end
            break
        end
        local name = ffi.string(ffi.cast(DIRENT_P, ent).d_name)
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
    end
    C.closedir(d)
    if err then return nil, err end
    return names
end

local READ_CHUNK = 65536
local read_buf = ffi.new("uint8_t[?]", READ_CHUNK)

-- Reads until EOF rather than trusting a size: /proc/self/mountinfo
-- reports 0 bytes to stat.
function Fs.read(path)
    local fd = C.open(path, bit.bor(O_RDONLY, O_CLOEXEC))
    if fd < 0 then return last_err() end
    local chunks = {}
    while true do
        local n = tonumber(C.read(fd, read_buf, READ_CHUNK))
        if n < 0 then
            local e = ffi.errno()
            if e ~= EINTR then return close_with(fd, nil, errname(e)) end
        elseif n == 0 then
            break
        else
            chunks[#chunks + 1] = ffi.string(read_buf, n)
        end
    end
    local ok, err = close_with(fd, true)
    if not ok then return nil, err end
    return table.concat(chunks)
end

--- One write(2) of s at the end of path, creating it.  No retry: a
-- second write after a partial one could put the rest of the record
-- after another writer's, and the journal repairs a torn tail anyway.
function Fs.append(path, s)
    local fd = C.open(path, bit.bor(O_WRONLY, O_APPEND, O_CREAT, O_CLOEXEC),
                      MODE_FILE)
    if fd < 0 then return last_err() end
    local n = tonumber(C.write(fd, s, #s))
    if n < 0 then return close_with(fd, nil, errname(ffi.errno())) end
    -- A regular-file write on a local filesystem is only cut short by a
    -- full disk or a file-size limit, and the next write would name
    -- which; there is none, so the short write is reported as EIO.
    if n ~= #s then return close_with(fd, nil, "EIO") end
    return close_with(fd, true)
end

function Fs.truncate(path, len)
    local fd = C.open(path, bit.bor(O_WRONLY, O_CLOEXEC))
    if fd < 0 then return last_err() end
    if C.ftruncate64(fd, len) ~= 0 then
        return close_with(fd, nil, errname(ffi.errno()))
    end
    return close_with(fd, true)
end

function Fs.fsync(path)
    local fd = C.open(path, bit.bor(O_RDONLY, O_CLOEXEC))
    if fd < 0 then return last_err() end
    if C.fsync(fd) ~= 0 then
        return close_with(fd, nil, errname(ffi.errno()))
    end
    return close_with(fd, true)
end

function Fs.fsync_dir(path)
    local fd = C.open(path, bit.bor(O_RDONLY, O_DIRECTORY, O_CLOEXEC))
    if fd < 0 then return last_err() end
    if C.fsync(fd) ~= 0 then
        return close_with(fd, nil, errname(ffi.errno()))
    end
    return close_with(fd, true)
end

--- Replace path with s: a reader sees the old file or the new one, and
-- after a power cut the new one only if this returned true.
function Fs.write_atomic(path, s)
    local tmp = path .. ".tmp"
    local fd = C.open(tmp, bit.bor(O_WRONLY, O_CREAT, O_TRUNC, O_CLOEXEC),
                      MODE_FILE)
    if fd < 0 then return last_err() end
    local ok, err = write_all(fd, s)
    if ok and C.fsync(fd) ~= 0 then ok, err = last_err() end
    ok, err = close_with(fd, ok, err)
    if ok and C.rename(tmp, path) ~= 0 then ok, err = last_err() end
    if not ok then
        -- Nothing replaced the target; leave no stray temporary behind.
        C.unlink(tmp)
        return nil, err
    end
    return Fs.fsync_dir(parent(path))
end

function Fs.exists(path)
    return C.access(path, F_OK) == 0
end

--- Remove a file (the store's append probe).  Not synced: the caller
-- says whether the removal needs to survive a power cut.
function Fs.unlink(path)
    if C.unlink(path) ~= 0 then return last_err() end
    return true
end

-- For the host test: the names it asserts come from this table.
Fs._errname = errname
Fs._O_DIRECTORY = O_DIRECTORY

return Fs
