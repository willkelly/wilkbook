#!/bin/sh
# Structural pins on the imperative halves: the trial boot's ordering and
# the deployer's refusal to promote without a passing health check.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
helper="$here/../../packages/update-path/wilkbook-generation.lua"
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
# add materializes every profile generation's payload (the shipped one has no /boot/gen-N).
grep -q 'ensure_payload(g)' "$helper"
grep -q 'ledger_with_payloads()' "$helper"
echo "PASS: add stages payloads for generations that predate the helper"
# writes are confined to /boot, /var/guix/profiles and guix gc.
! grep -q '/data\|mmcblk0p7\|mmcblk0p5\|sfdisk\|parted' "$helper"
echo "PASS: helper never names p7, os1 or the partition table"
# deployer: promote only after a passing health check; failure exits 1 without promoting.
after 'wilkbook-generation health --expect' 'wilkbook-generation promote' "$deploy"
grep -q 'NOT PROMOTED: health check failed' "$deploy"
grep -q 'NOT PROMOTED: generation .* never answered' "$deploy"
grep -q -- '--target=aarch64-linux-gnu' "$deploy"
grep -q 'guix archive --missing' "$deploy"
! grep -q 'guix archive --export -r' "$deploy"
grep -q 'guix archive --import' "$deploy"
echo "PASS: deployer promotes only after health, cross-builds, sends only the missing paths, and reports refusals"
# The trial's ssh session dies with the old kernel and kexec never closes the
# TCP connection; without keepalives the client hangs forever (2026-09-02).
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
