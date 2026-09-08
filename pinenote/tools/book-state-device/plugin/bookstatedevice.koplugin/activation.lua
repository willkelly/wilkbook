-- Exact opt-in marker check.  The authority repeats this validation and owns
-- the actual privilege boundary; this keeps even the menu dormant for malformed
-- files without following a symlink or accepting a path-swap race.
local bit = require("bit")
local ffi = require("ffi")

ffi.cdef[[
typedef unsigned int uint32_t;
typedef unsigned short uint16_t;
typedef unsigned long long uint64_t;
typedef long ssize_t;
struct statx_timestamp {
    long long tv_sec;
    uint32_t tv_nsec;
    int __reserved;
};
struct statx {
    uint32_t stx_mask;
    uint32_t stx_blksize;
    uint64_t stx_attributes;
    uint32_t stx_nlink;
    uint32_t stx_uid;
    uint32_t stx_gid;
    uint16_t stx_mode;
    uint16_t __spare0[1];
    uint64_t stx_ino;
    uint64_t stx_size;
    uint64_t stx_blocks;
    uint64_t stx_attributes_mask;
    struct statx_timestamp stx_atime;
    struct statx_timestamp stx_btime;
    struct statx_timestamp stx_ctime;
    struct statx_timestamp stx_mtime;
    uint32_t stx_rdev_major;
    uint32_t stx_rdev_minor;
    uint32_t stx_dev_major;
    uint32_t stx_dev_minor;
    uint64_t stx_mnt_id;
    uint32_t stx_dio_mem_align;
    uint32_t stx_dio_offset_align;
    uint64_t __spare3[12];
};
int statx(int dirfd, const char *path, int flags, unsigned int mask,
          struct statx *buffer);
int open(const char *path, int flags, ...);
ssize_t read(int fd, void *buffer, unsigned long count);
int close(int fd);
]]

local C = ffi.C
local ACTIVATION = "/data/wilkbook/book-state/enabled"
local AT_FDCWD, AT_SYMLINK_NOFOLLOW, AT_EMPTY_PATH = -100, 0x100, 0x1000
local STATX_BASIC_STATS = 0x7ff
local O_RDONLY, O_CLOEXEC, O_NOFOLLOW = 0, 0x80000, 0x20000
local S_IFMT, S_IFREG = 0xf000, 0x8000

local Activation = {}

local function same_file(left, right)
    return left.stx_dev_major == right.stx_dev_major
        and left.stx_dev_minor == right.stx_dev_minor
        and left.stx_ino == right.stx_ino
end

function Activation.enabled(path, expected_uid)
    path = path or ACTIVATION
    expected_uid = expected_uid or 0
    local named = ffi.new("struct statx")
    if C.statx(AT_FDCWD, path, AT_SYMLINK_NOFOLLOW,
            STATX_BASIC_STATS, named) ~= 0 then
        return false
    end
    if bit.band(named.stx_mode, S_IFMT) ~= S_IFREG
            or bit.band(named.stx_mode, 0xfff) ~= 0x180 -- 0600
            or tonumber(named.stx_uid) ~= expected_uid
            or tonumber(named.stx_nlink) ~= 1
            or tonumber(named.stx_size) ~= 8 then
        return false
    end
    local fd = C.open(path, bit.bor(O_RDONLY, O_CLOEXEC, O_NOFOLLOW))
    if fd < 0 then return false end
    local opened = ffi.new("struct statx")
    local bytes = ffi.new("uint8_t[9]")
    local ok = C.statx(fd, "", AT_EMPTY_PATH, STATX_BASIC_STATS, opened) == 0
        and same_file(named, opened)
        and bit.band(opened.stx_mode, S_IFMT) == S_IFREG
        and bit.band(opened.stx_mode, 0xfff) == 0x180
        and tonumber(opened.stx_uid) == expected_uid
        and tonumber(opened.stx_nlink) == 1
        and tonumber(opened.stx_size) == 8
        and C.read(fd, bytes, 9) == 8
        and ffi.string(bytes, 8) == "enabled\n"
        and C.read(fd, bytes, 1) == 0
    C.close(fd)
    return ok
end

return Activation
