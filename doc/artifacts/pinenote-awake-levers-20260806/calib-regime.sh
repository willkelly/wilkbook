#!/bin/sh
# Charging-regime calibration: can we measure load deltas while charging?
#
# The gauge counts BATTERY current. With the charger input saturated,
# extra system load comes 1:1 out of the battery-charge rate, and
# differential A/B measurements work (with ABBA to cancel taper drift).
# With the charger in constant-current mode instead, the input absorbs
# small load changes and the battery rate never moves -- in that regime
# tonight's measurements are impossible and we must say so.
#
# Test: idle window vs 4-core CPU-burn window.  Burn adds a large,
# certain load; if the battery rate barely moves, the regime is wrong.
set -u
W=${W:-300}
B=/sys/class/power_supply/rk817-battery
OUT=/tmp/calib-regime.txt
: > "$OUT"
say() { echo "$*" | tee -a "$OUT"; }

rate() { # $1 label -> prints net battery mA (negative = charging)
	C0=$(cat $B/charge_now); S0=$(date +%s)
	sleep "$W"
	C1=$(cat $B/charge_now); S1=$(date +%s)
	awk -v a="$C0" -v b="$C1" -v s="$((S1-S0))" -v l="$1" \
	  'BEGIN{printf "  %-12s net battery %+8.1f mA  (negative = charging)\n", l, (a-b)/1000.0*3600.0/s}' | tee -a "$OUT"
}

say "=== charging-regime calibration, ${W}s per phase ==="
say "  charger online: $(cat /sys/class/power_supply/rk817-charger/online)"
say "  capacity: $(cat $B/capacity)%   vbus: $(cat /sys/class/power_supply/rk817-charger/voltage_avg) uV"
sleep 30
rate "idle-1"
# burn: 4 cores of pure spin
for i in 1 2 3 4; do sh -c 'while :; do :; done' & done
BPIDS=$!
sleep 5
rate "burn"
# kill every spinner we started (they are our children's shells)
pkill -f 'while :; do :; done' 2>/dev/null
sleep 5
rate "idle-2"
say ""
say "verdict: if burn differs from the idle windows by >>50 mA, the input"
say "is saturated and differential ABBA measurements are valid tonight."
echo DONE > /tmp/calib-regime.done
