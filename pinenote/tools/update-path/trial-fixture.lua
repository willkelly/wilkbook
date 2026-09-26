-- Runtime adapter for test-trial.scm.  Execute the verbatim helper with an
-- isolated Lua environment; every external operation must match below or fail.
-- No commands, writes, sleeps, signals, mounts or kexecs reach the host.
local helper, scenario = assert(arg[1]), assert(arg[2])
local initial, failure = scenario:match("^(.-):(.+)$")
initial, scenario = initial or scenario, failure or scenario
local function event(s) print(s) end
local authority = "pinenote-book-state-device"
local service = { [authority] = "running", ["reader-session"] = "running" }
local root_ro, data_ro = false, false
local data_present = initial ~= "no-data"
local runtime = true
local wifi = initial ~= "wifi-off"
local irq = 0
local udc = "fcc00000.usb\n"
local dwc = "auto\n"
local record
if initial == "absent" then service[authority], runtime = "absent", false end
if initial == "stopped" or initial == "inert" then service[authority], runtime = "stopped", false end
if initial == "reader-stopped" then service["reader-session"] = "stopped" end
if initial == "already-ro" then root_ro, data_ro = true, true end
local data_id, root_id, root_present, loaded = "21", "20", true, false
local files = {
    ["/boot/gen-2/append"] = "root=LABEL=PNGuixRoot console=ttyS2,1500000n8\n",
    ["/run/current-system/profile/sbin/kexec"] = "binary",
    ["/proc/device-tree/model"] = scenario == "quiesce-fail" and "PineNote\0" or "linux,dummy-virt\0",
    ["/proc/sys/kernel/random/boot_id"] = "fixture-boot\n",
}
local function mountinfo()
    if scenario == "mountinfo-fail" or (scenario == "late-mountinfo-fail" and loaded) then return nil end
    local function mount(id, point, ro)
        local mode = ro and "ro" or "rw"
        return id .. " 1 179:6 / " .. point .. " " .. mode .. ",relatime - ext4 /dev/fixture " .. mode .. "\n"
    end
    local data = data_present and mount(data_id, "/data", data_ro) or ""
    if scenario == "bind-ro" then data = data:gsub("/data rw,", "/data ro,") end
    return (root_present and mount(root_id, "/", root_ro) or "") .. data
end
local function read(path)
    if path == "/proc/self/mountinfo" then return mountinfo() end
    if path == "/run/wilkbook-book-state" then return runtime and "" or nil end
    if path:match("/UDC$") then return udc end
    if path:match("/power/control$") then return dwc end
    if path == "/proc/interrupts" then irq = irq + 1; return " 19: " .. irq .. " fdec0000.ebc\n" end
    return files[path]
end
local function write(path, text)
    event("WRITE " .. path .. " " .. text:gsub("\n", "|"))
    if path:match("/UDC$") then
        if scenario == "udc-error" and text == "\n" then error("configfs write failed") end
        udc = text
    elseif path:match("/power/control$") then dwc = text
    elseif path == "/dev/watchdog0" then
        -- A real watchdog is never opened by this adapter.
    elseif path == "/run/wilkbook-generation/last-trial" then record = text
    else error("unexpected write: " .. path) end
end
local function port(text, writer)
    local pos = 1
    return {
        read = function(_, mode)
            if mode == "*a" then return text end
            assert(mode == "*l")
            local line = text:match("([^\n]*)", pos); pos = #text + 1; return line
        end,
        lines = function()
            return function()
                if pos > #text then return nil end
                local e = text:find("\n", pos, true) or (#text + 1)
                local s = text:sub(pos, e - 1); pos = e + 1; return s
            end
        end,
        write = function(self, s) assert(writer)(s); return self end,
        close = function() return true end,
    }
end
local exit_tag, kexec_tag = {}, {}
local function command(cmd)
    event("CMD " .. cmd)
    local action, name = cmd:match("herd (%w+) ([%w-]+)")
    if action then
        assert(service[name], "unknown service: " .. name)
        if action == "status" then
            if scenario == "status-fail" and name == authority then return 1, "cannot connect to Shepherd" end
            if service[name] == "absent" then return 1, "herd: error: service '" .. name .. "' could not be found" end
            local state = service[name]
            local suffix = initial == "inert" and " (failing)." or "."
            -- Stopped output deliberately has 'running' in its history.
            return 0, "Status of " .. name .. ":\n  It is " .. state .. suffix .. "\n  Previously running: yesterday\n"
        elseif action == "stop" then
            if scenario == "stop-in-progress" and name == authority then
                service[name] = "being stopped"; return 124, "stop request timed out"
            end
            if (scenario == "stop-fail" or scenario == "stop-still-running") and name == authority then
                return scenario == "stop-fail" and 1 or 0, "stop failed"
            end
            if scenario == "reader-stop-fail" and name == "reader-session" then return 1, "reader stop failed" end
            service[name] = "stopped"
            if name == authority and scenario ~= "cleanup-fail" then runtime = false end
            if scenario == "stop-fail-after" and name == authority then return 1, "lost reply after stopping" end
            return 0, "stopped"
        elseif action == "start" then
            if scenario == "restart-fail" and name == authority then return 1, "restart failed" end
            if name == authority and runtime and service[name] ~= "running" then return 1, "stale runtime" end
            service[name] = "running"
            if name == authority then runtime = true end
            return 0, "started"
        end
        error("unexpected herd action")
    end
    if cmd:find("pinenote-wifi-control", 1, true) then
        if cmd:find(" status", 1, true) then return wifi and 0 or 1, "" end
        wifi = cmd:find(" on", 1, true) ~= nil; return 0, ""
    end
    local mode, target = cmd:match("^mount %-o remount,(%w+) ([^ ]+)")
    if mode then
        assert(target == "/" or target == "/data", "unexpected mount target")
        if mode == "ro" then
            if target == "/data" then
                -- Model the original bug: an authority or orphan writer keeps
                -- the real filesystem busy even after a successful sync.
                if service[authority] == "running" or scenario == "busy-data" then return 32, "filesystem busy" end
                if scenario ~= "lying-mount" then data_ro = true end
            else
                if scenario == "busy-root" then return 32, "root busy" end
                root_ro = true
            end
        else
            assert(mode == "rw")
            if scenario == "restore-mount-fail" and target == "/data" then return 32, "restore busy" end
            if target == "/" then root_ro = false else data_ro = false end
        end
        return 0, ""
    end
    if cmd:find("sbin/kexec -l", 1, true) then
        loaded = true
        if scenario == "data-replaced" then data_id = "22" end
        if scenario == "data-appeared" then data_present = true end
        if scenario == "data-disappeared" then data_present = false end
        if scenario == "root-replaced" then root_id = "23" end
        if scenario == "root-disappeared" then root_present = false end
        return scenario == "load-fail" and 1 or 0, "load diagnostic"
    end
    if cmd:find("sbin/kexec -u", 1, true) then return 0, "" end
    if cmd:find("sbin/kexec -e", 1, true) then
        if scenario == "exec-fail" or scenario == "restart-fail" or scenario == "restore-mount-fail" then return 1, "exec diagnostic" end
        error(kexec_tag)
    end
    if cmd == "sync" or cmd:match("^sleep ") or cmd == "mkdir -p /run/wilkbook-generation" then return 0, "" end
    if cmd == "ls /var/guix/profiles 2>/dev/null" then return 0, "" end
    error("unexpected command: " .. cmd)
end
local env = setmetatable({
    arg = { [0] = helper, "trial", "2" },
    package = { path = package.path },
    require = function(name)
        if name == "generation_ledger" then return assert(loadfile((helper:gsub("[^/]+$", "generation_ledger.lua"))))() end
        assert(name == "ffi", "unexpected require: " .. name)
        return { cdef = function() end, C = { signal = function() end }, cast = function() end }
    end,
    pcall = function(fn, ...)
        local result = { pcall(fn, ...) }
        if not result[1] and (result[2] == exit_tag or result[2] == kexec_tag) then error(result[2]) end
        return unpack(result)
    end,
    io = {
        stderr = { write = function(_, s) event("LOG " .. s:gsub("\n", "|")) end },
        open = function(path, mode)
            if mode == "w" then return port("", function(s) write(path, s) end) end
            assert(mode == "r")
            local s = read(path)
            return s and port(s) or nil
        end,
        popen = function(cmd)
            local inner = cmd:match('^%( (.*) %) 2>&1; echo "__rc=%$%?"$')
            local rc, out = command(inner or cmd)
            return port(out .. (inner and ("\n__rc=" .. rc .. "\n") or ""))
        end,
    },
    os = {
        execute = function(cmd) local rc = command(cmd); return rc * 256 end,
        remove = function(path) assert(path == "/run/wilkbook-generation/last-trial"); record = nil; return true end,
        exit = function(rc) event("RESULT exit " .. rc); error(exit_tag) end,
    },
}, { __index = _G })
local chunk = assert(loadfile(helper))
setfenv(chunk, env)
local ok, err = pcall(chunk)
if err == kexec_tag then event("RESULT kexec")
elseif err ~= exit_tag then error(err or "helper unexpectedly returned") end
event("STATE reader=" .. service["reader-session"] .. " authority=" .. service[authority]
    .. " root=" .. (root_ro and "ro" or "rw") .. " data=" .. (data_present and (data_ro and "ro" or "rw") or "absent")
    .. " wifi=" .. tostring(wifi) .. " runtime=" .. tostring(runtime))
if record then event("RECORD " .. record:gsub("\n", "|")) end
