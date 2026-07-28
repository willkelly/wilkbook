#!/bin/sh
# Assertions over the ebc-logic test binaries (offline testing ladder,
# rungs 2 and 7a).  Usage: run-tests.sh BUILDDIR [/path/to/ebc.wbf]
#
# ebc-logic-test compiles the verbatim rockchip_ebc.c from the
# forward-port patch and unit-tests its pure logic; ebc-refresh-test
# executes the refresh state machine against the fake device (under
# ASan).  This wrapper checks their outcomes, that the waveform-gated
# tests ran (or were skipped with a clear message), that queued-area teardown
# is ASan-safe, that the rendered
# refresh goldens match, and that output is deterministic across runs.
set -eu

build=$1
wbf=${2:-}
out=$(mktemp)
out2=$(mktemp)
rout=$(mktemp)
rout2=$(mktemp)
pout=$(mktemp)
wout=$(mktemp)
wout2=$(mktemp)
trap 'rm -f -- "$out" "$out2" "$rout" "$rout2" "$pout" "$wout" "$wout2"' EXIT HUP INT TERM

fail=0

# --- rung 2: pure-logic unit tests ---
if "$build/ebc-logic-test" "$wbf" > "$out"; then
  :
else
  echo "FAIL: ebc-logic-test exited nonzero" >&2
  fail=1
fi

cat "$out"

if grep -q '^FAIL' "$out"; then
  fail=1
fi
if ! grep -q '^RESULT: ok$' "$out"; then
  echo "FAIL: missing RESULT: ok" >&2
  fail=1
fi

# --- rung 7a: refresh harness ---
# With a WBF: stage it where the driver's own request_firmware finds it,
# and dump the GC16 25C LUT with the rung-1 tool for the rastersim
# drive-sequence differential.
fwdir=
rsl=
if [ -n "$wbf" ]; then
  fwdir=$build/fw
  mkdir -p "$fwdir/rockchip"
  cp "$wbf" "$fwdir/rockchip/ebc.wbf"
  make -C ../wbf all > /dev/null
  rsl=$build/gc16-25.lut
  if ../wbf/build/wbf-info --dump-lut GC16 25 "$rsl" "$wbf" > "$build/dump-GC16.log"; then
    echo "PASS: dump-lut GC16 25C for the differential"
  else
    echo "FAIL: wbf-info --dump-lut GC16" >&2
    rsl=
    fail=1
  fi
fi

if "$build/ebc-refresh-test" "$fwdir" "$rsl" "$build" > "$rout"; then
  :
else
  echo "FAIL: ebc-refresh-test exited nonzero" >&2
  fail=1
fi

cat "$rout"

if grep -q '^FAIL' "$rout"; then
  fail=1
fi
if ! grep -q '^RESULT: ok$' "$rout"; then
  echo "FAIL: ebc-refresh-test missing RESULT: ok" >&2
  fail=1
fi

# --- refresh goldens (synthetic LUT, deterministic, committed) ---
if (cd "$build" && sha256sum -c ../testdata/refresh-goldens.sha256 > /dev/null 2>&1); then
  echo "PASS: refresh harness golden images (sha256)"
else
  echo "FAIL: refresh golden images differ from testdata/refresh-goldens.sha256" >&2
  fail=1
fi

# --- the phase-B replay workbench (see doc/refresh-policy.md) ---
if "$build/ebc-replay" selftest "$fwdir" > "$pout"; then
  :
else
  echo "FAIL: ebc-replay selftest exited nonzero" >&2
  fail=1
fi

cat "$pout"

if grep -q '^FAIL' "$pout"; then
  fail=1
fi
if ! grep -q '^RESULT: ok$' "$pout"; then
  echo "FAIL: ebc-replay missing RESULT: ok" >&2
  fail=1
fi

# With a WBF, a full synth->replay round trip must also be deterministic
# (the selftest covers correctness; this covers the CLI path end to end).
if [ -n "$wbf" ]; then
  if "$build/ebc-replay" synth "$build/replay-synth.trace" \
       pages=8 menus=1 full-every=4 seed=11 > /dev/null &&
     "$build/ebc-replay" replay "$fwdir" "$build/replay-synth.trace" \
       scale=8 > "$wout" &&
     "$build/ebc-replay" replay "$fwdir" "$build/replay-synth.trace" \
       scale=8 > "$wout2" &&
     cmp -s "$wout" "$wout2" &&
     grep -q '^washes: total=' "$wout"; then
    echo "PASS: ebc-replay CLI round trip is deterministic"
  else
    echo "FAIL: ebc-replay CLI round trip (see $build/replay-synth.trace)" >&2
    fail=1
  fi
fi

# --- waveform gating messages ---
if [ -n "$wbf" ]; then
  if grep -q '^SKIP: waveform' "$out"; then
    echo "FAIL: WBF was given but rung-2 waveform tests were skipped" >&2
    fail=1
  elif grep -q '^SKIP: waveform' "$rout"; then
    echo "FAIL: WBF was given but refresh waveform tests were skipped" >&2
    fail=1
  elif grep -q '^SKIP: waveform' "$pout"; then
    echo "FAIL: WBF was given but replay waveform tests were skipped" >&2
    fail=1
  else
    echo "PASS: waveform-dependent tests ran against $wbf"
  fi
else
  if grep -q '^SKIP: waveform' "$out" && grep -q '^SKIP: waveform' "$rout" &&
     grep -q '^SKIP: waveform' "$pout"; then
    echo "PASS: waveform-dependent tests skipped (no WBF given)"
  else
    echo "FAIL: expected SKIP messages without WBF" >&2
    fail=1
  fi
fi

# --- determinism: identical output across runs (all three binaries) ---
pout2=$(mktemp)
trap 'rm -f -- "$out" "$out2" "$rout" "$rout2" "$pout" "$pout2" "$wout" "$wout2"' EXIT HUP INT TERM
"$build/ebc-logic-test" "$wbf" > "$out2" || true
"$build/ebc-refresh-test" "$fwdir" "$rsl" "$build" > "$rout2" || true
"$build/ebc-replay" selftest "$fwdir" > "$pout2" || true
if cmp -s "$out" "$out2" && cmp -s "$rout" "$rout2" && cmp -s "$pout" "$pout2"; then
  echo "PASS: deterministic output"
else
  echo "FAIL: output differs between runs" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || { echo "TESTS FAILED" >&2; }
exit "$fail"
