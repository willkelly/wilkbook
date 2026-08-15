#!/bin/sh
# QEMU-virt page-turn / menu campaign (offline testing ladder rung 4v).
#
# Purpose: the offline reproduction attempt for GitHub issue #14
# ("occasional two-step page turns" — repeated full-panel refreshes
# 131 ms to ~1 s apart).  The issue's own re-analysis established that
#
#   * the events are RUNS, not pairs (largest: 8 refreshes in 2.26 s),
#   * the gap distribution is a CONTINUUM — no valley at 1 s, so any
#     fixed "sub-second" cut is arbitrary and a SWEEP must be reported,
#   * 4 of 5 episodes start within 15 s of BOTH a flashui/global wash
#     and a full-panel ui/partial repaint — the menu open/dismiss
#     signature (base rate 7.2 %, P(>=4 of 5) ~ 1e-4),
#
# so a plain page-turn loop would probably miss the antecedent that four
# of the five episodes share.  This harness therefore drives page turns
# AND interleaves menu open/dismiss cycles, at several cadences, then
# extracts the guest's own [pn-refresh] traces and hands them to
# pinenote/tools/refresh-episodes/refresh-episodes.py — the same
# signature logic the issue analysis used.
#
# It reuses the rung-4v boot verbatim (run-virt-visual.sh): real
# kernel/initrd/rootfs, virtio-gpu at panel resolution, virtio
# tablet/keyboard, wilkbook.force_device=pinenote.  Two things are new:
#
#   1. a PERSISTENT QMP driver.  run-virt-visual.sh spawns a fresh guile
#      per QMP command, which costs ~4 s of greeting/capability drain per
#      tap — unusable for a cadence campaign.  This one connects once and
#      executes a whole plan with millisecond pacing, writing a host-side
#      ledger of every action it took.
#   2. a console harvester that logs in as root and cats the
#      [pn-refresh] lines out of /var/log/reader-session.log between
#      sentinels, waiting on the sentinel rather than a fixed pause
#      (the log is thousands of lines).
#
# WHAT THIS CAN AND CANNOT SHOW.  The trace is emitted at the DECISION
# point in device.lua, before dispatch, so it measures exactly what the
# issue measures: how many times KOReader ASKED for a refresh, and when.
# That is a userspace-side question and it is faithful here.  What is
# NOT faithful: there is no EBC.  virtio-gpu absorbs a full-panel blit
# in microseconds where the panel takes ~300 ms, so any part of the
# mechanism that depends on e-ink service time — and the issue's 131 ms
# floor argues the second repaint is waiting on the previous pass —
# cannot reproduce here.  Absence of episodes offline is therefore weak
# evidence; presence is strong.
#
# Usage:
#   run-virt-pageturn-campaign.sh BOOT_BUNDLE_DIRECTORY DISK_IMAGE [OUT_DIR]
#
# Environment:
#   CAMPAIGN_PLAN=<file>     use this plan instead of the generated one
#   CAMPAIGN_TURNS=<n>       page turns in the generated plan (default 160)
#   CAMPAIGN_MENU_EVERY=<n>  menu open/dismiss cycle every n turns (default 8)
#   CAMPAIGN_HOLD_MS=<n>     tap contact duration (default 80)
#   CAMPAIGN_PROBE=1         run the short coordinate-probe plan and stop
#   VIRT_VISUAL_LOGIN_WAIT / _PAINT_WAIT  as run-virt-visual.sh
set -eu

: "${VIRT_VISUAL_LOGIN_WAIT:=180}"
: "${VIRT_VISUAL_PAINT_WAIT:=330}"
: "${CAMPAIGN_TURNS:=160}"
: "${CAMPAIGN_MENU_EVERY:=8}"
: "${CAMPAIGN_HOLD_MS:=80}"
: "${CAMPAIGN_PROBE:=0}"
: "${CAMPAIGN_HARVEST_WAIT:=240}"
# Cadences, in seconds between taps.  BURST is the harness's own floor
# and it sets what the analysis can see: one refresh per tap at cadence C
# already produces gaps at C, so the interesting band is everything BELOW
# the burst cadence.  Lowering the floor buys speed and costs resolution.
: "${CAMPAIGN_STEADY_WAIT:=3.5}"
: "${CAMPAIGN_MODE_WAIT:=1.6}"
: "${CAMPAIGN_BURST_WAIT:=0.9}"

usage() {
  printf 'usage: %s BOOT_BUNDLE_DIRECTORY DISK_IMAGE [OUT_DIR]\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 2; }

bundle=$1
disk=$2
outdir=${3:-}

here=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo_root=$(CDPATH= cd -P "$here/../../.." && pwd -P)
analyzer=$repo_root/pinenote/tools/refresh-episodes/refresh-episodes.py

command -v qemu-system-aarch64 >/dev/null 2>&1 || \
  fail "qemu-system-aarch64 not found; run via: guix shell qemu -- $0 ..."
command -v guile >/dev/null 2>&1 || fail "guile not found"

kernel=$bundle/extlinux/Image
initrd=$bundle/extlinux/initrd.cpio.gz
config=$bundle/extlinux/extlinux.conf
[ -f "$kernel" ] || fail "bundle is missing extlinux/Image: $bundle"
[ -f "$initrd" ] || fail "bundle is missing extlinux/initrd.cpio.gz: $bundle"
[ -f "$config" ] || fail "bundle is missing extlinux/extlinux.conf: $bundle"
[ -f "$disk" ]   || fail "disk image is not a regular file: $disk"

# Write containment: everything this harness produces stays under
# /tmp/opencode, the boundary the other qemu/preflight scripts hard-code.
opencode_root=$(CDPATH= cd -P /tmp/opencode 2>/dev/null && pwd -P) || \
  fail "cannot resolve /tmp/opencode (the write-containment boundary)"
if [ -z "$outdir" ]; then
  outdir=$opencode_root/pinenote-virt-pageturn-$$
fi
mkdir -p "$outdir" || fail "cannot create output dir: $outdir"
outdir=$(CDPATH= cd -P "$outdir" && pwd -P)
case "$outdir/" in
  "$opencode_root"/*) ;;
  *) fail "OUT_DIR must live under $opencode_root (got $outdir)" ;;
esac

log=$outdir/console.log
qmp=$outdir/qmp.sock
sock=$outdir/console.sock
plan=${CAMPAIGN_PLAN:-$outdir/plan.txt}
ledger=$outdir/action-ledger.txt
traces=$outdir/pn-refresh.log
harvest=$outdir/harvest.txt
: > "$log" || fail "cannot write console log: $log"

append=$(sed -n 's/^[[:space:]]*APPEND[[:space:]][[:space:]]*//p' "$config" | sed -n '1p')
[ -n "$append" ] || fail "bundle extlinux.conf has no APPEND line"
case " $append " in
  *' gnu.system='*) ;;
  *) fail "APPEND lacks gnu.system=; bundle does not match a Guix rootfs" ;;
esac
append=$(printf '%s' "$append" | sed \
  -e 's/console=ttyS2,1500000n8/console=ttyAMA0/' \
  -e 's/console=tty0 //')
append="$append wilkbook.force_device=pinenote"

# ---------------------------------------------------------------- plan --
# Panel-pixel coordinates in a plan are FRAMEBUFFER coordinates (1872x1404
# on virt).  KOReader renders its 1404x1872 PORTRAIT view rotated into
# that landscape framebuffer, and device.lua's MT-synthesis hook maps
# virtio-tablet events to the RAW framebuffer size — so a plan's
# coordinates are framebuffer coordinates while KOReader's tap zones are
# defined in its own portrait space.  The mapping between them was
# MEASURED by CAMPAIGN_PROBE=1 (3x3 grid + screendumps + trace
# correlation), not assumed:
#
#     logical_x = 1403 - fb_y        fb_y = 1403 - logical_x
#     logical_y = fb_x               fb_x = logical_y
#
# which puts KOReader's default zones (defaults.lua) at:
#
#   top menu    logical y < H/8        ->  fb_x <  234   (left edge)
#   bottom cfg  logical y >= 7H/8      ->  fb_x >= 1638  (right edge)
#   forward     logical x >= W/4       ->  fb_y <= 1052
#   backward    logical x <  W/4       ->  fb_y >  1052
#
# One trap the probe caught: the top-RIGHT corner of the logical page is
# KOReader's bookmark/dogear zone and it OVERRIDES the menu zone there.
# fb(160,120) — which looks like a fine menu tap — only toggles the
# dogear and repaints 44x44 plus the footer.  The menu tap has to sit at
# a logical x near the middle, i.e. fb_y near 700.
FB_W=1872
FB_H=1404
# Measured zone points (framebuffer coordinates), all confirmed by
# screendump AND by the trace they produce:
#   FWD  -> partial/partial 0,0,1404,1872   (a full-panel page turn)
#   BACK -> partial/partial 0,0,1404,1872
#   MENU -> flashui/global -28,0,1460,1872  (the full-panel wash)
Z_FWD_X=936;  Z_FWD_Y=300
Z_BACK_X=936; Z_BACK_Y=1250
Z_MENU_X=150; Z_MENU_Y=700

if [ "$CAMPAIGN_PROBE" = 1 ] && [ -z "${CAMPAIGN_PLAN:-}" ]; then
  # 3x3 grid of the framebuffer, generously spaced, each preceded by a
  # MARK so the trace stream can be cut at the taps.  Nothing is assumed
  # about which framebuffer edge is KOReader's "top".
  {
    printf '# coordinate probe: 3x3 framebuffer grid\n'
    printf 'WAIT 3\n'
    printf 'DUMP %s/probe-00-baseline.ppm\n' "$outdir"
    i=0
    for fy in 120 702 1290; do
      for fx in 160 936 1720; do
        i=$((i + 1))
        printf 'MARK probe-%s-%s\n' "$fx" "$fy"
        printf 'TAP %s %s\n' "$fx" "$fy"
        printf 'WAIT 5\n'
        printf 'DUMP %s/probe-%02d-%s-%s.ppm\n' "$outdir" "$i" "$fx" "$fy"
        # return to a known state: whatever the tap opened, a second tap
        # in the same place either closes it or is a no-op, and the probe
        # only has to attribute ONE effect per grid cell
        printf 'MARK probe-reset-%s-%s\n' "$fx" "$fy"
        printf 'TAP %s %s\n' "$fx" "$fy"
        printf 'WAIT 4\n'
      done
    done
  } > "$plan"
elif [ -z "${CAMPAIGN_PLAN:-}" ]; then
  # The campaign proper.  Three ingredients, mixed:
  #
  #  * steady reading — forward taps at ~3.5 s, between the field log's
  #    median (8.9 s) and its 1.5-2.0 s mode;
  #  * fast flipping — 1.6 s (the field mode) and 0.9 s.  0.9 s is the
  #    FLOOR on purpose: one refresh per tap at 0.9 s cadence already
  #    manufactures sub-second gaps, so tapping any faster would fill
  #    the interesting band with harness artefacts and make the sweep
  #    unreadable.  With this floor, any gap below ~0.85 s cannot be
  #    explained by one-refresh-per-tap and is a genuine anomaly;
  #  * menu open/dismiss cycles — the antecedent 4 of the 5 field
  #    episodes share.  Open the menu, let it settle, dismiss it, then
  #    IMMEDIATELY flip fast: that is the field sequencing (the wash
  #    precedes the run of repeated refreshes, it does not follow it).
  #
  # SHUTTLE, not a straight run.  The image's only book is KOReader's
  # 11-page quickstart guide.  200 forward taps would spend 190 of them
  # parked on the last page — no repaint, no trace, and an
  # end-of-document dialog in the way.  So the plan tracks a page cursor
  # and reverses inside a safe band, which keeps EVERY tap a real
  # full-panel repaint.  The dismiss tap is deliberately placed in the
  # BACKWARD zone so that when no menu happens to be open it is still a
  # page turn the cursor can account for, instead of silent drift.
  #
  # Tap positions are jittered by +-40 px.  Not cosmetic: two taps at
  # identical coordinates inside GestureDetector's double-tap window are
  # a DOUBLE TAP, not two page turns, and the fast bursts sit inside
  # that window.  Jitter separates them without touching any KOReader
  # default — this harness changes no defaults, which is the whole point
  # of using it to reason about the shipped configuration.
  awk -v turns="$CAMPAIGN_TURNS" -v every="$CAMPAIGN_MENU_EVERY" \
      -v fx="$Z_FWD_X" -v fy="$Z_FWD_Y" \
      -v bx="$Z_BACK_X" -v by="$Z_BACK_Y" \
      -v mx="$Z_MENU_X" -v my="$Z_MENU_Y" '
    function jitter() { seed = (seed * 1103515245 + 12345) % 2147483648
                        return int((seed / 2147483648.0) * 80) - 40 }
    # one page turn in the current shuttle direction, then reverse at
    # the band edges (the book is 11 pages; 2..8 never reaches either end)
    function turn(label, wait) {
      if (dir > 0 && page >= 8) dir = -1
      else if (dir < 0 && page <= 2) dir = 1
      if (dir > 0) { printf "MARK %s-fwd\n", label
                     printf "TAP %d %d\n", fx + jitter(), fy + jitter() }
      else         { printf "MARK %s-back\n", label
                     printf "TAP %d %d\n", bx + jitter(), by + jitter() }
      page += dir
      printf "WAIT %s\n", wait
    }
    BEGIN {
      seed = 20260814; page = 1; dir = 1
      print "# page-turn / menu campaign (issue #14 offline reproduction)"
      print "WAIT 5"
      print "MARK campaign-begin"
      n = 0
      while (n < turns) {
        if (every > 0 && n > 0 && n % every == 0) {
          # --- menu open, settle, dismiss, then flip fast ---
          printf "MARK menu-open\n"
          printf "TAP %d %d\n", mx + jitter(), my + jitter()
          printf "WAIT 3.0\n"
          printf "MARK menu-dismiss\n"
          printf "TAP %d %d\n", bx + jitter(), by + jitter()
          if (page > 2) page -= 1        # the dismiss tap may also turn back
          printf "WAIT 1.0\n"
          for (b = 0; b < 4 && n < turns; b++) { turn("postmenu", "0.9"); n++ }
          continue
        }
        # --- steady reading, with a mode-speed burst every 5th turn ---
        turn("steady", (n % 5 == 4) ? "1.6" : "3.5")
        n++
      }
      print "MARK campaign-end"
      print "WAIT 6"
    }' > "$plan"
fi
[ -s "$plan" ] || fail "campaign plan is empty: $plan"

printf 'qemu-virt page-turn campaign: booting (out -> %s)\n' "$outdir"
printf '  plan: %s (%s actions)\n' "$plan" "$(grep -c '^TAP' "$plan" || true)"

rm -f "$sock" "$qmp"
qemu-system-aarch64 \
  -M virt -cpu max -smp 4 -m 2048 \
  -display none -no-reboot \
  -device virtio-gpu-pci,xres=1872,yres=1404 \
  -device virtio-tablet-pci \
  -device virtio-keyboard-pci \
  -qmp "unix:$qmp,server=on,wait=off" \
  -chardev "socket,id=con0,path=$sock,server=on,wait=off,logfile=$log" \
  -serial chardev:con0 \
  -monitor none \
  -kernel "$kernel" \
  -initrd "$initrd" \
  -append "$append" \
  -drive if=virtio,format=raw,file="$disk" \
  2> "$outdir/qemu-stderr.log" &
qemu_pid=$!
start_time=$(date +%s)

elapsed() { echo $(( $(date +%s) - start_time )); }

kill_qemu() {
  kill "$qemu_pid" 2>/dev/null || true
  i=0
  while kill -0 "$qemu_pid" 2>/dev/null; do
    [ "$i" -ge 5 ] && { kill -9 "$qemu_pid" 2>/dev/null || true; break; }
    sleep 1; i=$((i + 1))
  done
}
trap kill_qemu EXIT

# ------------------------------------------------- persistent QMP driver --
# One connection for the whole plan.  run-virt-visual.sh's one-shot driver
# pays ~4 s of greeting/capability drain per command; at 160 taps that is
# ten minutes of pure overhead and no cadence control at all.  This one
# connects once, then walks the plan with usleep pacing, appending a
# host-clock ledger line per action so the trace stream can be aligned to
# what the harness actually did.
#
# It drains continuously for the same reason run-virt-assertions.sh's
# console driver does: while a client is connected qemu applies
# backpressure for it, and an unread socket eventually wedges qemu.
qmp_driver=$outdir/qmp-driver.scm
cat > "$qmp_driver" <<'EOF'
(use-modules (rnrs bytevectors) (ice-9 rdelim) (ice-9 format))
(sigaction SIGPIPE SIG_IGN)

(define args      (cdr (command-line)))
(define sock-path (list-ref args 0))
(define plan-path (list-ref args 1))
(define ledger    (list-ref args 2))
(define fb-w      (string->number (list-ref args 3)))
(define fb-h      (string->number (list-ref args 4)))
(define hold-ms   (string->number (list-ref args 5)))

(define s   (socket PF_UNIX SOCK_STREAM 0))
(define buf (make-bytevector 65536))
(define lp  (open-output-file ledger))

(define (now)
  (let ((tv (gettimeofday)))
    (+ (car tv) (/ (cdr tv) 1000000.0))))

(define (drain)
  (let loop ()
    (let ((n (catch 'system-error
               (lambda () (recv! s buf MSG_DONTWAIT))
               (lambda _ 0))))
      (when (> n 0) (loop)))))

;; sleep in 10 ms slices so the socket never sits unread
(define (nap seconds)
  (let loop ((left (inexact->exact (round (* seconds 100)))))
    (when (> left 0) (drain) (usleep 10000) (loop (- left 1)))))

(define (note action detail)
  (format lp "~,6f ~a ~a\n" (now) action detail)
  (force-output lp))

(define (send! json)
  (display json s) (display "\r\n" s) (force-output s) (drain))

;; QMP wants absolute axes in 0..32767 whatever the guest resolution is.
(define (qx x) (inexact->exact (round (/ (* x 32767) fb-w))))
(define (qy y) (inexact->exact (round (/ (* y 32767) fb-h))))

(define (tap x y)
  (note "TAP-DOWN" (format #f "~a,~a" x y))
  (send! (format #f "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":~a}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":~a}},{\"type\":\"btn\",\"data\":{\"down\":true,\"button\":\"left\"}}]}}"
                 (qx x) (qy y)))
  (nap (/ hold-ms 1000.0))
  (send! "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"btn\",\"data\":{\"down\":false,\"button\":\"left\"}}]}}")
  (note "TAP-UP" (format #f "~a,~a" x y)))

(define (key qcode)
  (note "KEY" qcode)
  (send! (format #f "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"key\",\"data\":{\"down\":true,\"key\":{\"type\":\"qcode\",\"data\":\"~a\"}}}]}}" qcode))
  (nap (/ hold-ms 1000.0))
  (send! (format #f "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"key\",\"data\":{\"down\":false,\"key\":{\"type\":\"qcode\",\"data\":\"~a\"}}}]}}" qcode)))

(connect s AF_UNIX sock-path)
(nap 1)                                             ;greeting
(send! "{\"execute\":\"qmp_capabilities\"}")
(nap 1)
(note "PLAN-BEGIN" plan-path)

(let ((pp (open-input-file plan-path)))
  (let loop ()
    (let ((line (read-line pp)))
      (unless (eof-object? line)
        (let* ((trimmed (string-trim-both line))
               (parts   (filter (lambda (t) (> (string-length t) 0))
                                (string-split trimmed #\space))))
          (unless (or (null? parts)
                      (char=? (string-ref trimmed 0) #\#))
            (let ((verb (car parts)))
              (cond
               ((string=? verb "TAP")
                (tap (string->number (list-ref parts 1))
                     (string->number (list-ref parts 2))))
               ((string=? verb "KEY")  (key (list-ref parts 1)))
               ((string=? verb "WAIT") (nap (string->number (list-ref parts 1))))
               ((string=? verb "MARK") (note "MARK" (list-ref parts 1)))
               ((string=? verb "DUMP")
                (note "DUMP" (list-ref parts 1))
                (send! (format #f "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"~a\"}}"
                               (list-ref parts 1)))
                (nap 2))
               (else (note "UNKNOWN-VERB" verb))))))
        (loop)))))

(note "PLAN-END" "-")
(nap 0.5)
(close-port s)
(close-port lp)
EOF

# ----------------------------------------------------- console harvester --
# Logs in as root and cats the guest's own [pn-refresh] traces out to the
# console between sentinels.  Unlike run-virt-assertions.sh's probe this
# WAITS ON THE END SENTINEL rather than a fixed pause: the trace stream is
# thousands of lines and a 3 s pause would truncate it mid-dump.  Received
# bytes are also written straight to a capture file, so the harvest does
# not have to be recovered from the console log's kernel-splat noise.
harvest_scm=$outdir/harvest.scm
cat > "$harvest_scm" <<'EOF'
(use-modules (rnrs bytevectors) (ice-9 format) (srfi srfi-13))
(sigaction SIGPIPE SIG_IGN)

(define args    (cdr (command-line)))
(define path    (list-ref args 0))
(define capture (list-ref args 1))
(define timeout (string->number (list-ref args 2)))
(define lines   (list-tail args 3))

(define s   (socket PF_UNIX SOCK_STREAM 0))
(define buf (make-bytevector 65536))
(define cp  (open-output-file capture))
(define seen "")

;; Bytes are decoded latin-1 style, one char per byte, NOT as UTF-8: the
;; socket hands us arbitrary chunk boundaries, and a book title in the
;; log splits a multi-byte sequence sooner or later.  utf8->string throws
;; on that and takes the whole harvest down; the sentinel search only
;; ever looks at ASCII, so byte==char is both safe and sufficient.
(define (bytes->string bv n)
  (let ((out (make-string n)))
    (let loop ((i 0))
      (if (>= i n) out
          (begin (string-set! out i (integer->char (bytevector-u8-ref bv i)))
                 (loop (+ i 1)))))))

(define (drain)
  (let loop ()
    (let ((n (catch 'system-error
               (lambda () (recv! s buf MSG_DONTWAIT))
               (lambda _ 0))))
      (when (> n 0)
        (let ((chunk (bytes->string buf n)))
          (display chunk cp) (force-output cp)
          ;; keep only a tail: the sentinel search never needs more
          (set! seen (string-append seen chunk))
          (when (> (string-length seen) 8192)
            (set! seen (substring seen (- (string-length seen) 4096)))))
        (loop)))))

(define (nap seconds)
  (let loop ((left (inexact->exact (round (* seconds 20)))))
    (when (> left 0) (drain) (usleep 50000) (loop (- left 1)))))

;; Bytes are paced ~2 ms apart: the guest PL011 has a 16-byte FIFO and a
;; blasted line loses everything past byte 16 when the guest is busy
;; (run-virt-assertions.sh learned this the expensive way).
(define (send-slow str)
  (string-for-each (lambda (c)
                     (display c s) (force-output s) (drain) (usleep 2000))
                   str))

(define (ctrl-c)
  (display (string (integer->char 3)) s) (force-output s) (nap 0.4))

;; On a match, stamp the HOST clock into the capture.  The guest-host
;; offset has to be measured at the moment the guest's own clock line
;; arrives: sampling the host clock before this driver starts charges
;; the whole console login (~8 s) to the offset and silently mis-aligns
;; every ledger correlation by that much.
(define (wait-for token limit)
  (let loop ((waited 0))
    (drain)
    (cond ((string-contains seen token)
           (let ((tv (gettimeofday)))
             (format cp "\nWBCAMP-HOSTAT ~a ~,6f\n" token
                     (+ (car tv) (/ (cdr tv) 1000000.0)))
             (force-output cp))
           #t)
          ((>= waited limit) #f)
          (else (usleep 100000) (loop (+ waited 0.1))))))

(connect s AF_UNIX path)
(send-slow "\r\n") (nap 0.8)
(ctrl-c)
(send-slow "root\r\n") (nap 6)
(for-each
 (lambda (spec)
   ;; spec is "SENTINEL<TAB>command"
   (let* ((tab (string-index spec #\tab))
          (sentinel (substring spec 0 tab))
          (cmd      (substring spec (+ tab 1))))
     (ctrl-c)
     (set! seen "")
     (send-slow cmd) (send-slow "\r\n")
     (unless (wait-for sentinel timeout)
       (format (current-error-port) "harvest: timed out waiting for ~a\n" sentinel))))
 lines)
(ctrl-c)
(send-slow "exit\r\n") (nap 1)
(close-port s)
(close-port cp)
EOF

# PPM uniformity check, same as run-virt-visual.sh.
ppm_check_scm=$outdir/ppm-check.scm
cat > "$ppm_check_scm" <<'EOF'
(use-modules (rnrs bytevectors) (ice-9 binary-ports))
(define file (cadr (command-line)))
(define port (open-input-file file #:binary #t))
(define (read-token)
  (let loop ((chars '()))
    (let ((b (get-u8 port)))
      (cond ((eof-object? b) (list->string (reverse chars)))
            ((memv b '(32 9 10 13))
             (if (null? chars) (loop chars) (list->string (reverse chars))))
            (else (loop (cons (integer->char b) chars)))))))
(define magic (read-token))
(define width (string->number (read-token)))
(define height (string->number (read-token)))
(define maxval (string->number (read-token)))
(unless (and (string=? magic "P6") width height) (display "BAD-HEADER\n") (exit 1))
(define data (get-bytevector-all port))
(define len (bytevector-length data))
(define first-r (bytevector-u8-ref data 0))
(define first-g (bytevector-u8-ref data 1))
(define first-b (bytevector-u8-ref data 2))
(define uniform
  (let loop ((i 0))
    (if (>= i len) #t
        (if (and (= (bytevector-u8-ref data i) first-r)
                 (= (bytevector-u8-ref data (+ i 1)) first-g)
                 (= (bytevector-u8-ref data (+ i 2)) first-b))
            (loop (+ i 30000))
            #f))))
(format #t "~ax~a ~a\n" width height (if uniform "UNIFORM" "VARIED"))
EOF

ppm_info() { guile -s "$ppm_check_scm" "$1" 2>/dev/null || echo "BAD"; }

oneshot_scm=$outdir/qmp-oneshot.scm
cat > "$oneshot_scm" <<'EOF'
(use-modules (rnrs bytevectors))
(sigaction SIGPIPE SIG_IGN)
(let* ((path (cadr (command-line)))
       (cmds (cddr (command-line)))
       (s    (socket PF_UNIX SOCK_STREAM 0))
       (buf  (make-bytevector 65536)))
  (define (drain-for seconds)
    (let loop ((left (* seconds 10)))
      (when (> left 0)
        (catch 'system-error (lambda () (recv! s buf MSG_DONTWAIT)) (lambda _ 0))
        (usleep 100000)
        (loop (- left 1)))))
  (connect s AF_UNIX path)
  (drain-for 1)
  (display "{\"execute\":\"qmp_capabilities\"}\r\n" s) (force-output s)
  (drain-for 1)
  (for-each (lambda (c) (display c s) (display "\r\n" s) (force-output s)
                        (drain-for 1))
            cmds)
  (close-port s))
EOF

screendump() {
  guile -s "$oneshot_scm" "$qmp" \
    "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$1\"}}" 2>/dev/null || true
  sleep 2
}

rc=0
require() {
  if [ "$2" = 0 ]; then printf '  PASS  require  %s\n' "$1"
  else printf '  FAIL  require  %s\n' "$1"; rc=1; fi
}

# Phase 1: boot to login prompt.
while kill -0 "$qemu_pid" 2>/dev/null; do
  grep -aq 'login:' "$log" 2>/dev/null && break
  [ "$(elapsed)" -ge "$VIRT_VISUAL_LOGIN_WAIT" ] && break
  sleep 3
done
printf '  login prompt (or wait expired) at %ss\n' "$(elapsed)"

# Phase 2: wait for KOReader to paint.
shot_a=$outdir/shot-pre.ppm
painted=1
while kill -0 "$qemu_pid" 2>/dev/null; do
  screendump "$shot_a"
  info=$(ppm_info "$shot_a")
  case "$info" in "1872x1404 VARIED") painted=0; break ;; esac
  [ "$(elapsed)" -ge "$VIRT_VISUAL_PAINT_WAIT" ] && break
  printf '  (shot at %ss: %s; waiting for KOReader paint)\n' "$(elapsed)" "$info"
  sleep 15
done
printf '  first painted shot at %ss\n' "$(elapsed)"
[ "$painted" = 0 ] || { require 'KOReader painted the fb' "$painted"; kill_qemu; trap - EXIT; exit 1; }

# Phase 3: let the reader settle (two identical consecutive shots), so the
# campaign does not start on top of a still-unfolding first paint.
settle_tries=0
sha_a=$(sha256sum "$shot_a" | cut -d' ' -f1)
while [ "$settle_tries" -lt 6 ]; do
  sleep 8
  screendump "$shot_a"
  sha_a2=$(sha256sum "$shot_a" | cut -d' ' -f1)
  [ "$sha_a" = "$sha_a2" ] && break
  sha_a=$sha_a2
  settle_tries=$((settle_tries + 1))
done
printf '  baseline settled at %ss (%s retries)\n' "$(elapsed)" "$settle_tries"

# Phase 4: run the plan.
campaign_started=$(date +%s.%N)
printf '  campaign starting at %ss\n' "$(elapsed)"
guile -s "$qmp_driver" "$qmp" "$plan" "$ledger" "$FB_W" "$FB_H" "$CAMPAIGN_HOLD_MS" \
  > "$outdir/qmp-driver.out" 2>&1 || printf '  (qmp driver exited non-zero)\n'
printf '  campaign done at %ss\n' "$(elapsed)"

shot_post=$outdir/shot-post.ppm
screendump "$shot_post"

# Phase 5: harvest the guest's traces over the console.
#
# GUEST-CLOCK ALIGNMENT: the traces carry the guest's gettimeofday, the
# ledger carries the host's.  Both are wall clock but the guest boots
# with its own idea of the time, so the guest echoes its clock inside a
# sentinel and the analyzer is told the offset.  A second or two of skew
# is irrelevant to a 15 s antecedent window.
host_clock_at_harvest=$(date +%s.%N)
printf '  harvesting traces over the console...\n'
tab=$(printf '\t')
# EVERY sentinel is assembled in the guest from $s, and the token the
# driver waits for is the ASSEMBLED string.  Spelling a sentinel
# literally in the command makes the shell's own echo of that command
# satisfy the wait instantly — the driver then sends its next Ctrl-C
# straight into the still-running grep and harvests nothing at all.
# (That failure is silent: you get the BEGIN marker and an empty body.)
guile -s "$harvest_scm" "$sock" "$harvest" "$CAMPAIGN_HARVEST_WAIT" \
  "WBCAMP-READY${tab}s=WBCAMP; stty columns 400; echo \$s-READY" \
  "WBCAMP-GUESTCLOCK${tab}s=WBCAMP; echo \$s-GUESTCLOCK \$(date +%s.%N)" \
  "WBCAMP-LOGSTAT${tab}s=WBCAMP; echo \$s-LOGSTAT \$(wc -c < /var/log/reader-session.log 2>/dev/null || echo missing) \$(grep -ac pn-refresh /var/log/reader-session.log 2>/dev/null || echo 0)" \
  "WBCAMP-TRACE-END${tab}s=WBCAMP; echo \$s-TRACE-BEGIN; grep -a pn-refresh /var/log/reader-session.log; echo \$s-TRACE-END" \
  "WBCAMP-WARN-END${tab}s=WBCAMP; echo \$s-WARN-BEGIN; grep -aE 'WARN|ERROR' /var/log/reader-session.log | tail -30; echo \$s-WARN-END" \
  > "$outdir/harvest-driver.out" 2>&1 || printf '  (harvest driver exited non-zero)\n'

kill_qemu
trap - EXIT

# Cut the trace block out of the capture.  Strip the echoed command line
# itself (it contains the sentinels) by requiring the [pn-refresh] tag.
tr -d '\r' < "$harvest" \
  | sed -n '/WBCAMP-TRACE-BEGIN/,/WBCAMP-TRACE-END/p' \
  | grep -a '\[pn-refresh\]' \
  | grep -av 'WBCAMP-TRACE' \
  > "$traces" || true

guest_clock=$(tr -d '\r' < "$harvest" \
  | sed -n 's/^WBCAMP-GUESTCLOCK \([0-9][0-9.]*\).*/\1/p' | tail -1)
guest_count=$(tr -d '\r' < "$harvest" \
  | sed -n 's/^WBCAMP-LOGSTAT [0-9]* \([0-9]*\).*/\1/p' | tail -1)
guest_logsize=$(tr -d '\r' < "$harvest" \
  | sed -n 's/^WBCAMP-LOGSTAT \([0-9a-z]*\) .*/\1/p' | tail -1)

trace_lines=$(wc -l < "$traces" | tr -d ' ')
# grep -c prints 0 AND exits 1 on no match, so `|| echo 0' appends a
# second line and every later [ ] test dies with "Illegal number".
taps=$(grep -c '^[0-9.]* TAP-DOWN' "$ledger" 2>/dev/null | head -1)
[ -n "$taps" ] || taps=0

printf '\nCampaign summary:\n'
printf '  taps issued          : %s\n' "$taps"
printf '  [pn-refresh] harvested: %s (guest reported %s in a %s-byte log)\n' \
  "$trace_lines" "${guest_count:-?}" "${guest_logsize:-?}"

# Guest-minus-host clock offset, for aligning the ledger to the traces.
# Measured against the host stamp taken when the guest's clock line
# actually arrived, not against $host_clock_at_harvest (which predates
# the console login).  The latter is kept only as a sanity bound.
offset=0
hostat=$(tr -d '\r' < "$harvest" \
  | sed -n 's/^WBCAMP-HOSTAT WBCAMP-GUESTCLOCK \([0-9][0-9.]*\).*/\1/p' | tail -1)
if [ -n "$guest_clock" ] && [ -n "$hostat" ]; then
  offset=$(awk -v g="$guest_clock" -v h="$hostat" 'BEGIN { printf "%.3f", g - h }')
  printf '  guest-host clock offset: %ss (login-to-harvest span %ss)\n' "$offset" \
    "$(awk -v a="$host_clock_at_harvest" -v b="$hostat" 'BEGIN { printf "%.1f", b - a }')"
  printf '%s\n' "$offset" > "$outdir/clock-offset.txt"
fi

printf '\nCampaign assertions:\n'
require 'boot reached login prompt' "$(grep -aq 'login:' "$log" && echo 0 || echo 1)"
require 'virtio-gpu DRM bound'      "$(grep -aq 'virtio[-_]gpu' "$log" && echo 0 || echo 1)"
require 'KOReader painted the fb'   "$painted"
require 'taps were issued'          "$([ "$taps" -gt 0 ] && echo 0 || echo 1)"
require 'traces were harvested'     "$([ "$trace_lines" -gt 0 ] && echo 0 || echo 1)"

# Phase 6: analyse.
if [ "$trace_lines" -gt 0 ] && [ -x "$analyzer" ] && command -v python3 >/dev/null 2>&1; then
  printf '\n'
  python3 "$analyzer" "$traces" \
    --ledger "$ledger" --clock-offset "$offset" \
    --json "$outdir/episodes.json" | tee "$outdir/episodes.txt" || true
fi

printf '\n'
if [ "$rc" -eq 0 ]; then
  printf 'qemu-virt page-turn campaign: OK (artifacts in %s)\n' "$outdir"
else
  printf 'qemu-virt page-turn campaign: FAILED — see %s\n' "$outdir"
fi
exit $rc
