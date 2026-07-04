#!/bin/sh
# Assertions over ebc-logic-test output (offline testing ladder, rung 2).
# Usage: run-tests.sh ./build/ebc-logic-test [/path/to/ebc.wbf]
#
# The test binary compiles the verbatim rockchip_ebc.c from the
# forward-port patch and unit-tests its pure logic; this wrapper checks
# the outcome, that the waveform-gated tests ran (or were skipped with a
# clear message), and that the output is deterministic across runs.
set -eu

tool=$1
wbf=${2:-}
out=$(mktemp)
out2=$(mktemp)
trap 'rm -f -- "$out" "$out2"' EXIT HUP INT TERM

fail=0

if "$tool" "$wbf" > "$out"; then
  :
else
  echo "FAIL: $tool exited nonzero" >&2
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

if [ -n "$wbf" ]; then
  if grep -q '^SKIP: waveform' "$out"; then
    echo "FAIL: WBF was given but waveform tests were skipped" >&2
    fail=1
  else
    echo "PASS: waveform-dependent tests ran against $wbf"
  fi
else
  if grep -q '^SKIP: waveform' "$out"; then
    echo "PASS: waveform-dependent tests skipped (no WBF given)"
  else
    echo "FAIL: expected a SKIP message without WBF" >&2
    fail=1
  fi
fi

# Determinism: identical output across runs (fixed-seed PRNG only).
"$tool" "$wbf" > "$out2" || true
if cmp -s "$out" "$out2"; then
  echo "PASS: deterministic output"
else
  echo "FAIL: output differs between runs" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || { echo "TESTS FAILED" >&2; }
exit "$fail"
