#!/bin/sh
# Attribute the ~173 mA awake floor by cumulative teardown.
#
# One coulomb counter, no per-rail current (the RK817 reports 0 mA for
# every rail), so the only way to attribute is differentially: measure,
# switch one subsystem off, measure again, and read the delta.
#
# Cumulative rather than restore-each-time, because every toggle costs a
# settling period and the battery is finite.  Deltas are therefore
# "what this subsystem cost GIVEN everything above it is already off",
# which is the honest framing -- they do not necessarily sum to the total
# if subsystems interact.
#
# The last line is the number that matters: what the board draws with
# essentially all of userspace and the radios gone.  Whatever remains is
# static rail/DDR/always-on draw, and no amount of scheduling fixes it.
set -u
W=${W:-300}
B=/sys/class/power_supply/rk817-battery
OUT=/tmp/domain-teardown.txt
: > "$OUT"
say() { echo "$*" | tee -a "$OUT"; }

[ "$(cat /sys/class/power_supply/rk817-charger/online)" = "0" ] || {
	say "ABORT: charging"; echo DONE > /tmp/domain-teardown.done; exit 1; }

PREV=""
measure() {   # $1 = label
	C0=$(cat "$B/charge_now"); T0=$(date +%s)
	sleep "$W"
	C1=$(cat "$B/charge_now"); T1=$(date +%s)
	MA=$(awk -v a="$C0" -v b="$C1" -v s="$((T1-T0))" 'BEGIN{printf "%.1f", (a-b)/1000.0*3600.0/s}')
	if [ -n "$PREV" ]; then
		D=$(awk -v p="$PREV" -v m="$MA" 'BEGIN{printf "%+.1f", m-p}')
		say "$(printf '  %-34s %7s mA   delta %s' "$1" "$MA" "$D")"
	else
		say "$(printf '  %-34s %7s mA   (baseline)' "$1" "$MA")"
	fi
	PREV=$MA
}

say "=== awake-power domain teardown, ${W}s per stage ==="
say "  capacity at start: $(cat "$B/capacity")%"
say "  cpufreq: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null) kHz  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
say "  vdd_cpu opmode: $(awk '/vdd_cpu/{print $6, $7}' /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | head -1)"
say ""

for ch in /sys/class/backlight/*; do echo 0 > "$ch/brightness" 2>/dev/null; done
mkdir -p /var/lib/pinenote; echo "enabled=0" > /var/lib/pinenote/autosuspend.conf

measure "0 baseline (reader + book, wifi up)"

# 1. the reader application itself
herd stop reader-session >/dev/null 2>&1
P=$(pgrep -f 'reade[r].lua' | head -3); [ -n "$P" ] && kill $P 2>/dev/null
sleep 5
measure "1 - KOReader stopped"

# 2. the orientation bridge + its 25 Hz accelerometer
herd stop orientation-bridge >/dev/null 2>&1
sleep 3
measure "2 - orientation bridge stopped"

# 3. Wi-Fi: down the link, then unload the driver entirely
ip link set wlan0 down 2>/dev/null
sleep 3
measure "3 - wlan0 down"

# 4. USB gadget (dwc3 stays powered while bound)
G=/sys/kernel/config/usb_gadget/pinenote-acm/UDC
UDC=$(cat $G 2>/dev/null); [ -n "$UDC" ] && printf '\n' > $G 2>/dev/null
sleep 3
measure "4 - usb gadget unbound"

# 5. panel: unbind fbcon and blank, so the EBC stops being driven
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
echo 4 > /sys/class/graphics/fb0/blank 2>/dev/null
sleep 3
measure "5 - fbcon unbound + fb blanked"

# 6. eMMC runtime-suspend pressure: dw-mci was ~21 IRQ/s
for d in /sys/bus/platform/devices/fe310000.mmc/power/control \
         /sys/bus/platform/devices/fe2c0000.mmc/power/control; do
	[ -f "$d" ] && echo auto > "$d" 2>/dev/null
done
sleep 3
measure "6 - mmc runtime pm = auto"

say ""
say "  capacity at end: $(cat "$B/capacity")%"
say "  NOTE: deltas are cumulative -- each is the cost GIVEN the stages"
say "  above are already off.  The final figure is the irreducible floor."

# restore
echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
echo 1 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
[ -n "${UDC:-}" ] && printf '%s' "$UDC" > $G 2>/dev/null
ip link set wlan0 up 2>/dev/null
herd start orientation-bridge >/dev/null 2>&1
herd start reader-session >/dev/null 2>&1
say "  restored: panel, gadget, wifi, bridge, reader"
echo DONE > /tmp/domain-teardown.done
