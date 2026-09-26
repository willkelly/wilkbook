#!/bin/sh
# Explicit desktop fixture; dependency lowering never selects a system image.
set -eu
tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$tool_dir/../../.." && pwd)
fail() { echo "book-workbench: $*" >&2; exit 2; }
mode=demo
case $# in
    1)
        case $1 in
            -h|--help) exec python3 -I -S "$tool_dir/native-demo.py" --help ;;
            --*) fail "usage: $0 [--export] DIRECTORY (or --help)" ;;
        esac
        directory=$1 ;;
    2)
        [ "$1" = --export ] || fail "usage: $0 [--export] DIRECTORY"
        mode=export
        directory=$2 ;;
    *) fail "usage: $0 [--export] DIRECTORY (or --help)" ;;
esac
# Reject a missing/public parent before asking Guix to lower or build anything.
if [ "$mode" = export ]; then
    python3 -I -S "$tool_dir/native-demo.py" --check-directory --export -- "$directory"
else
    python3 -I -S "$tool_dir/native-demo.py" --check-directory -- "$directory"
fi
echo 'trusted-native developer fixture: authored Guile runs with your host user privileges, without gVisor confinement.' >&2
unset GUILE_LOAD_PATH GUILE_LOAD_COMPILED_PATH GUILE_EXTENSIONS_PATH
unset GUILE_SYSTEM_PATH GUILE_SYSTEM_COMPILED_PATH
export GUILE_AUTO_COMPILE=0

supervisor=${BOOK_WORKBENCH_SUPERVISOR:-}
reader=${KOREADER_NATIVE_BUNDLE:-}
graphics=${BOOK_WORKBENCH_GRAPHICS:-}
need_graphics=no
if [ "$mode" = demo ] && [ "${SDL_VIDEODRIVER:-}" != offscreen ]; then
    need_graphics=yes
fi
[ -z "$supervisor" ] || [ -x "$supervisor/bin/guile" ] || fail "invalid supervisor override: $supervisor"
if [ "$mode" = demo ] && [ -n "$reader" ]; then
    [ -x "$reader/lib/koreader/luajit" ] || fail "invalid reader override: $reader"
fi
if [ "$need_graphics" = yes ] && [ -n "$graphics" ]; then
    for file in lib/libEGL.so.1 lib/libGLESv2.so.2; do
        [ -f "$graphics/$file" ] || fail "invalid graphics override: $graphics/$file"
    done
fi
if [ -z "$supervisor" ] || { [ "$mode" = demo ] && [ -z "$reader" ]; } \
        || { [ "$need_graphics" = yes ] && [ -z "$graphics" ]; }; then
    inputs=$(guix time-machine -C "$repo/channels.scm" -- repl -L "$repo" \
        "$tool_dir/derive-inputs.scm" </dev/null)
fi
build_input() {
    drv=$(printf '%s\n' "$inputs" | awk -F '\t' -v label="$1" '$1 == label {print $2}')
    out=$(printf '%s\n' "$inputs" | awk -F '\t' -v label="$1" '$1 == label {print $3}')
    [ -n "$drv" ] && [ -n "$out" ] || fail "missing native dependency: $1"
    echo "book-workbench: native $1: $out" >&2
    guix build --no-grafts --no-substitutes --max-jobs=1 --cores=2 "$drv" </dev/null >&2 || return $?
    printf '%s\n' "$out"
}
[ -n "$supervisor" ] || supervisor=$(build_input supervisor)
if [ "$mode" = demo ] && [ -z "$reader" ]; then
    reader=$(build_input koreader)
fi
if [ "$need_graphics" = yes ] && [ -z "$graphics" ]; then
    graphics=$(build_input graphics)
fi
export BOOK_WORKBENCH_SUPERVISOR="$supervisor" KOREADER_NATIVE_BUNDLE="$reader" \
    BOOK_WORKBENCH_GRAPHICS="$graphics"
if [ "$mode" = export ]; then
    exec python3 -I -S "$tool_dir/native-demo.py" --export -- "$directory"
fi
exec python3 -I -S "$tool_dir/native-demo.py" -- "$directory"
