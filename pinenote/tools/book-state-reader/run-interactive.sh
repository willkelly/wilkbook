#!/bin/sh
# Optional operator-driven SDL run. State lasts for this Guile authority
# process; no expected note value is supplied by argv or environment.
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
reader_tool="$tool_dir/../book-reader"
. "$reader_tool/process-identity.sh"

bundle=${1:-${KOREADER_BUNDLE:-/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03}}
if [ -z "$bundle" ]; then
    bundle=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
fi
koreader_dir="$bundle/lib/koreader"
luajit="$koreader_dir/luajit"
[ -x "$luajit" ] && [ "$(cat "$koreader_dir/git-rev")" = v2026.03 ] || {
    echo "KOReader v2026.03 bundle required" >&2
    exit 2
}
guile=$(command -v guile) || { echo "Guile is unavailable" >&2; exit 2; }

tmp_base=${BOOK_STATE_READER_TMPDIR:-/tmp/opencode}
mkdir -p "$tmp_base"
run_dir=$(mktemp -d "$tmp_base/book-state-reader-interactive.XXXXXX")
chmod 700 "$run_dir"
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

mkdir -p "$run_dir/home/.config" "$run_dir/home/.cache" \
    "$run_dir/home/.local/share" "$run_dir/ko/plugins" "$run_dir/tmp"
cp -R -- "$tool_dir/fixture/bookstatereader.koplugin" \
    "$run_dir/ko/plugins/bookstatereader.koplugin"
cat >"$run_dir/fixture-book.txt" <<'EOF'
Persistent note operator fixture

Select text and invoke “Open persistent note fixture” to reopen the note.
EOF

echo "Starting operator fixture; close KOReader or press Ctrl-C to stop."
"$guile" --no-auto-compile -L "$tool_dir" \
    "$tool_dir/integration-host.scm" \
    "$run_dir" "$koreader_dir" "$luajit" "$run_dir/fixture-book.txt" \
    v2026.03 interactive &
host_pid=$!
host_start=$(owned_process_start_time "$host_pid")
set +e
wait "$host_pid"
rc=$?
set -e
host_pid=
host_start=
exit "$rc"
