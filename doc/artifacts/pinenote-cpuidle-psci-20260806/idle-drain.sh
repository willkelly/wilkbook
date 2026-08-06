#!/bin/sh
# Idle drain, comparable across os1 (Debian/GNOME) and os2 (Guix/KOReader).
#
# The rk817 gauge is a PMIC coulomb counter (charge_now, uAh) that keeps
# counting while the SoC is powered down, so an awake window and a
# suspended window are measured the same way.  There is no current_now on
# this gauge; everything derives from charge_now deltas.
#
# Controlled, because each of these swamps the thing being compared:
#   * charger MUST be offline -- charging inverts the delta entirely
#   * frontlight forced to a fixed level on both slots (os1 was found at
#     12/255 and os2 defaults off; that alone is a real difference)
#   * platform sleep inhibited, or an "awake" window silently contains
#     suspended time (os1's GNOME sleeps on battery after 1800 s)
#
#   LABEL=os1-foliate WINDOW=900 FRONTLIGHT=0 ./idle-drain.sh
set -u
LABEL=${LABEL:-unlabelled}
WINDOW=${WINDOW:-900}
FRONTLIGHT=${FRONTLIGHT:-0}
B=/sys/class/power_supply/rk817-battery
OUT=/tmp/idle-drain-$LABEL.txt

say() { echo "$*" | tee -a "$OUT"; }
: > "$OUT"

online=$(cat /sys/class/power_supply/rk817-charger/online 2>/dev/null || echo "?")
if [ "$online" != "0" ]; then
	say "ABORT: charger online=$online -- unplug before measuring"
	exit 1
fi

# Frontlight: both channels, same value on both slots.
for ch in /sys/class/backlight/backlight_cool /sys/class/backlight/backlight_warm; do
	[ -d "$ch" ] && echo "$FRONTLIGHT" > "$ch/brightness" 2>/dev/null
done

# Inhibit sleep for the window.  systemd-inhibit on os1; os2's
# auto-suspend daemon reads this file before every idle wait.
INHIBIT_PID=""
if command -v systemd-inhibit >/dev/null 2>&1; then
	systemd-inhibit --what=sleep:idle --why="wilkbook idle drain" \
		sleep $((WINDOW + 120)) &
	INHIBIT_PID=$!
fi
if [ -d /var/lib/pinenote ] || [ -x /run/current-system/profile/bin/herd ]; then
	mkdir -p /var/lib/pinenote 2>/dev/null
	echo "enabled=0" > /var/lib/pinenote/autosuspend.conf 2>/dev/null
fi

say "=== idle drain: $LABEL ==="
say "kernel:     $(uname -r)"
say "window:     ${WINDOW}s"
say "frontlight: $FRONTLIGHT (both channels)"
say "charger:    offline"
say "capacity:   $(cat $B/capacity)%"
say ""

C0=$(cat $B/charge_now); T0=$(date +%s)
say "start: $C0 uAh"
sleep "$WINDOW"
C1=$(cat $B/charge_now); T1=$(date +%s)
SECS=$((T1 - T0))
say "end:   $C1 uAh  after ${SECS}s"

awk -v a="$C0" -v b="$C1" -v s="$SECS" -v l="$LABEL" 'BEGIN{
  ma = (a-b)/1000.0 * 3600.0 / s
  printf "\nRESULT %s: %.1f mA\n", l, ma
  if (ma > 0.5) {
    printf "  from a full 4000 mAh: %.1f h  (%.1f days)\n", 4000/ma, 4000/ma/24
  } else {
    print "  drain below gauge resolution over this window -- run longer"
  }
}' | tee -a "$OUT"

[ -n "$INHIBIT_PID" ] && kill "$INHIBIT_PID" 2>/dev/null
echo DONE > /tmp/idle-drain-$LABEL.done
