#!/bin/sh
# The notebook plugin inside a full native KOReader (ReaderUI, PluginLoader,
# TouchMenu, the real UIManager, widgets and fonts) on the SDL emulator,
# offscreen, at the PineNote's framebuffer type and geometry.  The working
# tree's notebook and idle-washer plugins are copied into a private KO_HOME
# beside a host-only controller (nbrealui.koplugin) that emulates the
# PineNote input hook chain from the working tree's device.lua, injects pen
# and touch, checks what KOReader and the plugin did, and takes screenshots.
#
# Usage: run-real-ui-test.sh [KOREADER_BUNDLE]   (or set KOREADER_BUNDLE)
#   NOTEBOOK_REAL_UI_ROTATIONS  KOReader rotation modes to run, one fresh
#                               profile each (default "1 0": the device's
#                               seeded portrait, then landscape)
#   NOTEBOOK_REAL_UI_SHOTS      directory to copy the screenshots into
#   NOTEBOOK_REAL_UI_TMPDIR     where the run directory goes (default $TMPDIR
#                               or /tmp)
#   KEEP_ARTIFACTS=1            keep the run directory (logs, KO_HOME, data)
#
# Host-only and not wired into run-tests.sh or CHECK_HOST_TARGETS.
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$tool_dir/../../../.." && pwd)
reader_tool="$repo/pinenote/tools/book-reader"
. "$reader_tool/process-identity.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bundle=${1:-${KOREADER_BUNDLE:-}}
[ -n "$bundle" ] || fail "usage: run-real-ui-test.sh KOREADER_BUNDLE (or set KOREADER_BUNDLE)"
koreader_dir="$bundle/lib/koreader"
luajit="$koreader_dir/luajit"
[ -x "$luajit" ] && [ -f "$koreader_dir/reader.lua" ] \
    || fail "no native KOReader in $bundle"
[ "$(cat "$koreader_dir/git-rev")" = v2026.03 ] \
    || fail "native KOReader revision is not v2026.03"

kd="$repo/pinenote/packages/koreader-device"
plugin="$kd/plugins/notebook.koplugin"
washer="$kd/plugins/idlewasher.koplugin"
device_lua="$kd/frontend/device/pinenote/device.lua"
evdev_lua="$kd/ffi/input_evdev.lua"
controller="$tool_dir/nbrealui.koplugin"
for file in "$plugin/main.lua" "$plugin/_meta.lua" "$washer/main.lua" \
        "$device_lua" "$evdev_lua" "$controller/main.lua" "$controller/_meta.lua"; do
    [ -f "$file" ] || fail "missing $file"
done

rotations=${NOTEBOOK_REAL_UI_ROTATIONS:-"1 0"}
for rotation in $rotations; do
    case "$rotation" in
        0|1|2|3) ;;
        *) fail "rotation mode must be 0..3: $rotation" ;;
    esac
done
shots_out=${NOTEBOOK_REAL_UI_SHOTS:-}

tmp_base=${NOTEBOOK_REAL_UI_TMPDIR:-${TMPDIR:-/tmp}}
mkdir -p "$tmp_base"
run_dir=$(mktemp -d "$tmp_base/notebook-real-ui.XXXXXX")
chmod 700 "$run_dir"
# The run directory goes into a mountinfo line, where whitespace and
# backslashes would need octal escapes.
case "$run_dir" in
    *[!A-Za-z0-9/._-]*) fail "run directory needs mountinfo escaping: $run_dir" ;;
esac
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

# A book long enough that a gesture leaking past the notebook would turn it.
book="$run_dir/fixture-book.txt"
{
    echo "Notebook real-UI fixture"
    echo
    i=1
    while [ "$i" -le 400 ]; do
        echo "Line $i. The notebook floats over this book; a gesture that leaked past it would turn this page."
        i=$((i + 1))
    done
} >"$book"

run_one() {
    rotation=$1
    run="$run_dir/r$rotation"
    home="$run/home"
    ko_home="$run/ko"
    shots="$run/shots"
    log="$run/koreader.log"
    mkdir -p "$home/.config" "$home/.cache" "$home/.local/share" \
        "$ko_home/plugins" "$run/tmp" "$run/data" "$shots"
    cp -R -- "$plugin" "$ko_home/plugins/notebook.koplugin"
    cp -R -- "$washer" "$ko_home/plugins/idlewasher.koplugin"
    cp -R -- "$controller" "$ko_home/plugins/nbrealui.koplugin"
    cp -- "$device_lua" "$run/device.lua"
    cp -- "$evdev_lua" "$run/input_evdev.lua"
    # The PineNote profile's refresh and rotation keys
    # (pinenote/services/koreader-profile.scm), with the rotation under test
    # as the one KOReader closed with; lock_rotation keeps the book from
    # overriding it.
    cat >"$ko_home/settings.reader.lua" <<EOF
return {
    ["avoid_flashing_ui"] = true,
    ["closed_rotation_mode"] = $rotation,
    ["flash_ui"] = false,
    ["full_refresh_count"] = 0,
    ["lock_rotation"] = true,
}
EOF
    # The notebook stores only on a data partition of its own: / on p6 and
    # the run's data directory as p7, both ext4 and read-write.
    printf '%s\n' \
        "22 1 179:6 / / rw,relatime shared:1 - ext4 /dev/mmcblk0p6 rw" \
        "30 22 179:7 / $run/data rw,relatime shared:2 - ext4 /dev/mmcblk0p7 rw" \
        >"$run/mountinfo"

    set +e
    "$reader_tool/timeout-owner.sh" 90 2 "$command_record" "$timeout_record" \
        "$koreader_dir" env -i \
            PATH="$PATH" \
            LC_ALL=C \
            HOME="$home" \
            KO_HOME="$ko_home" \
            XDG_CONFIG_HOME="$home/.config" \
            XDG_CACHE_HOME="$home/.cache" \
            XDG_DATA_HOME="$home/.local/share" \
            TMPDIR="$run/tmp" \
            NOTEBOOK_REAL_UI_ROOT="$run" \
            NOTEBOOK_REAL_UI_SHOTS="$shots" \
            NOTEBOOK_REAL_UI_ROTATION="$rotation" \
            EMULATE_BB_TYPE=BBRGB16 \
            EMULATE_READER_W=1872 \
            EMULATE_READER_H=1404 \
            EMULATE_READER_DPI=227 \
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
            fail "rotation $rotation: native KOReader exceeded its 90-second deadline"
            ;;
        *)
            cat "$log" >&2
            fail "rotation $rotation: native KOReader exited $rc"
            ;;
    esac
    for record in "$command_record" "$timeout_record"; do
        if owned_process_record_matches "$record"; then
            cat "$log" >&2
            fail "rotation $rotation: left a recorded process: $record"
        fi
    done
    [ "$(grep -Fxc ' [*] Version: v2026.03' "$log" || true)" -eq 1 ] \
        || { cat "$log" >&2; fail "rotation $rotation: version marker absent or duplicated"; }
    [ "$(grep -Fxc 'NOTEBOOK_REAL_UI: result:ok' "$log" || true)" -eq 1 ] \
        || { cat "$log" >&2; fail "rotation $rotation: success marker absent or duplicated"; }
    ! grep -Fq 'NOTEBOOK_REAL_UI: FAIL:' "$log" \
        || { cat "$log" >&2; fail "rotation $rotation: the controller reported a failure"; }
    [ "$(grep -Ec ' INFO  Tearing down UIManager with exit code: 0 $' "$log" || true)" -eq 1 ] \
        || { cat "$log" >&2; fail "rotation $rotation: KOReader did not tear down cleanly exactly once"; }
    ! grep -Eq ' (WARN|ERROR) +\[(notebook|pn-hint)\]' "$log" \
        || { cat "$log" >&2; fail "rotation $rotation: the notebook or the hint owner logged a warning"; }

    echo "rotation $rotation:"
    sed -n 's/^NOTEBOOK_REAL_UI: /  /p' "$log"
    if [ -n "$shots_out" ]; then
        mkdir -p "$shots_out"
        cp -- "$shots"/*.png "$shots_out/"
    fi
}

for rotation in $rotations; do
    run_one "$rotation"
done

echo "native-koreader: $bundle"
echo "mode: ReaderUI + PluginLoader + TouchMenu, SDL offscreen, BBRGB16 1872x1404 @ 227 dpi"
[ -z "$shots_out" ] || echo "screenshots: $shots_out"
echo "PASS: notebook plugin in native KOReader (rotations: $rotations)"
