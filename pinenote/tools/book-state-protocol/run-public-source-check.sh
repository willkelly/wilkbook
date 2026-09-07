#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { echo "usage: run-public-source-check.sh SOURCE_ROOT" >&2; exit 2; }
root=$1
case "$root" in /*) ;; *) echo "SOURCE_ROOT must be absolute" >&2; exit 2 ;; esac
exec "$root/pinenote/tools/book-source-check/run.sh" \
    check-task state-protocol-suite --source-root "$root"
