#!/bin/sh
# The update path, end to end, inside QEMU virt (doc/update-path.md, rung 4).
#
#   boot generation A (the rootfs image) with a data partition carrying the
#   harness's ssh key, a fixed host key and the workstation's guix signing key
#   -> guix archive export | ssh | import generation B into the guest over a
#      forwarded ssh port (the guix copy nar pipe over OpenSSH, which honors
#      the harness's pinned host key; Guile-SSH ignores $HOME)
#   -> wilkbook-generation add B      (menu rendered, DEFAULT still A)
#   -> wilkbook-generation trial N    (kexec inside the guest; the ssh link dies)
#   -> the guest answers again as B   (hostname, /run/current-system)
#   -> health --expect B; promote N   (DEFAULT now B)
#   -> pin 1; prune --keep 1; unpin 1 (the pinned A survives a prune that would
#      otherwise delete it -- the ledger pin, 2026-09-04)
#   -> trial A; health --expect A; promote A   (rollback is the same move)
#   -> prune --keep 0                 (the positive control: B, unpinned, goes;
#      keep 1 would keep it as the newest -- the first run of this step said so)
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
# Per-stage budget for a guest to answer ssh (cold boot, boot after each
# kexec).  Under TCG the guest-side nar import alone can take ten minutes,
# so the budget is per stage, not per run.
: "${VIRT_UPDATE_STAGE_TIMEOUT:=900}"
bundle=${1:?}; disk=${2:?}; home=${3:?}; sys_a=${4:?}; sys_b=${5:?}; log=${6:-}
disk_rootfs_bytes_file=$disk.rootfs-bytes
config=$bundle/extlinux/extlinux.conf
kernel=$bundle/extlinux/Image
initrd=$bundle/extlinux/initrd.cpio.gz
[ -f "$config" ] && [ -f "$kernel" ] && [ -f "$initrd" ] || { echo "FAIL: not a staged boot bundle: $bundle" >&2; exit 2; }
[ -d "$home/.ssh" ] || { echo "FAIL: $home/.ssh missing" >&2; exit 2; }
[ -d "$sys_b" ] || { echo "FAIL: generation B is not in the local store: $sys_b" >&2; exit 2; }
# The helper each generation ships must be the tree's, or the run tests a
# stale build (2026-09-02: a pre-gate SYSTEM_B refused the rollback trial
# with "EBC did not go idle" on a machine that has no EBC).
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_helper=$here/../../packages/update-path/wilkbook-generation.lua
for sys in "$sys_a" "$sys_b"; do
  shipped=$(find -L "$sys/profile/share" -name wilkbook-generation.lua 2>/dev/null | head -n 1)
  [ -n "$shipped" ] && cmp -s "$tree_helper" "$shipped" || { echo "FAIL: $sys ships a helper that is not the tree's (stale SYSTEM_B or ROOTFS? rebuild it)" >&2; exit 2; }
done
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
# The trial's ssh session dies WITH the old kernel: kexec never closes the
# TCP connection, so a client without keepalives waits forever (the
# 2026-09-02 hang, twice).  Keepalives make the replacement kernel answer
# the next probe with a reset within seconds; the timeout is the backstop.
vm_trial() { HOME=$home timeout 120 ssh -F "$home/.ssh/config" -o ServerAliveInterval=5 -o ServerAliveCountMax=2 vm "$@"; }
wait_ssh() {
  label=$1
  stage_start=$(date +%s)
  while :; do
    if [ $(( $(date +%s) - stage_start )) -gt "$VIRT_UPDATE_STAGE_TIMEOUT" ]; then fail "$label: timed out waiting for ssh (${VIRT_UPDATE_STAGE_TIMEOUT}s)"; return 1; fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then fail "$label: qemu exited"; return 1; fi
    if vm true 2>/dev/null; then return 0; fi
    sleep 5
  done
}

# 1. generation A answers
wait_ssh "generation A" || { finish; exit 1; }
cur=$(vm readlink -f /run/current-system)
[ "$cur" = "$sys_a" ] && pass "generation A booted: /run/current-system = $sys_a" || fail "A: running $cur"
boot_a1=$(vm cat /proc/sys/kernel/random/boot_id)
vm 'herd status guix-daemon | grep -q running' && pass "guix-daemon is running in the guest" || fail "guix-daemon not running"
image_bytes=$(cat "$disk_rootfs_bytes_file" 2>/dev/null || echo 0)
fs_bytes=$(vm 'df -B1 --output=size / | tail -n 1' | tr -d ' ')
if [ "${VIRT_ROOT_SLACK_MIB:-0}" -gt 0 ]; then
  [ "$fs_bytes" -gt "$image_bytes" ] && pass "pinenote-grow-root grew the root fs to its partition ($fs_bytes > image $image_bytes bytes)" \
    || fail "grow-root: fs is $fs_bytes bytes, image is $image_bytes (slack ${VIRT_ROOT_SLACK_MIB} MiB)"
fi
# The ACL holds the key's canonical sexp, not the file name: match on the
# public point (q #...#) from the signing key the fixture carried.
q=$(sed -n 's/.*(q #\([0-9A-Fa-f]*\)#).*/\1/p' /etc/guix/signing-key.pub | head -n 1)
if [ -n "$q" ] && vm "grep -q '$q' /etc/guix/acl"; then
  pass "the harness signing key is authorized in the guest ACL"
else
  fail "signing key not in /etc/guix/acl ($(vm 'herd status pinenote-guix-acl 2>&1 | head -2 | tr "\n" " "; grep pinenote-guix-acl /var/log/messages | tail -2 | tr "\n" " "'))"
fi
gens=$(vm wilkbook-generation list)
printf '%s\n' "$gens" | grep -q "gen-1 .*\[booted\]" && pass "ledger: gen-1 is the booted generation" || fail "ledger before add: $gens"

# 2. copy B in
# Only what the guest is missing -- the guix copy algorithm: closure locally,
# `guix archive --missing` remotely, export just those (topologically
# sorted by export), signed by this host's daemon, verified by the guest's.
closure=$(guix gc --references -R "$sys_b")
total=$(printf '%s\n' "$closure" | grep -c .)
missing=$(printf '%s\n' "$closure" | vm guix archive --missing)
count=$(printf '%s\n' "$missing" | grep -c . || true)
[ "$count" -gt 0 ] && [ "$count" -lt "$total" ] \
  && pass "transfer set: $count of $total closure paths are missing in the guest (a delta, not the whole closure)" \
  || fail "transfer set: $count of $total missing (expected a proper delta)"
if (printf '%s\n' "$missing" | xargs guix archive --export | HOME=$home ssh -F "$home/.ssh/config" vm guix archive --import) >/dev/null 2>"$log.copy-stderr"; then
  pass "guix archive export/import of the missing paths into the guest"
else
  fail "guix archive export/import failed: $(tail -n 2 "$log.copy-stderr" | tr '\n' ' ')"
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
vm_trial "wilkbook-generation trial $n" >"$log.trial-$n" 2>&1 || true
sed "s/^/        trial> /" "$log.trial-$n"
sleep 20
wait_ssh "generation B after kexec" || { finish; exit 1; }
cur=$(vm readlink -f /run/current-system)
[ "$cur" = "$sys_b" ] && pass "after kexec: /run/current-system = B" || fail "after kexec running $cur"
boot_b=$(vm cat /proc/sys/kernel/random/boot_id)
[ -n "$boot_b" ] && [ "$boot_b" != "$boot_a1" ] && pass "after kexec: a new boot id (the kernel really was replaced)" || fail "boot id unchanged after the trial: the kexec did not happen"
hn=$(vm hostname)
[ "$hn" = "pinenote-reader-genb" ] && pass "after kexec: hostname is generation B's" || fail "hostname $hn"
if vm "wilkbook-generation health --expect $sys_b" >/dev/null; then pass "health check passes on B"; else fail "health on B"; fi
dflt=$(vm 'sed -n "s/^DEFAULT gen-//p" /boot/extlinux/extlinux.conf')
[ "$dflt" = "1" ] && pass "DEFAULT still gen-1 while B is only on trial" || fail "DEFAULT during trial: $dflt"

# 5. promote
vm "wilkbook-generation promote $n" >/dev/null && pass "promote $n"
dflt=$(vm 'sed -n "s/^DEFAULT gen-//p" /boot/extlinux/extlinux.conf')
[ "$dflt" = "$n" ] && pass "DEFAULT is gen-$n after promote" || fail "DEFAULT after promote: $dflt"
vm "test \$(readlink /var/guix/profiles/system) = system-$n-link" && pass "Guix's current profile points at generation $n" || fail "profile link"

# 5b. the ledger pin (2026-09-04): with DEFAULT and the booted generation both
# B, `prune --keep 1` would delete A -- the generation the rollback below needs
# and, on a device, the one a cold boot proved.  Pinned, it stays; unpinned,
# the plan is back to what it was (the positive control is step 6b).
vm "wilkbook-generation pin 1" >/dev/null && pass "pin 1" || fail "pin 1"
vm wilkbook-generation list | grep -q '^gen-1  .*\[pinned\]' && pass "list shows gen-1 [pinned]" || fail "list has no [pinned] marker on gen-1"
out=$(vm "wilkbook-generation prune --keep 1" 2>&1 || true)
printf '%s\n' "$out" | sed "s/^/        prune> /"
printf '%s\n' "$out" | grep -q 'nothing to prune' && pass "prune --keep 1 with gen-1 pinned: nothing to prune" || fail "prune with a pin: $out"
vm "test -f /boot/gen-1/Image && test -f /boot/gen-1/pinned && test -L /var/guix/profiles/system-1-link" \
  && pass "gen-1's payload, marker and profile link survive the prune" || fail "gen-1 was pruned despite the pin"
vm "wilkbook-generation unpin 1" >/dev/null && pass "unpin 1" || fail "unpin 1"
if vm wilkbook-generation list | grep -q '\[pinned\]'; then fail "a [pinned] marker remains after unpin"; else pass "no [pinned] marker after unpin"; fi

# 6. rollback: trial A, health, promote A
vm_trial "wilkbook-generation trial 1" >"$log.trial-1" 2>&1 || true
sed "s/^/        trial> /" "$log.trial-1"
sleep 20
wait_ssh "generation A after rollback kexec" || { finish; exit 1; }
cur=$(vm readlink -f /run/current-system)
[ "$cur" = "$sys_a" ] && pass "rollback: kexec back into A" || fail "rollback running $cur"
boot_a2=$(vm cat /proc/sys/kernel/random/boot_id)
[ -n "$boot_a2" ] && [ "$boot_a2" != "$boot_b" ] && [ "$boot_a2" != "$boot_a1" ] && pass "rollback: a third boot id" || fail "boot id after rollback: $boot_a2"
vm "wilkbook-generation health --expect $sys_a" >/dev/null && pass "health check passes on A again" || fail "health on A"
vm "wilkbook-generation promote 1" >/dev/null && pass "promote 1 (rollback complete)"
dflt=$(vm 'sed -n "s/^DEFAULT gen-//p" /boot/extlinux/extlinux.conf')
[ "$dflt" = "1" ] && pass "DEFAULT is gen-1 after rollback" || fail "DEFAULT after rollback: $dflt"

# 6b. the positive control for 5b: nothing pinned, DEFAULT and booted back on
# A, so `prune --keep 0` deletes B (and runs guix gc in the guest).  Not
# `--keep 1`: B is the newest and the window keeps it -- the planner answered
# "nothing to prune" to that, correctly, on this step's first run (2026-09-04).
out=$(vm "wilkbook-generation prune --keep 0" 2>&1 || true)
printf '%s\n' "$out" | sed "s/^/        prune> /"
printf '%s\n' "$out" | grep -q "pruned generation $n" && pass "prune --keep 0 with nothing pinned: generation $n pruned" || fail "positive control: $out"
vm "test ! -e /boot/gen-$n && test ! -e /var/guix/profiles/system-$n-link && test -f /boot/gen-1/Image" \
  && pass "gen-$n's payload and profile link are gone, gen-1's stay" || fail "prune left gen-$n or took gen-1"
dflt=$(vm 'sed -n "s/^DEFAULT gen-//p" /boot/extlinux/extlinux.conf')
[ "$dflt" = "1" ] && pass "DEFAULT is still gen-1 after the prune" || fail "DEFAULT after prune: $dflt"

# 7. evidence.  Boot ids are the proof (above); the console is informational:
# a generation's APPEND carries the PineNote's console=ttyS2, so after a
# kexec the guest boots silently on the PL011 while answering ssh.
boots=$(grep -a -c "Linux version" "$log" || true)
printf '  note  console log shows %s kernel boot line(s); boot ids: %s -> %s -> %s\n' "$boots" "$boot_a1" "$boot_b" "$boot_a2"
finish
if [ "$fails" -eq 0 ]; then printf 'qemu update flow: OK (log: %s)\n' "$log"; exit 0; fi
printf 'qemu update flow: FAILED (%d) -- see %s\n' "$fails" "$log"; exit 1
