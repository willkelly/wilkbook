#!/bin/sh
# Mechanized QEMU-virt boot assertions (offline testing ladder rung 4).
#
# Boots the *real* PineNote kernel, initrd, and rootfs on QEMU's generic
# ARM64 "virt" machine exactly as run-pinenote-virt.sh does, captures the
# console to a log, then LOGS IN over the console socket and asserts the
# post-udev service state from inside the guest before powering it off.
# Exits non-zero if any assertion fails.
#
# Takes a boot bundle staged by stage-boot-bundle-from-rootfs.sh and a disk
# built by make-virt-disk.sh (the Makefile's qemu-virt-check target chains
# all three).  Host-side only; writes nothing outside /tmp/wilkbook.
#
# WHAT THIS RUNG PROVES:
#   Power-on through the full service stack: the hardware kernel image
#   boots with PREEMPT_RT, the initrd finds the waveform partition by
#   PARTNAME and installs it, loads the EBC display modules, sees
#   PNGuixRoot before the root switch, root mounts by label, Shepherd
#   brings up its base services, udev completes, the pinenote-waveform and
#   pinenote-ebc-params one-shots run, the orientation bridge creates its
#   named uinput device, and the reader-session service starts after it (its
#   shepherd requirements — udev, user-processes, the bridge, and both
#   one-shots — make it a transitive check of the whole chain). This is
#   the config/initrd/root-mount regression class (e.g. the VIRTIO_MENU
#   olddefconfig drop) plus the service-ordering regression class that
#   cost the first two hardware sessions.
#
# WHY THE HARNESS LOGS IN instead of watching the console:
#   Shepherd (PID 1) writes its messages to /dev/kmsg — visible on the
#   console — only until something listens on /dev/log.  Shepherd 1.0's
#   built-in system-log service starts listening ~5 s into boot, and from
#   that moment every "Service X has been started" goes to
#   /var/log/messages and the console goes dark BY DESIGN.  The boot
#   continues fine underneath (this deterministic silence was mistaken
#   for a udev deadlock on 2026-07-04; see doc/status.md 2026-07-05).
#   So post-switchover milestones are asserted by logging in as root on
#   the console socket, grepping /var/log/messages *inside* the guest,
#   and echoing VIRTCHK-* sentinel lines that land in the console log via
#   qemu's logfile= tee.  Sentinels are composed with shell variables
#   ($u etc.) so the echoed command text can never satisfy the grep.
set -eu

# Hard wall-clock cap.  virt boots run under TCG (no KVM for aarch64 on an
# x86 host) and are slow.  Override with VIRT_ASSERT_TIMEOUT if needed.
: "${VIRT_ASSERT_TIMEOUT:=420}"
# How long to wait for the console login prompt (getty is up early,
# independent of udev; a boot that never reaches it has failed early and
# the console-log assertions will say why).
: "${VIRT_ASSERT_LOGIN_WAIT:=180}"
# Pause between in-guest probe rounds while waiting for the one-shots.
: "${VIRT_ASSERT_PROBE_INTERVAL:=20}"

usage() {
  printf 'usage: %s BOOT_BUNDLE_DIRECTORY DISK_IMAGE [LOG_FILE]\n' "$0" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 2; }

bundle=$1
disk=$2
log=${3:-}

# Set VIRTCHK_EXPECT_DATA to the make-data-fixture.sh variant the disk
# carries -- os1-used, with-library or empty -- or leave it unset for a disk
# with no p7 at all (what qemu-virt-check has always exercised).
#
# The three variants have DIFFERENT correct answers, which is the whole
# point: os1-used must GAIN a library and a pointer; with-library must be
# left strictly alone, pointer and all; empty must gain a library and NO
# pointer, because there is no Debian home to point at.  Asserting one set
# against all three would have passed the case it was written for and said
# nothing about the other two.
expect_data=${VIRTCHK_EXPECT_DATA:-none}
case $expect_data in
  none|os1-used|with-library|empty) ;;
  1) expect_data=os1-used ;;
  *) printf 'FAIL: unknown VIRTCHK_EXPECT_DATA: %s\n' "$expect_data" >&2; exit 2 ;;
esac

command -v qemu-system-aarch64 >/dev/null 2>&1 || \
  fail "qemu-system-aarch64 not found; run via: guix shell qemu -- $0 ..."
command -v guile >/dev/null 2>&1 || \
  fail "guile not found (needed to drive the console socket)"

kernel=$bundle/extlinux/Image
initrd=$bundle/extlinux/initrd.cpio.gz
config=$bundle/extlinux/extlinux.conf

[ -f "$kernel" ] || fail "bundle is missing extlinux/Image: $bundle"
[ -f "$initrd" ] || fail "bundle is missing extlinux/initrd.cpio.gz: $bundle"
[ -f "$config" ] || fail "bundle is missing extlinux/extlinux.conf: $bundle"
[ -f "$disk" ]   || fail "disk image is not a regular file: $disk"

if [ -z "$log" ]; then
  artifact_root=$(CDPATH= cd -P /tmp/wilkbook 2>/dev/null && pwd -P) || \
    fail "cannot resolve /tmp/wilkbook for the default log path"
  log=$artifact_root/pinenote-virt-assert-$$.log
fi
: > "$log" || fail "cannot write console log: $log"

append=$(sed -n 's/^[[:space:]]*APPEND[[:space:]][[:space:]]*//p' "$config" | sed -n '1p')
[ -n "$append" ] || fail "bundle extlinux.conf has no APPEND line"

case " $append " in
  *' gnu.system='*) ;;
  *) fail "APPEND lacks gnu.system=; bundle does not match a Guix rootfs" ;;
esac

# Same console steering as run-pinenote-virt.sh: the hardware UART/tty do not
# exist on virt, so send the kernel console to the PL011 (ttyAMA0).  root=,
# the rockchip_ebc parameters, and everything else stay exactly as on hardware.
append=$(printf '%s' "$append" | sed \
  -e 's/console=ttyS2,1500000n8/console=ttyAMA0/' \
  -e 's/console=tty0 //')

printf 'qemu-virt assertions: booting (console -> %s)\n' "$log"
printf '  cap=%ss login-wait=%ss probe-interval=%ss\n' \
  "$VIRT_ASSERT_TIMEOUT" "$VIRT_ASSERT_LOGIN_WAIT" "$VIRT_ASSERT_PROBE_INTERVAL"

# Console on a socket chardev: qemu tees everything to $log via logfile=,
# and the harness (or a human, post-mortem) can connect to the socket to
# drive a login session.
sock=$log.sock
rm -f "$sock"
qemu-system-aarch64 \
  -M virt -cpu max -smp 4 -m 2048 \
  -display none -no-reboot \
  -chardev "socket,id=con0,path=$sock,server=on,wait=off,logfile=$log" \
  -serial chardev:con0 \
  -monitor none \
  -kernel "$kernel" \
  -initrd "$initrd" \
  -append "$append" \
  -drive if=virtio,format=raw,file="$disk" \
  2> "$log.qemu-stderr" &
qemu_pid=$!
start_time=$(date +%s)

elapsed() {
  echo $(( $(date +%s) - start_time ))
}

kill_qemu() {
  kill "$qemu_pid" 2>/dev/null || true
  i=0
  while kill -0 "$qemu_pid" 2>/dev/null; do
    [ "$i" -ge 5 ] && { kill -9 "$qemu_pid" 2>/dev/null || true; break; }
    sleep 1; i=$((i + 1))
  done
}

# Console driver: connects to the socket, logs in as root, sends each argv
# command with a pause, and exits the shell.  Command output is not parsed
# here — everything lands in $log via qemu's logfile= tee.  Three hard-won
# details:
#   (a) bytes are paced ~2 ms apart because the guest PL011 has a 16-byte
#       FIFO and blasting a whole line drops everything past byte 16 when
#       the guest is busy (the truncated line then leaves bash stuck in a
#       '>' continuation prompt);
#   (b) every line is preceded by Ctrl-C to clear any such stuck input
#       state from an earlier, interrupted round;
#   (c) the driver must continuously DRAIN the socket: while a client is
#       connected qemu applies backpressure for it, so an unread socket
#       fills up, qemu stops draining guest TX, bash blocks mid-echo and
#       stops reading input, guest RX fills, qemu stops reading the
#       client — and the writer deadlocks (and the logfile freezes with
#       it, since logging happens at delivery time).
probe_scm=$log.probe.scm
cat > "$probe_scm" <<'EOF'
(use-modules (rnrs bytevectors))
(sigaction SIGPIPE SIG_IGN)   ;peer may vanish mid-write (qemu exit at poweroff)
(let ((s     (socket PF_UNIX SOCK_STREAM 0))
      (path  (cadr (command-line)))
      (lines (cddr (command-line)))
      (buf   (make-bytevector 4096)))
  (define (drain)
    (let loop ()
      (define n
        (catch 'system-error
          (lambda () (recv! s buf MSG_DONTWAIT))
          (lambda args 0)))                       ;EAGAIN etc: nothing to read
      (when (> n 0) (loop))))
  (define (pause seconds)                         ;sleep, draining as we go
    (let loop ((ticks (inexact->exact (round (* seconds 10)))))
      (when (> ticks 0)
        (drain) (usleep 100000) (loop (- ticks 1)))))
  (define (send-slow str)
    (string-for-each (lambda (c)
                       (display c s) (force-output s)
                       (drain) (usleep 2000))
                     str))
  (define (ctrl-c)
    (display (string (integer->char 3)) s) (force-output s)
    (pause 0.4))
  (connect s AF_UNIX path)
  (send-slow "\r\n") (pause 0.8)
  (ctrl-c)
  (send-slow "root\r\n") (pause 6)
  (for-each (lambda (l)
              (ctrl-c)
              (send-slow l) (send-slow "\r\n")
              (pause 3))
            lines)
  (ctrl-c)
  (send-slow "exit\r\n") (pause 1)
  (close-port s))
EOF

# One probe round: log in and emit VIRTCHK sentinels for the post-switchover
# milestones.  The $u/$w/... indirection keeps the echoed command text from
# matching the assertion greps.  Once reader-session's start is confirmed,
# stop it: on virt there is no EBC framebuffer, so KOReader's luajit spins a
# whole vCPU, which under TCG floods the console with soft-lockup/RCU-stall
# splats and makes the shell sluggish — stopping it keeps later rounds and
# the poweroff crisp.  (Its 'has been started' line stays in the syslog, so
# the assertion is unaffected.)
probe_round() {
  guile -s "$probe_scm" "$sock" \
    "if grep -q 'Service udev has been started' /var/log/messages; then u=yes; else u=no; fi; echo VIRTCHK-UDEV-\$u" \
    "if grep -q 'Service pinenote-waveform has been started' /var/log/messages; then w=yes; else w=no; fi; echo VIRTCHK-WVF-\$w" \
    "if grep -q 'Service pinenote-ebc-direct-params has been started' /var/log/messages; then e=yes; else e=no; fi; echo VIRTCHK-EBCP-\$e" \
    "v=\$(cat /sys/module/rockchip_ebc/parameters/temp_override 2>/dev/null || echo absent); echo VIRTCHK-TO-\$v" \
    "v=\$(cat /sys/module/rockchip_ebc/parameters/default_hint 2>/dev/null || echo absent); echo VIRTCHK-DH-\$v" \
    "if grep -q 'Service pinenote-ebc-clut has been started' /var/log/messages; then c=yes; else c=no; fi; echo VIRTCHK-CLUT-\$c" \
    "if grep -q 'Service pinenote-ebc-splash has been started' /var/log/messages; then s=yes; else s=no; fi; echo VIRTCHK-SPLASH-\$s" \
    "if grep -q 'Service orientation-bridge has been started' /var/log/messages; then o=yes; else o=no; fi; echo VIRTCHK-ORI-SVC-\$o" \
    "if grep -q '^wilkbook-orientation\$' /sys/class/input/event*/device/name 2>/dev/null; then n=yes; else n=no; fi; echo VIRTCHK-ORI-NODE-\$n" \
    "if grep -q 'Service reader-session has been started' /var/log/messages; then r=yes; else r=no; fi; echo VIRTCHK-RDR-\$r" \
    "if mountpoint -q /data; then m=yes; else m=no; fi; echo VIRTCHK-DATA-MNT-\$m" \
    "if [ -d /data/books ]; then d=yes; else d=no; fi; echo VIRTCHK-LIB-DIR-\$d" \
    "t=\$(readlink '/data/books/Debian home' 2>/dev/null || echo none); echo VIRTCHK-LIB-PTR-\$t" \
    "if [ -f '/data/books/Debian home/Documents/A Book I Was Reading.epub' ]; then r=yes; else r=no; fi; echo VIRTCHK-LIB-RESOLVE-\$r" \
    "echo VIRTCHK-DEB-TOP-\$(ls /data/user 2>/dev/null | tr '\\n' ',')" \
    "echo VIRTCHK-DEB-DOCS-\$(ls /data/user/Documents 2>/dev/null | wc -l | tr -d ' ')" \
    "if grep -q /data/books /root/.config/koreader/settings.reader.lua 2>/dev/null; then h=yes; else h=no; fi; echo VIRTCHK-PROF-HOME-\$h" \
    "if grep -q quickstart_shown_version /root/.config/koreader/settings.reader.lua 2>/dev/null; then q=yes; else q=no; fi; echo VIRTCHK-PROF-QS-\$q" \
    "if grep -lq luajit /proc/[0-9]*/comm >/dev/null 2>&1; then k=yes; else k=no; fi; echo VIRTCHK-KO-ALIVE-\$k" \
    "if [ -f '/data/books/Existing Book.epub' ]; then x=yes; else x=no; fi; echo VIRTCHK-LIB-KEPT-\$x" \
    "if [ -f '/data/books/Existing Book.sdr/metadata.epub.lua' ]; then y=yes; else y=no; fi; echo VIRTCHK-LIB-KEPTSDR-\$y" \
    "echo VIRTCHK-LIB-COUNT-\$(ls /data/books 2>/dev/null | wc -l | tr -d ' ')" \
    "if [ \"\$r\" = yes ]; then timeout 20 herd stop reader-session > /dev/null 2>&1; fi" \
    2>/dev/null || true
}

all_sentinels_present() {
  grep -aq 'VIRTCHK-UDEV-yes' "$log" && \
  grep -aq 'VIRTCHK-WVF-yes'  "$log" && \
  grep -aq 'VIRTCHK-EBCP-yes' "$log" && \
  grep -aq 'VIRTCHK-TO-22'    "$log" && \
  grep -aq 'VIRTCHK-DH-32'    "$log" && \
  grep -aq 'VIRTCHK-CLUT-yes' "$log" && \
  grep -aq 'VIRTCHK-SPLASH-yes' "$log" && \
  grep -aq 'VIRTCHK-ORI-SVC-yes' "$log" && \
  grep -aq 'VIRTCHK-ORI-NODE-yes' "$log" && \
  grep -aq 'VIRTCHK-RDR-yes'  "$log" && \
  { [ "$expect_data" = "none" ] || {
      grep -aq 'VIRTCHK-DATA-MNT-yes' "$log" && \
      grep -aq 'VIRTCHK-LIB-DIR-yes' "$log" && \
      grep -aq 'VIRTCHK-KO-ALIVE-yes' "$log"; }; }
}

# Phase 1: wait for the console login prompt (or early death/stall).
reason=login-wait-expired
while kill -0 "$qemu_pid" 2>/dev/null; do
  if grep -aq 'login:' "$log" 2>/dev/null; then
    reason=probing
    break
  fi
  if [ "$(elapsed)" -ge "$VIRT_ASSERT_LOGIN_WAIT" ]; then
    break
  fi
  sleep 3
done
kill -0 "$qemu_pid" 2>/dev/null || reason=qemu-exited-early

# Phase 2: probe rounds until every sentinel is yes or the cap expires.
if [ "$reason" = probing ]; then
  printf '  login prompt at %ss; probing in-guest service state\n' "$(elapsed)"
  reason=cap
  while kill -0 "$qemu_pid" 2>/dev/null; do
    probe_round
    if all_sentinels_present; then
      reason=all-green
      break
    fi
    if [ "$(elapsed)" -ge "$VIRT_ASSERT_TIMEOUT" ]; then
      break
    fi
    printf '  (sentinels incomplete at %ss; will probe again)\n' "$(elapsed)"
    sleep "$VIRT_ASSERT_PROBE_INTERVAL"
  done
fi

# Phase 3: clean shutdown so the run ends deterministically (and the stop
# path gets exercised).  -no-reboot makes qemu exit on poweroff.
if [ "$reason" = all-green ] && kill -0 "$qemu_pid" 2>/dev/null; then
  printf '  all sentinels green at %ss; powering off\n' "$(elapsed)"
  # shepherd's halt powers the machine off; absolute path because there is
  # no 'poweroff' on Guix and root's PATH may lack sbin
  guile -s "$probe_scm" "$sock" "/run/current-system/profile/sbin/halt" \
    2>/dev/null || true
  i=0
  while kill -0 "$qemu_pid" 2>/dev/null; do
    [ "$i" -ge 90 ] && { reason=poweroff-timeout; break; }
    sleep 3; i=$((i + 3))
  done
fi
if kill -0 "$qemu_pid" 2>/dev/null; then
  kill_qemu
fi
wait "$qemu_pid" 2>/dev/null || true

printf 'qemu-virt assertions: capture ended (%s, %ss, %s bytes)\n\n' \
  "$reason" "$(elapsed)" "$(wc -c < "$log" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------------------
# Assertions.  require = must be present; forbid = must be absent.
# Milestones up to "Starting service udev" print on the console (shepherd
# still logs via /dev/kmsg then); everything later comes from the VIRTCHK
# sentinels emitted by the in-guest probe.
# ---------------------------------------------------------------------------
rc=0
require() { # LABEL REGEX
  if grep -aEq -- "$2" "$log"; then
    printf '  PASS  require  %s\n' "$1"
  else
    printf '  FAIL  require  %s\n' "$1"
    rc=1
  fi
}
forbid() { # LABEL REGEX
  if grep -aEq -- "$2" "$log"; then
    printf '  FAIL  forbid   %s\n' "$1"
    rc=1
  else
    printf '  PASS  forbid   %s\n' "$1"
  fi
}

printf 'Required boot milestones (console log, through Shepherd start):\n'
require 'kernel boots'                 'Booting Linux on physical CPU'
require 'PREEMPT_RT kernel'            'SMP PREEMPT_RT'
require 'root=PNGuixRoot on cmdline'   'Kernel command line:.*root=PNGuixRoot'
require 'initrd pre-mount ran'         'PineNote initrd: pre-mount diagnostics starting'
require 'initrd installed waveform'    'PineNote initrd: installed waveform firmware from'
require 'initrd loaded EBC modules'    'PineNote initrd: loaded EBC display modules'
require 'PNGuixRoot visible pre-root'  'PineNote initrd: PNGuixRoot is visible before Guix root mount'
require 'root fs mounts (fsck clean)'  'PNGuixRoot: clean'
require 'shepherd root-fs up'          'Service root-file-system running with value #t'
require 'reached udev service'         'Starting service udev'

printf '\nRequired service milestones (in-guest probe of /var/log/messages):\n'
require 'udev service completes'       'VIRTCHK-UDEV-yes'
require 'waveform one-shot ran'        'VIRTCHK-WVF-yes'
require 'direct-params one-shot ran'   'VIRTCHK-EBCP-yes'
# The live parameter values, not the intent: the 2026-07-05 A.2 image
# carried a module parameter on the cmdline, which the raw initrd module
# loader silently ignores.  Reading the sysfs values from inside the guest
# is the only check that catches the whole chain (module loaded, one-shot
# ran, parameters actually took).  Since S2 these are the direct driver's.
require 'live temp_override is 22'      'VIRTCHK-TO-22'
require 'live default_hint is 32'       'VIRTCHK-DH-32'
# The CLUT and splash one-shots succeed doing nothing where there is no
# panel; reader-session requires the former since S2, so a failure here
# would keep the reader from starting at all.
require 'CLUT one-shot ran (no-op here)' 'VIRTCHK-CLUT-yes'
require 'splash one-shot ran (no-op here)' 'VIRTCHK-SPLASH-yes'
require 'orientation service started'    'VIRTCHK-ORI-SVC-yes'
require 'orientation evdev exists'       'VIRTCHK-ORI-NODE-yes'
require 'reader-session started'       'VIRTCHK-RDR-yes'
require 'clean poweroff'               'reboot: Power down'

if [ "$expect_data" != "none" ]; then
  printf '\nRequired data-partition milestones (fixture: %s):\n' "$expect_data"
  require 'p7 mounts at /data'            'VIRTCHK-DATA-MNT-yes'
  require 'library exists on p7'          'VIRTCHK-LIB-DIR-yes'
  require 'profile points at the library' 'VIRTCHK-PROF-HOME-yes'
  require 'quickstart suppressed'         'VIRTCHK-PROF-QS-yes'
  require 'KOReader still running'        'VIRTCHK-KO-ALIVE-yes'

  case $expect_data in
    os1-used)
      # RELATIVE, because os1 mounts this same partition at /home and an
      # absolute /data/user target would dangle from the rescue slot.
      require 'Debian-home pointer is ../user'  'VIRTCHK-LIB-PTR-\.\./user'
      require 'pointer resolves to real books'  'VIRTCHK-LIB-RESOLVE-yes'
      require 'library holds only the pointer'  'VIRTCHK-LIB-COUNT-1'
      ;;
    with-library)
      # The author's device.  /root does not survive a reflash, so this
      # one-shot runs again on every deploy -- it must not add a pointer to
      # a library someone has been using, and must not disturb its contents.
      require 'existing library left alone (no pointer)' 'VIRTCHK-LIB-PTR-none'
      require 'existing book still present'     'VIRTCHK-LIB-KEPT-yes'
      require 'existing .sdr sidecar intact'    'VIRTCHK-LIB-KEPTSDR-yes'
      require 'nothing added to the library'    'VIRTCHK-LIB-COUNT-2'
      ;;
    empty)
      # A reprovisioned p7 with no Debian home: create the library, and do
      # NOT create a pointer to a directory that does not exist.
      require 'no pointer without a Debian home' 'VIRTCHK-LIB-PTR-none'
      require 'library created and empty'        'VIRTCHK-LIB-COUNT-0'
      ;;
  esac

  if [ "$expect_data" != "empty" ]; then
    # os1's home must come through byte-for-byte.
    require "os1's home untouched (top level)" \
      'VIRTCHK-DEB-TOP-Desktop,Documents,Downloads,Music,Pictures,Public,Templates,Videos,'
    require "os1's home untouched (Documents)" 'VIRTCHK-DEB-DOCS-3'
  fi
fi

printf '\nForbidden regressions:\n'
forbid 'waveform partition not found'  'PineNote initrd: warning: waveform partition not found'
forbid 'PNGuixRoot not visible'        'PineNote initrd: PNGuixRoot is not visible'
forbid 'kernel panic'                  'Kernel panic'
forbid 'init died'                     'Attempted to kill init'
forbid 'root device unavailable'       'VFS: Cannot open root device|Unable to mount root'
forbid 'RT sleeping-in-atomic splat'   'BUG: sleeping function called from invalid context'

printf '\n'
if [ "$rc" -eq 0 ]; then
  printf 'qemu-virt assertions: OK (log: %s)\n' "$log"
else
  printf 'qemu-virt assertions: FAILED — see %s\n' "$log"
fi
exit $rc
