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

# --- rung 7a liveness: the inherited starvation, pinned ---
# Reproduces the 2026-07-29 hardware failure offline: while damage arrives
# faster than one area lifetime, rockchip_ebc_partial_refresh never returns,
# so the refresh thread never reads do_one_full_refresh and a REFRESH_BARRIER
# generation is never credited -- with no timeout and no log.  Waveform-gated:
# the starvation boundary is the waveform's own phase count.
#
# Built against build/nogate (mutate-drain-gate.py removes the issue-#22
# work-item drain gate), because the SHIPPING driver no longer starves.
# This binary is the pinned `quirk:` record of what the m-weigand -> hrdl
# lineage's published trees still do; ebc-drain-gate-test below is the
# shipping driver's side of the same question.
sout=$build/starvation.out
if "$build/ebc-refresh-starvation-test" "$fwdir" > "$sout"; then
  :
else
  echo "FAIL: ebc-refresh-starvation-test exited nonzero" >&2
  fail=1
fi

# --- system-sleep bracket: the 2026-08-01 resume defect's pins ---
# quiesce/wake idempotence, poison-on-pending exactly once, no unpark
# into a NULL ctx, poison gating.  Not waveform-gated.
bout=$build/suspend-bracket.out
if "$build/ebc-suspend-bracket-test" > "$bout" && grep -q '^RESULT: ok$' "$bout"; then
  cat "$bout"
else
  cat "$bout" >&2
  echo "FAIL: ebc-suspend-bracket-test failed" >&2
  fail=1
fi

cat "$sout"

if grep -q '^FAIL' "$sout"; then
  fail=1
fi
if ! grep -qE '^RESULT: (ok|skipped)$' "$sout"; then
  echo "FAIL: ebc-refresh-starvation-test missing RESULT" >&2
  fail=1
fi

# --- rung 7a liveness: the work-item drain gate (issue #22) ---
# The positive claim: under the SAME sustained damage supply, a queued
# global refresh must launch, and a kthread_park must complete, within one
# area lifetime.  Waveform-gated -- the bound IS the waveform's phase count.
gout=$build/drain-gate.out
if "$build/ebc-drain-gate-test" "$fwdir" > "$gout"; then
  :
else
  echo "FAIL: ebc-drain-gate-test exited nonzero" >&2
  fail=1
fi

cat "$gout"

if grep -q '^FAIL' "$gout"; then
  fail=1
fi
if ! grep -qE '^RESULT: (ok|skipped)$' "$gout"; then
  echo "FAIL: ebc-drain-gate-test missing RESULT" >&2
  fail=1
fi

# --- and the negative test of that test ---
# The identical source compiled against build/nogate, i.e. the driver with
# the drain gate removed -- what the m-weigand lineage still ships.  It MUST
# fail; a liveness test that passes with and without the gate proves nothing.
ngout=$build/drain-gate-nogate.out
if [ -n "$wbf" ]; then
  if "$build/ebc-drain-gate-test-nogate" "$fwdir" > "$ngout" 2>&1; then
    echo "FAIL: the drain-gate test PASSES against the ungated driver -- it proves nothing" >&2
    cat "$ngout" >&2
    fail=1
  elif grep -q '^FAIL: rotating-damage: the queued global LAUNCHED while damage kept arriving' "$ngout" &&
       grep -q '^FAIL: park: parked ' "$ngout"; then
    echo "PASS: drain-gate test goes red against the ungated driver ($(grep -c '^FAIL' "$ngout") assertions)"
  else
    echo "FAIL: ungated build failed, but not on the starvation assertions" >&2
    cat "$ngout" >&2
    fail=1
  fi
else
  if "$build/ebc-drain-gate-test-nogate" "" > "$ngout" 2>&1 &&
     grep -q '^RESULT: skipped$' "$ngout"; then
    echo "PASS: drain-gate negative gate skipped (no WBF given)"
  else
    echo "FAIL: drain-gate negative gate did not skip cleanly without a WBF" >&2
    fail=1
  fi
fi

# --- the CONFIG_DRM_FBDEV_EMULATION blocks ---
# The only binary that defines the config, so the only one that compiles
# the driver's fbdev-guarded code: defio_delay_ms and its live retarget,
# the fbdev_probe wrapper, the publish-on-call deferred-io drain in
# GLOBAL_REFRESH, the resume barrier, and remove()'s clearing of the
# helper static.  Its workqueue is synchronous: ORDERING, never
# race-freedom -- see the header of ebc-fbdev-order-test.c.
fout=$build/fbdev-order.out
if "$build/ebc-fbdev-order-test" "$fwdir" > "$fout"; then
  :
else
  echo "FAIL: ebc-fbdev-order-test exited nonzero" >&2
  fail=1
fi

cat "$fout"

if grep -q '^FAIL' "$fout"; then
  fail=1
fi
if ! grep -qE '^RESULT: (ok|skipped)$' "$fout"; then
  echo "FAIL: ebc-fbdev-order-test missing RESULT" >&2
  fail=1
fi

# --- and the negative test of that test ---
# The identical source compiled against the pre-fix ordering
# (mutate-prefix-order.py moves the arm back after the drain: byte-for-byte
# the code `git show 8665ed8^` carried, modulo the added comment).  It MUST
# fail; a test that passes on both orderings proves nothing.  Waveform-gated,
# because the discriminating assertion counts partial frames and the frame
# count IS the waveform's phase count.
pfout=$build/fbdev-order-prefix.out
if [ -n "$wbf" ]; then
  if "$build/ebc-fbdev-order-test-prefix" "$fwdir" > "$pfout" 2>&1; then
    echo "FAIL: the ordering test PASSES against the pre-fix ordering -- it proves nothing" >&2
    cat "$pfout" >&2
    fail=1
  elif grep -q '^FAIL: one GLOBAL_REFRESH intent costs exactly one global refresh' "$pfout"; then
    echo "PASS: ordering test goes red against the pre-fix ordering ($(grep -c '^FAIL' "$pfout") assertions)"
  else
    echo "FAIL: pre-fix build failed, but not on the ordering assertion" >&2
    cat "$pfout" >&2
    fail=1
  fi
else
  if "$build/ebc-fbdev-order-test-prefix" "" > "$pfout" 2>&1 &&
     grep -q '^RESULT: skipped$' "$pfout"; then
    echo "PASS: pre-fix negative gate skipped (no WBF given)"
  else
    echo "FAIL: pre-fix negative gate did not skip cleanly without a WBF" >&2
    fail=1
  fi
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
  elif grep -q '^SKIP: waveform' "$fout"; then
    echo "FAIL: WBF was given but fbdev-order waveform tests were skipped" >&2
    fail=1
  else
    echo "PASS: waveform-dependent tests ran against $wbf"
  fi
else
  if grep -q '^SKIP: waveform' "$out" && grep -q '^SKIP: waveform' "$rout" &&
     grep -q '^SKIP: waveform' "$pout" && grep -q '^SKIP: waveform' "$fout"; then
    echo "PASS: waveform-dependent tests skipped (no WBF given)"
  else
    echo "FAIL: expected SKIP messages without WBF" >&2
    fail=1
  fi
fi

# --- determinism: identical output across runs (all three binaries) ---
pout2=$(mktemp)
fout2=$(mktemp)
gout2=$(mktemp)
trap 'rm -f -- "$out" "$out2" "$rout" "$rout2" "$pout" "$pout2" "$fout2" "$gout2" "$wout" "$wout2"' EXIT HUP INT TERM
"$build/ebc-logic-test" "$wbf" > "$out2" || true
"$build/ebc-refresh-test" "$fwdir" "$rsl" "$build" > "$rout2" || true
"$build/ebc-replay" selftest "$fwdir" > "$pout2" || true
"$build/ebc-fbdev-order-test" "$fwdir" > "$fout2" || true
"$build/ebc-drain-gate-test" "$fwdir" > "$gout2" || true
if cmp -s "$out" "$out2" && cmp -s "$rout" "$rout2" && cmp -s "$pout" "$pout2" &&
   cmp -s "$fout" "$fout2" && cmp -s "$gout" "$gout2"; then
  echo "PASS: deterministic output"
else
  echo "FAIL: output differs between runs" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || { echo "TESTS FAILED" >&2; }
exit "$fail"
