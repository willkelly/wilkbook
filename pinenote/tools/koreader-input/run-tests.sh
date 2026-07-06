#!/bin/sh
# Assertions over KOReader's verbatim input stack (offline testing
# ladder): runs test-mixedrouter.lua under the native koreader-bin
# bundle's own luajit, against the bundle's own frontend/device/input.lua
# + gesturedetector.lua, with the REPO's mixedrouter.lua as the fix
# under test.  Usage: run-tests.sh [/gnu/store/...-koreader-bin-...]
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
router=$repo_root/pinenote/packages/koreader-device/frontend/device/pinenote/mixedrouter.lua

if [ ! -x "$luajit" ]; then
  echo "FAIL: no luajit at $luajit (is $bundle a koreader-bin bundle?)" >&2
  exit 1
fi
if [ ! -f "$router" ]; then
  echo "FAIL: mixedrouter.lua not found at $router" >&2
  exit 1
fi

out=$(mktemp)
out2=$(mktemp)
trap 'rm -f -- "$out" "$out2"' EXIT HUP INT TERM

fail=0

echo "bundle: $bundle"

if "$luajit" "$tool_dir/test-mixedrouter.lua" "$koreader" "$router" > "$out"; then
  :
else
  echo "FAIL: test-mixedrouter.lua exited nonzero" >&2
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

# --- determinism: identical output across runs ---
"$luajit" "$tool_dir/test-mixedrouter.lua" "$koreader" "$router" > "$out2" || true
if cmp -s "$out" "$out2"; then
  echo "PASS: deterministic output"
else
  echo "FAIL: output differs between runs" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || { echo "TESTS FAILED" >&2; }
exit "$fail"
