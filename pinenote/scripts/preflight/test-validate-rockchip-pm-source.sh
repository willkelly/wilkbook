#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
validator="$script_dir/validate-rockchip-pm-source.sh"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-validate-rockchip-pm-source.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

mkdir "$tmpdir/source"
printf 'good\n' >"$tmpdir/patch"
cat >"$tmpdir/check.py" <<'PY'
import sys
from pathlib import Path

if sys.argv[1] == "--source-tree":
    raise SystemExit(1 if (Path(sys.argv[2]) / "reject").exists() else 0)
raise SystemExit(1 if Path(sys.argv[1]).read_text() != "good\n" else 0)
PY

expect_rejected() {
  description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: validator accepted %s\n' "$description" >&2
    exit 1
  fi
}

sh "$validator" "$tmpdir/check.py" "$tmpdir/patch" "$tmpdir/source" >/dev/null
expect_rejected "missing checker" sh "$validator" "$tmpdir/missing.py" "$tmpdir/patch" "$tmpdir/source"
expect_rejected "missing canonical patch" sh "$validator" "$tmpdir/check.py" "$tmpdir/missing.patch" "$tmpdir/source"
expect_rejected "missing source tree" sh "$validator" "$tmpdir/check.py" "$tmpdir/patch" "$tmpdir/missing-source"

printf 'bad\n' >"$tmpdir/patch"
expect_rejected "canonical patch failure" sh "$validator" "$tmpdir/check.py" "$tmpdir/patch" "$tmpdir/source"
printf 'good\n' >"$tmpdir/patch"
touch "$tmpdir/source/reject"
expect_rejected "applied-source failure" sh "$validator" "$tmpdir/check.py" "$tmpdir/patch" "$tmpdir/source"

mkdir "$tmpdir/no-python"
expect_rejected "missing python3" env PATH="$tmpdir/no-python" /bin/sh "$validator" \
  "$tmpdir/check.py" "$tmpdir/patch" "$tmpdir/source"
mkdir "$tmpdir/python-only"
ln -s "$(command -v python3)" "$tmpdir/python-only/python3"
expect_rejected "missing git" env PATH="$tmpdir/python-only" /bin/sh "$validator" \
  "$tmpdir/check.py" "$tmpdir/patch" "$tmpdir/source"

printf 'PASS: Rockchip PM patch/source wrapper rejects dependency and validation failures\n'
