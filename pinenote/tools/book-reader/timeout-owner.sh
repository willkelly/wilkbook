#!/bin/sh
# Fail-closed timeout ownership for one exact command. GNU timeout owns the
# deadline in --foreground mode; this supervisor waits for it and uses
# PID+start-time records to clean up if timeout itself is lost.
set -eu

[ "$#" -ge 6 ] || {
    echo "usage: timeout-owner.sh SECONDS KILL_AFTER COMMAND_RECORD TIMEOUT_RECORD WORKDIR COMMAND..." >&2
    exit 2
}
duration=$1
kill_after=$2
command_record=$3
timeout_record=$4
workdir=$5
shift 5
case "$duration:$kill_after" in
    *[!0-9:]*|:*|*:) echo "timeout durations must be non-negative integers" >&2; exit 2 ;;
esac
[ "$duration" -gt 0 ] && [ "$kill_after" -gt 0 ] || {
    echo "timeout durations must be positive" >&2
    exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/process-identity.sh"
record_exec="$script_dir/record-exec.sh"
timeout_pid=
timeout_start=

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM

    # First stop the recorded command, allowing timeout to reap it. Then stop
    # timeout itself if it has not already exited. Both paths escalate to KILL
    # after a finite TERM grace period and address only recorded identities.
    owned_process_terminate_record "$command_record" || rc=125
    if [ -n "$timeout_pid" ] && [ -z "$timeout_start" ]; then
        timeout_start=$(owned_process_start_time "$timeout_pid" || true)
    fi
    if [ -n "$timeout_pid" ] && [ -n "$timeout_start" ]; then
        owned_process_terminate "$timeout_pid" "$timeout_start" || rc=125
    fi
    owned_process_terminate_record "$timeout_record" || rc=125
    if [ -n "$timeout_pid" ]; then
        wait "$timeout_pid" 2>/dev/null || true
    fi
    owned_process_terminate_record "$command_record" || rc=125
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

rm -f -- "$command_record" "$timeout_record"
(
    cd -- "$workdir"
    exec "$record_exec" "$timeout_record" \
        timeout --foreground --signal=TERM --kill-after="${kill_after}s" \
            "${duration}s" "$record_exec" "$command_record" "$@"
) &
timeout_pid=$!
timeout_start=$(owned_process_start_time "$timeout_pid")

set +e
wait "$timeout_pid"
rc=$?
set -e

# A deadline-owner exit must imply command exit. If timeout was killed or
# otherwise failed open, clean the exact recorded command and force failure.
if owned_process_record_matches "$command_record"; then
    owned_process_terminate_record "$command_record" || rc=125
    [ "$rc" -ne 0 ] || rc=125
fi
timeout_pid=
timeout_start=
exit "$rc"
