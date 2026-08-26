#!/bin/sh
# validate-reader-stop.sh -- reader-session's stop destructor must send
# SIGINT and wait BEFORE any kill-style termination.  KOReader's INT
# handler runs the clean close that flushes the crengine cache; TERM --
# what make-kill-destructor leads with -- truncates that cache to zero
# bytes, and the next open of the same book silently pays a full
# re-parse (measured on glass 2026-08-26: 30.3 s for the 538-document
# manuals book vs 1.7 s cached; doc/manuals.md).  This gate pins the
# ordering and the dead-pid guard so a refactor cannot quietly restore
# the cache-destroying stop.
set -eu
cd "$(dirname "$0")/../../.."

svc=pinenote/services/reader-session.scm
fail=0

# The check itself, over an arbitrary file so the positive control can
# run it against a mutated copy.
check_stop() {
	f=$1
	# the stop block, from "(stop" to the next "(define"
	stop_block=$(sed -n '/^    (stop/,/^(define/p' "$f")
	[ -n "$stop_block" ] || { echo "no stop block found in $f"; return 1; }
	# match the actual call, not the comment that mentions SIGINT -- a
	# refactor that keeps the prose but drops the kill must fail here
	printf '%s\n' "$stop_block" | grep -q '(kill pid SIGINT)' || {
		echo "stop block has no (kill pid SIGINT) call"; return 1; }
	# the call must come before make-kill-destructor in the block
	int_line=$(printf '%s\n' "$stop_block" | grep -n '(kill pid SIGINT)' | head -1 | cut -d: -f1)
	kill_line=$(printf '%s\n' "$stop_block" | grep -nF '(make-kill-destructor)' | head -1 | cut -d: -f1)
	[ -n "$kill_line" ] || { echo "stop block lost the (make-kill-destructor) call (the wedged-reader fallback)"; return 1; }
	[ "$int_line" -lt "$kill_line" ] || {
		echo "SIGINT does not precede make-kill-destructor"; return 1; }
	# the dead-pid guard: the destructor must be conditional on liveness
	printf '%s\n' "$stop_block" | grep -q 'alive? pid' || {
		echo "stop block lost the alive? guard"; return 1; }
	return 0
}

# Positive controls: a copy with the CALL stripped (comment intact) must
# FAIL, and so must a copy with SIGINT stripped everywhere.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed 's/(kill pid SIGINT)/(kill pid SIGXXX)/g' "$svc" > "$tmp"
if check_stop "$tmp" >/dev/null 2>&1; then
	echo "FAIL: positive control -- the check passed a stop whose kill call is gone (comment kept)" >&2
	exit 1
fi
echo "PASS: positive control: a call-less stop is rejected even with the comment intact"
sed 's/SIGINT/SIGXXX/g' "$svc" > "$tmp"
if check_stop "$tmp" >/dev/null 2>&1; then
	echo "FAIL: positive control -- the check passed a stop with no SIGINT" >&2
	exit 1
fi
echo "PASS: positive control: a SIGINT-less stop is rejected"

if msg=$(check_stop "$svc" 2>&1); then
	echo "PASS: reader-session stop is INT-first with a guarded kill fallback"
else
	echo "FAIL: $svc: $msg" >&2
	fail=1
fi

exit $fail
