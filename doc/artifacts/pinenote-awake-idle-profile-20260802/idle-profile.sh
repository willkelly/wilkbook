#!/bin/sh
# Awake-idle power attribution, sampled with NO ssh session active.
#
# Live sampling over ssh perturbs what it measures: the wifi traffic and the
# shell itself wake the CPU and ramp the governor.  (Observed 2026-08-02:
# scaling_cur_freq read 1.8 GHz over ssh while time_in_state showed 96% at
# 408 MHz.)  So this runs detached and only writes files.
set -u
E=/tmp/idle-profile
rm -rf $E; mkdir -p $E
W=${W:-60}

snap() { # $1 = tag
	d=$E/$1; mkdir -p $d
	cp /proc/interrupts $d/interrupts 2>/dev/null
	cp /proc/stat $d/stat 2>/dev/null
	cat /sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state > $d/time_in_state 2>/dev/null
	cat /proc/uptime > $d/uptime
	cat /sys/class/power_supply/rk817-battery/charge_now > $d/charge 2>/dev/null
	date +%s > $d/wall
}

# quiesce exactly as the battery A/B did, so numbers are comparable
herd stop reader-session > /dev/null 2>&1
sleep 3
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
echo 4 > /sys/class/graphics/fb0/blank 2>/dev/null
sleep 2

# one-shot state that does not need a delta
{
	echo "== wakeup sources (active_count / active_since)"
	cat /sys/kernel/debug/wakeup_sources 2>/dev/null
} > $E/wakeup_sources.txt
{
	echo "== runtime PM status per device"
	for p in /sys/bus/*/devices/*/power/runtime_status; do
		s=$(cat "$p" 2>/dev/null); dev=${p%/power/runtime_status}
		[ -n "$s" ] && echo "$s	$(basename $dev)	$(dirname $dev | xargs basename)"
	done | sort
} > $E/runtime_pm.txt
{
	echo "== regulators"
	cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null
} > $E/regulators.txt
{
	echo "== clocks with nonzero enable_cnt"
	awk 'NR<=2 || $2+0 > 0' /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -80
} > $E/clocks.txt

snap pre
sleep "$W"
snap post

# derive the deltas
{
	P=$E/pre; Q=$E/post
	secs=$(( $(cat $Q/wall) - $(cat $P/wall) ))
	echo "window: ${secs}s"
	c0=$(cat $P/charge 2>/dev/null); c1=$(cat $Q/charge 2>/dev/null)
	[ -n "$c0" ] && [ -n "$c1" ] && awk -v a="$c0" -v b="$c1" -v s="$secs" \
		'BEGIN{printf "battery: %d -> %d uAh, drain %.1f mA\n", a, b, (a-b)/1000.0*3600.0/s}'
	echo
	echo "== interrupt rates (per second, only nonzero)"
	awk -v s="$secs" '
	  FNR==NR { if (FNR>1) { t=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) t+=$i; a[$1]=t; n[$1]=$0 } ; next }
	  FNR>1 { t=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) t+=$i;
	          d=t-a[$1]; if (d>0) { lbl=""; for(i=2;i<=NF;i++) if ($i !~ /^[0-9]+$/) lbl=lbl" "$i;
	          printf "%8.1f/s  %s%s\n", d/s, $1, lbl } }
	' $P/interrupts $Q/interrupts | sort -rn | head -25
	echo
	echo "== cpu time delta (jiffies)"
	awk 'FNR==NR && /^cpu /{for(i=2;i<=NF;i++) a[i]=$i; next} /^cpu /{printf "user=%d nice=%d sys=%d idle=%d iowait=%d irq=%d softirq=%d\n", $2-a[2],$3-a[3],$4-a[4],$5-a[5],$6-a[6],$7-a[7],$8-a[8]}' $P/stat $Q/stat
	echo
	echo "== cpufreq residency delta (10ms units)"
	awk 'FNR==NR{a[$1]=$2; next}{d=$2-a[$1]; if (d>0) printf "%8s kHz  %d\n", $1, d}' $P/time_in_state $Q/time_in_state
} > $E/RESULT.txt 2>&1

echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
herd start reader-session > /dev/null 2>&1
echo DONE > $E/COMPLETE
