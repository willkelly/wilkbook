#!/bin/sh
# Run the persistent-note UI fixture through the repository-pinned native
# KOReader. No network, QEMU, image, mount, or device operation is performed.
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$tool_dir/../../.." && pwd)
reader_tool="$tool_dir/../book-reader"
interaction_tool="$tool_dir/../book-interaction"
fixture="$tool_dir/fixture/bookstatereader.koplugin"
timeout_owner="$reader_tool/timeout-owner.sh"
. "$reader_tool/process-identity.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_hash() {
    expected_hash=$1
    path=$2
    actual_hash=$(sha256sum "$path" | sed 's/ .*//')
    [ "$actual_hash" = "$expected_hash" ] \
        || fail "frozen input changed: $path ($actual_hash)"
}

# Pin accepted inputs. The first two are not imported by the successor codec;
# these checks prove this slice did not widen their closed enumerations in place.
require_hash 1304b21dd9d0973dcb7b55a38e237d8f933f650276b415ccc91cfd6cedae932d \
    "$interaction_tool/private-control.scm"
require_hash 4d77c19113de5a9f4e02600e50e7cc584edc1a8aca4dafb6b8381e58b08b3832 \
    "$interaction_tool/fixture/bookinteractionprobe.koplugin/private_channel.lua"
require_hash cfca047afe708efb5ed396be31df077d7051b6cd9122c69402813e96ec6dd25a \
    "$interaction_tool/fixture/bookinteractionprobe.koplugin/ui_audit.lua"
require_hash 9b455fcd58eeb2ab03e18d94237de3052a43a8de1a85d4466e7d75c4a9f1d239 \
    "$reader_tool/canonical-koreader-output.scm"
require_hash e1507aeb8f0d2ac36efcead795bebdf28c9bb067dd52550e10bd64c26e7a080e \
    "$reader_tool/timeout-owner.sh"
require_hash 97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354 \
    "$reader_tool/process-identity.sh"
require_hash fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c \
    "$reader_tool/record-exec.sh"
require_hash 3051d24090152fd873a197cab6bfcbc88f977dbb4124ddf1ddbf910e62c9b7ff \
    "$reader_tool/lint-fixture.sh"
require_hash 661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1 \
    "$repo_root/channels.scm"

(cd "$tool_dir" && sha256sum --check --status SHA256SUMS) \
    || fail "book-state-reader packet hash verification failed"

canonical_info=$(guix repl -L "$repo_root" \
    "$reader_tool/canonical-koreader-output.scm") \
    || fail "could not evaluate the repository KOReader derivation offline"
canonical_drv=$(printf '%s\n' "$canonical_info" | sed -n '1p')
canonical_output=$(printf '%s\n' "$canonical_info" | sed -n '2p')
[ "$(printf '%s\n' "$canonical_info" | sed -n '$=')" -eq 2 ] \
    || fail "canonical KOReader evaluation did not return two lines"
[ -f "$canonical_drv" ] || fail "canonical derivation does not exist"
case "$canonical_output" in
    /gnu/store/*-koreader-bin-*) ;;
    *) fail "canonical evaluation returned an invalid output path" ;;
esac

bundle=${1:-${KOREADER_BUNDLE:-$canonical_output}}
if [ -z "$bundle" ]; then bundle=$canonical_output; fi
case "$bundle" in
    /*) ;;
    *) bundle=$(CDPATH= cd -- "$bundle" && pwd) ;;
esac
koreader_dir="$bundle/lib/koreader"
luajit="$koreader_dir/luajit"
[ -x "$luajit" ] && [ -f "$koreader_dir/reader.lua" ] \
    || fail "not a KOReader bundle: $bundle"
[ -f "$koreader_dir/git-rev" ] || fail "KOReader bundle has no git-rev"
bundle_revision=$(cat "$koreader_dir/git-rev")
[ "$bundle_revision" = v2026.03 ] \
    || fail "fixture requires KOReader v2026.03, got $bundle_revision"
canonical_name=${canonical_output##*/}
canonical_version=${canonical_name#*-koreader-bin-}
[ "$bundle_revision" = "v$canonical_version" ] \
    || fail "bundle revision does not match repository package version"

bundle_mode=compatibility
if [ "$bundle" = "$canonical_output" ]; then
    canonical_deriver_found=false
    while IFS= read -r deriver; do
        [ "$deriver" = "$canonical_drv" ] && canonical_deriver_found=true
    done <<EOF
$(guix gc --derivers "$bundle")
EOF
    [ "$canonical_deriver_found" = true ] \
        || fail "canonical output is not linked to the evaluated derivation"
    bundle_mode=package-pinned
fi

[ ! -e "$koreader_dir/plugins/bookstatereader.koplugin" ] \
    || fail "fixture unexpectedly exists in packaged KOReader"
for file in _meta.lua main.lua state_channel.lua ui_audit.lua; do
    [ -f "$fixture/$file" ] || fail "fixture lacks $file"
done
"$reader_tool/lint-fixture.sh" "$fixture"

guile=$(command -v guile) || fail "Guile is unavailable"
timeout 5 "$guile" --no-auto-compile -L "$tool_dir" \
    "$tool_dir/test-private-control.scm"
timeout 5 "$luajit" "$tool_dir/test-state-channel.lua" "$fixture"

tmp_base=${BOOK_STATE_READER_TMPDIR:-/tmp/opencode}
mkdir -p "$tmp_base"
run_dir=$(mktemp -d "$tmp_base/book-state-reader.XXXXXX")
chmod 700 "$run_dir"
home="$run_dir/home"
ko_home="$run_dir/ko"
tmp="$run_dir/tmp"
plugin_home="$ko_home/plugins/bookstatereader.koplugin"
book="$run_dir/fixture-book.txt"
host_log="$run_dir/host.log"
host_record="$run_dir/host.pid"
timeout_record="$run_dir/timeout.pid"
reader_record="$run_dir/reader.pid"
host_pid=
host_start=

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ -n "$host_pid" ] && [ -n "$host_start" ]; then
        owned_process_terminate "$host_pid" "$host_start" || rc=1
        wait "$host_pid" 2>/dev/null || true
    fi
    owned_process_terminate_record "$reader_record" || rc=1
    owned_process_terminate_record "$host_record" || rc=1
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

mkdir -p "$home/.config" "$home/.cache" "$home/.local/share" \
    "$ko_home/plugins" "$tmp"
cp -R -- "$fixture" "$plugin_home"
cat >"$book" <<'EOF'
Persistent note integration fixture

This inert document only opens ReaderUI. Lua owns the editable widget;
the connected Guile fixture owns all load and commit decisions.
EOF

"$timeout_owner" 25 2 "$host_record" "$timeout_record" "$repo_root" \
    "$guile" --no-auto-compile -L "$tool_dir" \
        "$tool_dir/integration-host.scm" \
        "$run_dir" "$koreader_dir" "$luajit" "$book" \
        "$bundle_revision" automated \
        >"$host_log" 2>&1 &
host_pid=$!
host_start=$(owned_process_start_time "$host_pid")

set +e
wait "$host_pid"
rc=$?
set -e
host_pid=
host_start=
case "$rc" in
    0) ;;
    124|137)
        cat "$host_log" >&2
        fail "persistent-note fixture exceeded its process deadline"
        ;;
    *)
        cat "$host_log" >&2
        fail "persistent-note fixture host exited $rc"
        ;;
esac

for record in "$host_record" "$timeout_record" "$reader_record"; do
    if owned_process_record_matches "$record"; then
        cat "$host_log" >&2
        fail "fixture left a recorded process present: $record"
    fi
done
[ "$(grep -Fxc 'BOOK_STATE_READER_HOST: result:ok' "$host_log" || true)" -eq 1 ] \
    || { cat "$host_log" >&2; fail "host success marker is absent or duplicated"; }
! grep -Fq 'BOOK_STATE_READER_HOST: FAIL:' "$host_log" \
    || { cat "$host_log" >&2; fail "host reported a failure"; }

echo "bundle: $bundle"
echo "bundle-mode: $bundle_mode"
echo "canonical-output: $canonical_output"
echo "canonical-derivation: $canonical_drv"
echo "verified-revision-before-fixture: $bundle_revision"
echo "mode: trusted-native-persistent-note-fixture (offscreen)"
cat "$host_log"

trap - EXIT HUP INT TERM
if [ "${KEEP_ARTIFACTS:-0}" = 1 ]; then
    echo "artifacts: $run_dir"
else
    rm -rf -- "$run_dir"
fi
echo "PASS: persistent-note load/save/failure/paint/late/reopen fixture"
