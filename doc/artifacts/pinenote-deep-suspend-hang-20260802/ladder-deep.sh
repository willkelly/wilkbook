#!/bin/sh
# Rung 3: platform `deep` suspend on the os2 reader image.
#
# Precedent: deep is hardware-proven on THIS device via the os1 oracle
# (2026-08-01) -- rc=0, panel worked on glass, PG 0x00->0xfa proving the
# rails genuinely cycled, VCOM 0x8f surviving a real SLEEP reset.  So
# bl31, DDR retention and the rail path are known good; what is untested
# is our stack across deep.  Operator-authorised override of the
# "rung 2 must pass acceptance first" rule.
#
# Deep also triggers the TPS65185 SLEEP register reset, so this is the
# FIRST hardware exercise of the forward-port's tps65185 PM restoration.
# Acceptance for that: VCOM (03) must still read 8f afterwards.
set -u
E=/tmp/ladder-deep
rm -rf $E; mkdir -p $E
LOG=$E/ladder.log
LJ=/gnu/store/rgi66d06i9m8fk4whk5nbhqrl55la1d0-koreader-bin-2026.03/lib/koreader/luajit

log() { echo "[$(date -u +%H:%M:%S)] $*" >> "$LOG"; }
irq() { awk '/ebc/{s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s; exit}' /proc/interrupts; }
snap() { sh /tmp/fb-damage-gates.sh > "$E/gates-$1.txt" 2>&1; }
drmstate() { cat /sys/kernel/debug/dri/0/state > "$E/drm-$1.txt" 2>&1; }
crtc_active() { awk '/^crtc\[/{c=1} c&&/^\tactive=/{print substr($0,9); exit}' /sys/kernel/debug/dri/0/state; }
fbstate() { cat /sys/class/graphics/fb0/state 2>/dev/null; }
tps() { cat /sys/kernel/debug/regmap/3-0068/registers 2>/dev/null; }

probe() {
	b=$(irq)
	$LJ /tmp/mmap-probe.lua fsync $2 >> "$LOG" 2>&1
	a=$(irq)
	log "PROBE $1: irq $b -> $a (delta $((a-b)))"
	echo "$((a-b))"
}

restore() {
	log "--- RESTORE"
	echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null
	echo fcc00000.usb > /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null
	herd start reader-session >> "$LOG" 2>&1
	sleep 6
	log "restore: irq=$(irq) fb0.state=$(fbstate) reader=$(herd status reader-session 2>/dev/null | head -1)"
	echo none > /sys/power/pm_test 2>/dev/null
	echo s2idle > /sys/power/mem_sleep 2>/dev/null
	log "mem_sleep left at: $(cat /sys/power/mem_sleep)"
	log "=== DEEP LADDER END ==="
	echo DONE > $E/COMPLETE
}
trap restore EXIT HUP INT TERM

log "=== DEEP LADDER START ==="
log "system=$(readlink -f /run/current-system) root=$(findmnt -no SOURCE /)"

echo deep > /sys/power/mem_sleep
log "mem_sleep: $(cat /sys/power/mem_sleep)"
case "$(cat /sys/power/mem_sleep)" in
*"[deep]"*) ;;
*) log "ABORT: could not select deep"; exit 1 ;;
esac

log "--- prep"
herd stop reader-session >> "$LOG" 2>&1
sleep 3
echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
sleep 1
snap pre; drmstate pre
tps > "$E/tps-pre.txt"
sh /tmp/pm-ground-truth.sh > "$E/gt-pre.txt" 2>&1
log "pre: irq=$(irq) fb0.state=$(fbstate) crtc_active=$(crtc_active) VCOM=$(awk '/^03:/{print $2}' $E/tps-pre.txt)"

# CONTROL: the instrument must be proven to paint before we suspend.
D0=$(probe "CONTROL-pre-suspend" 100)
if [ "${D0:-0}" -le 0 ]; then
	log "ABORT: control painted $D0 pre-suspend; dead instrument, not a dead resume"
	exit 1
fi
log "CONTROL PASS: $D0 frames before any suspend"

echo 4 > /sys/class/graphics/fb0/blank
sleep 2
drmstate blanked
log "post-blank: crtc_active=$(crtc_active) irq=$(irq)"

echo "" > /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null
log "gadget UDC blanked: [$(cat /sys/kernel/config/usb_gadget/pinenote-acm/UDC 2>/dev/null)]"

dmesg > "$E/dmesg-pre.txt"
IRQ_PRE=$(irq)

echo 0 > /sys/class/rtc/rtc0/wakealarm
NOW=$(cat /sys/class/rtc/rtc0/since_epoch)
echo $((NOW + 60)) > /sys/class/rtc/rtc0/wakealarm
log "alarm armed=$(cat /sys/class/rtc/rtc0/wakealarm) now=$NOW (+60s absolute epoch)"

log "--- RUNG 3: echo mem > /sys/power/state  (mode=deep)"
sync
S0=$(date +%s)
echo mem > /sys/power/state 2>> "$E/rung3.err"; rc=$?
S1=$(date +%s)

# FIRST ACTION ON RESUME.
snap post-resume
IRQ_POST=$(irq)
tps > "$E/tps-post.txt"
log "RESUMED rc=$rc asleep=$((S1-S0))s irq $IRQ_PRE -> $IRQ_POST"
log "post-resume: fb0.state=$(fbstate) crtc_active=$(crtc_active) VCOM=$(awk '/^03:/{print $2}' $E/tps-post.txt)"
dmesg > "$E/dmesg-post.txt"
drmstate post-resume

D1=$(probe "A-blanked" 400)
echo 0 > /sys/class/graphics/fb0/blank
sleep 3
drmstate unblanked
log "post-unblank: crtc_active=$(crtc_active)"
snap post-unblank
D2=$(probe "B-unblanked" 700)

# Discriminator: the GLOBAL_REFRESH ioctl bypasses the fbdev damage path
# entirely.  If this paints while the probes do not, ctx and hardware are
# healthy and the defect is damage delivery, not the context.
b=$(irq)
pinenote-ebc-refresh >> "$LOG" 2>&1 || log "global refresh returned nonzero"
sleep 4
a=$(irq)
log "PROBE C-global-refresh-ioctl: irq $b -> $a (delta $((a-b)))"
D3=$((a-b))
snap post-global

D4=$(probe "D-after-global-refresh" 1000)

sh /tmp/pm-ground-truth.sh > "$E/gt-post.txt" 2>&1
log "VERDICT control=$D0 A(blanked)=$D1 B(unblanked)=$D2 C(ioctl)=$D3 D(after-ioctl)=$D4"
log "TPS VCOM pre=$(awk '/^03:/{print $2}' $E/tps-pre.txt) post=$(awk '/^03:/{print $2}' $E/tps-post.txt) (8f required)"
if diff -q "$E/tps-pre.txt" "$E/tps-post.txt" >/dev/null; then
	log "TPS: all registers identical across deep"
else
	log "TPS: registers CHANGED across deep:"
	diff "$E/tps-pre.txt" "$E/tps-post.txt" >> "$LOG" 2>&1
fi
exit 0
