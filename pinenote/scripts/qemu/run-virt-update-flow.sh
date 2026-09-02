#!/bin/sh
# The update path, end to end, inside QEMU virt (doc/update-path.md, rung 4).
#
#   boot generation A (the rootfs image) with a data partition carrying the
#   harness's ssh key, a fixed host key and the workstation's guix signing key
#   -> guix copy generation B into the guest over a forwarded ssh port
#   -> wilkbook-generation add B      (menu rendered, DEFAULT still A)
#   -> wilkbook-generation trial N    (kexec inside the guest; the ssh link dies)
#   -> the guest answers again as B   (hostname, /run/current-system)
#   -> health --expect B; promote N   (DEFAULT now B)
#   -> trial A; health --expect A; promote A   (rollback is the same move)
#
# Proves the mechanism -- transfer, registration, menu, kexec, health,
# promote, rollback -- with no glass.  What it cannot prove is the SoC:
# kexec on RK3566 with the BSP firmware, the EBC and TPS65185 through a warm
# restart, brcmfmac over SDIO.  Those are UART-attended.
#
# usage: run-virt-update-flow.sh BOOT_BUNDLE_DIR DISK_IMAGE HOME_DIR SYSTEM_A SYSTEM_B [LOG]
#   HOME_DIR holds .ssh/{id_ed25519,config,known_hosts} prepared by the caller
#   (make qemu-update-check does all of it).  SYSTEM_A/B are the two system
#   store paths; B must already be built on this host.
set -eu
: "${VIRT_UPDATE_PORT:=2277}"
: "${VIRT_UPDATE_TIMEOUT:=1500}"
bundle=${1:?}; disk=${2:?}; home=${3:?}; sys_a=${4:?}; sys_b=${5:?}; log=${6:-}
config=$bundle/extlinux/extlinux.conf
kernel=$bundle/extlinux/Image
initrd=$bundle/extlinux/initrd.cpio.gz
[ -f "$config" ] && [ -f "$kernel" ] && [ -f "$initrd" ] || { echo "FAIL: not a staged boot bundle: $bundle" >&2; exit 2; }
[ -d "$home/.ssh" ] || { echo "FAIL: $home/.ssh missing" >&2; exit 2; }
[ -d "$sys_b" ] || { echo "FAIL: generation B is not in the local store: $sys_b" >&2; exit 2; }
if [ -z "$log" ]; then log=/tmp/wilkbook/pinenote-virt-update-$$.log; fi
: > "$log"
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

append=$(sed -n 's/^[[:space:]]*APPEND[[:space:]][[:space:]]*//p' "$config" | sed -n '1p')
append=$(printf '%s' "$append" | sed -e 's/console=ttyS2,1500000n8/console=ttyAMA0/' -e 's/console=tty0 //')
case " $append " in *" gnu.system=$sys_a "*) ;; *) echo "FAIL: the bundle's APPEND does not name SYSTEM_A ($sys_a)" >&2; exit 2;; esac

printf 'qemu update flow: booting generation A (console -> %s, ssh -> 127.0.0.1:%s)\n' "$log" "$VIRT_UPDATE_PORT"
qemu-system-aarch64 \
  -M virt -cpu max -smp 4 -m 2048 -display none -no-reboot \
  -chardev "socket,id=con0,path=$log.sock,server=on,wait=off,logfile=$log" -serial chardev:con0 -monitor none \
  -kernel "$kernel" -initrd "$initrd" -append "$append" \
  -drive if=virtio,format=raw,file="$disk" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${VIRT_UPDATE_PORT}-:22" -device virtio-net-pci,netdev=n0 \
  2> "$log.qemu-stderr" &
qemu_pid=$!
start=$(date +%s)
finish() { kill "$qemu_pid" 2>/dev/null || true; sleep 1; kill -9 "$qemu_pid" 2>/dev/null || true; }
trap finish EXIT

# ssh/guix through the harness HOME only: keys, config and the pinned host key live there.
vm() { HOME=$home ssh -F "$home/.ssh/config" vm "$@"; }
wait_ssh() {
  label=$1
  while :; do
    if [ $(( $(date +%s) - start )) -gt "$VIRT_UPDATE_TIMEOUT" ]; then fail "$label: timed out waiting for ssh"; return 1; fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then fail "$label: qemu exited"; return 1; fi
    if vm true 2>/dev/null; then return 0; fi
    sleep 5
  done
}

# 1. generation A answers
wait_ssh "generation A" || { finish; exit 1; }
cur=$(vm readlink -f /run/current-system)
[ "$cur" = "$sys_a" ] && pass "generation A booted: /run/current-system = $sys_a" || fail "A: running $cur"
vm 'herd status guix-daemon | grep -q running' && pass "guix-daemon is running in the guest" || fail "guix-daemon not running"
vm 'grep -q harness /etc/guix/acl' && pass "the harness signing key is authorized in the guest ACL" || fail "signing key not in /etc/guix/acl"
gens=$(vm wilkbook-generation list)
printf '%s\n' "$gens" | grep -q "gen-1 .*\[booted\]" && pass "ledger: gen-1 is the booted generation" || fail "ledger before add: $gens"

# 2. copy B in
if HOME=$home guix copy --to="root@127.0.0.1:${VIRT_UPDATE_PORT}" "$sys_b" >/dev/null 2>"$log.copy-stderr"; then
  pass "guix copy of generation B into the guest"
else
  fail "guix copy failed: $(tail -n 2 "$log.copy-stderr" | tr '\n' ' ')"
  finish; printf 'qemu update flow: FAILED (%d)\n' "$fails"; exit 1
fi
vm test -f "$sys_b/parameters" && pass "B's system is in the guest store" || fail "B missing in guest"

# 3. add: menu rendered, DEFAULT unchanged
n=$(vm wilkbook-generation add "$sys_b" | sed -n 's/^generation //p')
[ -n "$n" ] && pass "add registered generation $n" || { fail "add produced no generation number"; finish; exit 1; }
dflt=$(vm 'sed -n "s/^DEFAULT gen-//p" /boot/extlinux/extlinux.conf')
[ "$dflt" = "1" ] && pass "extlinux DEFAULT is still gen-1 after add (trial-then-promote)" || fail "DEFAULT after add: $dflt"
vm "test -f /boot/gen-$n/Image && test -f /boot/gen-$n/initrd.cpio.gz && test -f /boot/gen-1/Image" \
  && pass "payloads staged for gen-1 (pre-helper generation) and gen-$n" || fail "payload staging"

# 4. trial: kexec into B
vm "wilkbook-generation trial $n" >/dev/null 2>&1 || true
sleep 20
wait_ssh "generation B after kexec" || { finish; exit 1; }
cur=$(vm readlink -f /run/current-system)
[ "$cur" = "$sys_b" ] && pass "after kexec: /run/current-system = B" || fail "after kexec running $cur"
hn=$(vm hostname)
[ "$hn" = "pinenote-reader-direct-genb" ] && pass "after kexec: hostname is generation B's" || fail "hostname $hn"
if vm "wilkbook-generation health --expect $sys_b" >/dev/null; then pass "health check passes on B"; else fail "health on B"; fi
dflt=$(vm 'sed -n "s/^DEFAULT gen-//p" /boot/extlinux/extlinux.conf')
[ "$dflt" = "1" ] && pass "DEFAULT still gen-1 while B is only on trial" || fail "DEFAULT during trial: $dflt"

# 5. promote
vm "wilkbook-generation promote $n" >/dev/null && pass "promote $n"
dflt=$(vm 'sed -n "s/^DEFAULT gen-//p" /boot/extlinux/extlinux.conf')
[ "$dflt" = "$n" ] && pass "DEFAULT is gen-$n after promote" || fail "DEFAULT after promote: $dflt"
vm "test \$(readlink /var/guix/profiles/system) = system-$n-link" && pass "Guix's current profile points at generation $n" || fail "profile link"

# 6. rollback: trial A, health, promote A
vm "wilkbook-generation trial 1" >/dev/null 2>&1 || true
sleep 20
wait_ssh "generation A after rollback kexec" || { finish; exit 1; }
cur=$(vm readlink -f /run/current-system)
[ "$cur" = "$sys_a" ] && pass "rollback: kexec back into A" || fail "rollback running $cur"
vm "wilkbook-generation health --expect $sys_a" >/dev/null && pass "health check passes on A again" || fail "health on A"
vm "wilkbook-generation promote 1" >/dev/null && pass "promote 1 (rollback complete)"
dflt=$(vm 'sed -n "s/^DEFAULT gen-//p" /boot/extlinux/extlinux.conf')
[ "$dflt" = "1" ] && pass "DEFAULT is gen-1 after rollback" || fail "DEFAULT after rollback: $dflt"

# 7. evidence: three kernel boots in one console log
boots=$(grep -a -c "Linux version" "$log" || true)
[ "$boots" -ge 3 ] && pass "console log shows $boots kernel boots (A, B, A)" || fail "expected 3 kernel boots in the console log, saw $boots"
finish
if [ "$fails" -eq 0 ]; then printf 'qemu update flow: OK (log: %s)\n' "$log"; exit 0; fi
printf 'qemu update flow: FAILED (%d) -- see %s\n' "$fails" "$log"; exit 1
