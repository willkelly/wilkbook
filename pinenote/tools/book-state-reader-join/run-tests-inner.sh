#!/bin/sh
# Execute only after the outer runner has copied and authenticated one fixed
# source closure.  No mutable repository project source is on a load path.
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: run-tests-inner.sh PRIVATE_CLOSURE RUN_ROOT" >&2
    exit 2
}
closure=$1
run_root=$2
case "$closure:$run_root" in /*:/*) ;; *) exit 2 ;; esac
[ "$(CDPATH= cd -- "$closure" && pwd -P)" = "$closure" ]
[ "$(CDPATH= cd -- "$run_root" && pwd -P)" = "$run_root" ]

join="$closure/join"
native="$closure/native-v2"
observer="$closure/observer-v1"
ui="$closure/ui"
protocol="$native/accepted-inputs/book-protocol"
state="$native/accepted-inputs/state-protocol"
backend="$native/accepted-inputs/backend"
session="$join/empty-action-successor"
ccache="$run_root/ccache"
book_ccache="$run_root/book-ccache"
pycache="$run_root/pycache"
empty="$run_root/empty"
suite="$run_root/suite"
mkdir -m 700 "$ccache" "$book_ccache" "$pycache" "$empty" "$suite"
mkdir -m 700 "$ccache/book-protocol" "$ccache/checks" \
    "$book_ccache/book-protocol"

sh "$join/verify-source-closure.sh" "$closure"
sh "$join/test-source-gate.sh" "$closure" "$run_root"
sh "$join/test-helper-provenance.sh" "$closure" "$run_root"

# Prove the separately reviewable successor is exactly the committed patch over
# accepted completion-observer candidate 0342e87c..., not a hand-copied fork.
patched="$run_root/patched-observer-candidate.scm"
cp "$observer/candidate/book-session.scm" "$patched"
chmod 600 "$patched"
patch --quiet "$patched" <"$session/observer-0342-empty-state-text.patch"
cmp "$patched" "$session/book-session.scm"
chmod 400 "$patched"
echo "PASS: state-text successor is exact patch over accepted observer 0342e87c"

package_load=${GUILE_LOAD_PATH-}
package_compiled=${GUILE_LOAD_COMPILED_PATH-}
[ -n "$package_load" ] && [ -n "$package_compiled" ] || {
    echo "pinned Guix shell omitted Scheme package paths" >&2
    exit 1
}

compile_log="$run_root/compile.log"
: >"$compile_log"
compile_module () {
    output=$1
    source=$2
    mkdir -p "$(dirname "$ccache/$output")"
    guild compile -Warity-mismatch -Wformat \
        -L "$join" -L "$session" -L "$observer" \
        -L "$protocol" -L "$state" -L "$backend" -L "$ui" \
        -o "$ccache/$output" "$source" >>"$compile_log" 2>&1
}
compile_book_module () {
    output=$1
    source=$2
    mkdir -p "$(dirname "$book_ccache/$output")"
    guild compile -Warity-mismatch -Wformat \
        -L "$join" -L "$protocol" \
        -o "$book_ccache/$output" "$source" >>"$compile_log" 2>&1
}

compile_module book-protocol.go "$protocol/book-protocol.scm"
compile_module book-protocol/blocking-io.go \
    "$protocol/book-protocol/blocking-io.scm"
compile_module book-state.go "$backend/book-state.scm"
compile_module book-state-operation-id.go \
    "$state/book-state-operation-id.scm"
compile_module book-state-protocol.go "$state/book-state-protocol.scm"
compile_module book-state-backend-adapter.go \
    "$state/book-state-backend-adapter.scm"
compile_module book-state-session-delegate.go \
    "$observer/book-state-session-delegate.scm"
compile_module book-session.go "$session/book-session.scm"
compile_module private-control.go "$ui/private-control.scm"
compile_module book-state-reader-bridge.go \
    "$join/book-state-reader-bridge.scm"
compile_module adversarial-book-common.go \
    "$join/adversarial-book-common.scm"
compile_module checks/book-fd3-exec.go "$join/book-fd3-exec.scm"
compile_module checks/joined-note-book.go "$join/joined-note-book.scm"
compile_module checks/forged-present-book.go \
    "$join/forged-present-book.scm"
compile_module checks/mismatched-commit-book.go \
    "$join/mismatched-commit-book.scm"
compile_module checks/reader-join-authority.go \
    "$join/reader-join-authority.scm"
compile_module checks/verify-module-origins.go \
    "$join/verify-module-origins.scm"

compile_book_module book-protocol.go "$protocol/book-protocol.scm"
compile_book_module book-protocol/blocking-io.go \
    "$protocol/book-protocol/blocking-io.scm"
compile_book_module adversarial-book-common.go \
    "$join/adversarial-book-common.scm"

cat "$compile_log"
if grep -i 'warning:' "$compile_log"; then
    echo "compile warnings are forbidden" >&2
    exit 1
fi

cd "$empty"
regression_load="$session:$observer:$protocol:$state:$backend:$package_load"
regression_compiled="$ccache:$package_compiled"
run_scheme_regression () {
    label=$1
    source=$2
    expected=$3
    log="$run_root/$label.log"
    GUILE_LOAD_PATH="$regression_load" \
    GUILE_LOAD_COMPILED_PATH="$regression_compiled" \
    GUILE_AUTO_COMPILE=0 \
        guile --no-auto-compile "$source" | tee "$log"
    grep -E "# of expected passes[[:space:]]+$expected$" "$log" >/dev/null || {
        echo "Scheme regression did not report $expected passes: $label" >&2
        exit 1
    }
}
run_scheme_regression book-session-227 \
    "$join/accepted-regressions/test-book-session-227.scm" 227
run_scheme_regression book-session-state-61 \
    "$join/accepted-regressions/test-book-session-state-integration-61.scm" 61
run_scheme_regression completion-observer-37 \
    "$observer/test-completion-observer.scm" 37
run_scheme_regression state-text-policy \
    "$session/test-state-text-action-policy.scm" 7

python3 -I -S -X "pycache_prefix=$pycache" -m py_compile \
    "$protocol/book_protocol.py" \
    "$join/python-book-launcher.py" \
    "$join/joined_note_book.py" \
    "$join/test_reader_join.py"

koreader=/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03
koreader_dir="$koreader/lib/koreader"
luajit="$koreader_dir/luajit"
[ -x "$luajit" ] && [ -f "$koreader_dir/reader.lua" ] || {
    echo "exact KOReader store item is unavailable" >&2
    exit 1
}
[ "$(cat "$koreader_dir/git-rev")" = v2026.03 ] || {
    echo "exact KOReader store item has wrong revision" >&2
    exit 1
}
"$luajit" "$join/check-lua-syntax.lua" \
    "$join/fixture/pendingedit.koplugin/_meta.lua" \
    "$join/fixture/pendingedit.koplugin/main.lua"

export GUILE_LOAD_PATH="$join:$session:$observer:$protocol:$state:$backend:$ui:$package_load"
export GUILE_LOAD_COMPILED_PATH="$ccache:$package_compiled"
export GUILE_AUTO_COMPILE=0
export XDG_CACHE_HOME="$run_root/xdg-cache"
mkdir -m 700 "$XDG_CACHE_HOME"
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE

guile --no-auto-compile "$join/verify-module-origins.scm" \
    "$join" "$native" "$observer" "$session" "$ui" "$ccache" \
    | tee "$run_root/module-origins.log"
[ "$(grep -c '^JOIN-MODULE-ORIGIN:' "$run_root/module-origins.log")" -eq 11 ]

# The fixed Guile books get only protocol/adversarial modules plus Guile's
# package paths.  In particular their source path has no backend, adapter,
# delegate, authority, SQLite schema, namespace, or retained state directory.
json_source=$(guile -c \
    '(display (or (search-path %load-path "json.scm") ""))')
[ -n "$json_source" ]
json_source=$(readlink -f "$json_source")
book_load="$run_root/book-load"
mkdir -m 700 "$book_load"
ln -s "$(dirname "$json_source")/json.scm" "$book_load/json.scm"
ln -s "$(dirname "$json_source")/json" "$book_load/json"
[ ! -e "$book_load/sqlite3.scm" ]

export BOOK_JOIN_PYTHON_CODEC="$protocol/book_protocol.py"
export BOOK_JOIN_BOOK_GUILE_LOAD_PATH="$protocol:$book_load"
export BOOK_JOIN_BOOK_GUILE_COMPILED_PATH="$book_ccache:$package_compiled"

if grep -Eq '\(book-state|\(sqlite3' \
        "$join/joined-note-book.scm" "$join/adversarial-book-common.scm" \
        "$join/forged-present-book.scm" \
        "$join/mismatched-commit-book.scm"; then
    echo "fixed Guile book imports trusted state authority" >&2
    exit 1
fi
if grep -Eq '(^|[^A-Za-z_])(sqlite3|book_state)([^A-Za-z_]|$)' \
        "$join/joined_note_book.py"; then
    echo "fixed Python book imports trusted state authority" >&2
    exit 1
fi

python3 -I -S "$join/test_reader_join.py" \
    --run-root "$suite" \
    --join-dir "$join" \
    --ui-fixture "$ui/fixture/bookstatereader.koplugin" \
    --pending-edit-fixture "$join/fixture/pendingedit.koplugin" \
    --koreader-dir "$koreader_dir" \
    --guile "$(command -v guile)" \
    --authority "$join/reader-join-authority.scm" \
    --load-path "$join" \
    --load-path "$session" \
    --load-path "$observer" \
    --load-path "$protocol" \
    --load-path "$state" \
    --load-path "$backend" \
    --load-path "$ui" \
    | tee "$run_root/join-suite.log"

grep -F "JOIN_EVIDENCE guile version=3" "$run_root/join-suite.log"
grep -F "JOIN_EVIDENCE python version=3" "$run_root/join-suite.log"
grep -F "JOIN_EVIDENCE UI-empty-save=version2; read-only-empty-retained; exact-4096=ok; retry-one-receipt=ok" \
    "$run_root/join-suite.log"

printf '%s\n' \
    "PASS: exact private source closure executed after pre-execution gate" \
    "PASS: accepted native-v2/UI/completion-observer identities unchanged" \
    "PASS: accepted 227/61/37 regressions plus state-text policy delta" \
    "PASS: 11 Scheme project module source/compiled origins authenticated" \
    "PASS: Guile and Python books received only connected FD 3 authority" \
    "PASS: 22 fresh Guile/Book/KOReader lifecycles joined to real SQLite" \
    "PASS: Guile/Python restart saves advanced 1->2->3 with fresh operation IDs" \
    "PASS: actual UI clear/Save persisted present-empty; exact 4 KiB survived" \
    "PASS: real read-only failures retained empty draft without backend mutation" \
    "PASS: same-operation retry returned one receipt without a version bump" \
    "PASS: delayed edit, forged present, and mismatched commit never painted Saved" \
    "PASS: endpoint revoked before UI finish; exact children reaped; logs bounded" \
    "PASS: pinned native KOReader v2026.03 offscreen host gate"
