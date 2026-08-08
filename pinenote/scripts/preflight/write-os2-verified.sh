#!/bin/sh
# Write a staged rootfs to os2 (p6) and verify the readback, on-device.
#
# Runs FROM os1, which is the only slot that can write p6 safely. Every
# number it needs is DERIVED, never typed: the 2026-08-07 session compared
# a short readback against a whole-file hash because the block count was
# hand-computed one block low, and briefly concluded a good write had
# failed.
#
# Refuses rather than guesses:
#   * os1 must be the running root (never write the slot you booted)
#   * p6 must be unmounted
#   * p6 must be large enough
#   * the staged file's hash must match what the caller expects
#
# usage: write-os2-verified.sh STAGED_FILE EXPECTED_SHA256
set -eu

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { printf 'OK:   %s\n' "$1"; }

[ "$#" -eq 2 ] || { printf 'usage: %s STAGED_FILE EXPECTED_SHA256\n' "$0" >&2; exit 2; }
staged=$1
want=$2
target=/dev/mmcblk0p6

[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ -f "$staged" ] || fail "staged file is not a regular file: $staged"
[ -b "$target" ] || fail "$target is not a block device"

# 1. Never write the slot we booted.
root_src=$(findmnt -no SOURCE / 2>/dev/null || echo "?")
case $root_src in
  /dev/mmcblk0p5) ok "running from os1 ($root_src)" ;;
  /dev/mmcblk0p6) fail "running from os2 -- refusing to overwrite the running root" ;;
  *) fail "unrecognised root device $root_src; refusing" ;;
esac

# 2. p6 must not be mounted.
if mount | grep -q "^$target "; then
  fail "$target is mounted -- unmount before writing"
fi
ok "$target is unmounted"

# 3. Sizes, derived.
bytes=$(stat -c %s "$staged")
partbytes=$(blockdev --getsize64 "$target")
[ "$bytes" -le "$partbytes" ] || \
  fail "staged file ($bytes) is larger than $target ($partbytes)"
bs=4096
[ $((bytes % bs)) -eq 0 ] || fail "staged size $bytes is not a multiple of $bs"
count=$((bytes / bs))
ok "size $bytes bytes = $count blocks of $bs (partition holds $partbytes)"

# 4. The staged copy must be what the caller thinks it is, BEFORE we write.
got=$(sha256sum "$staged" | cut -d' ' -f1)
[ "$got" = "$want" ] || fail "staged hash mismatch
  want $want
  got  $got"
ok "staged hash matches"

# 5. Write.
printf 'writing %s -> %s ...\n' "$staged" "$target"
dd if="$staged" of="$target" bs=4M conv=fsync status=none
sync
ok "write complete"

# 6. Read back EXACTLY the bytes written -- the count is derived above, so a
#    short read cannot be mistaken for a bad write.
back=$(dd if="$target" bs=$bs count=$count status=none | sha256sum | cut -d' ' -f1)
[ "$back" = "$want" ] || fail "READBACK MISMATCH -- do not boot os2
  want $want
  got  $back"
ok "readback of $count blocks matches: $back"
printf '\nos2 now carries %s\n' "$want"
