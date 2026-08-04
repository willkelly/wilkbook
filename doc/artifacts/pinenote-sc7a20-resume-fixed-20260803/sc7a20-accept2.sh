#!/bin/sh
# SC7A20 IRQ-bracket acceptance test, v2.
#
# v1 was invalid twice over and both errors are worth recording:
#
#  1. It never quiesced the USB gadget, so `echo mem` returned -EAGAIN with
#     last_failed_dev=fcc00000.usb and the device NEVER SUSPENDED.  "No
#     storm after resume" was therefore vacuous -- there was no resume.
#     The autosuspend daemon unbinds the UDC before suspending; a manual
#     test must do the same.
#
#  2. Test C read in_accel_*_raw, which returns -EBUSY whenever the
#     buffer is enabled -- and the orientation bridge keeps it enabled.
#     Zero samples meant "bridge is running", not "sensor is dead".
#
# v2 measures the IRQ rate instead, and measures it BEFORE and AFTER the
# suspend over equal windows.  That is the like-for-like comparison: if
# the sensor produces interrupts before but not after, the bracket traded
# a storm for a dead sensor.  A pre-suspend rate of zero invalidates the
# post-suspend comparison, so the script says so rather than scoring it.
set -u
E=/tmp/sc7a20-accept2
rm -rf $E; mkdir -p $E
LOG=$E/result.txt
WINDOW=${WINDOW:-20}
GADGET=/sys/kernel/config/usb_gadget/pinenote-acm/UDC
UDCNAME=$(cat $GADGET 2>/dev/null || echo "")

log() { echo "$*" >> "$LOG"; }

NCPU=$(grep -c ^processor /proc/cpuinfo)
# Sum ONLY the per-CPU columns.  v1 summed every numeric field, which
# swept in the hwirq number (10) as a constant +10 offset.
irq_row()   { grep 'sc7a20-trigger' /proc/interrupts | grep -v consumer | head -1; }
irq_num()   { irq_row | awk -F: '{gsub(/ /,"",$1); print $1}'; }
irq_count() { irq_row | awk -v n="$NCPU" '{t=0; for(i=2;i<=n+1;i++) t+=$i; print t}'; }

log "=== SC7A20 IRQ acceptance v2 ==="
log "kernel: $(uname -r)   cpus: $NCPU   window: ${WINDOW}s"
IRQ=$(irq_num)
log "irq: $IRQ   ($(irq_row))"
log ""

log "--- pre-suspend baseline rate (${WINDOW}s) ---"
P0=$(irq_count); sleep "$WINDOW"; P1=$(irq_count)
PRE=$((P1 - P0))
log "  $P0 -> $P1   delta=$PRE   (~$(awk -v d=$PRE -v w=$WINDOW 'BEGIN{printf "%.2f", d/w}')/s)"

dmesg > $E/dmesg-pre.txt
PRELINES=$(wc -l < $E/dmesg-pre.txt)

log ""
log "--- suspend cycle ---"
echo deep > /sys/power/mem_sleep 2>/dev/null
MODE=$(cat /sys/power/mem_sleep)
log "  mem_sleep: $MODE"
case "$MODE" in *"[deep]"*) ;; *) log "  ABORT: deep not selectable"; cat "$LOG"; exit 1 ;; esac

# THE FIX v1 MISSED: unbind the UDC or dwc3 refuses to suspend (-EAGAIN).
if [ -n "$UDCNAME" ]; then
	log "  quiescing usb gadget (was bound to $UDCNAME)"
	printf '\n' > $GADGET 2>/dev/null
	sleep 1
	log "  UDC now: '$(cat $GADGET 2>/dev/null)'"
fi

echo 0 > /sys/class/rtc/rtc0/wakealarm
NOW=$(cat /sys/class/rtc/rtc0/since_epoch)
echo $((NOW + 30)) > /sys/class/rtc/rtc0/wakealarm
S0=$(cat /sys/power/suspend_stats/success); F0=$(cat /sys/power/suspend_stats/fail)
echo "<0>WILKBOOK: sc7a20 v2 suspending" > /dev/kmsg
sync
echo mem > /sys/power/state 2>> $E/suspend.err
RC=$?
echo "<0>WILKBOOK: sc7a20 v2 resumed" > /dev/kmsg
S1=$(cat /sys/power/suspend_stats/success); F1=$(cat /sys/power/suspend_stats/fail)
log "  echo mem rc=$RC   success $S0->$S1   fail $F0->$F1"

# Restore the gadget so the ACM console comes back.
if [ -n "$UDCNAME" ]; then
	printf '%s' "$UDCNAME" > $GADGET 2>/dev/null
	log "  gadget rebound: '$(cat $GADGET 2>/dev/null)'"
fi

SUSPENDED=no
[ "$S1" -gt "$S0" ] && SUSPENDED=yes
log "  ACTUALLY SUSPENDED: $SUSPENDED"

if [ "$SUSPENDED" = "no" ]; then
	log ""
	log "  ABORT: the device did not suspend, so nothing below would mean"
	log "         anything.  last_failed_dev=$(cat /sys/power/suspend_stats/last_failed_dev 2>/dev/null)"
	log "         last_failed_errno=$(cat /sys/power/suspend_stats/last_failed_errno 2>/dev/null)"
	cat "$LOG"
	exit 1
fi

sleep 10

log ""
log "--- A. error lines from THIS cycle ---"
dmesg > $E/dmesg-post.txt
tail -n +$((PRELINES + 1)) $E/dmesg-post.txt > $E/dmesg-delta.txt
log "  new dmesg lines: $(wc -l < $E/dmesg-delta.txt)"
if grep -qiE 'nobody cared|Disabling IRQ' $E/dmesg-delta.txt; then
	log "  FAIL:"
	grep -iE 'nobody cared|Disabling IRQ' $E/dmesg-delta.txt | sed 's/^/    /' >> "$LOG"
	A=FAIL
else
	log "  PASS: no 'nobody cared' / 'Disabling IRQ'"
	A=PASS
fi

log ""
log "--- B. IRQ still enabled ---"
if [ -r /sys/kernel/debug/irq/irqs/$IRQ ]; then
	grep -iE 'ddepth|wdepth|istate|unhandled' /sys/kernel/debug/irq/irqs/$IRQ | sed 's/^/    /' >> "$LOG"
	DD=$(awk '/ddepth/{print $2}' /sys/kernel/debug/irq/irqs/$IRQ | head -1)
	if [ "${DD:-0}" = "0" ]; then log "  PASS: ddepth=0 (enabled, bracket balanced)"; B=PASS
	else log "  FAIL: ddepth=$DD (left masked -- unbalanced bracket)"; B=FAIL; fi
else
	log "  SKIP: no debugfs irq node"; B=SKIP
fi

log ""
log "--- C. interrupt rate survives resume (${WINDOW}s, same as baseline) ---"
Q0=$(irq_count); sleep "$WINDOW"; Q1=$(irq_count)
POST=$((Q1 - Q0))
log "  pre : delta=$PRE"
log "  post: $Q0 -> $Q1   delta=$POST"
if [ "$PRE" -eq 0 ]; then
	log "  INVALID: baseline rate was 0, so the sensor was not producing"
	log "           interrupts even BEFORE suspend.  Nothing to compare."
	C=INVALID
elif [ "$POST" -gt 0 ]; then
	log "  PASS: still firing after resume ($(awk -v a=$POST -v b=$PRE 'BEGIN{printf "%.0f%%", 100*a/b}') of baseline)"
	C=PASS
else
	log "  FAIL: fired $PRE times before suspend, 0 after -- sensor is dead"
	C=FAIL
fi

log ""
log "--- buffer/consumer state (context for C) ---"
D=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = "sc7a20" ] && echo $d; done)
log "  node: $D"
log "  buffer enable: $(cat $D/buffer/enable 2>/dev/null)"
log "  trigger      : $(cat $D/trigger/current_trigger 2>/dev/null)"
log "  sampling_freq: $(cat $D/sampling_frequency 2>/dev/null)"
log "  bridge alive : $(pgrep -c -f orientation-bridge 2>/dev/null || echo 0)"

log ""
log "=== SUMMARY ==="
log "  suspended       : $SUSPENDED"
log "  A no-storm      : $A"
log "  B irq-enabled   : $B"
log "  C irq-survives  : $C"
log ""
log "Rotation on glass is still a human check."

cat "$LOG"
