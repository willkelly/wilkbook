#!/bin/sh
# Mechanized QEMU-virt boot assertions (offline testing ladder rung 4).
#
# Boots the *real* PineNote kernel, initrd, and rootfs on QEMU's generic
# ARM64 "virt" machine exactly as run-pinenote-virt.sh does, but instead of
# handing you an interactive console it captures the console to a log,
# terminates QEMU once the boot goes quiescent (or a hard cap elapses), and
# then asserts a set of REQUIRED boot signatures are present and FORBIDDEN
# regression signatures are absent.  Exits non-zero if any assertion fails.
#
# Takes a boot bundle staged by stage-boot-bundle-from-rootfs.sh and a disk
# built by make-virt-disk.sh (the Makefile's qemu-virt-check target chains
# all three).  Host-side only; writes nothing outside /tmp/opencode.
#
# WHAT THIS RUNG PROVES (and, deliberately, what it does NOT):
#   The virt boot is healthy from power-on through Shepherd start: the
#   hardware kernel image boots with PREEMPT_RT, the initrd finds the
#   waveform partition by PARTNAME and installs it, loads the EBC display
#   modules, sees PNGuixRoot before the root switch, root mounts by label,
#   and Shepherd brings up its base services.  This is the config/initrd/
#   root-mount regression class (e.g. the VIRTIO_MENU olddefconfig drop that
#   made virtio-blk vanish and root never appear).
#
#   It does NOT reach the post-udev one-shot services (pinenote-waveform,
#   the ACM gadget, pinenote-ebc-params): the virt boot deadlocks entering
#   the udev service (idle-CPU hang, confirmed 2026-07-04 — see
#   doc/status.md and doc/testing.md).  The waveform/udev-ordering and
#   gadget-modprobe regressions therefore stay guarded by the host tools and
#   hardware, not here, until that hang is fixed.  The harness pins the
#   current high-water mark so a regression *before* it goes red.
set -eu

# Hard wall-clock cap.  virt boots run under TCG (no KVM for aarch64 on an
# x86 host) and are slow; the quiescence detector normally kills QEMU well
# before this.  Override with VIRT_ASSERT_TIMEOUT if needed.
: "${VIRT_ASSERT_TIMEOUT:=420}"
# Kill QEMU once the console log has not grown for this many seconds (after
# the boot has reached at least the initrd handoff).  The virt boot goes
# silent when it deadlocks at udev; a healthy future boot that runs further
# would simply quiesce at its own login/idle point and still be captured.
: "${VIRT_ASSERT_QUIESCE:=25}"

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

command -v qemu-system-aarch64 >/dev/null 2>&1 || \
  fail "qemu-system-aarch64 not found; run via: guix shell qemu -- $0 ..."

kernel=$bundle/extlinux/Image
initrd=$bundle/extlinux/initrd.cpio.gz
config=$bundle/extlinux/extlinux.conf

[ -f "$kernel" ] || fail "bundle is missing extlinux/Image: $bundle"
[ -f "$initrd" ] || fail "bundle is missing extlinux/initrd.cpio.gz: $bundle"
[ -f "$config" ] || fail "bundle is missing extlinux/extlinux.conf: $bundle"
[ -f "$disk" ]   || fail "disk image is not a regular file: $disk"

if [ -z "$log" ]; then
  opencode_root=$(CDPATH= cd -P /tmp/opencode 2>/dev/null && pwd -P) || \
    fail "cannot resolve /tmp/opencode for the default log path"
  log=$opencode_root/pinenote-virt-assert-$$.log
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
printf '  cap=%ss quiesce=%ss\n' "$VIRT_ASSERT_TIMEOUT" "$VIRT_ASSERT_QUIESCE"

qemu-system-aarch64 \
  -M virt -cpu max -smp 4 -m 2048 \
  -nographic -no-reboot \
  -kernel "$kernel" \
  -initrd "$initrd" \
  -append "$append" \
  -drive if=virtio,format=raw,file="$disk" \
  > "$log" 2>&1 &
qemu_pid=$!

# Terminate QEMU on log quiescence or the hard cap, whichever comes first.
# "Quiescent" means the log stopped growing for VIRT_ASSERT_QUIESCE seconds
# AND the boot has progressed at least to the initrd handoff (so we never
# mistake a slow early boot for a finished one).
kill_qemu() {
  kill "$qemu_pid" 2>/dev/null || true
  # Give it a moment, then force.
  i=0
  while kill -0 "$qemu_pid" 2>/dev/null; do
    [ "$i" -ge 5 ] && { kill -9 "$qemu_pid" 2>/dev/null || true; break; }
    sleep 1; i=$((i + 1))
  done
}

reason=cap
waited=0
last_size=-1
quiet=0
while kill -0 "$qemu_pid" 2>/dev/null; do
  sleep 3
  waited=$((waited + 3))
  size=$(wc -c < "$log" 2>/dev/null || echo 0)
  if [ "$size" = "$last_size" ]; then
    quiet=$((quiet + 3))
  else
    quiet=0
    last_size=$size
  fi
  # Only honour quiescence once the boot has reached the initrd handoff,
  # so an unusually slow kernel/initrd stage is never read as "done".
  if [ "$quiet" -ge "$VIRT_ASSERT_QUIESCE" ] && \
     grep -q 'handoff to Guix root mount' "$log" 2>/dev/null; then
    reason=quiescent
    break
  fi
  # Fallback: a much longer silence with no handoff means an early panic or
  # stall (healthy boots produce steady output up to the handoff). Bound it
  # instead of waiting out the whole cap; the assertions then fail cleanly.
  if [ "$quiet" -ge $((VIRT_ASSERT_QUIESCE * 2)) ]; then
    reason=quiescent-early
    break
  fi
  if [ "$waited" -ge "$VIRT_ASSERT_TIMEOUT" ]; then
    reason=cap
    break
  fi
done
if kill -0 "$qemu_pid" 2>/dev/null; then
  kill_qemu
else
  reason=qemu-exited
fi
wait "$qemu_pid" 2>/dev/null || true

printf 'qemu-virt assertions: capture ended (%s, %ss, %s bytes)\n\n' \
  "$reason" "$waited" "$(wc -c < "$log" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------------------
# Assertions.  require = must be present; forbid = must be absent.
# ---------------------------------------------------------------------------
rc=0
require() { # LABEL REGEX
  if grep -Eq -- "$2" "$log"; then
    printf '  PASS  require  %s\n' "$1"
  else
    printf '  FAIL  require  %s\n' "$1"
    rc=1
  fi
}
forbid() { # LABEL REGEX
  if grep -Eq -- "$2" "$log"; then
    printf '  FAIL  forbid   %s\n' "$1"
    rc=1
  else
    printf '  PASS  forbid   %s\n' "$1"
  fi
}

printf 'Required boot milestones (through Shepherd start):\n'
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
