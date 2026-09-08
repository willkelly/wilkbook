#!/bin/sh
# Full pinned-KOReader desktop/offscreen integration probe. No device, VM, or
# shipping plugin is involved. The test fixture is copied into a temporary
# KO_HOME and all writable runtime paths are scoped below /tmp/opencode.
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
default_repo_root=$(CDPATH= cd -- "$tool_dir/../../.." && pwd)
repo_root=${BOOK_READER_REPO_ROOT:-$default_repo_root}
fixture="$tool_dir/fixture/bookreaderprobe.koplugin"
expected="$tool_dir/expected-markers.txt"
. "$tool_dir/process-identity.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Evaluate, but do not build or realise, the exact native package output. This
# is the canonical package-pin oracle and is intentionally resolved once.
canonical_info=$(guix repl -L "$repo_root" \
    "$tool_dir/canonical-koreader-output.scm") \
    || fail "could not evaluate the repository KOReader derivation"
canonical_drv=$(printf '%s\n' "$canonical_info" | sed -n '1p')
canonical_output=$(printf '%s\n' "$canonical_info" | sed -n '2p')
[ "$(printf '%s\n' "$canonical_info" | sed -n '$=')" -eq 2 ] \
    || fail "canonical evaluation did not return exactly two lines"
case "$canonical_drv" in
    /gnu/store/*.drv) ;;
    *) fail "repository evaluation returned an unexpected derivation: $canonical_drv" ;;
esac
[ -f "$canonical_drv" ] || fail "evaluated derivation does not exist: $canonical_drv"
case "$canonical_output" in
    /gnu/store/*-koreader-bin-*) ;;
    *) fail "could not read canonical output from $canonical_drv" ;;
esac
canonical_name=${canonical_output##*/}
canonical_version=${canonical_name#*-koreader-bin-}
[ "$canonical_version" != "$canonical_name" ] \
    || fail "could not read KOReader version from canonical output"
expected_revision="v$canonical_version"

bundle=${1:-${KOREADER_BUNDLE:-$canonical_output}}
case "$bundle" in
    /*) ;;
    *) bundle=$(CDPATH= cd -- "$bundle" && pwd) ;;
esac

koreader="$bundle/lib/koreader"
luajit="$koreader/luajit"
reader="$koreader/reader.lua"
[ -x "$luajit" ] && [ -f "$reader" ] \
    || fail "not a koreader-bin output: $bundle"
[ -f "$koreader/git-rev" ] \
    || fail "bundle has no KOReader git-rev: $bundle"
[ "$(wc -l <"$koreader/git-rev" | tr -d ' ')" = 1 ] \
    || fail "bundle git-rev is not exactly one line"
bundle_revision=$(cat "$koreader/git-rev")
[ "$bundle_revision" = "$expected_revision" ] \
    || fail "bundle revision $bundle_revision does not match $expected_revision"

bundle_mode=compatibility
if [ "$bundle" = "$canonical_output" ]; then
    canonical_deriver_found=false
    while IFS= read -r deriver; do
        if [ "$deriver" = "$canonical_drv" ]; then
            canonical_deriver_found=true
        fi
    done <<EOF
$(guix gc --derivers "$bundle")
EOF
    [ "$canonical_deriver_found" = true ] \
        || fail "canonical output is not linked to evaluated deriver"
    bundle_mode=package-pinned
fi

[ ! -e "$koreader/plugins/bookreaderprobe.koplugin" ] \
    || fail "test fixture unexpectedly exists in the packaged bundle"
[ -f "$fixture/main.lua" ] \
    && [ -f "$fixture/interaction_source.lua" ] \
    && [ -f "$fixture/public_seam_probe.lua" ] \
    || fail "fixture plugin is incomplete: $fixture"

tmp_base=${BOOK_READER_TMPDIR:-/tmp/opencode}
mkdir -p "$tmp_base"
run_dir=$(mktemp -d "$tmp_base/book-reader-run.XXXXXX")
supervisor_pid=
supervisor_start=
command_record="$run_dir/reader.pid"
timeout_record="$run_dir/timeout.pid"

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ -n "$supervisor_pid" ] && [ -z "$supervisor_start" ]; then
        supervisor_start=$(owned_process_start_time "$supervisor_pid" || true)
    fi
    if [ -n "$supervisor_pid" ] && [ -n "$supervisor_start" ]; then
        owned_process_terminate "$supervisor_pid" "$supervisor_start" || rc=1
        wait "$supervisor_pid" 2>/dev/null || true
    fi
    owned_process_terminate_record "$command_record" || rc=1
    owned_process_terminate_record "$timeout_record" || rc=1
    if [ "${KEEP_ARTIFACTS:-0}" = 1 ]; then
        echo "artifacts: $run_dir"
    else
        rm -rf -- "$run_dir"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A lexical convenience lint for a few common accidental writer spellings.
# The fixture is trusted and source-reviewed; this is not confinement, a Lua
# parser, or a security claim, and alternate spellings can bypass it.
"$tool_dir/lint-fixture.sh" "$fixture"

# Exercise the adapter independently before PluginLoader can execute it.
pure_log="$run_dir/interaction-source.log"
if ! "$luajit" "$tool_dir/test-interaction-source.lua" "$fixture" \
        >"$pure_log" 2>&1; then
    cat "$pure_log" >&2
    fail "interaction source unit checks failed"
fi
grep -Fxq 'RESULT: ok' "$pure_log" \
    || fail "interaction source unit checks lacked success result"

home="$run_dir/home"
ko_home="$run_dir/ko"
tmp="$run_dir/tmp"
plugin_home="$ko_home/plugins/bookreaderprobe.koplugin"
book="$run_dir/fixture-book.txt"
log="$run_dir/koreader.log"
actual_markers="$run_dir/actual-markers.txt"
mkdir -p "$home/.config" "$home/.cache" "$home/.local/share" \
    "$ko_home/plugins" "$tmp"
cp -R -- "$fixture" "$plugin_home"
cat >"$book" <<'EOF'
Book reader integration fixture

This temporary document exists only to enter the real KOReader ReaderUI.
EOF

echo "bundle: $bundle"
echo "bundle-mode: $bundle_mode"
echo "canonical-output: $canonical_output"
echo "canonical-derivation: $canonical_drv"
echo "verified-revision-before-fixture: $expected_revision"
echo "frontend: $reader"

set +e
"$tool_dir/timeout-owner.sh" 20 2 "$command_record" "$timeout_record" \
    "$koreader" env -i \
        PATH="$PATH" \
        LC_ALL=C \
        HOME="$home" \
        KO_HOME="$ko_home" \
        XDG_CONFIG_HOME="$home/.config" \
        XDG_CACHE_HOME="$home/.cache" \
        XDG_DATA_HOME="$home/.local/share" \
        TMPDIR="$tmp" \
        BOOK_READER_PROBE_ROOT="$run_dir" \
        SDL_VIDEODRIVER=offscreen \
        SDL_AUDIODRIVER=dummy \
        "$luajit" reader.lua "$book" >"$log" 2>&1 &
supervisor_pid=$!
supervisor_start=$(owned_process_start_time "$supervisor_pid")
wait "$supervisor_pid"
rc=$?
supervisor_pid=
supervisor_start=
set -e

if owned_process_record_matches "$command_record" \
        || owned_process_record_matches "$timeout_record"; then
    owned_process_terminate_record "$command_record" || true
    owned_process_terminate_record "$timeout_record" || true
    fail "timeout owner returned with a recorded process still alive"
fi
case "$rc" in
    124|137)
        cat "$log" >&2
        fail "KOReader probe exceeded the 20-second timeout"
        ;;
    0) ;;
    *)
        cat "$log" >&2
        fail "KOReader probe exited $rc"
        ;;
esac

# The official line is emitted by reader.lua before plugin discovery. Require
# one exact anchored line, and prove it precedes the fixture's first marker.
version_count=$(grep -Ec '^ \[\*\] Version: ' "$log" || true)
[ "$version_count" -eq 1 ] || {
    cat "$log" >&2
    fail "expected exactly one official KOReader version line"
}
version_line=$(grep -E '^ \[\*\] Version: ' "$log")
[ "$version_line" = " [*] Version: $expected_revision" ] || {
    cat "$log" >&2
    fail "official KOReader version line does not match $expected_revision"
}
version_line_number=$(grep -n -m1 -E '^ \[\*\] Version: ' "$log" | cut -d: -f1)
fixture_line_number=$(grep -n -m1 '^BOOK_READER_PROBE: ' "$log" | cut -d: -f1)
[ -n "$fixture_line_number" ] && [ "$version_line_number" -lt "$fixture_line_number" ] \
    || fail "official version was not logged before fixture output"

teardown_count=$(grep -Ec \
    ' INFO  Tearing down UIManager with exit code: 0 $' "$log" || true)
[ "$teardown_count" -eq 1 ] || {
    cat "$log" >&2
    fail "KOReader did not report exactly one clean UIManager teardown"
}
if grep -Fq 'BOOK_READER_PROBE: FAIL:' "$log"; then
    cat "$log" >&2
    fail "fixture assertion failed"
fi

sed -n 's/^BOOK_READER_PROBE: //p' "$log" >"$actual_markers"
if ! cmp -s "$expected" "$actual_markers"; then
    echo "FAIL: marker sequence differs" >&2
    diff -u "$expected" "$actual_markers" >&2 || true
    cat "$log" >&2
    exit 1
fi

cat "$pure_log"
cat "$actual_markers"
if [ "$bundle_mode" = package-pinned ]; then
    echo "PASS: pinned KOReader offscreen reader integration probe"
else
    echo "PASS: KOReader offscreen compatibility probe ($bundle)"
fi
