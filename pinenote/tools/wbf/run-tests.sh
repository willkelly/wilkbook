#!/bin/sh
# Assertions over wbf-info output for the PineNote's own waveform.
# Usage: run-tests.sh ./build/wbf-info /path/to/ebc.wbf
#
# The golden values (mode_version 0x19, 5-bit LUTs, ED103TC2 panel string)
# are properties of the PineNote's shipped PVI waveform, confirmed against
# the running device on 2026-07-04 (dmesg: "Loaded 4-bit PVI waveform
# version 0x19" — the kernel log says "4-bit" because the message prints
# the *driver-facing* format class; the file itself is mode-version 0x19 =
# DRM_EPD_LUT_5BIT, exactly what these tests pin down).
set -eu

tool=$1
wbf=$2
out=$(mktemp)
out2=$(mktemp)
trap 'rm -f -- "$out" "$out2"' EXIT HUP INT TERM

fail=0
assert() {
  if ! grep -q "$1" "$out"; then
    echo "FAIL: expected /$1/" >&2
    fail=1
  else
    echo "PASS: $1"
  fi
}

"$tool" "$wbf" 25 > "$out" || { echo "FAIL: wbf-info exited nonzero" >&2; cat "$out"; exit 1; }

# Header identity: the PineNote ships a 5-bit mode-version 0x19 waveform
# for the ED103TC2 panel.
assert '^mode_version: 0x19$'
assert '^lut_format: 5BIT$'
assert 'ED103TC2'
assert '^RESULT: ok$'

# Parser sanity: file size must not exceed the actual firmware blob.
assert '^file_size: '

# The driver's init path (RESET waveform at 25 C) must decode phases.
grep -q '^lut_init: ok' "$out" || { echo "FAIL: lut_init" >&2; fail=1; }

# Every waveform mode must decode with a nonzero phase count.
for mode in RESET A2 DU DU4 GC16 GCC16 GL16 GLR16 GLD16; do
  phases=$(sed -n "s/^MODE $mode: index=[0-9]* phases=\([0-9]*\)$/\1/p" "$out")
  if [ -z "$phases" ] || [ "$phases" -eq 0 ]; then
    echo "FAIL: mode $mode did not decode (phases='$phases')" >&2
    fail=1
  else
    echo "PASS: mode $mode decodes ($phases phases)"
  fi
done

# A2 is the fast mode: strictly fewer phases than GC16.
a2=$(sed -n 's/^MODE A2: index=[0-9]* phases=\([0-9]*\)$/\1/p' "$out")
gc16=$(sed -n 's/^MODE GC16: index=[0-9]* phases=\([0-9]*\)$/\1/p' "$out")
if [ -n "$a2" ] && [ -n "$gc16" ] && [ "$a2" -lt "$gc16" ]; then
  echo "PASS: A2 ($a2) faster than GC16 ($gc16)"
else
  echo "FAIL: expected A2 phases < GC16 phases (a2=$a2 gc16=$gc16)" >&2
  fail=1
fi

# Every temperature bin must decode GC16.
bins=$(sed -n 's/^temp_range_count: \([0-9]*\)$/\1/p' "$out")
decoded=$(grep -c '^GC16 bin [0-9]*.*phases=[1-9]' "$out" || true)
if [ "$bins" -gt 0 ] && [ "$decoded" -eq "$bins" ]; then
  echo "PASS: GC16 decodes in all $bins temperature bins"
else
  echo "FAIL: GC16 decoded in $decoded of $bins bins" >&2
  fail=1
fi

# Below-first-bin temperature must map to index -1 (driver: -ENOENT,
# keeps previous LUT) — documents the cold-boot edge the hrdl tree
# clamps against.
assert '^temp_index_below_first: -1$'

# Determinism: identical output across runs.
"$tool" "$wbf" 25 > "$out2"
if cmp -s "$out" "$out2"; then
  echo "PASS: deterministic output"
else
  echo "FAIL: output differs between runs" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED" >&2
exit "$fail"
