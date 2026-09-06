#!/bin/sh
# Structural pins on the imperative halves: the trial boot's ordering and
# the deployer's refusal to promote without a passing health check.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
helper="$here/../../packages/update-path/wilkbook-generation.lua"
ledger="$here/../../packages/update-path/generation_ledger.lua"
deploy="$here/../deploy/deploy.sh"
line() { grep -n -- "$1" "$2" | head -1 | cut -d: -f1; }
after() { [ "$(line "$2" "$3")" -gt "$(line "$1" "$3")" ] || { echo "FAIL: expected '$2' after '$1' in $3" >&2; exit 1; }; }
# trial: reader stopped, radio off, gadget unbound, EBC idle, kexec -l, sync, remount ro, then kexec -e -- in that order.
after 'herd stop reader-session' 'WIFI .. " off' "$helper"
after 'WIFI .. " off' 'write_file(UDC, "' "$helper"
after 'write_file(UDC, "' 'if not ebc_quiesce() then' "$helper"
after 'if not ebc_quiesce() then' 'kexec -l %s/Image' "$helper"
grep -q 'no EBC to quiesce' "$helper"
after 'kexec -l %s/Image' 'remount,ro' "$helper"
after 'remount,ro' 'sbin/kexec -e")' "$helper"
# The data partition is remounted read-only too, after the root and before
# kexec -e (2026-09-04, generation 18: a kexec'd boot lost /data to a journal
# recovery racing udev's probe), and the bail-out puts it back read-write.
after 'remount,ro / 2>/dev/null' 'remount,ro /data 2>/dev/null' "$helper"
after 'remount,ro /data 2>/dev/null' 'sbin/kexec -e")' "$helper"
[ "$(grep -c 'sbin/kexec -e")' "$helper")" -eq 1 ]
grep -q 'refusing to replace the kernel under a refresh' "$helper"
grep -q 'DEFAULT is unchanged' "$helper"
# The PineNote DTB rides only on a PineNote; elsewhere (QEMU) the running DT is reused.
grep -q 'model:find("PineNote", 1, true)' "$helper"
grep -q 'running device tree reused' "$helper"
grep -q 'console=ttyS2,%d+n%d", "console=ttyAMA0"' "$helper"
echo "PASS: trial boot tears down like a suspend, quiesces the EBC, and never touches DEFAULT"
# What the operator must hear is logged BEFORE the reader stop that leads the
# teardown: the radio goes off next, and whoever watches a trial over ssh is on
# that radio (2026-09-04: both device-tree notes lost through two trials).
after 'machine model %q -> %s' 'herd stop reader-session' "$helper"
after 'NOTE: generation %d' 'herd stop reader-session' "$helper"
after 'NOTE: the running kernel was kexec' 'herd stop reader-session' "$helper"
# Stated against the radio-off literally too (the reader-stop pin above chains
# to it, but the requirement is the radio), and the notes' wording is pinned:
# until 2026-09-04 nothing held either NOTE's text.
after 'NOTE: the running kernel was kexec' 'WIFI .. " off' "$helper"
grep -q 'kexec_file_load ignores --dtb' "$helper"
grep -q 'linux,booted-from-kexec' "$helper"
echo "PASS: the device-tree notes are logged before the radio goes off"
# add materializes every profile generation's payload (the shipped one has no /boot/gen-N).
grep -q 'ensure_payload(g)' "$helper"
grep -q 'ledger_with_payloads()' "$helper"
echo "PASS: add stages payloads for generations that predate the helper"
# writes are confined to /boot, /var/guix/profiles and guix gc.
! grep -q '/data\|mmcblk0p7\|mmcblk0p5\|sfdisk\|parted' "$helper"
echo "PASS: helper never names p7, os1 or the partition table"
# The ledger pin (2026-09-04, the review's S5): pin/unpin exist, list shows the
# marker, prune hands the pinned set to the planner and never deletes a pinned
# generation, and the marker lives inside /boot/gen-N -- so the write set is
# unchanged (the pin above still holds) and the marker dies with the payload.
grep -q '^function commands.pin(n)' "$helper"
grep -q '^function commands.unpin(n)' "$helper"
grep -q 'write_file(L.pin_path(n), "")' "$helper"
grep -q 'rm -f %s && sync", L.pin_path(n)' "$helper"
grep -q 'is_pinned(g.number) and "  \[pinned\]" or ""' "$helper"
grep -q 'L.prune_plan(numbers_of(gens), default_number(gens), booted_number(gens), keep, pinned)' "$helper"
grep -q 'return M.gen_dir(number) .. "/pinned"' "$ledger"
grep -q 'and not pinned\[n\] then' "$ledger"
grep -q 'pin N|unpin N|prune' "$helper"
! grep -q 'gen-pinned\|/boot/pinned\|pins\.conf' "$helper" "$ledger"
echo "PASS: pin/unpin mark a generation inside its own /boot/gen-N and prune honours the pinned set"
# ...and rung 4u exercises it: pin A, a prune that would take A, unpin, then
# the positive control after the rollback.
harness="$here/../../scripts/qemu/run-virt-update-flow.sh"
grep -q 'vm "wilkbook-generation pin 1"' "$harness"
grep -q 'vm "wilkbook-generation unpin 1"' "$harness"
grep -q 'vm "wilkbook-generation prune --keep 1"' "$harness"
grep -q 'vm "wilkbook-generation prune --keep 0"' "$harness"
after 'wilkbook-generation pin 1' 'wilkbook-generation unpin 1' "$harness"
after 'wilkbook-generation unpin 1' 'wilkbook-generation trial 1' "$harness"
after 'wilkbook-generation trial 1' 'wilkbook-generation prune --keep 0' "$harness"
echo "PASS: the QEMU rig pins, prunes around the pin, unpins, and prunes for real after the rollback"
# deployer: promote only after a passing health check; failure exits 1 without promoting.
after 'wilkbook-generation health --expect' 'wilkbook-generation promote' "$deploy"
grep -q 'NOT PROMOTED: health check failed' "$deploy"
grep -q 'NOT PROMOTED: generation .* never answered' "$deploy"
grep -q -- '--target=aarch64-linux-gnu' "$deploy"
grep -q 'guix archive --missing' "$deploy"
! grep -q 'guix archive --export -r' "$deploy"
grep -q 'guix archive --import' "$deploy"
echo "PASS: deployer promotes only after health, cross-builds, sends only the missing paths, and reports refusals"
# The trial's ssh session dies without a FIN (on QEMU with the old kernel, on a
# PineNote at the helper's Wi-Fi off) and nothing closes the TCP connection;
# without keepalives the client hangs forever (2026-09-02).
harness="$here/../../scripts/qemu/run-virt-update-flow.sh"
# three trials: the forced refusal (3b), B, and the rollback to A
[ "$(grep -c '^vm_trial "wilkbook-generation trial' "$harness")" -eq 3 ]
! grep -q '^vm "wilkbook-generation trial' "$harness"
grep -q 'ServerAliveInterval=5 -o ServerAliveCountMax=2' "$harness"
grep -q 'timeout 120 ssh' "$harness"
grep -q 'ServerAliveInterval=5 -o ServerAliveCountMax=2' "$deploy"
grep -q 'timeout 90 ssh' "$deploy"
grep -q 'ServerAliveInterval 5' "$here/../../../Makefile"
echo "PASS: every trial ssh carries keepalives and a timeout, so a kexec cannot hang the caller"
# A stale generation tests the wrong helper; the trial's output is evidence.
grep -q 'stale SYSTEM_B or ROOTFS' "$harness"
grep -q 'cmp -s "$tree_helper" "$shipped"' "$harness"
[ "$(grep -c 'sed "s/^/        trial> /"' "$harness")" -eq 3 ]
echo "PASS: the rig refuses a generation whose helper is not the tree's and keeps each trial's output"
# The rig forces one refusal (B's Image moved away -> kexec -l fails after the
# teardown) and requires the guest back on the same boot, health passing, the
# helper's exit 1 and the record, then a stale record refused on the new boot.
grep -q 'mv /boot/gen-$n/Image /boot/gen-$n/Image.away' "$harness"
grep -q '|| refused_rc=\$?' "$harness"
grep -q '\[ "$refused_rc" -eq 1 \]' "$harness"
grep -q 'trial abandoned: teardown undone' "$harness"
grep -q '\[ "$boot_still" = "$boot_a1" \]' "$harness"
grep -q 'wilkbook-generation last-trial" | grep -q' "$harness"
after 'refused trial: DEFAULT still gen-1' '^# 4. trial: kexec into B' "$harness"
after '^# 4. trial: kexec into B' 'a stale refusal record passed on the new boot' "$harness"
echo "PASS: the rig forces a refusal after the teardown and requires the guest back, reader running"
# kexec on the RK3566 (first glass trial 2026-09-02): the kexec'd kernel found
# the GICv3 LPI tables enabled and unreserved (no EFI to persist them) and
# hung; the PineNote has no LPI user, so LPIs are never enabled.
grep -q '"irqchip.gicv3_nolpi=1"' "$here/../../images/pinenote-initramfs.scm"
echo "PASS: every flavor boots with LPIs disabled, so a kexec'd kernel inherits a clean GIC"
# kexec on the RK3566 (glass, 2026-09-02): the next kernel's rockchip_grf_init
# writes the PIPE GRF, left unclocked by the previous kernel, and hangs the bus
# at 0.12 s; the values persist from the cold boot, so the kexec path -- and only
# the PineNote kexec path -- skips that initcall.
grep -q 'if pinenote then append = append .. " initcall_blacklist=rockchip_grf_init" end' "$helper"
after 'initcall_blacklist=rockchip_grf_init' 'kexec -l %s/Image' "$helper"
! grep -q 'initcall_blacklist' "$here/../../images/pinenote-initramfs.scm"
echo "PASS: the kexec path skips the GRF init that hangs a warm RK3566; cold boots keep it"
# The trial runs the target generation's helper, so a kexec-preparation fix
# applies to the first kexec that needs it.
grep -q 'cat /boot/gen-$gen/system)/profile/bin/wilkbook-generation trial $gen' "$deploy"
! grep -q '"wilkbook-generation trial $gen"' "$deploy"
echo "PASS: the deployer's trial runs the helper shipped by the generation on trial"
# kexec hardening (2026-09-02, offline; glass proof pending): the trial holds the
# PIPE power domain up (dwc3 runtime "on") after the gadget unbind and arms the
# SoC watchdog as the very last thing before kexec -e, both best-effort.
after 'write_file(UDC, "' 'write_file(DWC3_CONTROL, "on' "$helper"
after 'write_file(DWC3_CONTROL, "on' 'kexec -l %s/Image' "$helper"
after 'remount,ro' 'io.open(WATCHDOG, "w")' "$helper"
after 'io.open(WATCHDOG, "w")' 'sbin/kexec -e")' "$helper"
grep -q 'wd:write("1"); wd:close()' "$helper"
! grep -q 'wd:write("V")' "$helper"
grep -q 'needs the power button' "$helper"
echo "PASS: the trial holds the PIPE domain up and arms the watchdog last, both best-effort"
# A trial that never answers is recovered, not just reported: with a UART the
# deployer drives the menu back to os2 after the watchdog reset; without one it
# says what to do.  Never promotes on that path.
grep -q 'recover_after_failed_trial "$gen"' "$deploy"
# 2026-09-04: the watcher is armed BEFORE the kexec (the watchdog reset comes
# within minutes and U-Boot's menu shows for 15 s); recovery then waits on it.
after 'trial_health_promote() {' 'uboot-pick-slot.sh" "$uart_log" --slot os2' "$deploy"
after 'uboot-pick-slot.sh" "$uart_log" --slot os2' 'wilkbook-generation trial' "$deploy"
after 'recover_after_failed_trial() {' 'watcher_wait && wait_for_ssh' "$deploy"
sed -n '/^recover_after_failed_trial() {/,/^}/p' "$deploy" | grep -q '^  exit 1$'
! grep -q 'never answered; a power-cycle boots' "$deploy"
echo "PASS: a trial that never answers is recovered over the UART when one is configured, and never promoted"
# The watcher runs in its own process group and is reaped as a group, on both
# paths, and never through a bare kill that set -e can turn into an abort
# (review 2026-09-04: a watcher that had done its job and exited made the
# deployer die between a passed ssh wait and promote).  The group and the
# pid come from the picker's own handle file ("$uart_log.watcher"), read
# after the arm, with $! only as the fallback: from a shell with job control
# `setsid sh ... &` forks and $! is a wrapper that exited at once, so a reap
# or a wait by $! reached nothing (the 2026-09-04 hand-run trap); from make
# they coincide.  The picker writes pid=, pgid=, reader= before it opens the
# port and exit= when it has one (pinned in scripts/uart/test-uboot-pick-slot.sh).
grep -q 'setsid sh "$repo/pinenote/scripts/uart/uboot-pick-slot.sh"' "$deploy"
after 'rm -f "$uart_log.watcher"' 'setsid sh "$repo/pinenote/scripts/uart/uboot-pick-slot.sh"' "$deploy"
after 'setsid sh "$repo/pinenote/scripts/uart/uboot-pick-slot.sh"' 'watcher_handle || true' "$deploy"
after 'watcher_handle || true' 'wilkbook-generation trial' "$deploy"
sed -n '/^watcher_handle() {/,/^}/p' "$deploy" | grep -q "watcher_pid=\$(sed -n 's/^pid=//p' \"\$uart_log.watcher\")"
sed -n '/^watcher_handle() {/,/^}/p' "$deploy" | grep -q "watcher_pgid=\$(sed -n 's/^pgid=//p' \"\$uart_log.watcher\")"
sed -n '/^watcher_handle() {/,/^}/p' "$deploy" | grep -q 'watcher_pid=$watcher; watcher_pgid=$watcher'
sed -n '/^watcher_wait() {/,/^}/p' "$deploy" | grep -q 'wait "$watcher"'
sed -n '/^watcher_wait() {/,/^}/p' "$deploy" | grep -q "sed -n 's/^exit=//p' \"\$uart_log.watcher\""
sed -n '/^watcher_reap() {/,/^}/p' "$deploy" | grep -q 'kill -- -"$watcher_pgid" 2>/dev/null || true'
[ "$(grep -c '^ *watcher_reap$\|^ *\[ -z "$watcher" \] || watcher_reap$' "$deploy")" -eq 3 ]  # success, refusal, recovery
! grep -q 'kill "$watcher"' "$deploy"
! grep -q 'kill -- -"$watcher"' "$deploy"
! grep -q 'wait "$watcher" && wait_for_ssh' "$deploy"
picker="$here/../../scripts/uart/uboot-pick-slot.sh"
after 'echo "pid=$$"' 'stty -F "$tty"' "$picker"
after 'stty -F "$tty"' 'cat "$tty" >> "$log"' "$picker"
after 'cat "$tty" >> "$log"' 'echo "reader=$reader" >> "$handle"' "$picker"
grep -q 'echo "exit=$status" >> "$handle"' "$picker"
# exit= comes only from the picker's own exit paths, never from $? in the
# EXIT trap: bash as sh runs that trap on an untrapped SIGTERM with the last
# command's status, so a reaped picker recorded exit=0 -- the handle's "slot
# chosen", which watcher_wait reads (review 2026-09-04; dash records
# nothing).  The deployer itself was never misled -- its wait finishes before
# its reap -- only a hand-run watcher's handle, read after the reap, was.
# TERM/INT/HUP are trapped ahead of EXIT and record "terminated".
! grep -q 'status=$?' "$picker"
after "trap 'status=terminated; exit 143' TERM INT HUP" 'trap finish EXIT' "$picker"
sed -n '/^finish() {/,/^}/p' "$picker" | grep -q 'if \[ -n "$status" \]; then echo "exit=$status"'
grep -q 'status=0; exit 0' "$picker"
grep -q 'status=1; exit 1' "$picker"
echo "PASS: the UART watcher is reaped and waited for by the group and pid it records itself, its exit= is never a signal's, and a dead watcher cannot abort a successful deploy"
# A trial that dies AFTER the radio-off (review 2026-09-04): every die() past
# `pinenote-wifi-control off` in the trial goes through bail(), which undoes
# the teardown in reverse -- gadget re-bound (the saved UDC name written back,
# as the broker and the usb-gadget service do), radio on, reader started --
# before it dies, so the reader is never stranded stopped and silent.  The
# teardown ORDER above is untouched; only the failure paths changed.
trial_after_radio=$(sed -n '/^function commands.trial/,/^end$/p' "$helper" | sed -n '/WIFI .. " off/,$p')
! printf '%s\n' "$trial_after_radio" | grep -q 'die('
[ "$(printf '%s\n' "$trial_after_radio" | grep -c 'bail(')" -eq 3 ]
printf '%s\n' "$trial_after_radio" | grep -q 'bail("EBC did not go idle'
printf '%s\n' "$trial_after_radio" | grep -q 'bail("kexec -l failed for generation %d (exit %s): %s"'
printf '%s\n' "$trial_after_radio" | grep -q 'bail("kexec -e returned (exit %s): %s'
# bail() restores in reverse order and only then dies; each restore writes
# nothing to the session (it may be gone: EPIPE would abort the control script).
bail_body=$(sed -n '/^local function bail(/,/^end$/p' "$helper")
printf '%s\n' "$bail_body" | grep -q 'record_refusal(torn.generation'
printf '%s\n' "$bail_body" | grep -q 'sbin/kexec -u >/dev/null 2>&1'
printf '%s\n' "$bail_body" | grep -q 'remount,rw / >/dev/null 2>&1'
printf '%s\n' "$bail_body" | grep -q 'remount,rw /data >/dev/null 2>&1'
printf '%s\n' "$bail_body" | grep -q 'write_file, WATCHDOG, "V"'
printf '%s\n' "$bail_body" | grep -q 'write_file, DWC3_CONTROL, torn.dwc3'
printf '%s\n' "$bail_body" | grep -q 'write_file, UDC, torn.udc'
printf '%s\n' "$bail_body" | grep -q 'herd start pinenote-usb-acm-gadget >/dev/null 2>&1'
printf '%s\n' "$bail_body" | grep -q 'WIFI .. " on >/dev/null 2>&1'
printf '%s\n' "$bail_body" | grep -q 'herd start reader-session >/dev/null 2>&1'
after 'write_file, DWC3_CONTROL, torn.dwc3' 'write_file, UDC, torn.udc' "$helper"
after 'write_file, UDC, torn.udc' 'WIFI .. " on >/dev/null' "$helper"
after 'WIFI .. " on >/dev/null' 'herd start reader-session' "$helper"
after 'herd start reader-session' 'die("%s", message)' "$helper"
# the magic-close V lives only in the bail-out, never in the arm
[ "$(grep -c '"V"' "$helper")" -eq 1 ]
# the teardown remembers what it undid, and only what was up comes back
after 'herd status reader-session 2>/dev/null | grep -q running")' 'herd stop reader-session' "$helper"
after 'WIFI .. " status' 'WIFI .. " off' "$helper"
grep -q 'if bound ~= "" then torn.udc = bound; write_file(UDC, "' "$helper"
# the helper survives its session's death mid-restore, and the kexec binary's words come back
grep -q 'ffi.C.signal(13, ffi.cast("void \*", 1))' "$helper"
grep -q 'local loaded, load_rc, load_said = capture(load)' "$helper"
grep -q 'capture("/run/current-system/profile/sbin/kexec -e")' "$helper"
grep -q 'commands\["last-trial"\]' "$helper"
grep -q 'boot_id=%s' "$helper"
# the record is removed as a trial begins (only bail() writes it), so a later
# trial this boot that dies without one is never read as the earlier refusal
grep -q '^    os.remove(RECORD)$' "$helper"
after 'os.remove(RECORD)' 'herd stop reader-session' "$helper"
echo "PASS: every refusal after the radio-off undoes the teardown in reverse before it is said"
# The deployer tells a refusal from a dead link by the trial ssh's exit status:
# 255/124 is the link dying with the old kernel (success); any other non-zero
# is the helper refusing, reported without the five-minute wait and without
# the watchdog-recovery wording.  A refusal said after the link dropped is
# caught from the record before health, by the target generation's helper.
grep -q '|| trial_rc=\$?' "$deploy"
grep -q '^    0|255|124) ;;$' "$deploy"
grep -q 'NOT PROMOTED: the trial helper refused (exit \$trial_rc)' "$deploy"
grep -q 'NOT PROMOTED: the trial helper refused after the ssh link had dropped' "$deploy"
grep -q 'cat /boot/gen-$gen/system)/profile/bin/wilkbook-generation last-trial' "$deploy"
after 'NOT PROMOTED: the trial helper refused (exit' 'waiting for the new generation to answer ssh' "$deploy"
after 'wilkbook-generation last-trial' 'wilkbook-generation health --expect' "$deploy"
sed -n '/^  case \$trial_rc in/,/^  esac/p' "$deploy" | grep -q 'watcher_reap'
! sed -n '/^  case \$trial_rc in/,/^  esac/p' "$deploy" | grep -q 'watchdog'
echo "PASS: the deployer says refused, not never-answered, when the helper bails out"
