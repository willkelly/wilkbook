#!/bin/sh
# Regression fixture: one process, no subprocesses, deliberately ignores TERM.
set -eu

ready=$1
trap '' HUP INT TERM
printf 'ready\n' >"$ready"
while :; do :; done
