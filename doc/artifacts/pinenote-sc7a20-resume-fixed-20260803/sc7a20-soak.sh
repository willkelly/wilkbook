#!/bin/sh
# Repeat the SC7A20 deep-suspend acceptance N times.
#
# One passing cycle proves the fix is possible, not that it is reliable.
# Each iteration re-measures the interrupt rate on both sides of a real
# deep cycle and re-reads the polarity register, so a drift that only
# shows up on the 3rd or 5th sleep cannot hide.
set -u
N=${N:-5}
WINDOW=${WINDOW:-10}
E=/tmp/sc7a20-soak
rm -rf $E; mkdir -p $E
LOG=$E/result.txt
GADGET=/sys/kernel/config/usb_gadget/pinenote-acm/UDC
DBG=/sys/kernel/debug/iio/iio:device2
NCPU=$(grep -c ^processor /proc/cpuinfo)

log() { echo "$*" >> "$LOG"; }
irq_row()   { grep 'sc7a20-trigger' /proc/interrupts | grep -v consumer | head -1; }
irq_count() { irq_row | awk -v n="$NCPU" '{t=0; for(i=2;i<=n+1;i++) t+=$i; print t}'; }
reg() { echo "$1" > $DBG/direct_reg_access 2>/dev/null; cat $DBG/direct_reg_access 2>/dev/null; }

echo deep > /sys/power/mem_sleep 2>/dev/null
log "=== SC7A20 deep-suspend soak: $N cycles, ${WINDOW}s windows ==="
log "mem_sleep: $(cat /sys/power/mem_sleep)"
log ""
log "cycle |  pre/s | post/s | 0x25 | 0x27 | storm | ddepth | result"
log "------+--------+--------+------+------+-------+--------+-------"

PASSES=0
for c in $(seq 1 $N); do
	P0=$(irq_count); sleep "$WINDOW"; P1=$(irq_count); PRE=$((P1-P0))

	dmesg > $E/pre.$c.txt; PL=$(wc -l < $E/pre.$c.txt)
	UDC=$(cat $GADGET 2>/dev/null)
	[ -n "$UDC" ] && { printf '\n' > $GADGET 2>/dev/null; sleep 1; }

	echo 0 > /sys/class/rtc/rtc0/wakealarm
	NOW=$(cat /sys/class/rtc/rtc0/since_epoch)
	echo $((NOW + 25)) > /sys/class/rtc/rtc0/wakealarm
	S0=$(cat /sys/power/suspend_stats/success)
	sync
	echo mem > /sys/power/state 2>/dev/null
	S1=$(cat /sys/power/suspend_stats/success)
	[ -n "$UDC" ] && printf '%s' "$UDC" > $GADGET 2>/dev/null

	if [ "$S1" -le "$S0" ]; then
		log "$(printf '%5d | %6s | %6s | %4s | %4s | %5s | %6s | DID NOT SUSPEND' "$c" "$PRE" "-" "-" "-" "-" "-")"
		continue
	fi

	sleep 6
	Q0=$(irq_count); sleep "$WINDOW"; Q1=$(irq_count); POST=$((Q1-Q0))
	R25=$(reg 0x25); R27=$(reg 0x27)
	dmesg > $E/post.$c.txt
	tail -n +$((PL+1)) $E/post.$c.txt > $E/delta.$c.txt
	STORM=no
	grep -qiE 'nobody cared|Disabling IRQ' $E/delta.$c.txt && STORM=YES
	DD=$(awk '/ddepth/{print $2}' /sys/kernel/debug/irq/irqs/73 2>/dev/null | head -1)

	RES=FAIL
	if [ "$STORM" = "no" ] && [ "$POST" -gt 0 ] && [ "${DD:-1}" = "0" ] && [ "$R25" = "0x2" ]; then
		RES=PASS; PASSES=$((PASSES+1))
	fi
	log "$(printf '%5d | %6s | %6s | %4s | %4s | %5s | %6s | %s' \
		"$c" "$PRE" "$POST" "$R25" "$R27" "$STORM" "${DD:-?}" "$RES")"
done

log ""
log "=== $PASSES / $N cycles PASS ==="
log "(0x25 must stay 0x2 = active low; 0x27 0x00 means data is being consumed,"
log " 0xff means ready+overrun i.e. nobody is reading -- the silent failure.)"
cat "$LOG"
