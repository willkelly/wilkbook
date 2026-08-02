#!/bin/sh
# fb-damage-gates.sh -- read-only dump of every gate between a userspace
# framebuffer write and an EBC frame.  Device-side; run over SSH.
#
# Why this exists: the 2026-08-01 post-resume dead-write window was
# diagnosed with a *ladder* of write probes, each of which could only say
# "still no frames".  Every gate on that path fails **silently and
# successfully** -- the write returns the byte count, fsync returns 0,
# FBIOBLANK returns 0, and the kernel logs nothing.  A probe ladder can
# therefore never name the gate; only reading the gates can.  Run this
# once after resume and the answer is in the output.
#
# The four gates, in submission order (7.0.11 sources):
#
#   G1  drm_fb_helper_damage_work()            drm_fb_helper.c:271
#       returns before drm_fb_helper_fb_dirty() while
#       info->state != FBINFO_STATE_RUNNING.  Damage is not lost, it
#       accumulates in helper->damage_clip and is never flushed.
#       Reported below as fb0.state.
#
#   G2  drm_atomic_helper_dirtyfb()            drm_damage_helper.c
#       skips every plane whose plane->state->fb != the fbdev fb, then
#       commits the resulting state.  With no plane matched that is an
#       *empty* commit: it returns 0 and touches nothing.
#       Reported below as the plane fb= / crtc active= lines.
#
#   G3  drm_master_internal_acquire()          drm_auth.c
#       returns false while any process holds DRM master, so
#       drm_client_modeset_commit() and drm_client_modeset_dpms() return
#       -EBUSY -- and drm_fb_helper_blank()/drm_fb_helper_set_par()
#       discard that error and return 0.  So an FBIOBLANK unblank or a
#       set_par "succeeds" while doing nothing at all.  The first opener
#       of /dev/dri/card0 becomes master (drm_master_open()), which
#       includes our own diagnostics -- so this script never opens the
#       node, it only looks for openers.
#
#   G4  fbcon binding                          fbcon.c:2653
#       fbcon_resumed() -> update_screen() is what normally repaints
#       (and thus re-submits damage) after an un-suspend.  With fbcon
#       unbound -- our reader configuration -- nothing does.
#
# Read-only: opens no device node, writes nothing, changes no state.
set -eu

say() { printf '%s\n' "$*"; }
hdr() { say ""; say "== $*"; }

fb=${FB:-/sys/class/graphics/fb0}
dbg=/sys/kernel/debug/dri

read_or() {
	if [ -r "$1" ]; then cat -- "$1" 2>/dev/null || say "(unreadable)"
	else say "(absent)"; fi
}

hdr "G1  fbdev state (0=RUNNING 1=SUSPENDED)"
st=$(cat "$fb/state" 2>/dev/null || echo "?")
case $st in
0) say "fb0.state = 0  RUNNING              -- G1 open" ;;
1) say "fb0.state = 1  SUSPENDED            -- G1 CLOSED: damage_work drops every submission" ;;
*) say "fb0.state = $st (unreadable)" ;;
esac

hdr "G3  DRM master holders (no node is opened by this script)"
# Only primary nodes matter: render nodes can never take master
# (drm_master_open() is reached only for drm_is_primary_client()).
# One line per (pid, node); a process holding several fds on the same
# node is still just one opener.
found=$(
	for fdd in /proc/[0-9]*/fd; do
		pid=${fdd%/fd}; pid=${pid#/proc/}
		for fd in "$fdd"/*; do
			[ -e "$fd" ] || continue
			tgt=$(readlink "$fd" 2>/dev/null) || continue
			case $tgt in
			/dev/dri/card*)
				comm=$(tr -d '\0' < "/proc/$pid/comm" 2>/dev/null || echo '?')
				say "pid $pid ($comm) holds $tgt" ;;
			esac
		done
	done | sort -u
)
if [ -n "$found" ]; then
	say "$found"
	say "G3 CLOSED if any of the above is master: the earliest opener took"
	say "master, and fbdev set_par/blank then silently no-op."
else
	say "no process holds a DRM primary node -- G3 open (fbdev modesets can commit)"
fi
if [ -r "$dbg" ]; then
	for d in "$dbg"/*/clients; do
		[ -r "$d" ] || continue
		say "-- $d"; read_or "$d"
	done
fi

hdr "G2  atomic state: which plane owns which fb, and is the CRTC active"
shown=0
for d in "$dbg"/*/state; do
	[ -r "$d" ] || continue
	shown=1
	say "-- $d"
	awk '
	/^crtc\[/   { obj=$0; incrtc=1; inplane=0; print; next }
	/^plane\[/  { obj=$0; inplane=1; incrtc=0; print; next }
	incrtc  && /^\t(enable|active)=/ { print; next }
	inplane && /^\t(crtc|fb)=/       { print; next }
	' "$d"
done
[ "$shown" -eq 0 ] && say "(dri debugfs absent -- mount debugfs to read G2)"
say ""
say "G2 is CLOSED when the primary plane shows fb=0 or crtc=(null):"
say "drm_atomic_helper_dirtyfb() then commits an empty state and returns 0."
for d in "$dbg"/*/framebuffer; do
	[ -r "$d" ] || continue
	say "-- $d"; read_or "$d"
done

hdr "G4  fbcon binding (the thing that normally repaints after un-suspend)"
for v in /sys/class/vtconsole/*; do
	[ -d "$v" ] || continue
	n=$(cat "$v/name" 2>/dev/null || echo '?')
	b=$(cat "$v/bind" 2>/dev/null || echo '?')
	say "$(basename "$v"): bind=$b  name=$n"
done
say "bind=0 for the frame buffer device means nothing regenerates damage"
say "after fb_set_suspend(0); the reader image runs this way by design."

hdr "supporting counters"
say "defio_delay_ms = $(cat /sys/module/rockchip_ebc/parameters/defio_delay_ms 2>/dev/null || echo '(absent)')"
say "EBC IRQs       = $(awk '/ebc/ {s=0; for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s; exit}' /proc/interrupts 2>/dev/null || echo '(none)')"
for t in /proc/[0-9]*/comm; do
	c=$(tr -d '\0' < "$t" 2>/dev/null || true)
	case $c in
	*ebc*) p=${t%/comm}; say "$c ($(basename "$p")) state=$(awk '/^State:/{print $2,$3}' "$p/status" 2>/dev/null)" ;;
	esac
done

say ""
say "Reading order: G1 first (one bit, decisive), then G3 (an open card0"
say "invalidates any conclusion drawn from an unblank or a set_par), then"
say "G2, then G4.  G3 must be checked before trusting a recovery attempt."
