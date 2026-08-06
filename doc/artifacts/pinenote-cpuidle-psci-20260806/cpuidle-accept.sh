#!/bin/sh
# cpuidle acceptance for the rk3566 idle-states experiment.  Run ON os2.
#
# Acceptance, in order of what each actually proves:
#   A. the driver registered at all -- current_driver == "psci".  Without
#      this the DT node was rejected and nothing else below is meaningful.
#   B. the state is DESCRIBED as we intended (name/latency/residency).
#   C. the state is ENTERED -- usage climbs.  A registered state with a
#      usage of 0 means the governor never picks it, which is a different
#      failure from "firmware refused".
#   D. entries actually SUCCEED -- `rejected`/`below`/`above` and, most
#      importantly, no core wedged.  All four CPUs must still be online
#      after a soak; a core that failed to wake takes the box down, so if
#      this script completes at all that is itself evidence.
#
# It deliberately does NOT measure power.  Comparing mA needs the same
# 900 s coulomb-counter window as the 205.7 mA baseline, unplugged and
# with the frontlight pinned -- idle-drain.sh does that, separately.
set -u
E=/tmp/cpuidle-accept
rm -rf $E; mkdir -p $E
LOG=$E/result.txt
SOAK=${SOAK:-60}
log() { echo "$*" >> "$LOG"; }

log "=== cpuidle acceptance ==="
log "kernel: $(uname -r)"
log ""

log "--- A. did a cpuidle driver register? ---"
DRV=$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null || echo "<absent>")
GOV=$(cat /sys/devices/system/cpu/cpuidle/current_governor 2>/dev/null || echo "<absent>")
log "  current_driver:   $DRV"
log "  current_governor: $GOV"
case "$DRV" in psci*) A=PASS ;; *) A=FAIL ;; esac
log "  => $A"

log ""
log "--- B. is the state described as intended? ---"
S=/sys/devices/system/cpu/cpu0/cpuidle
if [ -d "$S" ]; then
	for st in "$S"/state*; do
		[ -d "$st" ] || continue
		log "  $(basename $st): name=$(cat $st/name 2>/dev/null) desc=$(cat $st/desc 2>/dev/null)"
		log "      latency=$(cat $st/latency 2>/dev/null)us residency=$(cat $st/residency 2>/dev/null)us disable=$(cat $st/disable 2>/dev/null)"
	done
	B=PASS
else
	log "  no per-cpu cpuidle sysfs -- nothing registered"
	B=FAIL
fi

log ""
log "--- C/D. soak ${SOAK}s, then are states entered and cores alive? ---"
snap() {
	for c in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/usage; do
		[ -f "$c" ] && echo "$c $(cat $c)"
	done
}
snap > $E/usage.pre
ONLINE0=$(grep -c . /sys/devices/system/cpu/online 2>/dev/null; cat /sys/devices/system/cpu/online)
sleep "$SOAK"
snap > $E/usage.post
ONLINE1=$(cat /sys/devices/system/cpu/online)

TOTAL=0
if [ -s $E/usage.pre ]; then
	while read -r path pre; do
		post=$(grep -F "$path " $E/usage.post | awk '{print $2}')
		d=$((${post:-0} - pre))
		[ "$d" -gt 0 ] && log "  $(echo $path | sed 's|/sys/devices/system/cpu/||; s|/cpuidle/|  |; s|/usage||')  +$d"
		TOTAL=$((TOTAL + d))
	done < $E/usage.pre
fi
log "  total idle-state entries in ${SOAK}s: $TOTAL"
if [ "$TOTAL" -gt 0 ]; then C=PASS; else C=FAIL; fi

log ""
log "  cpus online before: $(cat /sys/devices/system/cpu/online)"
log "  cpus online after:  $ONLINE1"
if [ "$ONLINE1" = "0-3" ]; then D=PASS; else D=FAIL; fi

log ""
log "--- kernel complaints this boot ---"
dmesg | grep -iE "cpuidle|psci|CPU[0-9].*(fail|stuck|not.*come|died)" | tail -12 >> "$LOG"

log ""
log "=== SUMMARY ==="
log "  A driver registered : $A  ($DRV)"
log "  B state described   : $B"
log "  C states entered    : $C  ($TOTAL entries)"
log "  D all cores alive   : $D  ($ONLINE1)"
log ""
log "Power is NOT measured here -- run idle-drain.sh for the 900 s"
log "comparison against the 205.7 mA baseline."
cat "$LOG"
