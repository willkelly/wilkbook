#!/bin/sh
# Generic ABBA differential measurement, valid while charging.
#
#   abba.sh LABEL W APPLY_SCRIPT REVERT_SCRIPT
#
# Phases: A1 (lever off) -> apply -> B1 -> B2 -> revert -> A2.
# delta = mean(B) - mean(A); the ABBA order cancels linear drift, which is
# what makes this valid during charger taper.  Sign: rates are net battery
# mA (negative = charging); a NEGATIVE delta means the lever REDUCED load.
#
# Every phase also records cpu-sleep residency so an A/B that accidentally
# changed scheduling behaviour is visible rather than silently folded in.
set -u
LABEL=${1:?label}; W=${2:?window}; APPLY=${3:?apply script}; REVERT=${4:?revert script}
B=/sys/class/power_supply/rk817-battery
OUT=/tmp/abba-$LABEL.txt
: > "$OUT"
say() { echo "$*" | tee -a "$OUT"; }

phase() { # $1 name -> appends "name rate_mA sleep_us"
	U0=0; for u in /sys/devices/system/cpu/cpu*/cpuidle/state1/time; do U0=$((U0+$(cat $u))); done
	C0=$(cat $B/charge_now); S0=$(date +%s)
	sleep "$W"
	C1=$(cat $B/charge_now); S1=$(date +%s)
	U1=0; for u in /sys/devices/system/cpu/cpu*/cpuidle/state1/time; do U1=$((U1+$(cat $u))); done
	awk -v a="$C0" -v b="$C1" -v s="$((S1-S0))" -v n="$1" -v us="$((U1-U0))" \
	  'BEGIN{printf "PHASE %-4s %+8.1f mA   cpu_sleep_us=%d\n", n, (a-b)/1000.0*3600.0/s, us}' | tee -a "$OUT"
}

say "=== ABBA $LABEL  ${W}s/phase  cap=$(cat $B/capacity)%  charger=$(cat /sys/class/power_supply/rk817-charger/online) ==="
sleep 60
phase A1
sh "$APPLY"  >> "$OUT" 2>&1
sleep 60
phase B1
phase B2
sh "$REVERT" >> "$OUT" 2>&1
sleep 60
phase A2

awk '/^PHASE/{r[$2]=$3+0} END{
  d=((r["B1"]+r["B2"])-(r["A1"]+r["A2"]))/2.0
  printf "DELTA %s: %+.1f mA  (negative = lever saves power)\n", "'"$LABEL"'", d
}' "$OUT" | tee -a "$OUT"
echo DONE > /tmp/abba-$LABEL.done
