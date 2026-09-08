#!/bin/sh
set -eu
tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$tool_dir/../../.." && pwd)
private_home=${BOOK_STATE_DEVICE_TEST_HOME:-/tmp/opencode/book-state-device-test-home}
private_cache=${BOOK_STATE_DEVICE_TEST_CACHE:-/tmp/opencode/book-state-device-test-cache}
mkdir -p "$private_home" "$private_cache"

python3 "$tool_dir/test-source.py"
guile --no-auto-compile "$tool_dir/test-authority-control-structure.scm" \
    "$tool_dir/book-state-device-authority.scm"

luajit=${LUAJIT:-}
if [ -z "$luajit" ]; then
    native_bundle=${KOREADER_NATIVE_BUNDLE:-/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03}
    luajit=$native_bundle/lib/koreader/luajit
fi
[ -x "$luajit" ] || {
    echo "FAIL: set LUAJIT to KOReader's LuaJIT" >&2
    exit 1
}
"$luajit" "$tool_dir/test-plugin.lua" \
    "$tool_dir/plugin/bookstatedevice.koplugin"
"$luajit" "$tool_dir/test-activation.lua" \
    "$tool_dir/plugin/bookstatedevice.koplugin"
"$tool_dir/run-real-ui-test.sh"

HOME="$private_home" XDG_CACHE_HOME="$private_cache" GUILE_AUTO_COMPILE=0 \
    guix repl -L "$repo" "$tool_dir/test-system.scm"

runtime_inputs=$(HOME="$private_home" XDG_CACHE_HOME="$private_cache" \
    GUILE_AUTO_COMPILE=0 guix repl -L "$repo" \
    "$tool_dir/derive-runtime-inputs.scm")
modules_drv=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "modules" { print $2 }')
modules_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "modules" { print $3 }')
supervisor_drv=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "supervisor" { print $2 }')
supervisor_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "supervisor" { print $3 }')
language_profile_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "language-profile" { print $3 }')
language_closure_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "language-closure" { print $3 }')
guile_boundary_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "guile-boundary" { print $3 }')
python_boundary_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "python-boundary" { print $3 }')
guile_book_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "guile-book" { print $3 }')
python_book_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "python-book" { print $3 }')
guile_protocol_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "guile-protocol" { print $3 }')
blocking_protocol_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "blocking-protocol" { print $3 }')
python_protocol_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "python-protocol" { print $3 }')
adapter_out=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$1 == "runsc-adapter" { print $3 }')
runtime_labels='modules supervisor language-profile language-closure guile-boundary python-boundary guile-book python-book guile-protocol blocking-protocol python-protocol runsc-adapter'
for label in $runtime_labels; do
    [ "$(printf '%s\n' "$runtime_inputs" | awk -F '\t' -v label="$label" '$1 == label && $3 ~ /^\/gnu\/store\// { count++ } END { print count + 0 }')" -eq 1 ] || {
        echo "FAIL: runtime input lowering did not return one $label output" >&2
        exit 1
    }
done
runtime_drvs=$(printf '%s\n' "$runtime_inputs" | awk -F '\t' '$2 != "-" { print $2 }')
HOME="$private_home" XDG_CACHE_HOME="$private_cache" GUILE_AUTO_COMPILE=0 \
    guix build --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
    $runtime_drvs >/dev/null

timeout -s KILL 15 env -i \
    HOME="$private_home" LANG=C LC_ALL=C GUILE_AUTO_COMPILE=0 \
    GUILE_LOAD_PATH="$modules_out:$supervisor_out/share/guile/site/3.0" \
    GUILE_LOAD_COMPILED_PATH="$supervisor_out/lib/guile/3.0/site-ccache" \
    "$supervisor_out/bin/guile" --no-auto-compile -c \
    "(primitive-load \"$modules_out/guest-book-protocol.scm\")
     (primitive-load \"$modules_out/book-state-device-authority.scm\")
     (let ((module (resolve-module '(book-state-device-authority))))
       (unless (procedure? (module-ref module 'book-state-device-main))
         (error \"device authority entry is not callable\")))
     (display \"PASS: exact production authority source closure loads\\n\")
     (force-output)"

runtime_test_root=$(mktemp -d /tmp/opencode/book-state-device-runtime.XXXXXX)
timeout -s KILL 45 env -i \
    HOME="$private_home" LANG=C LC_ALL=C GUILE_AUTO_COMPILE=0 \
    GUILE_LOAD_PATH="$modules_out:$supervisor_out/share/guile/site/3.0" \
    GUILE_LOAD_COMPILED_PATH="$supervisor_out/lib/guile/3.0/site-ccache" \
    BOOK_STATE_DEVICE_MODULES="$modules_out" \
    BOOK_STATE_DEVICE_GUILE="$supervisor_out/bin/guile" \
    BOOK_STATE_DEVICE_LANGUAGE_PROFILE="$language_profile_out" \
    BOOK_STATE_DEVICE_LANGUAGE_CLOSURE="$language_closure_out" \
    BOOK_STATE_DEVICE_GUILE_BOUNDARY="$guile_boundary_out" \
    BOOK_STATE_DEVICE_PYTHON_BOUNDARY="$python_boundary_out" \
    BOOK_STATE_DEVICE_ADAPTER="$adapter_out" \
    BOOK_STATE_DEVICE_GUILE_BOOK="$guile_book_out" \
    BOOK_STATE_DEVICE_PYTHON_BOOK="$python_book_out" \
    BOOK_STATE_DEVICE_GUILE_PROTOCOL="$guile_protocol_out" \
    BOOK_STATE_DEVICE_BLOCKING_PROTOCOL="$blocking_protocol_out" \
    BOOK_STATE_DEVICE_PYTHON_PROTOCOL="$python_protocol_out" \
    BOOK_STATE_DEVICE_RUNTIME_TEST_ROOT="$runtime_test_root" \
    "$supervisor_out/bin/guile" --no-auto-compile -c \
    "(primitive-load \"$modules_out/guest-book-protocol.scm\")
     (primitive-load \"$modules_out/book-state-device-authority.scm\")
     (primitive-load \"$tool_dir/test-authority-runtime.scm\")"
[ ! -e "$runtime_test_root" ] || {
    echo "FAIL: authority runtime test retained its private temporary root" >&2
    exit 1
}

idle_test_root=$(mktemp -d /tmp/opencode/book-state-device-idle-stop.XXXXXX)
env -i HOME="$private_home" LANG=C LC_ALL=C GUILE_AUTO_COMPILE=0 \
    GUILE_LOAD_PATH="$modules_out:$supervisor_out/share/guile/site/3.0" \
    GUILE_LOAD_COMPILED_PATH="$supervisor_out/lib/guile/3.0/site-ccache" \
    BOOK_STATE_DEVICE_GUILE="$supervisor_out/bin/guile" \
    BOOK_STATE_DEVICE_IDLE_ROOT="$idle_test_root" \
    "$supervisor_out/bin/guile" --no-auto-compile -c \
    "(primitive-load \"$modules_out/guest-book-protocol.scm\")
     (primitive-load \"$modules_out/book-state-device-authority.scm\")
     (primitive-load \"$tool_dir/test-authority-idle-stop.scm\")" &
idle_pid=$!
tries=1000
while [ ! -S "$idle_test_root/run/control.sock" ] && [ "$tries" -gt 0 ]; do
    sleep 0.005
    tries=$((tries - 1))
done
[ -S "$idle_test_root/run/control.sock" ] || {
    kill -KILL "$idle_pid" 2>/dev/null || true
    wait "$idle_pid" 2>/dev/null || true
    echo "FAIL: idle authority did not create its private socket" >&2
    exit 1
}
kill -TERM "$idle_pid"
tries=120
while kill -0 "$idle_pid" 2>/dev/null && [ "$tries" -gt 0 ]; do
    sleep 0.1
    tries=$((tries - 1))
done
if kill -0 "$idle_pid" 2>/dev/null; then
    kill -KILL "$idle_pid" 2>/dev/null || true
    wait "$idle_pid" 2>/dev/null || true
    echo "FAIL: idle authority did not stop within 12 seconds" >&2
    exit 1
fi
wait "$idle_pid"
[ ! -e "$idle_test_root/run" ] || {
    echo "FAIL: idle stop retained its runtime root" >&2
    exit 1
}
for suffix in -journal -wal -shm; do
    [ ! -e "$idle_test_root/state/book-state-v1.sqlite$suffix" ] || {
        echo "FAIL: idle stop retained SQLite sidecar $suffix" >&2
        exit 1
    }
done
rm "$idle_test_root/state/enabled" "$idle_test_root/state/book-state-v1.sqlite"
rmdir "$idle_test_root/state" "$idle_test_root"
echo "PASS: TERM wakes blocking accept and closes SQLite/socket without polling"
