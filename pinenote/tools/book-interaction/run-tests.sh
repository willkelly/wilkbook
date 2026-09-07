#!/bin/sh
# Run the trusted native fixture through real pinned KOReader, first with the
# Guile fixture book and then with the Python fixture book.
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$tool_dir/../../.." && pwd)
reader_tool="$tool_dir/../book-reader"
fixture="$tool_dir/fixture/bookinteractionprobe.koplugin"
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

require_hash f5823fa7fd7c6fd81780c70960fd80530e24f990af2fa346c30ed94604ba7668 \
    "$tool_dir/../book-session/book-session.scm"
require_hash 91f121adea358e198fac68aa399dec0b5d1f35df32d1f9f0dca42ccda8cefd44 \
    "$tool_dir/../book-protocol/book-protocol.scm"
require_hash 4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735 \
    "$tool_dir/../book-protocol/book_protocol.py"
require_hash 543570769d1f1cb3818c6c1bbdbca0025e1f865807f211ace043db42a30baccd \
    "$tool_dir/../book-protocol/book-protocol/blocking-io.scm"
require_hash 9b455fcd58eeb2ab03e18d94237de3052a43a8de1a85d4466e7d75c4a9f1d239 \
    "$reader_tool/canonical-koreader-output.scm"
require_hash e1507aeb8f0d2ac36efcead795bebdf28c9bb067dd52550e10bd64c26e7a080e \
    "$reader_tool/timeout-owner.sh"
require_hash 97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354 \
    "$reader_tool/process-identity.sh"
require_hash fe147cdadb72a161c1f4e023b7c52f87c037c506a08570b73044e5d2c78c617c \
    "$reader_tool/record-exec.sh"
require_hash 661e28e46437fd1e09d7f2482d15b4c6797edf1e157982cbdd1f3516d296b2f1 \
    "$repo_root/channels.scm"

canonical_info=$(guix repl -L "$repo_root" \
    "$reader_tool/canonical-koreader-output.scm") \
    || fail "could not evaluate the repository KOReader derivation"
canonical_drv=$(printf '%s\n' "$canonical_info" | sed -n '1p')
canonical_output=$(printf '%s\n' "$canonical_info" | sed -n '2p')
[ "$(printf '%s\n' "$canonical_info" | sed -n '$=')" -eq 2 ] \
    || fail "canonical KOReader evaluation did not return two lines"
case "$canonical_drv" in
    /gnu/store/*.drv) ;;
    *) fail "canonical evaluation returned an invalid derivation path" ;;
esac
[ -f "$canonical_drv" ] || fail "canonical derivation does not exist"
case "$canonical_output" in
    /gnu/store/*-koreader-bin-*) ;;
    *) fail "canonical evaluation returned an invalid output path" ;;
esac

canonical_name=${canonical_output##*/}
canonical_version=${canonical_name#*-koreader-bin-}
[ "$canonical_version" != "$canonical_name" ] \
    || fail "could not derive the canonical KOReader version"
expected_revision="v$canonical_version"

bundle=${1:-${KOREADER_BUNDLE:-$canonical_output}}
case "$bundle" in
    /*) ;;
    *) bundle=$(CDPATH= cd -- "$bundle" && pwd) ;;
esac
koreader_dir="$bundle/lib/koreader"
luajit="$koreader_dir/luajit"
[ -x "$luajit" ] && [ -f "$koreader_dir/reader.lua" ] \
    || fail "not a KOReader bundle: $bundle"
[ -f "$koreader_dir/git-rev" ] \
    || fail "KOReader bundle has no git-rev"
[ "$(wc -l <"$koreader_dir/git-rev" | tr -d ' ')" = 1 ] \
    || fail "KOReader git-rev is not exactly one line"
bundle_revision=$(cat "$koreader_dir/git-rev")
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
        || fail "canonical output is not linked to the evaluated derivation"
    bundle_mode=package-pinned
fi

[ ! -e "$koreader_dir/plugins/bookinteractionprobe.koplugin" ] \
    || fail "integration fixture unexpectedly exists in packaged KOReader"
[ -f "$fixture/main.lua" ] && [ -f "$fixture/private_channel.lua" ] \
    && [ -f "$fixture/ui_audit.lua" ] && [ -f "$fixture/_meta.lua" ] \
    || fail "KOReader integration fixture is incomplete"
"$reader_tool/lint-fixture.sh" "$fixture"

guile=$(command -v guile) || fail "Guile is unavailable"
python=$(command -v python3) || fail "Python is unavailable"

expected_result_for() {
    "$python" -c \
        'import sys; print("Book result: " + sys.argv[1].upper())' "$1"
}

latin_input='Ada'
unicode_input='élan λ'
latin_result=$(expected_result_for "$latin_input")
unicode_result=$(expected_result_for "$unicode_input")
[ "$latin_result" = 'Book result: ADA' ] \
    || fail "independent Latin result oracle changed"
[ "$unicode_result" = 'Book result: ÉLAN Λ' ] \
    || fail "independent Unicode result oracle changed"
[ "$latin_input" != "$unicode_input" ] \
    && [ "$latin_result" != "$unicode_result" ] \
    || fail "fixture result cases are not distinct"

tmp_base=${BOOK_INTERACTION_TMPDIR:-/tmp/opencode}
mkdir -p "$tmp_base"

active_run=
host_record=
timeout_record=
reader_record=
peer_record=
host_pid=
host_start=
mutation_root=
mutation_owner_pid=
mutation_owner_start=
mutation_hold_record=

cleanup_active() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ -n "$host_pid" ] && [ -n "$host_start" ]; then
        owned_process_terminate "$host_pid" "$host_start" || rc=1
        wait "$host_pid" 2>/dev/null || true
    fi
    if [ -n "$mutation_owner_pid" ] && [ -n "$mutation_owner_start" ]; then
        owned_process_terminate \
            "$mutation_owner_pid" "$mutation_owner_start" || rc=1
        wait "$mutation_owner_pid" 2>/dev/null || true
    fi
    if [ -n "$mutation_hold_record" ]; then
        owned_process_terminate_record "$mutation_hold_record" || rc=1
    fi
    for record in "$peer_record" "$reader_record" "$host_record" \
            "$timeout_record"; do
        if [ -n "$record" ]; then
            owned_process_terminate_record "$record" || rc=1
        fi
    done
    if [ -n "$active_run" ]; then
        if [ "${KEEP_ARTIFACTS:-0}" = 1 ]; then
            echo "artifacts: $active_run"
        else
            rm -rf -- "$active_run"
        fi
    fi
    if [ -n "$mutation_root" ]; then
        rm -rf -- "$mutation_root"
    fi
    exit "$rc"
}
trap cleanup_active EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

prepare_run() {
    label=$1
    active_run=$(mktemp -d "$tmp_base/book-interaction-$label.XXXXXX")
    chmod 700 "$active_run"
    home="$active_run/home"
    ko_home="$active_run/ko"
    tmp="$active_run/tmp"
    plugin_home="$ko_home/plugins/bookinteractionprobe.koplugin"
    book="$active_run/fixture-book.txt"
    host_log="$active_run/host.log"
    host_record="$active_run/host.pid"
    timeout_record="$active_run/timeout.pid"
    reader_record="$active_run/reader.pid"
    peer_record="$active_run/peer.pid"
    mkdir -p "$home/.config" "$home/.cache" "$home/.local/share" \
        "$ko_home/plugins" "$tmp"
    cp -R -- "$fixture" "$plugin_home"
    cat >"$book" <<'EOF'
Book interaction integration fixture

This inert temporary document only opens the real KOReader ReaderUI.
Fixture program behavior lives in the reviewed Guile and Python peer files.
EOF
}

host_command() {
    label=$1
    update_input=$2
    expected_result=$3
    exec "$guile" --no-auto-compile \
        -L "$tool_dir" \
        -L "$tool_dir/../book-protocol" \
        -L "$tool_dir/../book-session" \
        "$tool_dir/integration-host.scm" \
        "$active_run" "$koreader_dir" "$luajit" "$book" \
        "$label" "$guile" "$python" "$expected_revision" \
        "$update_input" "$expected_result"
}

reset_active() {
    active_run=
    host_record=
    timeout_record=
    reader_record=
    peer_record=
    host_pid=
    host_start=
}

require_live_identity_records() {
    owner_pid=$1
    owner_start=$2
    command_record=$3
    deadline_record=$4
    identity_attempt=0
    while [ "$identity_attempt" -lt 200 ]; do
        if owned_process_record_alive "$command_record" \
                && owned_process_record_alive "$deadline_record"; then
            read -r command_pid command_start <"$command_record"
            read -r deadline_pid deadline_start <"$deadline_record"
            [ "$command_pid" != "$deadline_pid" ] \
                && owned_process_alive "$command_pid" "$command_start" \
                && owned_process_alive "$deadline_pid" "$deadline_start"
            return
        fi
        owned_process_alive "$owner_pid" "$owner_start" || return 1
        sleep 0.01
        identity_attempt=$((identity_attempt + 1))
    done
    return 1
}

run_recorder_mutation() {
    mutation_root=$(mktemp -d "$tmp_base/book-interaction-recorder.XXXXXX")
    chmod 700 "$mutation_root"
    cp -- "$reader_tool/timeout-owner.sh" \
        "$reader_tool/process-identity.sh" "$mutation_root/"
    cat >"$mutation_root/record-exec.sh" <<'EOF'
#!/bin/sh
set -eu
shift
exec "$@"
EOF
    chmod +x "$mutation_root/timeout-owner.sh" \
        "$mutation_root/process-identity.sh" "$mutation_root/record-exec.sh"
    mutation_hold_record="$mutation_root/hold.pid"
    mutation_command_record="$mutation_root/command.pid"
    mutation_timeout_record="$mutation_root/timeout.pid"
    "$mutation_root/timeout-owner.sh" 10 1 \
        "$mutation_command_record" "$mutation_timeout_record" \
        "$mutation_root" "$tool_dir/identity-hold.sh" \
        "$mutation_hold_record" "$mutation_root/process-identity.sh" \
        >"$mutation_root/owner.log" 2>&1 &
    mutation_owner_pid=$!
    mutation_owner_start=$(owned_process_start_time "$mutation_owner_pid")

    if require_live_identity_records \
            "$mutation_owner_pid" "$mutation_owner_start" \
            "$mutation_command_record" "$mutation_timeout_record"; then
        fail "no-op identity recorder unexpectedly satisfied the owner gate"
    fi
    owned_process_record_alive "$mutation_hold_record" \
        || fail "no-op recorder mutation command did not start"
    [ ! -e "$mutation_command_record" ] \
        && [ ! -e "$mutation_timeout_record" ] \
        || fail "no-op recorder mutation unexpectedly published an identity"

    owned_process_terminate \
        "$mutation_owner_pid" "$mutation_owner_start" \
        || fail "could not stop recorder mutation owner"
    wait "$mutation_owner_pid" 2>/dev/null || true
    mutation_owner_pid=
    mutation_owner_start=
    owned_process_terminate_record "$mutation_hold_record" \
        || fail "could not stop recorder mutation command"
    owned_process_record_matches "$mutation_hold_record" \
        && fail "recorder mutation command survived exact cleanup"
    echo "PASS: no-op identity recorder is rejected before cleanup acceptance"
    rm -rf -- "$mutation_root"
    mutation_root=
    mutation_hold_record=
}

run_cleanup_regression() {
    prepare_run cleanup
    # Start the exact host directly, wait until both gated children have been
    # recorded, then remove the host. The outer owner must terminate both by
    # PID plus Linux start time, even though their immediate parent is gone.
    host_command guile "$latin_input" "$latin_result" >"$host_log" 2>&1 &
    host_pid=$!
    host_start=$(owned_process_start_time "$host_pid")
    attempts=0
    while [ "$attempts" -lt 200 ]; do
        if owned_process_record_alive "$reader_record" \
                && owned_process_record_alive "$peer_record"; then
            break
        fi
        if ! owned_process_alive "$host_pid" "$host_start"; then
            cat "$host_log" >&2
            fail "cleanup regression host exited before recording both children"
        fi
        sleep 0.01
        attempts=$((attempts + 1))
    done
    [ "$attempts" -lt 200 ] \
        || fail "cleanup regression did not publish both child identities"
    kill -KILL "$host_pid"
    set +e
    wait "$host_pid" 2>/dev/null
    rc=$?
    set -e
    host_pid=
    host_start=
    [ "$rc" -ne 0 ] || fail "terminated cleanup regression unexpectedly passed"
    owned_process_terminate_record "$reader_record" \
        || fail "could not terminate recorded KOReader child"
    owned_process_terminate_record "$peer_record" \
        || fail "could not terminate recorded book peer"
    owned_process_record_matches "$reader_record" \
        && fail "KOReader child survived supervisor termination"
    owned_process_record_matches "$peer_record" \
        && fail "book peer survived supervisor termination"
    echo "PASS: exact outer cleanup terminated both children after owner loss"
    rm -rf -- "$active_run"
    reset_active
}

run_mutated_host_expect_failure() {
    mutation_label=$1
    host_source=$2
    label=$3
    update_input=$4
    expected_result=$5
    expected_reader_failure=$6
    require_cleanup_audit=$7

    "$timeout_owner" 20 2 "$host_record" "$timeout_record" "$repo_root" \
        "$guile" --no-auto-compile \
            -L "$tool_dir" \
            -L "$tool_dir/../book-protocol" \
            -L "$tool_dir/../book-session" \
            "$host_source" \
            "$active_run" "$koreader_dir" "$luajit" "$book" \
            "$label" "$guile" "$python" "$expected_revision" \
            "$update_input" "$expected_result" \
            >"$host_log" 2>&1 &
    host_pid=$!
    host_start=$(owned_process_start_time "$host_pid")
    if ! require_live_identity_records \
            "$host_pid" "$host_start" "$host_record" "$timeout_record"; then
        cat "$host_log" >&2
        fail "$mutation_label did not publish two live owner records"
    fi
    set +e
    wait "$host_pid"
    rc=$?
    set -e
    host_pid=
    host_start=
    [ "$rc" -eq 1 ] || {
        cat "$host_log" >&2
        fail "$mutation_label returned $rc instead of the expected failure"
    }
    for record in "$host_record" "$timeout_record" "$reader_record" \
            "$peer_record"; do
        owned_process_record_matches "$record" \
            && fail "$mutation_label left a recorded process present"
    done
    [ -f "$active_run/reader.log" ] \
        || fail "$mutation_label did not run actual KOReader"
    [ "$(grep -Fc "$expected_reader_failure" \
            "$active_run/reader.log" || true)" -eq 1 ] \
        || fail "$mutation_label lacked its exact reader-side rejection"
    if [ "$require_cleanup_audit" = yes ]; then
        [ "$(grep -Fxc \
                'BOOK_INTERACTION_READER: cleanup-audit:before-quit' \
                "$active_run/reader.log" || true)" -eq 1 ] \
            || fail "$mutation_label did not reject before UIManager quit"
    fi
    ! grep -Fq 'BOOK_INTERACTION_READER: result:ok' \
        "$active_run/reader.log" \
        || fail "$mutation_label emitted the final reader success marker"
    ! grep -Fq 'BOOK_INTERACTION_HOST: language=' "$host_log" \
        || fail "$mutation_label emitted the final host success marker"
}

mutate_reader_cleanup() {
    mutation=$1
    target=$2
    "$python" - "$mutation" "$target" <<'PY'
from pathlib import Path
import sys

mutation, target = sys.argv[1:]
replacements = {
    "close": "        UIManager:close(self.dialog)\n",
    "remove": "        UIManager:removeZMQ(self.channel)\n",
    "stop": "        self.channel:stop()\n",
}
old = replacements[mutation]
path = Path(target)
source = path.read_text()
if source.count(old) != 1:
    raise SystemExit(f"mutation anchor count for {mutation} was {source.count(old)}")
path.write_text(source.replace(old, f"        -- omitted by {mutation} mutation\n"))
PY
}

run_reader_cleanup_mutation() {
    mutation=$1
    expected_failure=$2
    prepare_run "reader-$mutation-mutation"
    mutate_reader_cleanup "$mutation" "$plugin_home/main.lua"
    run_mutated_host_expect_failure \
        "reader $mutation omission" "$tool_dir/integration-host.scm" \
        guile "$latin_input" "$latin_result" \
        "$expected_failure" yes
    echo "PASS: reader $mutation omission failed before UIManager quit"
    rm -rf -- "$active_run"
    reset_active
}

run_pending_message_mutation() {
    prepare_run "reader-pending-message-mutation"
    "$python" - "$plugin_home/main.lua" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = (
    "    -- Exercise InputDialog's real rejected/pending branch without a message.\n"
    "    return false, false\n"
)
new = (
    "    -- Mutation: omit the false no-message sentinel.\n"
    "    return false\n"
)
if source.count(old) != 1:
    raise SystemExit(f"pending callback anchor count was {source.count(old)}")
path.write_text(source.replace(old, new))
PY
    run_mutated_host_expect_failure \
        "pending callback message omission" "$tool_dir/integration-host.scm" \
        guile "$latin_input" "$latin_result" \
        'top-text=Saving failed.' no
    echo "PASS: false/nil pending callback exposed its modal overlay"
    rm -rf -- "$active_run"
    reset_active
}

run_hardcoded_relay_mutation() {
    prepare_run "host-hardcoded-relay-mutation"
    source_root="$active_run/source"
    mkdir -p "$source_root"
    cp -R -- "$tool_dir" "$source_root/book-interaction"
    ln -s -- "$tool_dir/../book-protocol" "$source_root/book-protocol"
    mutated_host="$source_root/book-interaction/integration-host.scm"
    "$python" - "$mutated_host" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "(queue-control! control 'present (presented-text-value value))"
new = "(queue-control! control 'present \"Book result: ADA\")"
if source.count(old) != 1:
    raise SystemExit(f"hardcoded relay anchor count was {source.count(old)}")
path.write_text(source.replace(old, new))
PY
    run_mutated_host_expect_failure \
        "hardcoded presentation relay" "$mutated_host" \
        python "$unicode_input" "$unicode_result" \
        'BOOK_INTERACTION_READER: FAIL:presentation did not match the independent test oracle' no
    ! grep -Fq "BOOK_INTERACTION_READER: present-painted-exact:$unicode_result" \
        "$active_run/reader.log" \
        || fail "hardcoded relay mutation painted the expected Unicode result"
    echo "PASS: hardcoded host presentation relay failed the Unicode paint oracle"
    rm -rf -- "$active_run"
    reset_active
}

run_language() {
    run_peer_label=$1
    run_case_label=$2
    run_update_input=$3
    run_expected_result=$4
    prepare_run "$run_peer_label-$run_case_label"
    "$timeout_owner" 20 2 "$host_record" "$timeout_record" "$repo_root" \
        "$guile" --no-auto-compile \
            -L "$tool_dir" \
            -L "$tool_dir/../book-protocol" \
            -L "$tool_dir/../book-session" \
            "$tool_dir/integration-host.scm" \
            "$active_run" "$koreader_dir" "$luajit" "$book" \
            "$run_peer_label" "$guile" "$python" "$expected_revision" \
            "$run_update_input" "$run_expected_result" \
            >"$host_log" 2>&1 &
    host_pid=$!
    host_start=$(owned_process_start_time "$host_pid")
    if ! require_live_identity_records \
            "$host_pid" "$host_start" "$host_record" "$timeout_record"; then
        cat "$host_log" >&2
        fail "$run_peer_label/$run_case_label owner did not publish two live identity records"
    fi
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
            fail "$run_peer_label/$run_case_label exceeded the process deadline"
            ;;
        *)
            cat "$host_log" >&2
            fail "$run_peer_label/$run_case_label interaction host exited $rc"
            ;;
    esac
    for record in "$host_record" "$timeout_record" "$reader_record" \
            "$peer_record"; do
        if owned_process_record_matches "$record"; then
            cat "$host_log" >&2
            fail "$run_peer_label/$run_case_label left a recorded process present"
        fi
    done
    expected="BOOK_INTERACTION_HOST: language=$run_peer_label update-present-navigation-close:ok"
    [ "$(grep -Fxc "$expected" "$host_log" || true)" -eq 1 ] \
        || fail "$run_peer_label/$run_case_label lacked its success marker"
    if grep -Fq 'BOOK_INTERACTION_HOST: FAIL:' "$host_log"; then
        cat "$host_log" >&2
        fail "$run_peer_label/$run_case_label run reported host failure"
    fi
    cat "$host_log"
    grep -Fx \
        "BOOK_INTERACTION_UI_AUDIT: paintTo-topmost-exact:$run_expected_result" \
        "$active_run/reader.log"
    grep -Fx \
        'BOOK_INTERACTION_READER: ui-wait-task:navigation:topmost-during-delay' \
        "$active_run/reader.log"
    grep -Fx \
        'BOOK_INTERACTION_READER: ui-wait-task:close:topmost-during-delay' \
        "$active_run/reader.log"
    grep -Fx \
        'BOOK_INTERACTION_UI_AUDIT: cleanup:dialog-source-counts-closed-fd-no-callback:ok' \
        "$active_run/reader.log"
    echo "PASS: $run_peer_label/$run_case_label completed the real IPC/UI interaction"
    rm -rf -- "$active_run"
    reset_active
}

echo "bundle: $bundle"
echo "bundle-mode: $bundle_mode"
echo "canonical-output: $canonical_output"
echo "canonical-derivation: $canonical_drv"
echo "verified-revision-before-fixture: $expected_revision"
echo "frontend: $koreader_dir/reader.lua"
echo "mode: trusted-native-fixture (no sandbox)"

timeout 5 "$luajit" "$tool_dir/test-private-channel.lua" "$fixture"
run_cleanup_regression
run_recorder_mutation
run_pending_message_mutation
run_reader_cleanup_mutation \
    close 'exact InputDialog is still shown before quit'
run_reader_cleanup_mutation \
    remove 'exact private source remains registered before quit'
run_reader_cleanup_mutation \
    stop 'private channel closed flag is false before quit'
run_hardcoded_relay_mutation
run_language guile latin "$latin_input" "$latin_result"
run_language python latin "$latin_input" "$latin_result"
run_language guile unicode "$unicode_input" "$unicode_result"
run_language python unicode "$unicode_input" "$unicode_result"

trap - EXIT HUP INT TERM
echo "PASS: Book interaction vertical fixture"
