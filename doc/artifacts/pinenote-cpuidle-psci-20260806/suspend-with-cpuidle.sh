#!/bin/sh
# Does deep suspend still work with cpuidle idle-states present?
#
# The 20.6 mA suspend figure was measured on the PRE-cpuidle image; deep
# has never been exercised with idle-states in the DT.  The interaction
# should be benign -- cpuidle is disabled across suspend entry and the
# CPUs are hotplugged off via PSCI CPU_OFF, which demonstrably works here
# ("psci: CPU3 killed") -- but suspend IS the power strategy on this
# board, so "should be" is not good enough.
#
# Runs several cycles rather than one: a rare interaction between a core
# resuming from cpu-sleep and the suspend path would not necessarily show
# on the first try.
set -u
N=${N:-4}
E=/tmp/suspend-cpuidle
rm -rf $E; mkdir -p $E
LOG=$E/result.txt
G=/sys/kernel/config/usb_gadget/pinenote-acm/UDC
say() { echo "$*" | tee -a "$LOG"; }

usage_total() {
	t=0
	for u in /sys/devices/system/cpu/cpu*/cpuidle/state1/usage; do
		[ -f "$u" ] && t=$((t + $(cat "$u")))
	done
	echo "$t"
}

say "=== deep suspend WITH cpuidle idle-states, $N cycles ==="
say "  driver:      $(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)"
say "  cpus online: $(cat /sys/devices/system/cpu/online)"
echo deep > /sys/power/mem_sleep 2>/dev/null
say "  mem_sleep:   $(cat /sys/power/mem_sleep)"
case "$(cat /sys/power/mem_sleep)" in
	*"[deep]"*) ;;
	*) say "  ABORT: deep not selectable"; echo DONE > /tmp/suspend-cpuidle.done; exit 1 ;;
esac
say ""
say "cycle | rc | success | cpus after | cpu-sleep entries | verdict"
say "------+----+---------+------------+-------------------+--------"

PASSES=0
for c in $(seq 1 $N); do
	dmesg > $E/pre.$c; PL=$(wc -l < $E/pre.$c)
	U0=$(usage_total)
	# dwc3 vetoes suspend with -EAGAIN while the gadget is bound
	UDC=$(cat $G 2>/dev/null); [ -n "$UDC" ] && { printf '\n' > $G 2>/dev/null; sleep 1; }
	echo 0 > /sys/class/rtc/rtc0/wakealarm
	NOW=$(cat /sys/class/rtc/rtc0/since_epoch)
	echo $((NOW + 25)) > /sys/class/rtc/rtc0/wakealarm
	S0=$(cat /sys/power/suspend_stats/success)
	sync
	echo mem > /sys/power/state 2>>$E/err.$c; RC=$?
	S1=$(cat /sys/power/suspend_stats/success)
	[ -n "$UDC" ] && printf '%s' "$UDC" > $G 2>/dev/null
	sleep 5
	U1=$(usage_total)
	ONLINE=$(cat /sys/devices/system/cpu/online)
	dmesg > $E/post.$c
	tail -n +$((PL+1)) $E/post.$c > $E/delta.$c
	BAD=""
	grep -qiE 'nobody cared|Disabling IRQ|CPU[0-9].*(fail|stuck|not.*come)|Unable to handle' $E/delta.$c && BAD="dmesg"
	V=FAIL
	if [ "$S1" -gt "$S0" ] && [ "$ONLINE" = "0-3" ] && [ -z "$BAD" ]; then
		V=PASS; PASSES=$((PASSES+1))
	fi
	say "$(printf '%5d | %2d | %3d->%-3d | %10s | %17d | %s%s' \
		"$c" "$RC" "$S0" "$S1" "$ONLINE" "$((U1-U0))" "$V" "${BAD:+ ($BAD)}")"
done

say ""
say "=== $PASSES / $N cycles PASS ==="
say "  cpu-sleep entries between cycles prove idle states are still being"
say "  used after each resume, not merely that the box came back."
say ""
say "--- any complaint from the last cycle ---"
grep -iE 'psci|cpuidle|error|fail' $E/delta.$N 2>/dev/null | head -8 >> "$LOG"
cat "$LOG"
echo DONE > /tmp/suspend-cpuidle.done
