#!/bin/sh
# Exercise the same copy/authenticate/source boundary used by the outer owner.
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: test-helper-provenance.sh PRIVATE_CLOSURE RUN_ROOT" >&2
    exit 2
}
closure=$1
run_root=$2
helper="$closure/join/accepted-helper/process-identity.sh"
expected=97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354

actual=$(sha256sum "$helper")
actual=${actual%% *}
[ "$actual" = "$expected" ]
[ "$(stat -c %a "$helper")" = 400 ]

# The inner project consumer sources the already-authenticated closure path,
# never a repository path.
(
    # shellcheck source=/dev/null
    . "$helper"
    start=$(owned_process_start_time "$$")
    [ -n "$start" ]
)
echo "JOIN-HELPER-PROVENANCE: inner=$helper sha256=$actual"

# Model the exact check/use concern: copy a source helper privately, authenticate
# that copy, then replace the source with executable canary content before the
# source operation.  The authenticated private copy is what is actually sourced.
race="$run_root/helper-copy-race"
source_helper="$race/repository-helper.sh"
private="$race/private/process-identity.sh"
canary="$race/external-execution-canary"
mkdir -m 700 "$race" "$race/private"
cp "$helper" "$source_helper"
cp "$source_helper" "$private"
chmod 400 "$private"
private_hash=$(sha256sum "$private")
private_hash=${private_hash%% *}
[ "$private_hash" = "$expected" ]
chmod 600 "$source_helper"
cat >"$source_helper" <<EOF
: >'$canary'
false
EOF
(
    # shellcheck source=/dev/null
    . "$private"
    start=$(owned_process_start_time "$$")
    [ -n "$start" ]
)
[ ! -e "$canary" ] || {
    echo "mutable source helper executed after private authentication" >&2
    exit 1
}
echo "PASS: helper mutation after private copy could not reach execution"
