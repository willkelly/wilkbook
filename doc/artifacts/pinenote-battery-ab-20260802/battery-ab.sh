#!/bin/sh
# Standby power A/B: awake-idle vs deep-suspend, same device state.
#
# doc/power-management.md requires comparing repeated unplugged awake and
# deep-suspend intervals under equivalent conditions before any battery
# claim.  This measures both in one unattended run and reports mA.
#
# The fuel gauge is a PMIC coulomb counter (charge_now, uAh) that keeps
# counting while the SoC is powered down, so a deep interval is measured
# the same way as an awake one.  There is no voltage_now/current_now on
# this gauge, so everything derives from charge_now deltas.
set -u
E=/tmp/battery
rm -rf $E; mkdir -p $E
LOG=$E/battery.log
B=/sys/class/power_supply/rk817-battery
AWAKE=${AWAKE:-900}
DEEP=${DEEP:-2700}

log() { echo "[$(date -u +%H:%M:%S)] $*" >> "$LOG"; }
chg() { cat $B/charge_now; }
cap() { cat $B/capacity; }
online() { cat /sys/class/power_supply/rk817-charger/online 2>/dev/null || echo "?"; }

restore() {
	echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
	echo fcc00000.usb > /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null
	herd start reader-session >> "$LOG" 2>&1
	log "=== BATTERY AB END ==="
	echo DONE > $E/COMPLETE
}
trap restore EXIT HUP INT TERM

log "=== BATTERY AB START (awake ${AWAKE}s, deep ${DEEP}s) ==="
[ "$(online)" = "0" ] || { log "ABORT: charger online=$(online); unplug before measuring"; exit 1; }

# Identical device state for both phases: reader stopped, fbcon unbound,
# panel blanked, gadget quiesced.  The only difference is who is running
# the CPU.
herd stop reader-session >> "$LOG" 2>&1
sleep 3
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
echo 4 > /sys/class/graphics/fb0/blank
echo "" > /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null
sleep 2
log "prep done: capacity=$(cap)% charge=$(chg) uAh charger_online=$(online)"

rate() { # $1 start_uAh  $2 end_uAh  $3 seconds -> mA (positive = drain)
	awk -v a="$1" -v b="$2" -v s="$3" 'BEGIN{ printf "%.1f", (a-b)/1000.0 * 3600.0 / s }'
}

# ---- phase A: awake idle ----
A0=$(chg); T0=$(date +%s)
log "PHASE A awake-idle start: charge=$A0"
sleep "$AWAKE"
A1=$(chg); T1=$(date +%s); TA=$((T1-T0))
RA=$(rate "$A0" "$A1" "$TA")
log "PHASE A awake-idle: ${TA}s, $A0 -> $A1 uAh, drain ${RA} mA"

# ---- phase B: deep suspend ----
echo deep > /sys/power/mem_sleep
case "$(cat /sys/power/mem_sleep)" in *"[deep]"*) ;; *) log "ABORT: no deep"; exit 1 ;; esac
echo 0 > /sys/class/rtc/rtc0/wakealarm
NOW=$(cat /sys/class/rtc/rtc0/since_epoch)
echo $((NOW + DEEP)) > /sys/class/rtc/rtc0/wakealarm
B0=$(chg); S0=$(date +%s)
log "PHASE B deep start: charge=$B0 alarm=+${DEEP}s"
echo "<0>WILKBOOK: battery deep phase entering" > /dev/kmsg
sync
echo mem > /sys/power/state 2>> "$E/deep.err"; rc=$?
S1=$(date +%s); B1=$(chg); TB=$((S1-S0))
echo "<0>WILKBOOK: battery deep phase resumed" > /dev/kmsg
RB=$(rate "$B0" "$B1" "$TB")
log "PHASE B deep: rc=$rc ${TB}s, $B0 -> $B1 uAh, drain ${RB} mA"

log "--- RESULT"
log "awake-idle : ${RA} mA over ${TA}s"
log "deep       : ${RB} mA over ${TB}s"
awk -v ra="$RA" -v rb="$RB" 'BEGIN{
  if (rb > 0.05) printf "deep standby from 4000 mAh full: %.1f days (%.1f h)\n", 4000/rb/24, 4000/rb;
  else print "deep drain below gauge resolution over this interval -- run a longer dwell";
  if (rb > 0.05 && ra > 0) printf "deep is %.1fx lower draw than awake-idle\n", ra/rb;
}' >> "$LOG"
log "capacity now $(cap)%  charger_online=$(online)"
exit 0
