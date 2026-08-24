#!/bin/sh
# QEMU-virt visual loop (offline testing ladder rung 4v).
#
# Boots the real PineNote kernel/initrd/rootfs on QEMU virt like
# run-virt-assertions.sh, but adds a virtio-gpu framebuffer at panel
# resolution plus virtio tablet/keyboard, forces the KOReader pinenote
# device target via the wilkbook.force_device=pinenote cmdline token
# (the DT model on virt is "linux,dummy-virt"), and drives the UI from
# the host: QMP screendumps prove KOReader actually paints, a scripted
# tap proves the input path moves pixels.  This is the offline loop for
# refresh-policy and UI iteration — what the panel *shows* still needs
# hardware; what KOReader *paints and damages* iterates here.
#
# Assertions:
#   - boot reaches the login prompt (console log, same as rung 4)
#   - virtio-gpu DRM device binds (console log)
#   - screendump A: PPM at 1872x1404 that is NOT uniform (KOReader UI)
#   - tap at the menu zone, screendump B: differs from A (input works)
set -eu

: "${VIRT_VISUAL_TIMEOUT:=420}"
: "${VIRT_VISUAL_LOGIN_WAIT:=180}"
# KOReader under TCG takes a while to first paint; poll until the shot
# is non-uniform or this many seconds have passed since boot.
: "${VIRT_VISUAL_PAINT_WAIT:=330}"

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

if [ -z "$outdir" ]; then
  artifact_root=$(CDPATH= cd -P /tmp/wilkbook 2>/dev/null && pwd -P) || \
    fail "cannot resolve /tmp/wilkbook for the default output dir"
  outdir=$artifact_root/pinenote-virt-visual-$$
fi
mkdir -p "$outdir" || fail "cannot create output dir: $outdir"
log=$outdir/console.log
qmp=$outdir/qmp.sock
sock=$outdir/console.sock
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
# Select the pinenote KOReader device target despite the virt DT model.
append="$append wilkbook.force_device=pinenote"

printf 'qemu-virt visual: booting (out -> %s)\n' "$outdir"

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

# --- QMP driver: greeting + capabilities + one command per invocation ---
qmp_scm=$outdir/qmp.scm
cat > "$qmp_scm" <<'EOF'
(use-modules (rnrs bytevectors) (ice-9 textual-ports))
(sigaction SIGPIPE SIG_IGN)
(let* ((path (cadr (command-line)))
       (cmds (cddr (command-line)))
       (s    (socket PF_UNIX SOCK_STREAM 0))
       (buf  (make-bytevector 65536)))
  (define (drain-for seconds)
    (let loop ((left (* seconds 10)))
      (when (> left 0)
        (let ((n (catch 'system-error
                   (lambda () (recv! s buf MSG_DONTWAIT))
                   (lambda args 0))))
          (usleep 100000)
          (loop (- left 1))))))
  (connect s AF_UNIX path)
  (drain-for 1)                                    ;greeting
  (display "{\"execute\":\"qmp_capabilities\"}\r\n" s) (force-output s)
  (drain-for 1)
  (for-each (lambda (c)
              (display c s) (display "\r\n" s) (force-output s)
              (drain-for 1))
            cmds)
  (close-port s))
EOF

qmp_cmd() { # JSON...
  guile -s "$qmp_scm" "$qmp" "$@" 2>/dev/null || true
}

screendump() { # FILE
  qmp_cmd "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$1\"}}"
  # allow the dump to finish writing
  sleep 2
}

tap() { # X Y  (panel pixel coordinates; QMP wants 0..32767 absolute)
  qx=$(( $1 * 32767 / 1872 ))
  qy=$(( $2 * 32767 / 1404 ))
  qmp_cmd \
    "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":$qx}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":$qy}},{\"type\":\"btn\",\"data\":{\"down\":true,\"button\":\"left\"}}]}}" \
    "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"btn\",\"data\":{\"down\":false,\"button\":\"left\"}}]}}"
}

# PPM checks in guile: header must say 1872x1404; "uniform" means every
# sampled pixel triple equals the first (sampled, not exhaustive).
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
            (loop (+ i 30000))                     ;sample every 10k pixels
            #f))))
(format #t "~ax~a ~a\n" width height (if uniform "UNIFORM" "VARIED"))
EOF

ppm_info() { # FILE -> "WxH UNIFORM|VARIED"
  guile -s "$ppm_check_scm" "$1" 2>/dev/null || echo "BAD"
}

rc=0
require() { # LABEL COND(0=pass)
  if [ "$2" = 0 ]; then
    printf '  PASS  require  %s\n' "$1"
  else
    printf '  FAIL  require  %s\n' "$1"
    rc=1
  fi
}

# Phase 1: boot to login prompt.
while kill -0 "$qemu_pid" 2>/dev/null; do
  grep -aq 'login:' "$log" 2>/dev/null && break
  [ "$(elapsed)" -ge "$VIRT_VISUAL_LOGIN_WAIT" ] && break
  sleep 3
done
printf '  login prompt (or wait expired) at %ss\n' "$(elapsed)"

# Phase 2: poll screendumps until KOReader has painted something.
shot_a=$outdir/shot-a.ppm
painted=1
while kill -0 "$qemu_pid" 2>/dev/null; do
  screendump "$shot_a"
  info=$(ppm_info "$shot_a")
  case "$info" in
    "1872x1404 VARIED") painted=0; break ;;
  esac
  [ "$(elapsed)" -ge "$VIRT_VISUAL_PAINT_WAIT" ] && break
  printf '  (shot at %ss: %s; waiting for KOReader paint)\n' "$(elapsed)" "$info"
  sleep 15
done
printf '  first painted shot at %ss\n' "$(elapsed)"

# Phase 3: wait for a SETTLED baseline (two identical consecutive shots
# — transient toasts expiring between shots once faked a tap-pass), then
# tap the menu zone (top center) and require a pixel change.
changed=1
if [ "$painted" = 0 ]; then
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
  tap 936 100
  sleep 12                       # give TCG time to repaint
  shot_b=$outdir/shot-b.ppm
  screendump "$shot_b"
  sha_b=$(sha256sum "$shot_b" 2>/dev/null | cut -d' ' -f1 || echo missing)
  [ "$sha_a" != "$sha_b" ] && [ -s "$shot_b" ] && changed=0
fi

kill_qemu
trap - EXIT

printf '\nVisual-loop assertions:\n'
require 'boot reached login prompt' "$(grep -aq 'login:' "$log" && echo 0 || echo 1)"
require 'virtio-gpu DRM bound'      "$(grep -aq 'virtio[-_]gpu' "$log" && echo 0 || echo 1)"
require 'KOReader painted the fb (1872x1404, non-uniform)' "$painted"
require 'tap changed the screen'    "$changed"

printf '\n'
if [ "$rc" -eq 0 ]; then
  printf 'qemu-virt visual: OK (shots in %s)\n' "$outdir"
else
  printf 'qemu-virt visual: FAILED — see %s\n' "$outdir"
fi
exit $rc
