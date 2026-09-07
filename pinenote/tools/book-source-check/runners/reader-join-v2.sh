#!/bin/sh
# Deadline/process owner for the public reader-join v2 source successor.
set -eu

[ "$#" -eq 3 ] || {
    echo "usage: reader-join-v2.sh PREPARED_ROOT RUN_ROOT KOREADER_OUTPUT" >&2
    exit 2
}
prepared=$1
run_root=$2
koreader=$3
ulimit -f 8192
closure="$prepared/closure"
join="$closure/join"
inner="$prepared/repo/pinenote/tools/book-source-check/runners/reader-join-inner.sh"
private_helper="$prepared/repo/pinenote/tools/book-source-check/private-environment.sh"
mkdir -m 700 "$run_root/join" "$run_root/empty-package-view"
run="$run_root/join"
helper_loaded=0
. "$private_helper"
private_environment="$run_root/private-environment"
book_source_create_private_environment "$private_environment"

cleanup () {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$helper_loaded" -eq 1 ] && [ -d "$run" ]; then
        records="$run/.cleanup-process-records"
        find "$run" -type f -name '*.pid' -print >"$records"
        while IFS= read -r record; do
            owned_process_terminate_record "$record" || rc=125
        done <"$records"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sh "$join/verify-source-closure.sh" "$closure"
private_process_identity="$join/accepted-helper/process-identity.sh"
[ "$(sha256sum "$private_process_identity" | sed 's/ .*//')" = \
  97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354 ]
# shellcheck source=/dev/null
. "$private_process_identity"
helper_loaded=1

env -u BOOK_JOIN_PYTHON_CODEC -u BOOK_JOIN_BOOK_GUILE_LOAD_PATH \
    -u BOOK_JOIN_BOOK_GUILE_COMPILED_PATH \
    "$BOOK_SOURCE_GUIX" time-machine \
    -C "$closure/native-v2/accepted-inputs/channels.scm" -- \
    shell --pure --no-grafts --max-jobs=1 --cores=2 \
    -L "$run_root/empty-package-view" \
    -m "$join/test-manifest.scm" -- \
    sh "$inner" "$closure" "$run" "$koreader" \
        "$private_helper" "$private_environment" "$BOOK_SOURCE_GUIX"

printf '%s\n' \
    "PASS: public reader-join v2 source successor" \
    "PASS: KOReader path came from the canonical derivation resolver"
