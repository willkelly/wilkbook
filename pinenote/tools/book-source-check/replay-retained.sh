#!/bin/sh
# Re-run the immutable native-v1 host runner from authenticated external evidence.
set -eu

usage () {
    echo "usage: replay-retained.sh FRESH_SOURCE_ROOT AUTHENTICATED_ARTIFACT_ROOT [EMPTY_OUTPUT]" >&2
    exit 2
}
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
source_root=$1
artifact_root=$2
output=${3-}
case "$source_root:$artifact_root" in /*:/*) ;; *) usage ;; esac
[ "$(CDPATH= cd -- "$source_root" && pwd -P)" = "$source_root" ] || usage
[ "$(CDPATH= cd -- "$artifact_root" && pwd -P)" = "$artifact_root" ] || usage

if [ -z "$output" ]; then
    mkdir -p /tmp/opencode
    output=$(mktemp -d /tmp/opencode/book-retained-replay.XXXXXX)
else
    case "$output" in /*) ;; *) usage ;; esac
    if [ -e "$output" ]; then
        [ -d "$output" ] && \
            [ -z "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
            echo "retained replay output must be absent or empty" >&2
            exit 1
        }
    else
        mkdir -m 700 -p "$output"
    fi
    [ "$(CDPATH= cd -- "$output" && pwd -P)" = "$output" ] || usage
fi
chmod 700 "$output"
ulimit -f 32768

tool="$source_root/pinenote/tools/book-source-check"
capsule="$output/capsule"
stage="$output/historical-v1-repo"
packet="$artifact_root/book-state-native-integration-sources-20260906-v1"
integration="$stage/pinenote/tools/book-state-integration"
backend="$stage/pinenote/tools/book-state/build/artifacts/book-state-backend-sources-20260906-v2"
sqlite="$stage/pinenote/tools/book-state/build/artifacts/aarch64-guile-sqlite3-0.1.3-20260906-v1"
protocol="$stage/pinenote/tools/book-protocol"
state="$stage/pinenote/tools/book-state-protocol"
session="$state/session-integration/bsd1-successor-v4"

python3 -I -S "$tool/prepare.py" prepare \
    --source-root "$source_root" --output "$capsule" \
    >"$output/prepare.log" 2>&1
cat "$output/prepare.log"
sh "$capsule/repo/pinenote/tools/book-source-check/check-retained.sh" \
    "$artifact_root" >"$output/authenticate.log" 2>&1
cat "$output/authenticate.log"
private_helper="$capsule/repo/pinenote/tools/book-source-check/private-environment.sh"
. "$private_helper"
book_source_resolve_guix_launcher
private_environment="$output/private-environment"
book_source_create_private_environment "$private_environment"

mkdir -m 700 -p "$integration" "$backend" "$sqlite" "$protocol" \
    "$state" "$session/candidate" "$stage/doc/reviews"
cp -a "$packet/." "$integration/"
cp -a "$capsule/views/backend-v2/." "$backend/"
cp -a "$packet/accepted-inputs/aarch64-guile-sqlite3-0.1.3-20260906-v1/." \
    "$sqlite/"
cp -a "$packet/accepted-inputs/book-protocol/." "$protocol/"
cp -a "$packet/accepted-inputs/state-protocol/." "$state/"
cp "$packet/accepted-inputs/channels.scm" "$stage/channels.scm"
cp "$packet/accepted-inputs/session/book-session.scm" \
    "$session/candidate/book-session.scm"
cp "$packet/accepted-inputs/session/book-state-session-delegate.scm" \
    "$session/book-state-session-delegate.scm"
cp "$packet/accepted-inputs/session/book-session-state-delegate.patch" \
    "$session/book-session-state-delegate.patch"
cp "$packet/accepted-inputs/session/packet-manifest.json" \
    "$session/packet-manifest.json"
cp "$capsule/repo/pinenote/tools/book-state-protocol/session-integration/bsd1-successor-v4/CONTRACT.md" \
    "$session/CONTRACT.md"
cp "$packet/accepted-inputs/reviews/book-state-backend-adapter-adversarial.md" \
    "$stage/doc/reviews/2026-09-06-book-state-backend-adapter-adversarial.md"
cp "$packet/accepted-inputs/reviews/book-session-state-delegate-adversarial.md" \
    "$stage/doc/reviews/2026-09-06-book-session-state-delegate-adversarial.md"
find "$stage" -type f -exec chmod 400 {} +
find "$stage" -type d -exec chmod 500 {} +

profile=/gnu/store/kxwhmhxf2ykn40nc4krsr22wrzjwbrrr-wilkbook-book-execution-languages
[ -e "$profile" ] || {
    echo "historical exact 45-path language profile is absent: $profile" >&2
    exit 1
}
profile_count=$("$BOOK_SOURCE_GUIX" gc --requisites "$profile" | wc -l)
profile_hash=$("$BOOK_SOURCE_GUIX" hash -r "$profile")
[ "$profile_count" -eq 45 ]
[ "$profile_hash" = \
  1lmksjn9k8k5bxpnckh5bdd0wwnz3ab7q7wp4cnk5wmfayp1dwln ]
echo "PASS: retained exact 45-path language profile authenticated"
echo "RETAINED_REPLAY_OUTPUT=$output"
echo "RETAINED_REPLAY_RUNNER=$integration/run-host-tests.sh"
echo "RETAINED_PROFILE=$profile"
set +e
env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT \
    -u PYTHONPATH -u PYTHONHOME -u PYTHONSTARTUP -u PYTHONUSERBASE \
    -u BOOK_SESSION_STATE_SOURCE_DIR \
    -u BOOK_SESSION_STATE_BOOK_SESSION_SHA256 \
    -u BOOK_SESSION_STATE_DELEGATE_SHA256 \
    -u BOOK_SESSION_STATE_CONTRACT_SHA256 \
    -u BOOK_SESSION_STATE_PACKET_SHA256 \
    timeout --signal=TERM --kill-after=5s 420s \
    sh "$integration/run-host-tests.sh" >"$output/replay.log" 2>&1
replay_status=$?
set -e
cat "$output/replay.log"
[ "$replay_status" -eq 1 ] || {
    echo "historical v1 runner returned unexpected status $replay_status" >&2
    exit 1
}
grep -F "ModuleNotFoundError: No module named 'book_protocol'" \
    "$output/replay.log" >/dev/null || {
    echo "historical v1 runner did not reproduce its blocked missing-codec boundary" >&2
    exit 1
}
echo "PASS: authenticated immutable native-v1 runner reproduced its expected block"
echo "EXPECTED-BLOCKED: v1 depends on an undeclared Python codec path"
echo "INFO: native-v2 is the public functional successor"
