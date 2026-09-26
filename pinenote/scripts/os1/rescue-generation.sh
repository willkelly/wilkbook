#!/bin/sh
# Change which generation the reader boots, FROM os1 -- no cable, no UART.
#
#   rescue-generation.sh list           # the ledger, and the DEFAULT extlinux boots
#   rescue-generation.sh promote N      # DEFAULT = generation N (the next os2 boot)
#   rescue-generation.sh demote         # DEFAULT = the generation before it
#   rescue-generation.sh log [LINES]    # tail of os2's /var/log/messages
#
# Runs ON os1 (stock Debian) as user, with its passwordless sudo.  Nothing
# is copied to os1; from the host:
#   ssh <os1> sh -s -- list < pinenote/scripts/os1/rescue-generation.sh
#
# What it is for: os2's DEFAULT names a generation that should not boot, and
# os2 cannot fix it -- a candidate the deployer promoted on health before the
# operator's checks failed, or a kexec-only generation whose device tree
# fails its first cold boot.  (A trial that fails before promotion leaves
# DEFAULT on the previous generation; picking os2 at the menu is enough.)
# From os1 the ledger on p6 is one chroot away (doc/device-access.md,
# "Chroot testing"), and the generation helper that ships in os2's promoted
# system runs as shipped.  Then reboot and pick "Boot OS2 (part 6)" at the
# U-Boot menu; extlinux boots the new DEFAULT with no further key.
#
# Refuses unless / is os1 (p5) and p6 is not mounted.  An interrupted run
# unmounts on its way out; one killed outright leaves p6 mounted, and the
# next run refuses and says how to unmount it.  promote and demote write
# three things in turn (gen-default, the profile link, extlinux.conf), so a
# write cut short can leave them disagreeing: list then reports a MISMATCH,
# and running the same promote again puts them back in step.
# doc/hardware-deploy.md, "Recovery from os1, no cable".  make os1-rescue-check.
set -eu
usage() { echo "usage: rescue-generation.sh list | promote N | demote | log [LINES]" >&2; exit 2; }
what=${1:-list}
if [ $# -gt 0 ]; then shift; fi    # dash's shift with no arguments exits the shell
case $what in
  list|demote) ;;
  promote) case ${1:-} in ''|*[!0-9]*) usage ;; esac ;;
  log) case ${1:-60} in ''|*[!0-9]*) usage ;; esac ;;
  *) usage ;;
esac
[ "$(findmnt -n -o SOURCE /)" = /dev/mmcblk0p5 ] || { echo "REFUSE: / is not /dev/mmcblk0p5 (os1)" >&2; exit 1; }
mnt=/mnt/os2
if findmnt -n -S /dev/mmcblk0p6 >/dev/null 2>&1; then
  echo "REFUSE: /dev/mmcblk0p6 is already mounted (a run killed outright?) at:" >&2
  findmnt -n -S /dev/mmcblk0p6 -o TARGET >&2 || true
  echo "Unmount each with: sudo umount -R <target>" >&2
  exit 1
fi
sudo -n mkdir -p "$mnt"
# Plain ro, never noload: a generation that booted and then hung or was
# reset can leave committed writes -- its own promotion, the last lines of
# its log -- only in the journal, where noload would hide them.  A
# read-only ext4 mount still replays the journal, as os2's next boot would.
case $what in
  list|log) sudo -n mount -o ro /dev/mmcblk0p6 "$mnt" ;;
  *) sudo -n mount -o rw /dev/mmcblk0p6 "$mnt" ;;
esac
cleanup() { for d in proc dev; do sudo -n umount "$mnt/$d" 2>/dev/null || true; done; sync; sudo -n umount "$mnt"; }
trap cleanup EXIT
# dash runs no EXIT trap for a signal it has not trapped: a dropped ssh
# session (HUP, or PIPE at the next write), ^C or a kill would leave p6
# mounted, read-write for promote and demote.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 141' PIPE
trap 'exit 143' TERM
if [ "$what" = log ]; then sudo -n tail -n "${1:-60}" "$mnt/var/log/messages"; exit 0; fi
# The profile links end in absolute /gnu/store paths, which resolve only
# under p6's root, so the helper can only be looked for inside the chroot.
helper=/var/guix/profiles/system/profile/bin/wilkbook-generation
sudo -n /usr/sbin/chroot "$mnt" /bin/sh -c 'test -x "$1"' sh "$helper" ||
  { echo "REFUSE: no generation helper on os2 ($helper) -- pre-update-path image?" >&2; exit 1; }
# /proc gives the helper os1's /proc/cmdline, which names no Guix system, so
# no generation is marked [booted].  /dev gives it the /dev/null its
# shell-outs redirect to: without it they fail and the ledger reads empty.
# No /sys: list, promote and demote never read it, and nothing run here
# should reach os1's USB gadget, which the helper's trial drives.
for d in proc dev; do sudo -n mount --bind "/$d" "$mnt/$d"; done
# The helper shells out to ls, readlink, ln, mkdir, cp and mv, which inside
# the Guix root exist only in a system profile; sudo's Debian PATH names
# none of them.  So it runs with the promoted system's profile as PATH, and
# env and chroot are named by path, since that PATH means nothing on os1.
# It is DEFAULT's own helper -- the generation being rescued from -- but the
# deployer has already run its promote on os2.  Its list is not read-only
# either: it stages /boot/gen-N for a generation that has none, which fails
# under list's read-only mount (only an image the helper never ran on has
# such a generation).  stdin is /dev/null so that, run as `sh -s`, nothing
# it starts can read the rest of this script.
prof=/var/guix/profiles/system/profile
helper_run() { sudo -n /usr/bin/env PATH="$prof/bin:$prof/sbin" /usr/sbin/chroot "$mnt" "$helper" "$@" </dev/null; }
# Print the ledger and the DEFAULT extlinux will boot; fail if they differ.
show() {
  printf '%s\n' "$1"
  promoted=$(printf '%s\n' "$1" | sed -n 's/^\(gen-[0-9]*\) .*\[promoted\].*/\1/p')
  booting=$(sudo -n sed -n 's/^DEFAULT //p' "$mnt/boot/extlinux/extlinux.conf")
  echo "extlinux DEFAULT: ${booting:-none}"
  [ "$promoted" = "$booting" ] || {
    echo "MISMATCH: the ledger promotes ${promoted:-nothing} but extlinux boots ${booting:-nothing}; run promote again to put them in step" >&2
    return 1
  }
}
ledger=$(helper_run list)
[ -n "$ledger" ] || { echo "ERROR: the helper listed no generations: the chroot is broken (PATH, /dev), not the ledger" >&2; exit 1; }
if [ "$what" = list ]; then show "$ledger"; exit 0; fi
helper_run "$what" "$@"
ledger=$(helper_run list)
show "$ledger"
case $(printf '%s\n' "$ledger" | grep '\[promoted\]' || true) in
  *'[pinned]'*) ;;
  *) echo "NOTE: the new DEFAULT is not [pinned], so it may never have cold-booted, and this boot may be the first of its device tree. A [pinned] generation is the proven fallback." ;;
esac
echo "DEFAULT changed on os2. Reboot and choose \"Boot OS2 (part 6)\" at the U-Boot menu."
