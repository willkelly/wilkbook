#!/bin/sh
# Record this exact PID and Linux start time, then replace this process with
# the command. The timeout owner uses the record for bounded fallback cleanup.
set -eu

record=$1
shift
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/process-identity.sh"

start=$(owned_process_start_time "$$")
tmp="$record.tmp.$$"
umask 077
printf '%s %s\n' "$$" "$start" >"$tmp"
mv -f -- "$tmp" "$record"
exec "$@"
