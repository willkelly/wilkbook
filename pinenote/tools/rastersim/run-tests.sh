#!/bin/sh
# rastersim test runner (offline ladder rung 3).
# Usage: run-tests.sh BUILDDIR [WBF_PATH]
#
# Waveform-independent tests always run; the waveform-dependent ones
# need the device's own ebc.wbf (never committed) and are skipped with a
# message when WBF_PATH is empty.
set -eu

build=$1
wbf=${2:-}
fail=0

# --- waveform-independent unit tests ---
if ! "$build/test-rastersim"; then
  echo "FAIL: test-rastersim" >&2
  fail=1
fi

# --- committed test image is exactly what gen-testimage produces ---
"$build/gen-testimage" "$build/gradient-checker.pgm"
if cmp -s "$build/gradient-checker.pgm" testdata/gradient-checker.pgm; then
  echo "PASS: committed test image matches generator"
else
  echo "FAIL: testdata/gradient-checker.pgm out of date (make regen-goldens)" >&2
  fail=1
fi

# --- quantization goldens ---
"$build/test-rastersim" dump-quant testdata/gradient-checker.pgm "$build"
if (cd "$build" && sha256sum -c ../testdata/quant-goldens.sha256 > /dev/null); then
  echo "PASS: quantization goldens (5 modes, sha256)"
else
  echo "FAIL: quantization output differs from testdata/quant-goldens.sha256" >&2
  fail=1
fi
od -A x -t x1 -v "$build/quant-shift.y4" > "$build/quant-shift.hex"
if cmp -s "$build/quant-shift.hex" testdata/quant-shift.hex; then
  echo "PASS: shift-mode hex golden"
else
  echo "FAIL: shift-mode output differs from testdata/quant-shift.hex" >&2
  diff "$build/quant-shift.hex" testdata/quant-shift.hex | head -5 >&2 || true
  fail=1
fi

# --- waveform-dependent tests ---
if [ -z "$wbf" ]; then
  echo "SKIP: waveform-dependent tests (set WBF=/path/to/ebc.wbf to run them;"
  echo "      the waveform is per-device and never committed — see doc/device-runbook.md)"
else
  # Build the rung-1 tool (extracts the kernel's LUT decoder from the
  # forward-port patch) and dump the LUTs this run needs.
  make -C ../wbf all > /dev/null
  for mode in GC16 GL16 A2 DU; do
    out=$build/$(echo "$mode" | tr 'A-Z' 'a-z')-25.lut
    if ../wbf/build/wbf-info --dump-lut "$mode" 25 "$out" "$wbf" > "$build/dump-$mode.log"; then
      if grep -q '^dump-lut: crosscheck-4bit-packed: ok' "$build/dump-$mode.log"; then
        echo "PASS: dump-lut $mode 25C (axis crosscheck ok)"
      else
        echo "FAIL: dump-lut $mode missing crosscheck" >&2
        fail=1
      fi
    else
      echo "FAIL: dump-lut $mode" >&2
      fail=1
    fi
  done

  if ! "$build/sim-wbf-test" "$build/gc16-25.lut" "$build/gl16-25.lut" \
       "$build/a2-25.lut" "$build/du-25.lut"; then
    echo "FAIL: sim-wbf-test" >&2
    fail=1
  fi
fi

[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED" >&2
exit "$fail"
