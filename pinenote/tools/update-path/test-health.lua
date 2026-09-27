-- Execute the production health command. Unknown reads/commands are errors;
-- this fixture cannot run a host command or modify a filesystem.
local helper = assert(arg[1])
local ledger = assert(loadfile((helper:gsub("[^/]+$", "generation_ledger.lua"))))()
local system = "/gnu/store/fixture-system"
local mount = "21 20 179:7 / /data rw,relatime - ext4 /dev/mmcblk0p7 rw\n"
local count = 0
local function check(name, options, expected, diagnostic)
    local output, exit = {}, {}
    local files = {
        ["/proc/self/mountinfo"] = options.mount or mount,
        ["/sys/dev/block/179:7/uevent"] = options.uevent or "PARTNAME=data\n",
        ["/run/wilkbook-power/ready"] = "ready\n",
        ["/proc/cmdline"] = "gnu.system=" .. system,
    }
    local function port(s)
        return {
            read = function(_, mode) return mode == "*l" and s:match("[^\n]+") or s end,
            lines = function() return s:gmatch("[^\n]+") end,
            close = function() return true end,
        }
    end
    local env = setmetatable({
        arg = { [0] = helper, "health", "--expect", system },
        package = { path = package.path },
        require = function(n) assert(n == "generation_ledger"); return ledger end,
        print = function(s) output[#output + 1] = s end,
        io = {
            open = function(path, mode)
                assert(mode == "r")
                assert(files[path] ~= nil, "unexpected read: " .. path)
                return port(files[path])
            end,
            popen = function(cmd)
                if cmd == "readlink -f /run/current-system 2>/dev/null" then return port(system) end
                if cmd == "ls /var/guix/profiles 2>/dev/null" then return port("") end
                assert(cmd == '( LC_ALL=C timeout 30 herd status reader-session ) 2>&1; echo "__rc=$?"', cmd)
                return port(options.status or "  It is running since yesterday\n__rc=0\n")
            end,
        },
        os = { exit = function(rc) exit.code = rc; error(exit) end },
    }, { __index = _G })
    local chunk = assert(loadfile(helper)); setfenv(chunk, env)
    local ok, err = pcall(chunk)
    assert(not ok and err == exit, tostring(err))
    assert(exit.code == expected, name .. ": wrong exit " .. tostring(exit.code))
    assert(table.concat(output, "\n"):find(diagnostic, 1, true), name .. ": missing diagnostic")
    count = count + 1
    print("PASS: health entrypoint: " .. name)
end
check("mounted data", {}, 0, "data_ready=true")
check("placeholder", { mount = "20 1 179:6 / / rw - ext4 /dev/root rw\n" }, 1, "health=FAIL: /data is not mounted")
check("read-only data", { mount = mount:gsub("rw", "ro") }, 1, "health=FAIL: /data is not read-write")
check("wrong partition", { uevent = "PARTNAME=os1\n" }, 1, "health=FAIL: /data is not the GPT data partition")
check("stopped reader with running history", { status = "  It is stopped.\n  It was running yesterday.\n__rc=0\n" }, 1, "health=FAIL: reader-session not started")
check("unreachable shepherd", { status = "connection refused\n__rc=1\n" }, 1, "health=FAIL: reader-session not started")
print(string.format("PASS: %d production health command cases", count))
