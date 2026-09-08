#!/bin/sh
# Full native KOReader/ReaderUI test for the production device plugin. The
# canonical plugin is copied into a private profile and only that temporary
# copy receives activation and socketpair fixture adapters.
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
reader_tool="$tool_dir/../book-reader"
. "$reader_tool/process-identity.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bundle=${KOREADER_NATIVE_BUNDLE:-/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03}
koreader_dir="$bundle/lib/koreader"
luajit="$koreader_dir/luajit"
[ -x "$luajit" ] && [ -f "$koreader_dir/reader.lua" ] \
    || fail "pinned native KOReader is unavailable: $bundle"
[ "$(cat "$koreader_dir/git-rev")" = v2026.03 ] \
    || fail "native KOReader revision is not v2026.03"

production="$tool_dir/plugin/bookstatedevice.koplugin"
fixture="$tool_dir/real-ui-fixture"
for file in main.lua state_channel.lua _meta.lua; do
    [ -f "$production/$file" ] || fail "production plugin lacks $file"
done
for file in activation.lua unix_client.lua real_ui_socket_fixture.lua \
        bookstatedevicerealui.koplugin/main.lua \
        bookstatedevicerealui.koplugin/_meta.lua; do
    [ -f "$fixture/$file" ] || fail "real-UI fixture lacks $file"
done

tmp_base=${BOOK_STATE_DEVICE_REAL_UI_TMPDIR:-/tmp/opencode}
mkdir -p "$tmp_base"
run_dir=$(mktemp -d "$tmp_base/book-state-device-real-ui.XXXXXX")
chmod 700 "$run_dir"
home="$run_dir/home"
ko_home="$run_dir/ko"
tmp="$run_dir/tmp"
plugin_home="$ko_home/plugins/bookstatedevice.koplugin"
controller_home="$ko_home/plugins/bookstatedevicerealui.koplugin"
book="$run_dir/fixture-book.txt"
log="$run_dir/koreader.log"
command_record="$run_dir/reader.pid"
timeout_record="$run_dir/timeout.pid"
supervisor_pid=
supervisor_start=

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

mkdir -p "$home/.config" "$home/.cache" "$home/.local/share" \
    "$ko_home/plugins" "$tmp"
cp -R -- "$production" "$plugin_home"
cp -R -- "$fixture/bookstatedevicerealui.koplugin" "$controller_home"
cp -- "$fixture/activation.lua" "$plugin_home/activation.lua"
cp -- "$fixture/unix_client.lua" "$plugin_home/unix_client.lua"
cp -- "$fixture/real_ui_socket_fixture.lua" \
    "$plugin_home/real_ui_socket_fixture.lua"
cat >"$book" <<'EOF'
Book State device native UI fixture

This inert document only opens the real KOReader ReaderUI.
EOF

set +e
"$reader_tool/timeout-owner.sh" 20 2 "$command_record" "$timeout_record" \
    "$koreader_dir" env -i \
        PATH="$PATH" \
        LC_ALL=C \
        HOME="$home" \
        KO_HOME="$ko_home" \
        XDG_CONFIG_HOME="$home/.config" \
        XDG_CACHE_HOME="$home/.cache" \
        XDG_DATA_HOME="$home/.local/share" \
        TMPDIR="$tmp" \
        BOOK_STATE_DEVICE_REAL_UI_ROOT="$run_dir" \
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

case "$rc" in
    0) ;;
    124|137)
        cat "$log" >&2
        fail "native KOReader real-UI test exceeded its 20-second process deadline"
        ;;
    *)
        cat "$log" >&2
        fail "native KOReader real-UI test exited $rc"
        ;;
esac

for record in "$command_record" "$timeout_record"; do
    if owned_process_record_matches "$record"; then
        cat "$log" >&2
        fail "native real-UI test left a recorded process: $record"
    fi
done
[ "$(grep -Fxc ' [*] Version: v2026.03' "$log" || true)" -eq 1 ] \
    || { cat "$log" >&2; fail "native KOReader version marker is absent or duplicated"; }
[ "$(grep -Fxc 'BOOK_STATE_DEVICE_REAL_UI: result:ok' "$log" || true)" -eq 1 ] \
    || { cat "$log" >&2; fail "real-UI success marker is absent or duplicated"; }
! grep -Fq 'BOOK_STATE_DEVICE_REAL_UI: FAIL:' "$log" \
    || { cat "$log" >&2; fail "real-UI fixture reported a failure"; }
[ "$(grep -Ec ' INFO  Tearing down UIManager with exit code: 0 $' "$log" || true)" -eq 1 ] \
    || { cat "$log" >&2; fail "native KOReader did not tear down cleanly exactly once"; }

echo "native-koreader: $bundle"
echo "mode: full ReaderUI + PluginLoader + TouchMenu + InputDialog (SDL offscreen)"
sed -n 's/^BOOK_STATE_DEVICE_REAL_UI: /  /p' "$log"
echo "PASS: production device plugin native KOReader UI save/paint/close/reopen"

trap - EXIT HUP INT TERM
if [ "${KEEP_ARTIFACTS:-0}" = 1 ]; then
    echo "artifacts: $run_dir"
else
    rm -rf -- "$run_dir"
fi
