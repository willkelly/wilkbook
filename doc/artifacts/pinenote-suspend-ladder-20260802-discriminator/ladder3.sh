#!/bin/sh
# Supervised suspend ladder, rungs 1-2, console-free.
# Detached: survives the SSH drop when Wi-Fi goes down at suspend.
# Bounded auto-wake via absolute-epoch RTC alarm; every step writes
# evidence to $E so the session is reconstructible after the drop.
set -u
E=/tmp/ladder
rm -rf $E; mkdir -p $E
LOG=$E/ladder.log

log() { echo "[$(date -u +%H:%M:%S)] $*" >> "$LOG"; }
irq() { awk '/ebc/{s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s; exit}' /proc/interrupts; }
snap() { sh /tmp/fb-damage-gates.sh > "$E/gates-$1.txt" 2>&1; }
drmstate() { cat /sys/kernel/debug/dri/0/state > "$E/drm-$1.txt" 2>&1; }
crtc_active() { awk '/^crtc\[/{c=1} c&&/^\tactive=/{print substr($0,9); exit}' /sys/kernel/debug/dri/0/state; }
fbstate() { cat /sys/class/graphics/fb0/state 2>/dev/null; }

LJ=/gnu/store/rgi66d06i9m8fk4whk5nbhqrl55la1d0-koreader-bin-2026.03/lib/koreader/luajit
# mmap + fsync: the production publish path.  A plain write() to /dev/fb0
# changes the buffer but generates NO damage that reaches the panel
# (measured 2026-08-02 on a healthy device: 0 frames, fb0 md5 changed) --
# which is why the first run of this ladder produced an uninterpretable
# ACCEPTANCE FAIL.  Do not go back to dd.
probe() {
	b=$(irq)
	$LJ /tmp/mmap-probe2.lua fsync $2 "${3:-black}" >> "$LOG" 2>&1
	a=$(irq)
	log "PROBE $1: irq $b -> $a (delta $((a-b)))"
	echo "$((a-b))"
}

# Restore runs on every exit path, including a failed rung.
restore() {
	log "--- RESTORE"
	echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
	echo fcc00000.usb > /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null
	echo 1 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
	herd start reader-session >> "$LOG" 2>&1
	sleep 6
	log "restore done: irq=$(irq) fb0.state=$(fbstate) reader=$(herd status reader-session 2>/dev/null | head -1)"
	snap restored
	echo none > /sys/power/pm_test 2>/dev/null
	log "=== LADDER END ==="
	echo DONE > $E/COMPLETE
}
trap restore EXIT HUP INT TERM

log "=== LADDER START ==="
log "system=$(readlink -f /run/current-system) root=$(findmnt -no SOURCE /)"

# deep is forbidden by the ladder rule until rung 2 passes acceptance.
echo s2idle > /sys/power/mem_sleep
log "mem_sleep forced: $(cat /sys/power/mem_sleep)"
case "$(cat /sys/power/mem_sleep)" in
*"[s2idle]"*) ;;
*) log "ABORT: could not select s2idle"; exit 1 ;;
esac

# ---------------- RUNG 1: freezer-only dry run ----------------
log "--- RUNG 1 freezer pm_test dry run"
echo freezer > /sys/power/pm_test
t0=$(date +%s)
echo mem > /sys/power/state 2>> "$E/rung1.err"; rc1=$?
t1=$(date +%s)
echo none > /sys/power/pm_test
log "RUNG 1 rc=$rc1 elapsed=$((t1-t0))s pm_test=$(cat /sys/power/pm_test)"
[ $rc1 -eq 0 ] || { log "RUNG 1 FAIL -- stopping before rung 2"; exit 1; }
log "RUNG 1 PASS"

# ------------- RUNG 2 prep: the known-failing configuration -------------
# The 2026-08-01 failure was a blanked-CRTC resume.  Reproduce it, which
# needs DRM master free -- KOReader holds it in production.
log "--- RUNG 2 prep"
herd stop reader-session >> "$LOG" 2>&1
sleep 3
cp /sys/kernel/debug/dri/0/clients "$E/clients-after-reader-stop.txt" 2>/dev/null
# fbcon re-binds on reader stop; unbind it (starvation mitigation, and it
# keeps the post-resume repaint attributable to our probe alone).
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
sleep 1
snap pre
drmstate pre
sh /tmp/pm-ground-truth.sh > "$E/gt-pre.txt" 2>&1
log "pre: irq=$(irq) fb0.state=$(fbstate) crtc_active=$(crtc_active)"

# CONTROL: prove the instrument paints on THIS boot before suspending.
# Without this gate a dead instrument is indistinguishable from a dead
# resume -- exactly the trap the first run fell into.
D0=$(probe "CONTROL-pre-suspend" 100 checker)
if [ "${D0:-0}" -le 0 ]; then
	log "ABORT: control probe painted $D0 frames pre-suspend; instrument is dead, not the resume"
	exit 1
fi
log "CONTROL PASS: instrument paints ($D0 frames) before any suspend"

# explicit blank -> deterministic blanked-CRTC precondition
echo 4 > /sys/class/graphics/fb0/blank
sleep 2
drmstate blanked
log "post-blank: crtc_active=$(crtc_active) irq=$(irq) fb0.blank=$(cat /sys/class/graphics/fb0/blank)"

echo "" > /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null
log "gadget UDC blanked: [$(cat /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null)]"

dmesg > "$E/dmesg-pre.txt"
IRQ_PRE=$(irq)

echo 0 > /sys/class/rtc/rtc0/wakealarm
NOW=$(cat /sys/class/rtc/rtc0/since_epoch)
echo $((NOW + 45)) > /sys/class/rtc/rtc0/wakealarm
log "alarm armed=$(cat /sys/class/rtc/rtc0/wakealarm) now=$NOW (+45s absolute epoch)"

# ---------------- RUNG 2: the real s2idle ----------------
log "--- RUNG 2 entering s2idle"
sync
S0=$(date +%s)
echo mem > /sys/power/state 2>> "$E/rung2.err"; rc2=$?
S1=$(date +%s)

# FIRST ACTION ON RESUME -- before anything touches the display.
snap post-resume
IRQ_POST=$(irq)
log "RESUMED rc=$rc2 asleep=$((S1-S0))s irq $IRQ_PRE -> $IRQ_POST"
log "post-resume: fb0.state=$(fbstate) crtc_active=$(crtc_active)"
dmesg > "$E/dmesg-post.txt"
drmstate post-resume

# ---------------- acceptance: does an fb write paint? ----------------
# One row = 7488 bytes (1872 x 4).  A 100-row black band at row 400.

# THE DISCRIMINATOR.  A is the historical black probe -- the exact
# content a stale/zeroed comparison baseline swallows silently.  B is
# distinctive at the same blank state.  If A=0 and B>0, drop-on-match is
# confirmed and something still leaves a stale baseline; if both paint,
# the 2026-08-02 damage-baseline fix closed it; if both are 0, there is a
# further cause and we have genuinely new information.
D1=$(probe "A-blanked-BLACK" 400 black)
D1b=$(probe "A2-blanked-CHECKER" 560 checker)
snap post-probeA

# now unblank and retry -- with the reader stopped, DRM master is free,
# so this unblank is not silently refused (G3 open).
echo 0 > /sys/class/graphics/fb0/blank
sleep 3
drmstate unblanked
log "post-unblank: crtc_active=$(crtc_active) irq=$(irq)"
snap post-unblank

D2=$(probe "B-unblanked-BLACK" 700 black)
D2b=$(probe "B2-unblanked-CHECKER" 860 checker)
snap post-probeB

sh /tmp/pm-ground-truth.sh > "$E/gt-post.txt" 2>&1
log "VERDICT control=$D0 | blanked black=$D1 checker=$D1b | unblanked black=$D2 checker=$D2b"
if [ "${D2:-0}" -gt 0 ] || [ "${D2b:-0}" -gt 0 ]; then
	log "ACCEPTANCE: post-resume fb writes DO paint (delta>0)"
else
	log "ACCEPTANCE FAIL: post-resume fb writes still produce no frames"
fi
exit 0
