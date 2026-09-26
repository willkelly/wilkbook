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
sudo -n mkdir -p "$mnt"
# Read-only skips journal replay where ext4 allows it; ext4 refuses noload
# on a read-write mount, so the writers mount plainly.
if [ "$opt" = ro ]; then
  sudo -n mount -o ro,noload /dev/mmcblk0p6 "$mnt" 2>/dev/null || sudo -n mount -o ro /dev/mmcblk0p6 "$mnt"
else
  sudo -n mount -o rw /dev/mmcblk0p6 "$mnt"
fi
cleanup() { for d in proc sys dev; do sudo -n umount "$mnt/$d" 2>/dev/null || true; done; sync; sudo -n umount "$mnt"; }
trap cleanup EXIT
if [ "$what" = log ]; then sudo -n tail -n "${1:-60}" "$mnt/var/log/messages"; exit 0; fi
# The profile links end in absolute /gnu/store paths, which resolve only
# under p6's root, so the helper can only be looked for inside the chroot.
helper=/var/guix/profiles/system/profile/bin/wilkbook-generation
sudo -n chroot "$mnt" /bin/sh -c "test -x $helper" ||
  { echo "REFUSE: no generation helper on os2 ($helper) -- pre-update-path image?" >&2; exit 1; }
for d in proc sys dev; do sudo -n mount --bind "/$d" "$mnt/$d"; done
# The helper reads /proc/cmdline for the [booted] mark; os1's has no gnu.system=, so none is marked.
# It shells out to ls, readlink, ln, mkdir, cp and mv, which inside the
# Guix root live only in a system profile; sudo's Debian PATH has none of
# them, and without them the ledger reads as empty.  So it runs with the
# promoted system's profile as PATH (env and chroot named by path, since
# that PATH means nothing on os1).
prof=/var/guix/profiles/system/profile
sudo -n /usr/bin/env PATH="$prof/bin:$prof/sbin" /usr/sbin/chroot "$mnt" "$helper" "$what" "$@"
if [ "$opt" = rw ]; then
  echo "DEFAULT changed on os2. Reboot and choose \"Boot OS2 (part 6)\" at the U-Boot menu (or let uboot-pick-slot.sh)."
fi
