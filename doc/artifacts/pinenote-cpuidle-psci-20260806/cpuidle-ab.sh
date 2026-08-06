#!/bin/sh
# cpuidle A/B on ONE boot: same book, same frontlight, same window; the
# only variable is whether the cpu-sleep state may be entered.
#
# This beats comparing against a previous boot because it removes
# boot-to-boot variation entirely.  Phase B should also land near the
# 205.7 mA measured on 2026-08-05 with the pre-cpuidle kernel -- if it
# does, that validates both this method and that baseline.
set -u
W=${W:-900}
B=/sys/class/power_supply/rk817-battery
CHG=/sys/class/power_supply/rk817-charger/online
OUT=/tmp/cpuidle-ab.txt
: > "$OUT"
say() { echo "$*" | tee -a "$OUT"; }

online=$(cat "$CHG" 2>/dev/null || echo "?")
[ "$online" = "0" ] || { say "ABORT: charger online=$online (must be 0)"; echo DONE > /tmp/cpuidle-ab.done; exit 1; }

for ch in /sys/class/backlight/*; do echo 0 > "$ch/brightness" 2>/dev/null; done
mkdir -p /var/lib/pinenote
echo "enabled=0" > /var/lib/pinenote/autosuspend.conf

set_state() {   # $1: 0 = allow cpu-sleep, 1 = forbid it
	for d in /sys/devices/system/cpu/cpu*/cpuidle/state1/disable; do
		[ -f "$d" ] && echo "$1" > "$d" 2>/dev/null
	done
}
usage_total() {
	t=0
	for u in /sys/devices/system/cpu/cpu*/cpuidle/state1/usage; do
		[ -f "$u" ] && t=$((t + $(cat "$u")))
	done
	echo "$t"
}

run() {   # $1: label
	C0=$(cat "$B/charge_now"); U0=$(usage_total); T0=$(date +%s)
	sleep "$W"
	C1=$(cat "$B/charge_now"); U1=$(usage_total); T1=$(date +%s)
	S=$((T1 - T0))
	awk -v a="$C0" -v b="$C1" -v s="$S" -v l="$1" -v u="$((U1 - U0))" \
	  'BEGIN{printf "  %-26s %6.1f mA    cpu-sleep entries: %d\n", l, (a-b)/1000.0*3600.0/s, u}' \
	  | tee -a "$OUT"
}

say "=== cpuidle A/B, one boot, book open, ${W}s per phase ==="
say "  driver:   $(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)"
say "  reader:   $(pgrep -c -f 'reade[r].lua' 2>/dev/null || echo 0) proc"
say "  capacity: $(cat "$B/capacity")%"
say ""

set_state 0; sleep 2
run "A: cpu-sleep ENABLED"

set_state 1; sleep 2
run "B: cpu-sleep DISABLED"

set_state 0
say ""
say "  cpus online: $(cat /sys/devices/system/cpu/online)"
say "  capacity now: $(cat "$B/capacity")%"
say ""
say "  (B is the pre-patch behaviour: WFI only.  Compare with the 205.7 mA"
say "   measured on the previous kernel under the same 900 s conditions.)"
echo DONE > /tmp/cpuidle-ab.done
