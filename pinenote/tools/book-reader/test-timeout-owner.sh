#!/bin/sh
# Prove both deadline and caller-signal paths clean a TERM-resistant command by
# exact PID+start-time ownership, without process-name matching.
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$tool_dir/process-identity.sh"
tmp_base=${TMPDIR:-/tmp/opencode}
mkdir -p "$tmp_base"
test_root=$(mktemp -d "$tmp_base/book-reader-timeout.XXXXXX")
outer_pid=
outer_start=

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ -n "$outer_pid" ] && [ -n "$outer_start" ]; then
        owned_process_terminate "$outer_pid" "$outer_start" || rc=1
        wait "$outer_pid" 2>/dev/null || true
    fi
    owned_process_terminate_record "$test_root/deadline-command.pid" || rc=1
    owned_process_terminate_record "$test_root/deadline-timeout.pid" || rc=1
    owned_process_terminate_record "$test_root/signal-command.pid" || rc=1
    owned_process_terminate_record "$test_root/signal-timeout.pid" || rc=1
    owned_process_terminate_record "$test_root/lost-command.pid" || rc=1
    owned_process_terminate_record "$test_root/lost-timeout.pid" || rc=1
    rm -rf -- "$test_root"
    exit "$rc"
}
trap cleanup EXIT HUP INT TERM

set +e
"$tool_dir/timeout-owner.sh" 1 1 \
    "$test_root/deadline-command.pid" "$test_root/deadline-timeout.pid" \
    "$test_root" "$tool_dir/term-resistant-helper.sh" \
    "$test_root/deadline-ready"
deadline_rc=$?
set -e
case "$deadline_rc" in
    124|137) ;;
    *) echo "FAIL: TERM-resistant deadline returned $deadline_rc" >&2; exit 1 ;;
esac
[ -f "$test_root/deadline-ready" ] || {
    echo "FAIL: TERM-resistant deadline helper did not start" >&2
    exit 1
}
if owned_process_record_matches "$test_root/deadline-command.pid" \
        || owned_process_record_matches "$test_root/deadline-timeout.pid"; then
    echo "FAIL: deadline path left a recorded process" >&2
    exit 1
fi
echo "PASS: foreground timeout killed TERM-resistant exact process"

"$tool_dir/timeout-owner.sh" 30 1 \
    "$test_root/signal-command.pid" "$test_root/signal-timeout.pid" \
    "$test_root" "$tool_dir/term-resistant-helper.sh" \
    "$test_root/signal-ready" &
outer_pid=$!
outer_start=$(owned_process_start_time "$outer_pid")
i=0
while [ ! -f "$test_root/signal-ready" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
[ -f "$test_root/signal-ready" ] || {
    echo "FAIL: signal-path helper did not start" >&2
    exit 1
}
kill -TERM "$outer_pid"
i=0
while owned_process_alive "$outer_pid" "$outer_start" && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
if owned_process_alive "$outer_pid" "$outer_start"; then
    echo "FAIL: signalled timeout owner did not exit within bound" >&2
    exit 1
fi
set +e
wait "$outer_pid"
signal_rc=$?
set -e
outer_pid=
outer_start=
[ "$signal_rc" -eq 143 ] || {
    echo "FAIL: signalled timeout owner returned $signal_rc, expected 143" >&2
    exit 1
}
if owned_process_record_matches "$test_root/signal-command.pid" \
        || owned_process_record_matches "$test_root/signal-timeout.pid"; then
    echo "FAIL: signal path left a recorded process" >&2
    exit 1
fi
echo "PASS: signal cleanup killed TERM-resistant exact process"

"$tool_dir/timeout-owner.sh" 30 1 \
    "$test_root/lost-command.pid" "$test_root/lost-timeout.pid" \
    "$test_root" "$tool_dir/term-resistant-helper.sh" \
    "$test_root/lost-ready" >"$test_root/lost-owner.log" 2>&1 &
outer_pid=$!
outer_start=$(owned_process_start_time "$outer_pid")
i=0
while { [ ! -f "$test_root/lost-ready" ] \
        || [ ! -f "$test_root/lost-timeout.pid" ]; } && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
[ -f "$test_root/lost-ready" ] && [ -f "$test_root/lost-timeout.pid" ] || {
    echo "FAIL: timeout-loss helper did not start" >&2
    exit 1
}
read -r lost_timeout_pid lost_timeout_start <"$test_root/lost-timeout.pid"
owned_process_alive "$lost_timeout_pid" "$lost_timeout_start" || {
    echo "FAIL: recorded timeout owner was not alive" >&2
    exit 1
}
kill -KILL "$lost_timeout_pid"
i=0
while owned_process_alive "$outer_pid" "$outer_start" && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
if owned_process_alive "$outer_pid" "$outer_start"; then
    echo "FAIL: supervisor did not fail closed after timeout loss" >&2
    exit 1
fi
set +e
wait "$outer_pid"
lost_rc=$?
set -e
outer_pid=
outer_start=
[ "$lost_rc" -ne 0 ] || {
    echo "FAIL: timeout loss returned success" >&2
    exit 1
}
if owned_process_record_matches "$test_root/lost-command.pid" \
        || owned_process_record_matches "$test_root/lost-timeout.pid"; then
    echo "FAIL: timeout-loss path left a recorded process" >&2
    exit 1
fi
echo "PASS: timeout-owner loss failed closed without process residue"
echo "RESULT: ok"
