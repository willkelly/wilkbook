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
[ "$(grep -c '^vm_trial "wilkbook-generation trial' "$harness")" -eq 2 ]
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
[ "$(grep -c 'sed "s/^/        trial> /"' "$harness")" -eq 2 ]
echo "PASS: the rig refuses a generation whose helper is not the tree's and keeps each trial's output"
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
after 'recover_after_failed_trial() {' 'wait "$watcher" && wait_for_ssh' "$deploy"
sed -n '/^recover_after_failed_trial() {/,/^}/p' "$deploy" | grep -q '^  exit 1$'
! grep -q 'never answered; a power-cycle boots' "$deploy"
echo "PASS: a trial that never answers is recovered over the UART when one is configured, and never promoted"
# The watcher runs in its own process group and is reaped as a group, on both
# paths, and never through a bare kill that set -e can turn into an abort
# (review 2026-09-04: a watcher that had done its job and exited made the
# deployer die between a passed ssh wait and promote).
grep -q 'setsid sh "$repo/pinenote/scripts/uart/uboot-pick-slot.sh"' "$deploy"
[ "$(grep -c 'kill -- -"$watcher" 2>/dev/null || true' "$deploy")" -eq 2 ]
! grep -q 'kill "$watcher"' "$deploy"
echo "PASS: the UART watcher is reaped as a process group, and a dead watcher cannot abort a successful deploy"
