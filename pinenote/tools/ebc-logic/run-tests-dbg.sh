#!/bin/sh
# Assertions over the DEBUG-driver harness binary (ebc-refresh-test-dbg:
# the extraction with the linux-pinenote-debug-*.patch stack applied).
# Usage: run-tests-dbg.sh BUILDDIR [/path/to/ebc.wbf]
#
# Three things are proven here, offline:
#   1. the debug patches change no refresh behavior: the full rung-7a
#      suite passes and the rendered goldens hash identically to the
#      committed ones (the same testdata/refresh-goldens.sha256 the
#      primary binary is checked against);
#   2. the EXTRACT_FBS implementation behaves (the extract:* tests
#      inside the dbg binary: pre-modeset -ENODEV, roundtrip, exact
#      sizes under ASan, NULL planes, -EFAULT, the mid-copy kref
#      lifetime guarantee);
#   3. the ebc-dump decoder's conventions match the pinned driver
#      conventions: the container the dbg suite dumps decodes to a
#      final.pgm byte-identical to the harness's own rs_y4_to_gray8
#      rendering, and the decoder selftest pins nibble order + mirror.
set -eu

build=$1
wbf=${2:-}
outdir=$build/dbg-out
sha_file=$(cd "$(dirname "$0")" && pwd)/testdata/refresh-goldens.sha256
rout=$(mktemp)
trap 'rm -f -- "$rout"' EXIT HUP INT TERM

fail=0
mkdir -p "$outdir"

# The WBF-gated half needs the staged firmware dir + LUT dump; reuse
# run-tests.sh's staging if present, else stage here.
fwdir=
rsl=
if [ -n "$wbf" ]; then
  fwdir=$build/fw
  mkdir -p "$fwdir/rockchip"
  cp "$wbf" "$fwdir/rockchip/ebc.wbf"
  rsl=$build/gc16-25.lut
  if [ ! -f "$rsl" ]; then
    make -C ../wbf all > /dev/null
    if ! ../wbf/build/wbf-info --dump-lut GC16 25 "$rsl" "$wbf" > "$build/dump-GC16-dbg.log"; then
      echo "FAIL: wbf-info --dump-lut GC16 (dbg)" >&2
      rsl=
      fail=1
    fi
  fi
fi

if "$build/ebc-refresh-test-dbg" "$fwdir" "$rsl" "$outdir" > "$rout"; then
  :
else
  echo "FAIL: ebc-refresh-test-dbg exited nonzero" >&2
  fail=1
fi

cat "$rout"

if grep -q '^FAIL' "$rout"; then
  fail=1
fi
if ! grep -q '^RESULT: ok$' "$rout"; then
  echo "FAIL: ebc-refresh-test-dbg missing RESULT: ok" >&2
  fail=1
fi
if ! grep -q '^PASS: extract:' "$rout"; then
  echo "FAIL: dbg binary ran no extract tests (EBC_HARNESS_DBG define lost?)" >&2
  fail=1
fi

# --- debug patches must not change refresh behavior: same goldens ---
if (cd "$outdir" && sha256sum -c "$sha_file" > /dev/null 2>&1); then
  echo "PASS: dbg goldens identical to the primary driver's (debug patches change no refresh behavior)"
else
  echo "FAIL: dbg golden images differ from testdata/refresh-goldens.sha256" >&2
  fail=1
fi

# --- decoder selftest + decode differential ---
if "$build/ebc-dump" --selftest > /dev/null; then
  echo "PASS: ebc-dump selftest (nibble order + mirror)"
else
  echo "FAIL: ebc-dump selftest" >&2
  fail=1
fi

if [ -f "$outdir/extract-dump.bin" ]; then
  if "$build/ebc-dump" --json "$outdir/extract-dump.bin" "$outdir/decoded" \
       > "$outdir/extract-dump.json" &&
     cmp -s "$outdir/decoded/final.pgm" "$outdir/extract-final-expected.pgm"; then
    echo "PASS: ebc-dump decode differential (final.pgm byte-identical to the harness rendering)"
  else
    echo "FAIL: ebc-dump decode differential (see $outdir)" >&2
    fail=1
  fi
  # a completed refresh means the driver believes nothing is in flight
  if grep -q '"prev_ne_next": { "count": 0' "$outdir/extract-dump.json"; then
    echo "PASS: ebc-dump json reports prev==next for the quiescent dump"
  else
    echo "FAIL: ebc-dump json prev!=next nonzero for a quiescent dump" >&2
    fail=1
  fi
else
  echo "FAIL: dbg suite produced no extract-dump.bin container" >&2
  fail=1
fi

# --- the grabber is device-side; here it must at least build and answer --help ---
if "$build/ebc-dump-grab" --help > /dev/null; then
  echo "PASS: ebc-dump-grab builds and answers --help (device-only beyond that)"
else
  echo "FAIL: ebc-dump-grab --help" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL DBG TESTS PASSED" || { echo "DBG TESTS FAILED" >&2; }
exit "$fail"
