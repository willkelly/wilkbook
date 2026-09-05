-- wilkbook-generation: system generations on the device (doc/update-path.md).
--
--   list                 the ledger, the promoted default, the booted one
--   add SYSTEM           register a copied system as the next generation
--                        (also materializes any profile generation that
--                        has no /boot/gen-N yet, e.g. the shipped one)
--   render               rewrite /boot/extlinux/extlinux.conf from the ledger
--   trial N              kexec into generation N WITHOUT changing DEFAULT
--   promote N            make N the DEFAULT (and Guix's current profile)
--   demote               promote the newest generation older than DEFAULT
--   health [--expect S]  report; exit 0 iff the running system is healthy
--   prune --keep K       delete generations beyond K (never DEFAULT/booted), guix gc
--   last-trial           the record of a trial this boot bailed out of, if any
--
-- Every write is confined to p6's /boot, /var/guix/profiles and, through
-- guix gc, the store.  Nothing here touches p7, os1 or the partition table.
local script_dir = (arg[0] or "."):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local L = require("generation_ledger")

local PROFILES = "/var/guix/profiles"
local DEFAULT_FILE = "/boot/gen-default"
local EXTLINUX = "/boot/extlinux/extlinux.conf"
local READY = "/run/wilkbook-power/ready"
local WIFI = "/run/current-system/profile/bin/pinenote-wifi-control"
local UDC = "/sys/kernel/config/usb_gadget/pinenote-acm/UDC"
local DWC3_CONTROL = "/sys/bus/platform/devices/fcc00000.usb/power/control"
local WATCHDOG = "/dev/watchdog0"
local function die(fmt, ...) io.stderr:write("wilkbook-generation: " .. fmt:format(...) .. "\n"); os.exit(1) end
local function log(fmt, ...) io.stderr:write("wilkbook-generation: " .. fmt:format(...) .. "\n") end
local function read_file(path) local f = io.open(path, "r"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function write_file(path, text) local f = assert(io.open(path, "w")); f:write(text); f:close() end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end; return false end
local function run(cmd) return os.execute(cmd) == 0 end
local function readlink(path)
    local p = io.popen("readlink -f " .. path .. " 2>/dev/null"); local s = p:read("*l"); p:close(); return s
end
local function sleep_ms(ms) run(string.format("sleep %.3f", ms / 1000)) end
-- Run a command and keep what it says (stdout and stderr together) instead
-- of letting it reach a session that may already be gone; the exit status
-- rides on a trailer line because luajit's popen close does not carry it.
local function capture(cmd)
    local p = io.popen("( " .. cmd .. " ) 2>&1; echo \"__rc=$?\"", "r")
    local out = p:read("*a") or ""; p:close()
    local rc = tonumber(out:match("__rc=(%d+)%s*$"))
    out = (out:gsub("__rc=%d+%s*$", "")); out = (out:gsub("%s+$", ""))
    return rc == 0, rc, out
end
local function boot_id() return ((read_file("/proc/sys/kernel/random/boot_id") or ""):gsub("%s+$", "")) end

-- The trial's teardown, remembered so that a refusal after it can be undone.
-- Past `pinenote-wifi-control off` the session that ran the helper is on a
-- dead radio, and until 2026-09-04 every die() there -- an EBC that never
-- went idle, a failed kexec -l, a kexec -e that returned -- left the reader
-- stopped, the radio off and the gadget unbound, with no message
-- deliverable (found by review; doc/hardware-deploy.md).  bail() is what
-- those sites use now: it writes the refusal record first (so it exists
-- even if a restore hangs), then undoes the teardown in REVERSE -- loaded
-- kernel unloaded, root writable again, watchdog handed back to the kernel,
-- PIPE-domain hold released, gadget re-bound the way the broker and the
-- usb-gadget service do it (the saved UDC name written back into configfs),
-- radio on, reader started -- and only then dies with the message.  The
-- glass-proven teardown order itself is untouched (test-static.sh pins it).
--
-- Nothing in the restore writes to the session: it may be gone (the
-- deployer's keepalives give up ~15 s after the radio-off), a write there
-- is EPIPE, and the control script's `set -e` would abort on its own first
-- message.  When the session did survive, the die message travels over the
-- restored radio; when it did not, `last-trial` hands the record to whoever
-- reconnects (the deployer checks it before health).
local torn = {}
local RECORD_DIR = "/run/wilkbook-generation"
local RECORD = RECORD_DIR .. "/last-trial"
local function record_refusal(n, message)
    run("mkdir -p " .. RECORD_DIR)
    pcall(write_file, RECORD, string.format("boot_id=%s\ngeneration=%d\nresult=refused\nreason=%s\n", boot_id(), n, message))
end
local function bail(fmt, ...)
    local message = fmt:format(...)
    if torn.readonly then run("mount -o remount,rw / >/dev/null 2>&1") end
    record_refusal(torn.generation or 0, message)
    if torn.loaded then run("/run/current-system/profile/sbin/kexec -u >/dev/null 2>&1") end
    -- The magic close: the core stops the dog, or -- the dw_wdt has no
    -- reset line, so it cannot stop -- keeps feeding it from the kernel.
    -- Either way it stops counting down under a system that is staying.
    if torn.armed then pcall(write_file, WATCHDOG, "V") end
    if torn.dwc3 then pcall(write_file, DWC3_CONTROL, torn.dwc3) end
    if torn.udc then
        pcall(write_file, UDC, torn.udc .. "\n")
        if not (read_file(UDC) or ""):find(torn.udc, 1, true) then run("herd start pinenote-usb-acm-gadget >/dev/null 2>&1") end
    end
    if torn.wifi then run(WIFI .. " on >/dev/null 2>&1") end
    if torn.reader then run("herd start reader-session >/dev/null 2>&1") end
    log("trial abandoned: teardown undone (%s%s%s%s); the running system is unchanged, DEFAULT untouched",
        torn.udc and "gadget re-bound, " or "", torn.wifi and "radio on, " or "",
        torn.reader and "reader started" or "reader was not running", torn.armed and ", watchdog handed back" or "")
    die("%s", message)
end

-- ledger from Guix's own profile links
local function profile_generations()
    local gens = {}
    local p = io.popen("ls " .. PROFILES .. " 2>/dev/null")
    for name in p:lines() do
        local n = name:match("^system%-(%d+)%-link$")
        if n then gens[#gens + 1] = { number = tonumber(n), system = readlink(PROFILES .. "/" .. name) } end
    end
    p:close()
    table.sort(gens, function(a, b) return a.number < b.number end)
    return gens
end
local function numbers_of(gens) local t = {} for _, g in ipairs(gens) do t[#t + 1] = g.number end return t end
local function booted_number(gens)
    local sys = L.booted_system(read_file("/proc/cmdline"))
    for _, g in ipairs(gens) do if g.system == sys then return g.number end end
    return nil
end
local function default_number(gens)
    local n = tonumber((read_file(DEFAULT_FILE) or ""):match("%d+"))
    if n then return n end
    return booted_number(gens) or (gens[#gens] and gens[#gens].number)
end

-- /boot/gen-N: the payload U-Boot and kexec load (short, real paths)
local function ensure_payload(g)
    local dir = L.gen_dir(g.number)
    if exists(dir .. "/append") then return read_file(dir .. "/append") end
    local text = read_file(g.system .. "/parameters") or die("%s/parameters unreadable", g.system)
    local params, err = L.parse_parameters(text); if not params then die("%s", err) end
    local kernel_dir = params.kernel:match("^(.*)/Image$") or die("kernel path %s is not .../Image", params.kernel)
    local dtb = kernel_dir .. "/lib/dtbs/rockchip/" .. L.DTB_NAME
    for _, f in ipairs({ params.kernel, params.initrd, dtb }) do
        if not exists(f) then die("generation %d: %s missing", g.number, f) end
    end
    run("mkdir -p " .. dir)
    if not (run(string.format("cp %s %s/Image", params.kernel, dir))
            and run(string.format("cp %s %s/initrd.cpio.gz", params.initrd, dir))
            and run(string.format("cp %s %s/%s", dtb, dir, L.DTB_NAME))) then
        die("generation %d: payload copy failed", g.number)
    end
    local append = L.append_for(g.system, params.kernel_arguments)
    write_file(dir .. "/append", append .. "\n")
    write_file(dir .. "/system", g.system .. "\n")
    log("generation %d: payload staged in %s", g.number, dir)
    return append .. "\n"
end

local function ledger_with_payloads()
    local gens = profile_generations()
    for _, g in ipairs(gens) do g.append = (ensure_payload(g)):gsub("\n$", "") end
    return gens
end

local function render(gens, default)
    local text, err = L.render_extlinux(gens, default); if not text then die("%s", err) end
    run("mkdir -p /boot/extlinux")
    write_file(EXTLINUX .. ".new", text)
    if not run(string.format("mv %s.new %s && sync", EXTLINUX, EXTLINUX)) then die("could not replace %s", EXTLINUX) end
    log("extlinux menu: %d generation(s), DEFAULT gen-%d", #gens, default)
end

local function ebc_irq_count()
    local f = io.open("/proc/interrupts", "r"); if not f then return nil end
    local sum
    for line in f:lines() do
        if line:find("fdec0000.ebc", 1, true) then
            sum = 0; for tok in line:gmatch("%S+") do local n = tonumber(tok); if n then sum = sum + n end end; break
        end
    end
    f:close(); return sum
end
local function ebc_quiesce()
    local last = ebc_irq_count(); if not last then return false end
    local stable, elapsed = 0, 0
    while elapsed < 10000 do
        sleep_ms(25); elapsed = elapsed + 25
        local now = ebc_irq_count(); if not now then return false end
        if now == last then stable = stable + 25; if stable >= 250 then return true end else stable = 0; last = now end
    end
    return false
end

local commands = {}

function commands.list()
    local gens = ledger_with_payloads()
    local default, booted = default_number(gens), booted_number(gens)
    for _, g in ipairs(gens) do
        print(string.format("gen-%d  %s%s%s", g.number, g.system,
                            g.number == default and "  [promoted]" or "", g.number == booted and "  [booted]" or ""))
    end
end

function commands.add(system)
    if not system then die("add needs a system store path") end
    system = readlink(system) or system
    if not exists(system .. "/parameters") then die("%s is not a system (no parameters file)", system) end
    local gens = ledger_with_payloads()
    for _, g in ipairs(gens) do if g.system == system then die("%s is already generation %d", system, g.number) end end
    local n = L.next_number(numbers_of(gens))
    if not run(string.format("ln -s %s %s/system-%d-link", system, PROFILES, n)) then die("could not link generation %d", n) end
    local g = { number = n, system = system }
    g.append = (ensure_payload(g)):gsub("\n$", "")
    gens[#gens + 1] = g
    render(gens, default_number(gens))
    print(string.format("generation %d", n))
end

function commands.render()
    local gens = ledger_with_payloads(); render(gens, default_number(gens))
end

function commands.promote(n)
    n = tonumber(n) or die("promote needs a generation number")
    local gens = ledger_with_payloads()
    local found = false
    for _, g in ipairs(gens) do if g.number == n then found = true end end
    if not found then die("no generation %d", n) end
    write_file(DEFAULT_FILE, n .. "\n")
    run(string.format("ln -sfn system-%d-link %s/system", n, PROFILES))
    render(gens, n)
    print(string.format("promoted generation %d", n))
end

function commands.demote()
    local gens = ledger_with_payloads()
    local current = default_number(gens)
    local prev
    for _, g in ipairs(gens) do if g.number < current and (not prev or g.number > prev) then prev = g.number end end
    if not prev then die("no generation older than %d to demote to", current) end
    commands.promote(tostring(prev))
end

function commands.trial(n)
    n = tonumber(n) or die("trial needs a generation number")
    local dir = L.gen_dir(n)
    local append = read_file(dir .. "/append") or die("no staged payload for generation %d (run add)", n)
    append = append:gsub("\n$", "")
    if not exists("/run/current-system/profile/sbin/kexec") then die("kexec-tools is not in this image") end
    log("trial boot of generation %d: DEFAULT is unchanged; a power-cycle returns to it", n)
    torn.generation = n
    -- A record left by a trial this boot refused is stale from here on: a
    -- later trial that dies without leaving one must not be read as that
    -- earlier refusal.  Removed at the start; only bail() writes it.
    os.remove(RECORD)
    -- The session that ran this helper may be gone by the time a refusal is
    -- reported; a write to its pipe must come back EPIPE, not kill the
    -- helper mid-restore (SIGPIPE's default).  Best-effort: no ffi, no change.
    pcall(function() local ffi = require("ffi"); ffi.cdef("void *signal(int, void *);"); ffi.C.signal(13, ffi.cast("void *", 1)) end)
    local model = (read_file("/proc/device-tree/model") or ""):gsub("%z", "")
    local pinenote = model:find("PineNote", 1, true) ~= nil
    -- The generation's DTB is the PineNote's; on any other machine (the
    -- QEMU virt rig, rung 4) kexec-tools reuses the running device tree
    -- when --dtb is omitted.
    local dtb_arg = pinenote and string.format(" --dtb=%s/%s", dir, L.DTB_NAME) or ""
    -- Everything the operator must hear is said HERE, before the teardown.
    -- The teardown's first act after stopping the reader is the radio, and
    -- an operator watching a trial over ssh (the deployer, or a hand-run
    -- helper) is on that radio: no line logged after it ever arrives.
    -- 2026-09-04: the two device-tree notes below went "uncaptured" through
    -- two trials for exactly this reason.  Only the UART sees the later lines.
    log("machine model %q -> %s", model, dtb_arg ~= "" and "generation DTB" or "running device tree reused")
    -- A trial boots on the RUNNING kernel's device tree, whatever --dtb says:
    -- kexec-tools (2.0.31) tries kexec_file_load first and its arm64 loader
    -- drops a user DTB on that path ("(ignored)", kexec-arm64.c), and the
    -- kernel then builds the next tree from the current one -- U-Boot's
    -- serial-number and memory layout included, which is also why forcing
    -- the legacy syscall is not the fix.  Proven 2026-09-03: a generation
    -- whose DTB carried a new property booted without it.  So a trial
    -- half-tests a generation whose device tree differs from the promoted
    -- one; only a cold boot of that generation runs its own tree.  Say so.
    if pinenote then
        local gens = ledger_with_payloads()
        local booted = booted_number(gens)
        if booted and booted ~= n then
            local ours = read_file(dir .. "/" .. L.DTB_NAME)
            local theirs = read_file(L.gen_dir(booted) .. "/" .. L.DTB_NAME)
            if ours and theirs and ours ~= theirs then
                log("NOTE: generation %d's device tree differs from the booted gen-%d's; this trial runs on the running tree (kexec_file_load ignores --dtb) -- cold-boot generation %d before trusting a device-tree change", n, booted, n)
            end
        end
        -- And the running tree may be older still: a kernel that was itself
        -- kexec'd inherited the tree of whatever last cold-booted.
        if exists("/proc/device-tree/chosen/linux,booted-from-kexec") then
            log("NOTE: the running kernel was kexec'd; its device tree is the last cold boot's, not gen-%d's -- a device-tree change is proven only by a cold boot", booted or 0)
        end
    end
    -- The same teardown a suspend runs: stop the reader cleanly (INT-first
    -- destructor), radio off, gadget unbound, panel idle, disk synced.
    -- Each step remembers what it undid, for bail(): only what was up comes
    -- back (a reader that was not running stays stopped, a radio that was
    -- off stays off).
    torn.reader = run("herd status reader-session 2>/dev/null | grep -q running")
    run("herd stop reader-session >/dev/null 2>&1")
    torn.wifi = run(WIFI .. " status >/dev/null 2>&1")
    run(WIFI .. " off >/dev/null 2>&1")
    local bound = (read_file(UDC) or ""):gsub("%s+$", "")
    if bound ~= "" then torn.udc = bound; write_file(UDC, "\n") end
    -- Hold the PIPE power domain up through the kexec.  The USB controller
    -- is its only live device; once the gadget is unbound it runtime-
    -- suspends and genpd gates the domain, and the next kernel's early GRF
    -- init writes into a powered-off block -- the bus never answers.  dwc3
    -- has no shutdown hook, so a runtime-PM "on" set here survives to the
    -- new kernel (U-Boot hands a cold boot every domain on; hand the
    -- kexec'd kernel the same).  Best-effort: absent on other machines.
    if exists(DWC3_CONTROL) then torn.dwc3 = read_file(DWC3_CONTROL); write_file(DWC3_CONTROL, "on\n") end
    -- The EBC must be idle before the kernel is replaced under it -- on a
    -- PineNote.  On any other machine there is no EBC interrupt line and
    -- nothing to quiesce.
    if pinenote then
        if not ebc_quiesce() then bail("EBC did not go idle; refusing to replace the kernel under a refresh") end
    else
        log("machine model %q: no EBC to quiesce", model)
    end
    -- On the RK3566 a kexec'd kernel hangs, silently, 0.12 s into boot: its
    -- early rockchip_grf_init writes three USB3-OTG bits into the PIPE GRF,
    -- whose APB clock (pclk_pipe) the previous kernel gated as unused --
    -- U-Boot hands a cold boot with it running -- and the bus never
    -- answers (the pipe power domain itself was on).  The values it
    -- would write are already there -- the cold boot wrote them and the
    -- GRF persists across a kexec -- so on the kexec path, and only there,
    -- that initcall is skipped.  Cold boots are untouched.  Proven on
    -- glass 2026-09-02: three hangs at the same line, then a full boot
    -- with exactly this argument (doc/update-path.md).
    if pinenote then append = append .. " initcall_blacklist=rockchip_grf_init" end
    -- Likewise the generation's console: ttyS2 is the PineNote's UART.  On
    -- QEMU virt the console is the PL011 (ttyAMA0); a kernel told to use a
    -- console that does not exist leaves the initrd's init unable to open
    -- /dev/console, and Guix's initrd then runs away in memory and is
    -- OOM-killed (rung 4, 2026-09-02: 1.9 GB anon RSS, init reaped).
    if not pinenote then
        append = append:gsub("console=ttyS2,%d+n%d", "console=ttyAMA0")
        log("machine model %q: console argument rewritten for the PL011", model)
    end
    local load = string.format("/run/current-system/profile/sbin/kexec -l %s/Image --initrd=%s/initrd.cpio.gz%s --command-line='%s'",
                               dir, dir, dtb_arg, append)
    -- The kexec binary's own words come back with the refusal (until
    -- 2026-09-04 they went to a session already off the air).
    local loaded, load_rc, load_said = capture(load)
    if not loaded then bail("kexec -l failed for generation %d (exit %s): %s", n, tostring(load_rc), load_said) end
    torn.loaded = true
    run("sync")
    if run("mount -o remount,ro / 2>/dev/null") then torn.readonly = true end
    log("kexec -e into generation %d", n)
    run("sync")
    -- Arm the SoC watchdog last.  A kernel that dies before its drivers
    -- probe (the 2026-09-02 hangs: 0.12 s in, no serial driver, so no
    -- sysrq, no ssh -- only the power button) never pings it, and the SoC
    -- SHOULD reset into U-Boot after the hardware timeout.  On glass it
    -- did not (2026-09-02/03: armed, expired, nothing; CRU_GLB_RST_CON
    -- was already 0x103, so the PX30-style route bit is not the enabler).
    -- The arm stays: it is harmless, and it is what delivers the
    -- self-reset once the real enabler is found (doc/upstream-register.md
    -- 25).  A kernel that
    -- boots finds it running and pings it from the moment the driver
    -- probes (watchdog.handle_boot_enabled=y); it cannot be stopped again
    -- without a reset line, so it simply stays kernel-fed.  Closing
    -- without the magic character keeps it running on purpose.
    -- Best-effort: no /dev/watchdog0 (QEMU virt) means no cover.
    local wd = io.open(WATCHDOG, "w")
    if wd then wd:write("1"); wd:close(); torn.armed = true; log("watchdog armed: a trial that never boots resets into U-Boot")
    else log("no %s: a trial that never boots needs the power button", WATCHDOG) end
    local _, exec_rc, exec_said = capture("/run/current-system/profile/sbin/kexec -e")
    bail("kexec -e returned (exit %s): %s; the running system is unchanged", tostring(exec_rc), exec_said)
end

-- The record bail() leaves, for a caller whose link had already dropped
-- when the refusal was said: printed, exit 0, only when it belongs to THIS
-- boot (a trial that went through is a new boot, so a stale record can
-- never pass for a fresh one).
commands["last-trial"] = function()
    local rec = read_file(RECORD)
    if not rec or rec:match("boot_id=(%S+)") ~= boot_id() then die("no trial refused in this boot") end
    io.write(rec)
end

function commands.health(flag, expected)
    local report = {
        current_system = readlink("/run/current-system"),
        broker_ready = exists(READY),
        reader_started = run("herd status reader-session 2>/dev/null | grep -q 'running'"),
    }
    local gens = profile_generations()
    print("current_system=" .. tostring(report.current_system))
    print("booted_generation=" .. tostring(booted_number(gens)))
    print("broker_ready=" .. tostring(report.broker_ready))
    print("reader_started=" .. tostring(report.reader_started))
    if flag == "--expect" then
        local ok, why = L.health_ok(report, expected)
        print("health=" .. (ok and "ok" or ("FAIL: " .. why)))
        os.exit(ok and 0 or 1)
    end
end

function commands.prune(flag, keep)
    keep = (flag == "--keep") and tonumber(keep) or 5 -- the deployer's default too
    local gens = ledger_with_payloads()
    local plan = L.prune_plan(numbers_of(gens), default_number(gens), booted_number(gens), keep)
    if #plan == 0 then print("nothing to prune"); return end
    for _, n in ipairs(plan) do
        run(string.format("rm -rf %s %s/system-%d-link", L.gen_dir(n), PROFILES, n))
        log("pruned generation %d", n)
    end
    local remaining = ledger_with_payloads()
    render(remaining, default_number(remaining))
    if exists("/run/current-system/profile/bin/guix") then
        log("guix gc (roots: the remaining profile links)")
        run("/run/current-system/profile/bin/guix gc >/dev/null 2>&1")
    end
end

local cmd = commands[arg[1] or ""]
if not cmd then
    io.stderr:write("usage: wilkbook-generation list|add SYSTEM|render|trial N|promote N|demote|health [--expect S]|prune [--keep K]|last-trial\n")
    os.exit(2)
end
cmd(arg[2], arg[3])
