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
# kill the reader pid it prints when done.  Only NEW bytes are searched, so
# a LOG that already holds an earlier menu is fine.
#
# The menu is drawn without a contiguous "Hit any key" string, so the
# trigger is the menu text itself (doc/status.md 2026-08-26).
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
stty -F "$tty" 1500000 cs8 -cstopb -parenb -crtscts clocal -echo raw || exit 2
touch "$log"
start=$(wc -c < "$log")
cat "$tty" >> "$log" 2>/dev/null &
reader=$!
sleep 0.5
if [ -n "$reboot_dest" ]; then
  echo "== one reboot attempt via $reboot_dest (exit status ignored; no reconnect until U-Boot)"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$reboot_dest" 'sudo -n reboot 2>/dev/null || reboot' >/dev/null 2>&1 || true
fi
echo "== watching $tty beyond byte $start of $log for the U-Boot menu (reader pid $reader)"
i=0
while [ $i -lt 1800 ]; do
  if tail -c +$((start + 1)) "$log" | grep -a -q 'U-Boot Boot Menu\|Boot OS2 (part 6)'; then
    printf "$keys" > "$tty"
    echo "== menu seen at poll $i: selected $slot"
    sleep 5
    tail -c +$((start + 1)) "$log" | tr -d '\r' \
      | grep -a -o 'Boot OS[12] (part [56])\|Retrieving file[^\n]*\|Starting kernel[^\n]*\|Linux version [^\n]*' | tail -5
    echo "== capture continues in $log (kill $reader to stop it)"
    exit 0
  fi
  sleep 0.5; i=$((i + 1))
done
echo "!! no U-Boot menu in 15 min; an unattended countdown lands on os1" >&2
kill "$reader" 2>/dev/null; exit 1
