#!/bin/sh
# Assertions over KOReader's verbatim input stack (offline testing
# ladder), run under the native koreader-bin bundle's own luajit against
# the bundle's own frontend/device/input.lua + gesturedetector.lua:
#
#   * test-mixedrouter.lua   -- the pen-hover tap-capture bug + the
#                               REPO's mixedrouter.lua fix under test;
#   * test-optics-inject.lua -- the optics page-turn injector and orientation
#                               bridge discovery/MSC_RAW translation chains:
#                               the REPO device.lua's 'wilkbook-optics'
#                               whitelist + the 159/158 -> RPgFwd/RPgBack
#                               key mapping (optics PLAN task 1);
#   * test-idlewasher-logic.lua -- the idle-washer refresh manager: the
#                               pure debt/idle decision core, plus the
#                               REPO plugin main.lua wired to a recording
#                               UIManager over the bundle's verbatim
#                               hook container (doc/refresh-policy.md
#                               finding 10's userspace-wash policy).
#   * test-touch-normalization.lua -- cyttsp5 source-gated MT-axis mirror
#                               against measured TOP-mode calibration points.
#   * test-continuous-gesture-cost.lua -- what a continuous two-finger
#                               gesture actually costs (issue #26): one
#                               terminal pinch/spread per interaction
#                               whatever the frame count, the mid-gesture
#                               inward_pan/outward_pan variants having no
#                               consumer anywhere, upstream's verbatim
#                               gesToFontSize arithmetic, and the 900 ms
#                               swipe-interval ceiling that makes a slow
#                               pinch a silent no-op;
#   * test-refresh-seam.lua  -- publish-on-call seam: every refresh*Imp
#                               the REPO device.lua overrides must still
#                               exist on the bundle's verbatim
#                               ffi/framebuffer.lua (loaded, not
#                               grepped), and every override must call
#                               publish() with publish-before-wash
#                               ordering (doc/refresh-policy.md).
#   * test-rotation-decision.lua -- the rotation-decision hierarchy the
#                               rung-4v D5 investigation mapped
#                               (2026-08-25): closed_rotation_mode is
#                               the boot decider; lock_rotation gates
#                               the doc-sidecar/copt and FM restores;
#                               the orientation state file is reachable
#                               only through toggleGSensor, which
#                               nothing on the boot path calls.  Source
#                               pins over the bundle's verbatim files,
#                               so a KOReader upgrade that moves any
#                               link fails loudly.
#
# Usage: run-tests.sh [/gnu/store/...-koreader-bin-...]
#
# The bundle is resolved (in order) from: $1, $KOREADER_BUNDLE, or
# `guix build -L <repo> koreader-bin` (native, cached -- seconds).
set -eu

tool_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$tool_dir/../../.." && pwd)

bundle=${1:-${KOREADER_BUNDLE:-}}
if [ -z "$bundle" ]; then
  bundle=$(guix build -L "$repo_root" koreader-bin | tail -n 1)
fi

luajit=$bundle/lib/koreader/luajit
koreader=$bundle/lib/koreader
pinenote_dev=$repo_root/pinenote/packages/koreader-device/frontend/device/pinenote
router=$pinenote_dev/mixedrouter.lua
device_lua=$pinenote_dev/device.lua
koreader_device=$repo_root/pinenote/packages/koreader-device
idlewasher=$koreader_device/plugins/idlewasher.koplugin

if [ ! -x "$luajit" ]; then
  echo "FAIL: no luajit at $luajit (is $bundle a koreader-bin bundle?)" >&2
  exit 1
fi
if [ ! -f "$router" ]; then
  echo "FAIL: mixedrouter.lua not found at $router" >&2
  exit 1
fi
if [ ! -f "$device_lua" ]; then
  echo "FAIL: device.lua not found at $device_lua" >&2
  exit 1
fi
if [ ! -f "$idlewasher/main.lua" ] || [ ! -f "$idlewasher/idlewasher_core.lua" ]; then
  echo "FAIL: idlewasher.koplugin not found at $idlewasher" >&2
  exit 1
fi

out=$(mktemp)
out2=$(mktemp)
trap 'rm -f -- "$out" "$out2"' EXIT HUP INT TERM

fail=0

echo "bundle: $bundle"

# run_case <label> <script> [args...]: run twice (PASS/FAIL scan +
# RESULT marker + output determinism across runs).
run_case() {
  label=$1; script=$2; shift 2
  if "$luajit" "$script" "$@" > "$out"; then
    :
  else
    echo "FAIL: $label exited nonzero" >&2
    fail=1
  fi

  cat "$out"

  if grep -q '^FAIL' "$out"; then
    fail=1
  fi
  if ! grep -q '^RESULT: ok$' "$out"; then
    echo "FAIL: $label missing RESULT: ok" >&2
    fail=1
  fi

  "$luajit" "$script" "$@" > "$out2" || true
  if cmp -s "$out" "$out2"; then
    echo "PASS: $label deterministic output"
  else
    echo "FAIL: $label output differs between runs" >&2
    fail=1
  fi
}

run_case test-mixedrouter.lua "$tool_dir/test-mixedrouter.lua" \
  "$koreader" "$router"
run_case test-slotguard.lua "$tool_dir/test-slotguard.lua" \
  "$koreader" "$router" "$pinenote_dev/slotguard.lua"
run_case test-optics-inject.lua "$tool_dir/test-optics-inject.lua" \
  "$koreader" "$device_lua" "$router"
run_case test-idlewasher-logic.lua "$tool_dir/test-idlewasher-logic.lua" \
  "$koreader" "$idlewasher"
run_case test-touch-normalization.lua "$tool_dir/test-touch-normalization.lua" \
  "$koreader" "$device_lua"
run_case test-refresh-seam.lua "$tool_dir/test-refresh-seam.lua" \
  "$koreader" "$device_lua"
run_case test-continuous-gesture-cost.lua \
  "$tool_dir/test-continuous-gesture-cost.lua" "$koreader" "$koreader_device"
run_case test-rotation-decision.lua "$tool_dir/test-rotation-decision.lua" \
  "$koreader" "$device_lua"

# Required-device loss is a poll/HUP contract, independent of input-event
# payloads. Exercise both registrations and an optional node independently.
run_required_case() {
  label=$1; lost=$2; expected=$3
  required_tmp=$(mktemp -d)
  mkfifo "$required_tmp/first" "$required_tmp/second" "$required_tmp/optional"
  "$luajit" "$tool_dir/test-required-device.lua" "$koreader" \
    "$repo_root/pinenote/packages/koreader-device/ffi/input_evdev.lua" \
    "$required_tmp/first" "$required_tmp/second" "$required_tmp/optional" \
    "$required_tmp/$lost" "$expected" "$required_tmp/ready" > "$required_tmp/out" 2>&1 &
  required_pid=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$required_tmp/ready" ]; do sleep 0.1; i=$((i+1)); done
  if [ -s "$required_tmp/ready" ]; then
    : > "$required_tmp/$lost"
    wait "$required_pid" || fail=1
    cat "$required_tmp/out"
    grep -q '^RESULT: ok$' "$required_tmp/out" || fail=1
  else
    echo "FAIL: $label lifecycle test did not open its FIFOs" >&2
    cat "$required_tmp/out" >&2 || true
    kill "$required_pid" 2>/dev/null || true
    fail=1
  fi
  rm -rf -- "$required_tmp"
}
run_required_case first-required first fatal
run_required_case second-required second fatal
run_required_case optional optional nonfatal

# --- opportunistic: the injector daemon body against the HOST's real
# /dev/uinput (needs write access; skipped cleanly where root-only).
# Proves the ffi struct layout + ioctl numbers + naming live: create ->
# a device named 'wilkbook-optics' appears in sysfs with EXACTLY the
# declared capabilities (EV_SYN|EV_KEY; keybits 139/158/159 = key
# bitmap word 'c0000800') -> QUIT destroys it.  No key event is ever
# emitted, so nothing can leak into the host's input session.
optics_daemon=$repo_root/pinenote/tools/optics/optics-inject.lua
if [ -w /dev/uinput ] && [ -f "$optics_daemon" ]; then
  tmpd=$(mktemp -d)
  mkfifo "$tmpd/fifo"
  ( setsid "$luajit" "$optics_daemon" "$tmpd/fifo" "$tmpd/pid" \
      > "$tmpd/log" 2>&1 & )
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$tmpd/pid" ]; do sleep 0.1; i=$((i+1)); done
  node=$(grep -l '^wilkbook-optics$' /sys/class/input/event*/device/name \
           2>/dev/null | head -n 1 || true)
  if [ -s "$tmpd/pid" ] && [ -n "$node" ]; then
    devdir=$(dirname "$node")
    caps=$(cat "$devdir/capabilities/key")
    evs=$(cat "$devdir/capabilities/ev")
    # shellcheck disable=SC2086
    set -- $caps
    caps_ok=1
    [ "$1" = "c0000800" ] || caps_ok=0
    shift
    for w in "$@"; do [ "$w" = "0" ] || caps_ok=0; done
    if [ "$caps_ok" -eq 1 ] && [ "$evs" = "3" ]; then
      echo "PASS: uinput-live: 'wilkbook-optics' created with exactly keybits 139/158/159 + EV_SYN|EV_KEY"
    else
      echo "FAIL: uinput-live: wrong capabilities (key='$caps' ev='$evs')" >&2
      fail=1
    fi
    kill -0 "$(cat "$tmpd/pid")" 2>/dev/null && printf 'QUIT\n' > "$tmpd/fifo"
    sleep 0.5
    if grep -q '^wilkbook-optics$' /sys/class/input/event*/device/name 2>/dev/null; then
      echo "FAIL: uinput-live: device survived QUIT" >&2
      fail=1
    elif [ -e "$tmpd/pid" ]; then
      echo "FAIL: uinput-live: pid file not removed on QUIT" >&2
      fail=1
    else
      echo "PASS: uinput-live: QUIT destroyed the device and cleaned up"
    fi
  else
    echo "FAIL: uinput-live: daemon did not come up (log follows)" >&2
    cat "$tmpd/log" >&2 || true
    fail=1
  fi
  rm -rf -- "$tmpd"
else
  echo "SKIP: uinput-live (no writable /dev/uinput on this host)"
fi

[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || { echo "TESTS FAILED" >&2; }
exit "$fail"
