-- generation_ledger.lua: the update path's pure decisions, pinned.
local L = assert(loadfile(arg[1] or "../../packages/update-path/generation_ledger.lua"))()
local failures = 0
local function check(ok, label, detail)
    print((ok and "PASS: " or "FAIL: ") .. label .. (detail and (" -- " .. tostring(detail)) or ""))
    if not ok then failures = failures + 1 end
end

-- 1. The REAL parameters sexp of the v0.2.0-lineage system (device, 2026-09-02).
local params_text = [[(boot-parameters (version 1) (label "GNU with Linux-Pinenote-Hrdl-Direct 7.1.8-pinenote") (root-device (uuid dce #vu8(112 196 194 71 217 180 18 109 239 103 77 73 112 196 194 71))) (kernel "/gnu/store/lixcxaxnygyqrhjfh68yzgqip42q3dcc-linux-pinenote-hrdl-direct-7.1.8-pinenote/Image") (kernel-arguments ("ignore_loglevel" "rw" "rootwait" "earlycon" "console=ttyS2,1500000n8" "brcmfmac.feature_disable=0x82000" "vt.global_cursor_default=0" "no_console_suspend" "fw_devlink=off" "fbcon=map:1")) (initrd "/gnu/store/l5yprpavcr5b6abylbmdpylwhg1p1i4h-raw-initrd/initrd.cpio.gz") (bootloader-name pinenote-rootfs-extlinux) (bootloader-menu-entries ()) (locale "en_US.utf8") (store (device (uuid dce #vu8(112 196 194 71 217 180 18 109 239 103 77 73 112 196 194 71))) (mount-point "/") (directory-prefix #f) (crypto-devices ())))]]
local p = L.parse_parameters(params_text)
check(p and p.kernel == "/gnu/store/lixcxaxnygyqrhjfh68yzgqip42q3dcc-linux-pinenote-hrdl-direct-7.1.8-pinenote/Image",
      "parameters: kernel image path is read from the real sexp", p and p.kernel)
check(p and p.initrd:match("raw%-initrd/initrd%.cpio%.gz$") ~= nil, "parameters: initrd path is read")
check(p and #p.kernel_arguments == 10 and p.kernel_arguments[10] == "fbcon=map:1" and p.kernel_arguments[5] == "console=ttyS2,1500000n8",
      "parameters: all ten kernel arguments in order (quoted strings with commas survive)")
check(L.parse_parameters("(boot-parameters (version 1))") == nil, "parameters: a sexp without kernel/initrd/arguments is refused")

-- 2. APPEND is exactly what the shipped extlinux carried for this system.
local S = "/gnu/store/2aa94c1v9l4r77gxf0mifgq31qqyj9r7-system"
local append = L.append_for(S, p.kernel_arguments)
local shipped = "root=PNGuixRoot gnu.system=" .. S .. " gnu.load=" .. S .. "/boot ignore_loglevel rw rootwait earlycon console=ttyS2,1500000n8 brcmfmac.feature_disable=0x82000 vt.global_cursor_default=0 no_console_suspend fw_devlink=off fbcon=map:1"
check(append == shipped, "append_for reproduces the shipped extlinux APPEND byte for byte")

-- 3. The menu: newest first, DEFAULT is the PROMOTED generation, not the newest.
local ledger = {
    { number = 1, system = "/gnu/store/aaa-system", append = "A" },
    { number = 3, system = "/gnu/store/ccc-system", append = "C" },
    { number = 2, system = "/gnu/store/bbb-system", append = "B" },
}
local menu = L.render_extlinux(ledger, 2)
check(menu and menu:find("\nDEFAULT gen%-2\n") ~= nil, "render: DEFAULT names the promoted generation (2), not the newest (3)")
check(menu and menu:find("LABEL gen%-3") < menu:find("LABEL gen%-2") and menu:find("LABEL gen%-2") < menu:find("LABEL gen%-1"),
      "render: entries are newest first")
check(menu and menu:find("  KERNEL /boot/gen%-3/Image\n  FDT /boot/gen%-3/rk3566%-pinenote%-v1%.2%.dtb\n  INITRD /boot/gen%-3/initrd%.cpio%.gz\n  APPEND C\n") ~= nil,
      "render: each entry loads its own short /boot/gen-N payload with its own APPEND")
check(menu and menu:find("TIMEOUT 30\n") ~= nil and menu:find("%(promoted%)") ~= nil, "render: timeout and the promoted marker are present")
check(L.render_extlinux(ledger, 9) == nil, "render: refuses a DEFAULT that is not in the ledger")
check(L.parse_default(menu) == 2, "parse_default reads DEFAULT back")

-- 4. Numbering and pruning.
check(L.next_number({ 1, 3, 2 }) == 4 and L.next_number({}) == 1, "next_number is max+1, 1 on an empty ledger")
local plan = L.prune_plan({ 1, 2, 3, 4, 5, 6 }, 2, 6, 3)
check(table.concat(plan, ",") == "1,3", "prune: keeps the 3 newest (4,5,6), never the promoted (2) or booted (6), deletes 1 and 3", table.concat(plan, ","))
check(#L.prune_plan({ 1, 2 }, 2, 2, 3) == 0, "prune: nothing to delete under the keep count")
-- The pin (2026-09-04): a pinned generation is kept whatever its age, and
-- does not count against the keep window -- like the promoted and booted ones.
local pinned_in = L.prune_plan({ 1, 2, 3, 4, 5, 6 }, 2, 6, 3, { [5] = true })
check(table.concat(pinned_in, ",") == "1,3", "prune: a pin inside the window changes nothing (5 was kept anyway)", table.concat(pinned_in, ","))
local pinned_out = L.prune_plan({ 1, 2, 3, 4, 5, 6 }, 2, 6, 3, { [1] = true })
check(table.concat(pinned_out, ",") == "3", "prune: a pin outside the window keeps the oldest (1) and still deletes 3", table.concat(pinned_out, ","))
local pinned_two = L.prune_plan({ 1, 2, 3, 4, 5, 6 }, 2, 6, 3, { [1] = true, [3] = true })
check(#pinned_two == 0, "prune: two pins outside the window leave nothing to delete", table.concat(pinned_two, ","))
local pinned_default = L.prune_plan({ 1, 2, 3, 4, 5, 6 }, 2, 6, 3, { [2] = true })
check(table.concat(pinned_default, ",") == "1,3", "prune: pinning the promoted generation is redundant, not harmful", table.concat(pinned_default, ","))
local all_pinned = L.prune_plan({ 1, 2, 3, 4, 5, 6 }, 6, 6, 1, { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true })
check(#all_pinned == 0, "prune: everything pinned means nothing to prune, even with keep=1", table.concat(all_pinned, ","))
local no_set = L.prune_plan({ 1, 2, 3, 4, 5, 6 }, 2, 6, 3, nil)
check(table.concat(no_set, ",") == "1,3", "prune: no pinned set behaves as before (nothing pinned)", table.concat(no_set, ","))
check(L.pin_path(16) == "/boot/gen-16/pinned", "pin_path: the marker lives in the generation's own payload directory", L.pin_path(16))

-- 5. Health predicate.
local ok1 = L.health_ok({ current_system = S, broker_ready = true, reader_started = true }, S)
local ok2, why2 = L.health_ok({ current_system = "/gnu/store/other-system", broker_ready = true, reader_started = true }, S)
local ok3, why3 = L.health_ok({ current_system = S, broker_ready = false, reader_started = true }, S)
local ok4, why4 = L.health_ok({ current_system = S, broker_ready = true, reader_started = false }, S)
check(ok1 == true, "health: expected system + broker + reader is ok")
check(ok2 == false and why2:find("expected", 1, true), "health: a different running system fails", why2)
check(ok3 == false and why3:find("broker", 1, true), "health: broker not ready fails", why3)
check(ok4 == false and why4:find("reader", 1, true), "health: reader not started fails", why4)

-- 6. Booted system from a command line.
check(L.booted_system("root=PNGuixRoot gnu.system=" .. S .. " gnu.load=" .. S .. "/boot rw") == S, "booted_system reads gnu.system= off the command line")
check(L.booted_system("root=PNGuixRoot rw") == nil, "booted_system is nil without gnu.system=")

os.exit(failures == 0 and 0 or 1)
