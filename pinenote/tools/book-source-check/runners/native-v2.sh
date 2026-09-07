#!/bin/sh
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: native-v2.sh PREPARED_ROOT RUN_ROOT" >&2
    exit 2
}
prepared=$1
run_root=$2
snapshot="$prepared/closure/native-v2"
runner="$prepared/repo/pinenote/tools/book-source-check/runners/native-v2-inner.sh"
private_helper="$prepared/repo/pinenote/tools/book-source-check/private-environment.sh"
mkdir -m 700 "$run_root/functional"
. "$private_helper"
private_environment="$run_root/private-environment"
book_source_create_private_environment "$private_environment"
sh "$snapshot/integration/verify-source-snapshot.sh" "$snapshot"
env -u BOOK_SESSION_STATE_SOURCE_DIR \
    -u BOOK_SESSION_STATE_BOOK_SESSION_SHA256 \
    -u BOOK_SESSION_STATE_DELEGATE_SHA256 \
    -u BOOK_SESSION_STATE_CONTRACT_SHA256 \
    -u BOOK_SESSION_STATE_PACKET_SHA256 \
    sh "$runner" "$snapshot" "$run_root/functional" \
        "$private_helper" "$private_environment"
