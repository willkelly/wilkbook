#!/bin/sh
# Drive the PineNote's U-Boot boot menu over the UART (doc/device-access.md).
#
#   uboot-pick-slot.sh LOG [--slot os2|os1] [--reboot SSH_DEST] [--tty DEV]
#
# Watches the serial line for the menu and selects the slot: the menu's
# first entry ("Search for extlinux.conf on all partitions") is the
# default and lands on os1; "Boot OS2 (part 6)" is two DOWNs away.  With
# --reboot the script first issues ONE `sudo reboot` over ssh to the given
# destination (an os1 alias or user@host), ignores its exit status and
# makes no further connection until U-Boot has drawn the menu -- a
# reconnect mid-halt is what wedges a shutdown (device-access.md, UART
# trap 3).  Without --reboot it waits for a menu you produce by hand (a
# power-cycle after a hang).  Everything the port says goes to LOG; the
# capture keeps running after the pick so the whole boot is recorded --
# reap the process group recorded in LOG.watcher when done.  Only NEW
# bytes are searched, so a LOG that already holds an earlier menu is fine.
#
# LOG.watcher (written before the port is opened, appended at exit) is the
# handle for whoever started this script:
#   pid=      this script
#   pgid=     its process group -- `kill -- -PGID` reaps script and reader
#             together; equals pid when started under setsid or from a
#             shell with job control
#   reader=   the `cat` of the tty (outlives the pick by design)
#   termios=  what the port was actually set to, as evidence
#   exit=     the script's exit status, once it has one
# From a shell WITH job control a backgrounded `setsid sh ...` forks, so
# the caller's $! is a wrapper that has already exited and names nothing
# to reap; from make (no job control) setsid execs in place and $! is this
# script (doc/status.md 2026-09-04).  The file says the same thing in
# both cases.
#
# The menu is drawn without a contiguous "Hit any key" string, so the
# trigger is the menu text itself (doc/status.md 2026-08-26).  Any ONE of
# the menu's three entry lines is enough: the capture loses ~20-30 bytes
# every 150-250 bytes at 1.5 Mbaud (the CH340 side, not termios -- see
# device-access.md), so a single 16-byte string can be the one clipped in
# a given redraw (2026-09-04's capture: each of the three redraws had a
# different entry clipped and never all three).  Only the ENTRY lines are
# matched: the title "U-Boot Boot Menu" and "Press UP/DOWN to move, ENTER
# to select" are drawn by the same bootmenu code for extlinux's generation
# menu right after the pick, where two DOWNs would choose an old
# generation; and this U-Boot prints "Hit key to stop autoboot('CTRL+C')"
# BEFORE the menu, where a keystroke would stop autoboot into the
# console.  Pinned by test-uboot-pick-slot.sh.
#
# WILKBOOK_UBOOT_MENU_TIMEOUT: seconds to wait for the menu (default 900;
# the offline test shortens it).
set -u
log=${1:?usage: uboot-pick-slot.sh LOG [--slot os2|os1] [--reboot SSH_DEST] [--tty DEV]}; shift
slot=os2; reboot_dest=; tty=/dev/ttyUSB0
while [ $# -gt 0 ]; do
  case $1 in
    --slot) slot=$2; shift 2 ;;
    --reboot) reboot_dest=$2; shift 2 ;;
    --tty) tty=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case $slot in
  os2) keys='\033[B\033[B\r' ;;
  os1) keys='\033[B\r' ;;
  *) echo "slot must be os2 or os1" >&2; exit 2 ;;
esac
menu='Search for extlinux.conf on all partitions\|Boot OS1 (part 5)\|Boot OS2 (part 6)'
timeout=${WILKBOOK_UBOOT_MENU_TIMEOUT:-900}
polls=$((timeout * 2))

# /proc/self/stat field 5 is the pgrp; skip past the "(comm)" so a comm
# with spaces cannot shift the fields.
pgid=$(sed 's/^.*) //' "/proc/$$/stat" | cut -d' ' -f3)
handle="$log.watcher"
reader=
finish() {
  status=$?
  echo "exit=$status" >> "$handle"
  exit "$status"
}
trap finish EXIT
{ echo "pid=$$"; echo "pgid=$pgid"; } > "$handle"

# 1.5 Mbaud, 8N1, no flow control (neither RTS/CTS nor XON/XOFF: the
# console's bytes must never be eaten as ^S/^Q), no CR/NL translation, no
# echo, no signals from the line, 1-byte reads -- the settings
# device-access.md documents.  `raw` covers -icrnl -inlcr -igncr -ixon
# -ixoff -icanon -isig -opost -istrip; -echo is separate from raw.
stty -F "$tty" 1500000 cs8 -cstopb -parenb -crtscts -ixon -ixoff clocal raw -echo || exit 2
echo "termios=$(stty -F "$tty" -a 2>/dev/null | tr '\n' ' ')" >> "$handle"
touch "$log"
start=$(wc -c < "$log")
cat "$tty" >> "$log" 2>/dev/null &
reader=$!
echo "reader=$reader" >> "$handle"
sleep 0.5
if [ -n "$reboot_dest" ]; then
  echo "== one reboot attempt via $reboot_dest (exit status ignored; no reconnect until U-Boot)"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$reboot_dest" 'sudo -n reboot 2>/dev/null || reboot' >/dev/null 2>&1 || true
fi
echo "== watching $tty beyond byte $start of $log for the U-Boot menu (pid $$, pgid $pgid, reader pid $reader; $handle)"
i=0
while [ $i -lt "$polls" ]; do
  if tail -c +$((start + 1)) "$log" | grep -a -q "$menu"; then
    printf "$keys" > "$tty"
    echo "== menu seen at poll $i: selected $slot"
    sleep 5
    tail -c +$((start + 1)) "$log" | tr -d '\r' \
      | grep -a -o 'Boot OS[12] (part [56])\|Retrieving file[^\n]*\|Starting kernel[^\n]*\|Linux version [^\n]*' | tail -5
    echo "== capture continues in $log (kill -- -$pgid to stop it, or kill $reader)"
    exit 0
  fi
  sleep 0.5; i=$((i + 1))
done
echo "!! no U-Boot menu in $timeout s; an unattended countdown lands on os1" >&2
kill "$reader" 2>/dev/null; exit 1
