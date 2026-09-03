#!/bin/sh
# Change the reader's boot generation FROM os1 -- no cable, no UART.
#
#   rescue-generation.sh list
#   rescue-generation.sh promote N      # DEFAULT = generation N (the next os2 boot)
#   rescue-generation.sh demote         # DEFAULT = the previous generation
#   rescue-generation.sh log [LINES]    # tail of os2's /var/log/messages
#
# Run ON os1 (stock Debian) as user, with sudo.  The failsafe path after a
# trial that never booted: the watchdog (or the power button) resets into
# U-Boot, whose default lands here on os1; from here the generation ledger
# on p6 is one chroot away (doc/device-access.md "Chroot testing" -- the
# Guix root carries its own store, so the helper runs as shipped).  Then
# reboot and pick "Boot OS2 (part 6)" at the U-Boot menu -- extlinux boots
# the promoted generation with no further key.  Refuses unless / is os1.
set -eu
what=${1:-list}; shift || true
[ "$(findmnt -n -o SOURCE /)" = /dev/mmcblk0p5 ] || { echo "REFUSE: / is not /dev/mmcblk0p5 (os1)" >&2; exit 1; }
mnt=/mnt/os2
case $what in
  list|log) opt=ro ;;
  promote|demote) opt=rw ;;
  *) echo "usage: rescue-generation.sh list | promote N | demote | log [LINES]" >&2; exit 2 ;;
esac
findmnt -n -S /dev/mmcblk0p6 >/dev/null 2>&1 && { echo "REFUSE: /dev/mmcblk0p6 is already mounted" >&2; exit 1; }
sudo mkdir -p "$mnt"
sudo mount -o "$opt,noload" /dev/mmcblk0p6 "$mnt" 2>/dev/null || sudo mount -o "$opt" /dev/mmcblk0p6 "$mnt"
cleanup() { for d in proc sys dev; do sudo umount "$mnt/$d" 2>/dev/null || true; done; sync; sudo umount "$mnt"; }
trap cleanup EXIT
if [ "$what" = log ]; then sudo tail -n "${1:-60}" "$mnt/var/log/messages"; exit 0; fi
helper=$mnt/var/guix/profiles/system/profile/bin/wilkbook-generation
[ -e "$helper" ] || { echo "REFUSE: no generation helper on os2 ($helper) -- pre-update-path image?" >&2; exit 1; }
for d in proc sys dev; do sudo mount --bind "/$d" "$mnt/$d"; done
# The helper reads /proc/cmdline for the [booted] mark; os1's has no gnu.system=, so none is marked.
sudo chroot "$mnt" /var/guix/profiles/system/profile/bin/wilkbook-generation "$what" "$@"
[ "$opt" = rw ] && echo "DEFAULT changed on os2. Reboot and choose \"Boot OS2 (part 6)\" at the U-Boot menu (or let uboot-pick-slot.sh)."
