#!/bin/sh
# Known mutation-test command: publish its own exact identity, then remain alive.
set -eu

[ "$#" -eq 2 ] || exit 2
record=$1
identity_helper=$2
. "$identity_helper"

start=$(owned_process_start_time "$$")
temporary="$record.tmp.$$"
umask 077
printf '%s %s\n' "$$" "$start" >"$temporary"
mv -f -- "$temporary" "$record"
exec sleep 30
