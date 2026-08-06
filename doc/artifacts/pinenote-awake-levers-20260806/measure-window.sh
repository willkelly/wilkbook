#!/bin/sh
# One labelled coulomb-counter window with context counters.
#
# Context counters ride along so every window can be sanity-checked:
# cpu-sleep residency (is cpuidle behaving the same in both phases of an
# A/B), and the interrupt delta (did something unexpected wake up).
set -u
LABEL=${LABEL:?need LABEL}
W=${W:-900}
SETTLE=${SETTLE:-0}
B=/sys/class/power_supply/rk817-battery
OUT=/tmp/win-$LABEL.txt
: > "$OUT"
say() { echo "$*" >> "$OUT"; }

[ "$(cat /sys/class/power_supply/rk817-charger/online)" = "0" ] || {
  say "ABORT: charging"; echo DONE > /tmp/win-$LABEL.done; exit 1; }
for ch in /sys/class/backlight/*; do echo 0 > "$ch/brightness" 2>/dev/null; done

say "label=$LABEL settle=${SETTLE}s window=${W}s start_capacity=$(cat $B/capacity)%"
sleep "$SETTLE"

cp /proc/interrupts /tmp/win-$LABEL.int0
U0=0; for u in /sys/devices/system/cpu/cpu*/cpuidle/state1/usage; do U0=$((U0+$(cat $u))); done
T0=0; for t in /sys/devices/system/cpu/cpu*/cpuidle/state1/time;  do T0=$((T0+$(cat $t))); done
C0=$(cat $B/charge_now); S0=$(date +%s)
sleep "$W"
C1=$(cat $B/charge_now); S1=$(date +%s)
U1=0; for u in /sys/devices/system/cpu/cpu*/cpuidle/state1/usage; do U1=$((U1+$(cat $u))); done
T1=0; for t in /sys/devices/system/cpu/cpu*/cpuidle/state1/time;  do T1=$((T1+$(cat $t))); done
cp /proc/interrupts /tmp/win-$LABEL.int1

SEC=$((S1-S0))
awk -v a="$C0" -v b="$C1" -v s="$SEC" -v l="$LABEL" \
  'BEGIN{printf "RESULT %s: %.1f mA over %ds\n", l, (a-b)/1000.0*3600.0/s, s}' >> "$OUT"
say "charge $C0 -> $C1"
say "cpu_sleep_entries=$((U1-U0)) cpu_sleep_us=$((T1-T0))"
echo DONE > /tmp/win-$LABEL.done
