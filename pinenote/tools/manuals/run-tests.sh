#!/bin/sh
# Host-side gate for the manual/info -> EPUB converter (issue #17).
#
# Exercises the REPO's converter -- pinenote/packages/manuals/manuals.py, the
# exact file pinenote/packages/manuals.scm hands to the build -- so a change
# to the shipped converter is what turns this red, not a copy of it.
#
#   ./run-tests.sh [/path/to/mandoc]
#
# mandoc is OPTIONAL.  Without it the roff stage cannot run and the
# end-to-end pass says SKIP; the post-processor is still covered, against
# fixtures/wilkdemo.1.mandoc-html -- mandoc's own output for
# fixtures/wilkdemo.1, committed so this suite has something real to chew on
# on a host with no roff formatter at all.  Regenerate it with:
#
#   mandoc -Thtml -O 'fragment,man=#%N.%S' -Ios=PineNote \
#       fixtures/wilkdemo.1 > fixtures/wilkdemo.1.mandoc-html
#
# Everything else is Python 3 standard library.  No device, no waveform, no
# Guix: the converter evaluates no Guix module and never looks at the store.
set -eu

tool_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$tool_dir/../../.." && pwd)
converter_dir=$repo_root/pinenote/packages/manuals

mandoc=${1:-${MANDOC:-}}
if [ -z "$mandoc" ]; then
  mandoc=$(command -v mandoc 2>/dev/null || true)
fi

if [ ! -f "$converter_dir/manuals.py" ]; then
  echo "FAIL: no converter at $converter_dir/manuals.py" >&2
  exit 1
fi

out=$(mktemp)
out2=$(mktemp)
trap 'rm -f -- "$out" "$out2"' EXIT HUP INT TERM

fail=0

if [ -n "$mandoc" ]; then
  echo "mandoc: $mandoc"
else
  echo "mandoc: none on PATH (roff stage will report SKIP)"
fi

if python3 "$tool_dir/test-manuals.py" "$tool_dir" "$converter_dir" \
     "$mandoc" > "$out" 2>&1; then
  :
else
  echo "FAIL: test-manuals.py exited nonzero" >&2
  fail=1
fi
cat "$out"
grep -q '^RESULT: ok$' "$out" || { echo "FAIL: no RESULT: ok" >&2; fail=1; }

# The converter runs inside a Guix derivation, where a nondeterministic
# result would make every unrelated rebuild look like a change.  Same
# assertion the suite makes about one book, made about the whole run.
python3 "$tool_dir/test-manuals.py" "$tool_dir" "$converter_dir" \
  "$mandoc" > "$out2" 2>&1 || true
if cmp -s "$out" "$out2"; then
  echo "PASS: test output is identical across two runs"
else
  echo "FAIL: test output differs between runs" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "ALL TESTS PASSED" || { echo "TESTS FAILED" >&2; }
exit "$fail"
