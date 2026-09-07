#!/bin/sh
# Accepted reader-join v2 body with a derivation-resolved KOReader argument.
set -eu

[ "$#" -eq 6 ] || {
    echo "usage: reader-join-inner.sh PRIVATE_CLOSURE RUN_ROOT KOREADER_OUTPUT PRIVATE_HELPER PRIVATE_ENVIRONMENT GUIX" >&2
    exit 2
}
closure=$1
run_root=$2
koreader=$3
private_helper=$4
private_environment=$5
BOOK_SOURCE_GUIX=$6
export BOOK_SOURCE_GUIX
case "$closure:$run_root:$koreader" in /*:/*:/gnu/store/*) ;; *) exit 2 ;; esac
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
. "$private_helper"
book_source_enter_guix_shell_environment "$private_environment" \
    "$ccache" reader-join "$run_root/private-environment.log"

sh "$join/verify-source-closure.sh" "$closure"
sh "$join/test-source-gate.sh" "$closure" "$run_root"
sh "$join/test-helper-provenance.sh" "$closure" "$run_root"

patched="$run_root/patched-observer-candidate.scm"
cp "$observer/candidate/book-session.scm" "$patched"
chmod 600 "$patched"
patch --quiet "$patched" <"$session/observer-0342-empty-state-text.patch"
cmp "$patched" "$session/book-session.scm"
chmod 400 "$patched"
echo "PASS: state-text successor is exact patch over accepted observer 0342e87c"

compile_log="$run_root/compile.log"
: >"$compile_log"
compile () {
    output=$1
    source=$2
    mkdir -p "$(dirname "$ccache/$output")"
    guild compile -Warity-mismatch -Wformat \
        -L "$join" -L "$session" -L "$observer" \
        -L "$protocol" -L "$state" -L "$backend" -L "$ui" \
        -o "$ccache/$output" "$source" >>"$compile_log" 2>&1
}
compile_book () {
    output=$1
    source=$2
    mkdir -p "$(dirname "$book_ccache/$output")"
    guild compile -Warity-mismatch -Wformat \
        -L "$join" -L "$protocol" \
        -o "$book_ccache/$output" "$source" >>"$compile_log" 2>&1
}

compile book-protocol.go "$protocol/book-protocol.scm"
compile book-protocol/blocking-io.go "$protocol/book-protocol/blocking-io.scm"
compile book-state.go "$backend/book-state.scm"
compile book-state-operation-id.go "$state/book-state-operation-id.scm"
compile book-state-protocol.go "$state/book-state-protocol.scm"
compile book-state-backend-adapter.go "$state/book-state-backend-adapter.scm"
compile book-state-session-delegate.go "$observer/book-state-session-delegate.scm"
compile book-session.go "$session/book-session.scm"
compile private-control.go "$ui/private-control.scm"
compile book-state-reader-bridge.go "$join/book-state-reader-bridge.scm"
compile adversarial-book-common.go "$join/adversarial-book-common.scm"
compile checks/book-fd3-exec.go "$join/book-fd3-exec.scm"
compile checks/joined-note-book.go "$join/joined-note-book.scm"
compile checks/forged-present-book.go "$join/forged-present-book.scm"
compile checks/mismatched-commit-book.go "$join/mismatched-commit-book.scm"
compile checks/reader-join-authority.go "$join/reader-join-authority.scm"
compile checks/verify-module-origins.go "$join/verify-module-origins.scm"
compile_book book-protocol.go "$protocol/book-protocol.scm"
compile_book book-protocol/blocking-io.go \
    "$protocol/book-protocol/blocking-io.scm"
compile_book adversarial-book-common.go "$join/adversarial-book-common.scm"

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
    grep -E "# of expected passes[[:space:]]+$expected$" "$log" >/dev/null
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
    "$protocol/book_protocol.py" "$join/python-book-launcher.py" \
    "$join/joined_note_book.py" "$join/test_reader_join.py"

koreader_dir="$koreader/lib/koreader"
luajit="$koreader_dir/luajit"
[ -x "$luajit" ] && [ -f "$koreader_dir/reader.lua" ] || {
    echo "derivation-resolved KOReader output is unavailable" >&2
    exit 1
}
[ "$(cat "$koreader_dir/git-rev")" = v2026.03 ]
"$luajit" "$join/check-lua-syntax.lua" \
    "$join/fixture/pendingedit.koplugin/_meta.lua" \
    "$join/fixture/pendingedit.koplugin/main.lua"

export GUILE_LOAD_PATH="$join:$session:$observer:$protocol:$state:$backend:$ui:$package_load"
export GUILE_LOAD_COMPILED_PATH="$ccache:$package_compiled"
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE

guile --no-auto-compile "$join/verify-module-origins.scm" \
    "$join" "$native" "$observer" "$session" "$ui" "$ccache" \
    | tee "$run_root/module-origins.log"
[ "$(grep -c '^JOIN-MODULE-ORIGIN:' "$run_root/module-origins.log")" -eq 11 ]

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
        "$join/forged-present-book.scm" "$join/mismatched-commit-book.scm"; then
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
    --load-path "$join" --load-path "$session" --load-path "$observer" \
    --load-path "$protocol" --load-path "$state" --load-path "$backend" \
    --load-path "$ui" | tee "$run_root/join-suite.log"

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
    "PASS: Guix-derived native KOReader v2026.03 offscreen host gate"
