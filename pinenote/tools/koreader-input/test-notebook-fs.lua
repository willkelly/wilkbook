--[[--
Host harness for the notebook's real fs (notebook.koplugin nb_fs.lua):
the ffi implementation of nb_journal's injected fs interface, run on real
files in a scratch directory (mktemp -d, removed at the end; its path is
never printed).

  1. each function's success and errno paths: mkdir_excl and EEXIST,
     ENOENT under a missing parent; append creating the file, appending
     byte for byte with no newline joining, into a directory (EISDIR);
     truncate, unlink, fsync and fsync_dir (ENOTDIR on a file, which is
     what proves O_DIRECTORY is the right bit for this architecture);
     listdir without "." and "..", and of a directory bigger than one
     getdents buffer; read of a /proc file stat calls empty;
     write_atomic replacing a file and leaving no temporary, also over a
     stale temporary a crash left; exists;
  2. a permission failure (EACCES) on append and write_atomic, when the
     process is not root;
  3. no fd leaks across a few thousand calls, error paths included;
  4. nb_journal's Store over this fs: probe (which leaves no file),
     create, open, append, fsync, the torn-tail repair through truncate,
     list, prefs, and the root's EEXIST on a second probe.

NOT covered: ENOSPC, EROFS and EIO themselves (they need a full or
failing filesystem; the journal's in-memory fs injects them), and that
append is one write(2) (the source says so; strace on the device would).

Usage: luajit test-notebook-fs.lua <koreader_dir> <plugin_dir>
--]]

local koreader_dir = assert(arg[1], "arg1: koreader bundle dir (lib/koreader)")
local plugin_dir = assert(arg[2], "arg2: path to notebook.koplugin")

package.path = table.concat({
    plugin_dir .. "/?.lua",
    koreader_dir .. "/frontend/?.lua",
    koreader_dir .. "/?.lua",
    package.path,
}, ";")

local format = string.format

local fail = 0
local function report(ok, label, msg)
    if msg and msg ~= "" then
        print(format("%s: %s: %s", ok and "PASS" or "FAIL", label, msg))
    else
        print(format("%s: %s", ok and "PASS" or "FAIL", label))
    end
    if not ok then fail = fail + 1 end
end

local Fs = require("nb_fs")
local J = require("nb_journal")

local p = io.popen("mktemp -d")
local root = p:read("*l")
p:close()
assert(root and root:match("^/"), "mktemp -d failed")

-- Hide the scratch path in anything printed, and keep each check on
-- one line.
local function clean(s)
    s = tostring(s)
    local i, j = s:find(root, 1, true)
    while i do
        s = s:sub(1, i - 1) .. "<tmp>" .. s:sub(j + 1)
        i, j = s:find(root, 1, true)
    end
    return (s:gsub("\n", "\\n"))
end

local function show(...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do parts[i] = clean(tostring((select(i, ...)))) end
    return table.concat(parts, ",")
end

local function expect(label, want, ...)
    local got = show(...)
    want = clean(want)
    report(got == want, label, got == want and got or ("got " .. got
           .. ", want " .. want))
end

------------------------------------------------------------------------
-- 1. Each function.
------------------------------------------------------------------------

local d = root .. "/d"
expect("mkdir_excl creates a directory", "true", Fs.mkdir_excl(d))
expect("mkdir_excl on an existing directory is EEXIST", "nil,EEXIST",
       Fs.mkdir_excl(d))
expect("mkdir_excl under a missing parent is ENOENT", "nil,ENOENT",
       Fs.mkdir_excl(root .. "/missing/x"))
expect("exists: a directory", "true", Fs.exists(d))
expect("exists: a missing path", "false", Fs.exists(root .. "/nope"))

local f = d .. "/page-0.jsonl"
expect("append creates the file", "true", Fs.append(f, "abc"))
expect("exists: the appended file", "true", Fs.exists(f))
expect("append again", "true", Fs.append(f, "def\n"))
expect("appends join byte for byte, no newline added", "abcdef\n",
       Fs.read(f))
expect("append an empty string", "true", Fs.append(f, ""))
expect("an empty append changes nothing", "abcdef\n", Fs.read(f))
local big = string.rep("0123456789", 100000) .. "\n"
Fs.append(f, big)
local all = Fs.read(f)
report(all == "abcdef\n" .. big, "a 1 MB append lands whole and reads back",
       format("%d bytes", #all))
expect("append into a missing directory is ENOENT", "nil,ENOENT",
       Fs.append(root .. "/missing/page-0.jsonl", "x\n"))
expect("append to a directory is EISDIR", "nil,EISDIR", Fs.append(d, "x"))

expect("read of a missing file is ENOENT", "nil,ENOENT",
       Fs.read(root .. "/nope"))
expect("read of a directory is EISDIR", "nil,EISDIR", Fs.read(d))
local mi = Fs.read("/proc/self/mountinfo")
report(type(mi) == "string" and #mi > 0 and mi:find(" - ", 1, true) ~= nil,
       "read of /proc/self/mountinfo (stat size 0) reads to EOF", "")

expect("truncate shortens the file", "true", Fs.truncate(f, 3))
expect("the truncated file holds its prefix", "abc", Fs.read(f))
expect("truncate to 0", "true", Fs.truncate(f, 0))
expect("the file is empty and still exists", ",true", Fs.read(f),
       Fs.exists(f))
expect("truncate of a missing file is ENOENT", "nil,ENOENT",
       Fs.truncate(root .. "/nope", 0))

local gone = d .. "/gone"
Fs.append(gone, "x\n")
expect("unlink removes a file", "true", Fs.unlink(gone))
expect("the unlinked file is gone", "false", Fs.exists(gone))
expect("unlink of a missing file is ENOENT", "nil,ENOENT", Fs.unlink(gone))

expect("fsync a file", "true", Fs.fsync(f))
expect("fsync a missing file is ENOENT", "nil,ENOENT",
       Fs.fsync(root .. "/nope"))
expect("fsync_dir a directory", "true", Fs.fsync_dir(d))
expect("fsync_dir a regular file is ENOTDIR (O_DIRECTORY honoured)",
       "nil,ENOTDIR", Fs.fsync_dir(f))
expect("fsync_dir a missing directory is ENOENT", "nil,ENOENT",
       Fs.fsync_dir(root .. "/nope"))

Fs.mkdir_excl(d .. "/sub")
Fs.append(d .. "/page--3.jsonl", "x\n")
local names = Fs.listdir(d)
table.sort(names)
expect("listdir names the entries, without . and ..",
       "page--3.jsonl,page-0.jsonl,sub", table.concat(names, ","))
expect("listdir of an empty directory", "0", #Fs.listdir(d .. "/sub"))
expect("listdir of a missing directory is ENOENT", "nil,ENOENT",
       Fs.listdir(root .. "/nope"))
expect("listdir of a file is ENOTDIR", "nil,ENOTDIR", Fs.listdir(f))

local pj = d .. "/prefs.json"
expect("write_atomic creates the file", "true", Fs.write_atomic(pj, "one\n"))
expect("write_atomic content", "one\n", Fs.read(pj))
expect("write_atomic replaces the file", "true", Fs.write_atomic(pj, "two\n"))
expect("write_atomic replaced content", "two\n", Fs.read(pj))
expect("write_atomic leaves no temporary", "false", Fs.exists(pj .. ".tmp"))
expect("write_atomic into a missing directory is ENOENT", "nil,ENOENT",
       Fs.write_atomic(root .. "/missing/prefs.json", "x"))
local ok_w, err_w = Fs.write_atomic(d .. "/sub", "x")
expect("write_atomic over a directory fails and leaves no temporary",
       "nil,EISDIR,false", ok_w, err_w, Fs.exists(d .. "/sub.tmp"))
-- A crash between the temporary's write and the rename leaves a longer
-- temporary behind; the next write truncates it rather than keeping its
-- tail.
Fs.append(pj .. ".tmp", "a stale temporary, longer than what replaces it\n")
expect("write_atomic over a stale temporary", "true,three\n,false",
       Fs.write_atomic(pj, "three\n"), Fs.read(pj), Fs.exists(pj .. ".tmp"))

-- More entries than one getdents buffer holds (32 KiB in glibc): the
-- readdir loop must run to the real end, not stop at a buffer boundary.
local many = root .. "/many"
Fs.mkdir_excl(many)
local name_pad = string.rep("x", 200)
for i = 1, 400 do Fs.append(format("%s/%03d-%s", many, i, name_pad), "") end
local listed = Fs.listdir(many)
local all_there = #listed == 400
local seen = {}
for _, nm in ipairs(listed) do seen[nm] = true end
for i = 1, 400 do
    if not seen[format("%03d-%s", i, name_pad)] then all_there = false end
end
report(all_there, "listdir returns all 400 entries of a large directory",
       format("%d entries", #listed))

------------------------------------------------------------------------
-- 2. Permissions.
------------------------------------------------------------------------

local ro = root .. "/ro"
Fs.mkdir_excl(ro)
Fs.append(ro .. "/page-0.jsonl", "keep\n")
os.execute("chmod 0555 '" .. ro .. "' && chmod 0444 '" .. ro
           .. "/page-0.jsonl'")
local ok_a, err_a = Fs.append(ro .. "/page-0.jsonl", "x\n")
if ok_a then
    -- root ignores the mode bits; nothing to assert then
    report(true, "permission checks (running as root: mode bits not enforced)")
else
    expect("append to a read-only file is EACCES", "nil,EACCES", ok_a, err_a)
    expect("write_atomic in a read-only directory is EACCES", "nil,EACCES",
           Fs.write_atomic(ro .. "/prefs.json", "x"))
    expect("the read-only file is unchanged", "keep\n",
           Fs.read(ro .. "/page-0.jsonl"))
end
os.execute("chmod 0755 '" .. ro .. "' && chmod 0644 '" .. ro
           .. "/page-0.jsonl'")

------------------------------------------------------------------------
-- 3. No fd leaks, error paths included.
------------------------------------------------------------------------

local function fd_count() return #Fs.listdir("/proc/self/fd") end
local before = fd_count()
for i = 1, 500 do
    Fs.append(f, "l" .. i .. "\n")
    Fs.fsync(f)
    Fs.read(f)
    Fs.truncate(f, 0)
    Fs.fsync_dir(d)
    Fs.fsync_dir(f)                         -- ENOTDIR after the open
    Fs.append(d, "x")                       -- EISDIR at the write
    Fs.read(d)                              -- EISDIR at the read
    Fs.write_atomic(pj, "p" .. i .. "\n")
    Fs.write_atomic(d .. "/sub", "x")       -- fails at the rename
    Fs.listdir(d)
end
expect("no fds leaked across 5500 calls", "0", fd_count() - before)

------------------------------------------------------------------------
-- 4. nb_journal's Store over this fs.
------------------------------------------------------------------------

local cfg = dofile(plugin_dir .. "/nb_config.lua")
local seq = 0
local store = J.Store.new{ fs = Fs, root = root .. "/notebooks", cfg = cfg,
                           rand = function()
                               seq = seq + 1
                               return seq
                           end }
expect("Store:probe creates the root and probes it", "true", store:probe())
expect("the probe leaves no file behind", "false",
       Fs.exists(root .. "/notebooks/.probe"))
local store2 = J.Store.new{ fs = Fs, root = root .. "/notebooks", cfg = cfg }
expect("a second store's probe takes EEXIST on the root", "true",
       store2:probe())
local T = 1790000000
local id = store:create(T)
expect("Store:create", J.utc_stamp(T) .. "-000001", id)
expect("notebook.json exists", "true",
       Fs.exists(root .. "/notebooks/" .. id .. "/notebook.json"))
local nb = store:open(id)
expect("Store:open", "table", type(nb))
local lines = nb:page_lines(-2)
expect("a blank page has no lines", "0", #lines)
expect("append to page -2", "true", nb:append(-2, '{"k":"u","a":1}'))
expect("fsync page -2 (and its directory, the file being new)", "true",
       nb:fsync(-2))
expect("the page file holds one line", '{"k":"u","a":1}\n',
       Fs.read(nb:page_path(-2)))
-- A torn tail: a record cut short, then the repair at the next read.
Fs.append(nb:page_path(-2), '{"k":"u","a":2')
local nb2 = store:open(id)
local l2, repaired = nb2:page_lines(-2)
expect("page_lines repairs the torn tail through truncate",
       '1,true,{"k":"u","a":1}\n', #l2, repaired, Fs.read(nb2:page_path(-2)))
local pages = nb2:pages()
expect("nb:pages", "-2", table.concat(pages, ","))
local list = store:list()
expect("Store:list", "1," .. id .. ",-2", #list, list[1].id,
       table.concat(list[1].pages, ","))
expect("save_prefs", "true", store:save_prefs{ brush = "pencil", size = "L",
                                               last_page = { [id] = -2 } })
local prefs = store:load_prefs()
expect("load_prefs round trip", "pencil,L,-2", prefs.brush, prefs.size,
       prefs.last_page[id])
expect("prefs.json leaves no temporary", "false",
       Fs.exists(root .. "/notebooks/prefs.json.tmp"))
expect("Store:open of a missing notebook names the path",
       "nil,ENOENT <tmp>/notebooks/" .. J.utc_stamp(T) .. "-0000ff/notebook.json",
       store:open(J.utc_stamp(T) .. "-0000ff"))

os.execute("rm -rf '" .. root .. "'")

if fail == 0 then
    print("RESULT: ok")
else
    print(format("RESULT: %d failure(s)", fail))
    os.exit(1)
end
