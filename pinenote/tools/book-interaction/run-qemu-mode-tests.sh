#!/bin/sh
# Host-only QEMU-mode seam gate.  "QEMU" is a trusted Guile Unix-socket mock;
# this script never starts QEMU, runsc, an ARM binary, or a guest image.
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
reader_tool="$tool_dir/../book-reader"
. "$reader_tool/process-identity.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

require_count() {
    expected=$1
    text=$2
    path=$3
    actual=$(grep -Fxc "$text" "$path" 2>/dev/null || true)
    [ "$actual" -eq "$expected" ] \
        || fail "$path contained $actual rather than $expected copies of: $text"
}

require_hash() {
    expected_hash=$1
    path=$2
    actual_hash=$(sha256sum "$path" | sed 's/ .*//')
    [ "$actual_hash" = "$expected_hash" ] \
        || fail "pinned source changed: $path ($actual_hash)"
}

guile=$(command -v guile) || fail "Guile is unavailable"
python=$(command -v python3) || fail "Python is unavailable for reviewer oracles"
setsid_command=$(command -v setsid) || fail "setsid is unavailable"

bundle=${1:-${KOREADER_BUNDLE:-}}
[ -n "$bundle" ] || fail "usage: run-qemu-mode-tests.sh KOREADER_BUNDLE"
case "$bundle" in
    /*) ;;
    *) bundle=$(CDPATH= cd -- "$bundle" && pwd) ;;
esac
case "${bundle##*/}" in
    *-koreader-bin-2026.03) ;;
    *) fail "QEMU-mode gate requires the KOReader 2026.03 package output" ;;
esac
koreader_dir="$bundle/lib/koreader"
luajit="$koreader_dir/luajit"
[ -x "$luajit" ] && [ -f "$koreader_dir/reader.lua" ] \
    && [ "$(cat "$koreader_dir/git-rev")" = v2026.03 ] \
    || fail "KOReader package does not have the exact v2026.03 runtime"
require_hash 846aed94948bfa1c155325770bf4df8673850a14395ec585c3d594c859d5b2d5 \
    "$koreader_dir/git-rev"
require_hash a189ca83623153f2a1b048c7bc04eba1fca76068bd9705dc71296d26292613cc \
    "$koreader_dir/reader.lua"
require_hash f74b56b1885647770da9596e753990dd065032b6f85777260c841c19b1999464 \
    "$koreader_dir/frontend/ui/uimanager.lua"
require_hash a03bdd3827a3108d313a19407c7e2db6176e20c3066595356f4c86e3a50930b4 \
    "$koreader_dir/frontend/ui/widget/inputdialog.lua"
require_hash 1431c5cb7f5e42c5494c9f7ebc570d74627c9299e6d00f9c54762b4abded0f66 \
    "$koreader_dir/frontend/ui/widget/inputtext.lua"
require_hash 1f6bde433c349ef8e07f2ca8f2d24b209127ca9d1a80e1a89b710a27d403e711 \
    "$koreader_dir/frontend/apps/reader/modules/readerhighlight.lua"

fixture="$tool_dir/fixture/bookinteractionprobe.koplugin"
"$reader_tool/lint-fixture.sh" "$fixture"
timeout 5 "$luajit" "$tool_dir/test-private-channel.lua" "$fixture"
! grep -Eq '\(setpgid|AF_INET|BOOK_INTERACTION_(EXPECTED_RESULT|UPDATE_INPUT)|nonce|language' \
    "$tool_dir/qemu-coordinator.scm" \
    || fail "lifetime-only coordinator acquired a forbidden authority/transport seam"

tmp_base=${BOOK_INTERACTION_TMPDIR:-/tmp/opencode}
mkdir -p "$tmp_base"
test_root=$(mktemp -d "$tmp_base/book-interaction-qemu-host.XXXXXX")
chmod 700 "$test_root"
active_group=
active_coordinator=
active_coordinator_start=

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ -n "$active_group" ]; then
        kill -KILL "-$active_group" 2>/dev/null || true
    fi
    if [ -n "$active_coordinator" ]; then
        wait "$active_coordinator" 2>/dev/null || true
    fi
    if [ "${KEEP_ARTIFACTS:-0}" = 1 ]; then
        echo "artifacts: $test_root"
    else
        rm -rf -- "$test_root"
    fi
    exit "$rc"
}

finish_success() {
    message=$1
    trap - EXIT HUP INT TERM
    if [ "${KEEP_ARTIFACTS:-0}" = 1 ]; then
        echo "artifacts: $test_root"
    else
        rm -rf -- "$test_root"
    fi
    echo "$message"
    exit 0
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

prepare_run() {
    label=$1
    run="$test_root/$label"
    mkdir -m 700 "$run"
    mkdir -m 700 "$run/home" "$run/tmp" "$run/xdg-cache" \
        "$run/xdg-config" "$run/xdg-runtime" "$run/boot"
    : >"$run/boot/Image"
    : >"$run/boot/initrd.cpio.gz"
    : >"$run/disk-overlay.qcow2"
    chmod 600 "$run/boot/Image" "$run/boot/initrd.cpio.gz" \
        "$run/disk-overlay.qcow2"
    socket="$run/book-ui.sock"
    coordinator_log="$run/coordinator.log"
}

make_fake_qemu() {
    mode=$1
    fake_qemu="$test_root/fake-qemu-$mode"
    cat >"$fake_qemu" <<EOF
#!/bin/sh
exec "$guile" --no-auto-compile -L "$tool_dir" \
    "$tool_dir/test-qemu-mode-guest.scm" "$mode" "\$@"
EOF
    chmod 700 "$fake_qemu"
}

copy_short_connect_deadline_tool() {
    mutated_tool="$test_root/mutated-connect-deadline"
    mkdir -m 700 "$mutated_tool" "$mutated_tool/fixture"
    cp -- "$tool_dir/qemu-coordinator.scm" "$mutated_tool/"
    cp -R -- "$fixture" "$mutated_tool/fixture/"
    "$python" - "$mutated_tool/qemu-coordinator.scm" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
old = "(define socket-connect-timeout-seconds 30.0)"
new = "(define socket-connect-timeout-seconds 0.25)"
if source.count(old) != 1:
    raise SystemExit(f"production connect-deadline anchor count was {source.count(old)}")
path.write_text(source.replace(old, new))
PY
}

copy_query_fault_tool() {
    query_fault=$1
    mutated_tool="$test_root/mutated-$query_fault"
    mkdir -m 700 "$mutated_tool" "$mutated_tool/fixture"
    cp -- "$tool_dir/qemu-coordinator.scm" "$mutated_tool/"
    cp -R -- "$fixture" "$mutated_tool/fixture/"
    "$python" - "$query_fault" "$mutated_tool/qemu-coordinator.scm" <<'PY'
from pathlib import Path
import sys

mode, filename = sys.argv[1:]
path = Path(filename)
source = path.read_text()
definition_anchor = '''(define c-connect
  (pointer->procedure int (dynamic-func "connect" libc)
                      (list int '* uint32) #:return-errno? #t))
'''
if source.count(definition_anchor) != 1:
    raise SystemExit("query-fault definition anchor was not unique")

if mode == "peer-eintr-once":
    injection = '''
(define injected-getpeername-calls 0)
(define primitive-getpeername getpeername)
(define (injected-getpeername client)
  (set! injected-getpeername-calls (+ injected-getpeername-calls 1))
  (if (= injected-getpeername-calls 1)
      (begin
        (format (current-error-port)
                "BOOK_INTERACTION_QEMU_TEST_INJECTION: getpeername:EINTR-once\\n")
        (force-output (current-error-port))
        (throw 'system-error "getpeername" "~A"
               '("Interrupted system call") (list EINTR)))
      (primitive-getpeername client)))
'''
    call_anchor = "(lambda () (list 'peer (getpeername client)))"
    call_replacement = "(lambda () (list 'peer (injected-getpeername client)))"
elif mode == "peer-eintr-repeated":
    injection = '''
(define injected-getpeername-calls 0)
(define (injected-getpeername _client)
  (set! injected-getpeername-calls (+ injected-getpeername-calls 1))
  (when (= injected-getpeername-calls 1)
    (format (current-error-port)
            "BOOK_INTERACTION_QEMU_TEST_INJECTION: getpeername:EINTR-repeated\\n")
    (force-output (current-error-port)))
  (throw 'system-error "getpeername" "~A"
         '("Interrupted system call") (list EINTR)))
'''
    call_anchor = "(lambda () (list 'peer (getpeername client)))"
    call_replacement = "(lambda () (list 'peer (injected-getpeername client)))"
elif mode == "peer-wrong-address":
    injection = '''
(define (injected-getpeername _client)
  (format (current-error-port)
          "BOOK_INTERACTION_QEMU_TEST_INJECTION: getpeername:wrong-address\\n")
  (force-output (current-error-port))
  (vector AF_UNIX "/tmp/opencode/not-the-book-ui-socket"))
'''
    call_anchor = "(lambda () (list 'peer (getpeername client)))"
    call_replacement = "(lambda () (list 'peer (injected-getpeername client)))"
elif mode == "so-error-eintr-repeated":
    injection = '''
(define injected-getsockopt-calls 0)
(define (injected-getsockopt _client _level _option)
  (set! injected-getsockopt-calls (+ injected-getsockopt-calls 1))
  (when (= injected-getsockopt-calls 1)
    (format (current-error-port)
            "BOOK_INTERACTION_QEMU_TEST_INJECTION: SO_ERROR:EINTR-repeated\\n")
    (force-output (current-error-port)))
  (throw 'system-error "getsockopt" "~A"
         '("Interrupted system call") (list EINTR)))
'''
    call_anchor = "(getsockopt client SOL_SOCKET SO_ERROR)"
    call_replacement = "(injected-getsockopt client SOL_SOCKET SO_ERROR)"
else:
    raise SystemExit(f"unknown query fault: {mode}")

source = source.replace(definition_anchor, definition_anchor + injection)
if source.count(call_anchor) != 1:
    raise SystemExit(f"{mode} call anchor count was {source.count(call_anchor)}")
source = source.replace(call_anchor, call_replacement)
if mode in {"peer-eintr-repeated", "so-error-eintr-repeated"}:
    deadline = "(define socket-connect-timeout-seconds 30.0)"
    if source.count(deadline) != 1:
        raise SystemExit("production connect-deadline anchor was not unique")
    source = source.replace(
        deadline, "(define socket-connect-timeout-seconds 0.25)"
    )
path.write_text(source)
PY
}

make_invoker() {
    coordinator_source=$1
    option_socket=$2
    invoker="$run/invoke-coordinator"
    console="$run/console.sock"
    console_log="$run/console.log"
    overlay="$run/disk-overlay.qcow2"
    overlay_file="{\"driver\":\"file\",\"filename\":\"$overlay\",\"node-name\":\"rootfs-overlay-file\",\"read-only\":false}"
    overlay_format='{"driver":"qcow2","file":"rootfs-overlay-file","node-name":"rootfs-overlay","read-only":false}'
    # Every interpolated pathname was made by mktemp under /tmp/opencode and is
    # rejected here if it could change the generated shell quoting.
    case "$run$option_socket$bundle$fake_qemu$coordinator_source$guile" in
        *"'"*|*\\*|*' '*|*','*) fail "test path cannot be represented canonically" ;;
    esac
    cat >"$invoker" <<EOF
#!/bin/sh
exec '$guile' --no-auto-compile -L '$tool_dir' '$coordinator_source' \
  --run-root '$run' \
  --socket '$option_socket' \
  --koreader-package '$bundle' \
  --qemu '$fake_qemu' \
  -- \
  -no-user-config \
  -nodefaults \
  -M virt \
  -accel tcg,thread=multi \
  -cpu max \
  -smp 4 \
  -m 2048 \
  -display none \
  -no-reboot \
  -nic none \
  -monitor none \
  -chardev 'socket,id=console0,path=$console,server=on,wait=off,logfile=$console_log,logappend=off' \
  -serial chardev:console0 \
  -chardev 'socket,id=bookui0,path=$run/book-ui.sock,server=on,wait=off' \
  -device virtio-serial-pci,id=book-ui-serial \
  -device virtserialport,id=book-ui-port,chardev=bookui0,name=org.wilkbook.book-interaction \
  -kernel '$run/boot/Image' \
  -initrd '$run/boot/initrd.cpio.gz' \
  -append 'console=ttyAMA0 panic=1' \
  -blockdev '$overlay_file' \
  -blockdev '$overlay_format' \
  -device virtio-blk-pci,drive=rootfs-overlay
EOF
    chmod 700 "$invoker"
}

assert_records_dead() {
    for record in "$run/reader-ui/qemu.pid" "$run/reader-ui/reader.pid"; do
        if owned_process_record_matches "$record"; then
            owned_process_terminate_record "$record" || true
            fail "recorded child survived coordinator cleanup: $record"
        fi
    done
}

await_records_dead() {
    attempt=0
    while [ "$attempt" -lt 300 ]; do
        if ! owned_process_record_matches "$run/reader-ui/qemu.pid" \
                && ! owned_process_record_matches "$run/reader-ui/reader.pid"; then
            return 0
        fi
        sleep 0.01
        attempt=$((attempt + 1))
    done
    return 1
}

run_bounded() {
    set +e
    timeout --foreground --signal=TERM --kill-after=7s 30s \
        "$invoker" >"$coordinator_log" 2>&1
    bounded_status=$?
    set -e
}

run_short_connect_bounded() {
    connect_started_ns=$("$python" -c 'import time; print(time.monotonic_ns())')
    set +e
    timeout --foreground --signal=TERM --kill-after=7s 4s \
        "$invoker" >"$coordinator_log" 2>&1
    bounded_status=$?
    set -e
    connect_finished_ns=$("$python" -c 'import time; print(time.monotonic_ns())')
    connect_elapsed_ns=$((connect_finished_ns - connect_started_ns))
}

require_short_connect_bound() {
    timing_label=$1
    "$python" - "$timing_label" "$connect_elapsed_ns" <<'PY'
import sys

label = sys.argv[1]
elapsed = int(sys.argv[2]) / 1_000_000_000
if not 0.15 <= elapsed < 2.0:
    raise SystemExit(
        f"short internal connect deadline completed outside its bound: {elapsed:.6f}s"
    )
print(f"{label}: {elapsed:.6f}")
PY
}

require_failure() {
    label=$1
    [ "$bounded_status" -ne 0 ] || fail "$label unexpectedly passed"
    case "$bounded_status" in
        124|137) fail "$label exceeded its host-only deadline" ;;
    esac
    ! grep -Fq \
        'BOOK_INTERACTION_QEMU_COORDINATOR: children=zero; reader-lifecycle=pass' \
        "$coordinator_log" || fail "$label emitted coordinator success"
    assert_records_dead
}

verify_semantic_paints() {
    "$python" - "$run/reader-ui/reader.log" <<'PY'
from pathlib import Path
import sys

log = Path(sys.argv[1]).read_text()
guile_inputs = [
    "Ada|nonce=g-aB3dE5fG7hJ9kL2m",
    "élan λ|nonce=g-N4pQ6rS8tV0xY2zA",
]
python_inputs = [
    "Grace|nonce=p-bC4eF6gH8jK0mN2q",
    "東京|nonce=p-R5tU7wX9yZ1aB3dE",
]
expected = [f"GUILE[{len(value)}]:{value.upper()}" for value in guile_inputs]
expected += [f"PYTHON[{len(value)}]:{value[::-1]}" for value in python_inputs]
if len(expected) != 4 or len(set(expected)) != 4:
    raise SystemExit("reviewer oracle did not produce four distinct results")
for value in expected:
    paint = f"BOOK_INTERACTION_UI_AUDIT: paintTo-topmost-exact:{value}"
    presented = f"BOOK_INTERACTION_READER: present-painted-exact:{value}"
    if log.splitlines().count(paint) != 1 or log.splitlines().count(presented) != 1:
        raise SystemExit(f"missing exact independent paint oracle: {value}")
PY
}

require_successful_paints() {
    success_label=$1
    [ "$bounded_status" -eq 0 ] || {
        cat "$coordinator_log" >&2
        [ ! -f "$run/reader-ui/qemu.stderr" ] \
            || cat "$run/reader-ui/qemu.stderr" >&2
        [ ! -f "$run/reader-ui/reader.log" ] \
            || cat "$run/reader-ui/reader.log" >&2
        fail "$success_label exited $bounded_status"
    }
    assert_records_dead
    require_count 1 \
        'BOOK_INTERACTION_QEMU_COORDINATOR: children=zero; reader-lifecycle=pass' \
        "$coordinator_log"
    require_count 1 \
        'BOOK_INTERACTION_QEMU_SPAWN: qemu:exec-fd-hygiene:stdio-only' \
        "$run/reader-ui/qemu.stdout"
    verify_semantic_paints
}

run_protocol_rejection() {
    mode=$1
    expected_failure=$2
    prepare_run "reject-$mode"
    make_fake_qemu "$mode"
    make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
    run_bounded
    require_failure "$mode control mutation"
    [ -f "$run/reader-ui/reader.log" ] \
        || fail "$mode did not reach actual KOReader"
    grep -Fq 'BOOK_INTERACTION_READER: FAIL:' "$run/reader-ui/reader.log" \
        && grep -Fq "$expected_failure" "$run/reader-ui/reader.log" \
        || fail "$mode lacked its exact native-reader rejection"
    echo "PASS: QEMU-mode $mode control mutation was rejected by real KOReader"
}

copy_mutated_tool() {
    mutation=$1
    mutated_tool="$test_root/mutated-$mutation"
    mkdir -m 700 "$mutated_tool" "$mutated_tool/fixture"
    cp -- "$tool_dir/qemu-coordinator.scm" "$mutated_tool/"
    cp -R -- "$fixture" "$mutated_tool/fixture/"
    mutated_main="$mutated_tool/fixture/bookinteractionprobe.koplugin/main.lua"
    "$python" - "$mutation" "$mutated_main" <<'PY'
from pathlib import Path
import sys

mutation, filename = sys.argv[1:]
path = Path(filename)
source = path.read_text()
replacements = {
    "action-removal": (
        "    if self.action_factory then\n",
        "    if false and self.action_factory then -- omitted by mutation\n",
    ),
    "hardcoded-paint": (
        "        self.dialog:setInputText(value, true)\n",
        '        self.dialog:setInputText("Book result: ADA", true)\n',
    ),
}
old, new = replacements[mutation]
if source.count(old) != 1:
    raise SystemExit(f"{mutation} anchor count was {source.count(old)}")
path.write_text(source.replace(old, new))
PY
}

process_pgrp() (
    pid=$1
    owned_process_details "$pid" || exit 1
    # /proc suffix fields begin with state, ppid, pgrp.
    set -- $owned_rest
    printf '%s\n' "$3"
)

await_live_children() {
    attempt=0
    while [ "$attempt" -lt 1000 ]; do
        if owned_process_record_alive "$run/reader-ui/qemu.pid" \
                && owned_process_record_alive "$run/reader-ui/reader.pid"; then
            read -r qemu_pid qemu_start <"$run/reader-ui/qemu.pid"
            read -r reader_pid reader_start <"$run/reader-ui/reader.pid"
            return 0
        fi
        owned_process_alive "$active_coordinator" "$active_coordinator_start" \
            || return 1
        sleep 0.01
        attempt=$((attempt + 1))
    done
    return 1
}

assert_group_and_reader_capability() {
    coordinator_pgrp=$(process_pgrp "$active_coordinator") \
        || fail "could not inspect coordinator process group"
    qemu_pgrp=$(process_pgrp "$qemu_pid") \
        || fail "could not inspect fake-QEMU process group"
    reader_pgrp=$(process_pgrp "$reader_pid") \
        || fail "could not inspect KOReader process group"
    [ "$coordinator_pgrp" = "$active_coordinator" ] \
        && [ "$qemu_pgrp" = "$coordinator_pgrp" ] \
        && [ "$reader_pgrp" = "$coordinator_pgrp" ] \
        || fail "coordinator and children did not share the dedicated outer group"
    active_group=$coordinator_pgrp

    reader_cmdline="$run/reader.cmdline"
    reader_environment="$run/reader.environment"
    tr '\000' '\n' <"/proc/$reader_pid/cmdline" >"$reader_cmdline"
    tr '\000' '\n' <"/proc/$reader_pid/environ" >"$reader_environment"
    ! grep -Fq "$socket" "$reader_cmdline" \
        && ! grep -Fq "$socket" "$reader_environment" \
        || fail "KOReader received the private socket pathname"
    ! grep -Eq 'BOOK_INTERACTION_(EXPECTED_RESULT|UPDATE_INPUT)=' \
        "$reader_environment" \
        || fail "KOReader received a host input/result oracle"
    [ "$(readlink "/proc/$reader_pid/fd/3")" != "$socket" ] \
        || fail "KOReader FD 3 was a pathname rather than a connected socket"
    for descriptor in "/proc/$active_coordinator/fd/"*; do
        target=$(readlink "$descriptor" 2>/dev/null || true)
        case "$target" in
            socket:*) fail "coordinator retained a socket after FD donation" ;;
        esac
    done
}

echo "bundle: $bundle"
echo "mode: trusted-native-QEMU-seam-host-test (fake QEMU; no VM/ARM/runsc)"

# Exact regression for the independent review's Linux AF_UNIX failure.  The
# fake listener owns a backlog-zero socket and one queued filler connection; it
# independently proves EAGAIN + writable + SO_ERROR=0 + ENOTCONN, then never
# accepts.  Only this copied coordinator gets a short deadline: production must
# remain fixed at 30 seconds and must not start KOReader or leak either socket
# descriptors or the exact fake-QEMU child when the whole connection times out.
require_count 1 '(define socket-connect-timeout-seconds 30.0)' \
    "$tool_dir/qemu-coordinator.scm"
copy_short_connect_deadline_tool
prepare_run full-backlog-timeout
make_fake_qemu full-backlog
make_invoker "$mutated_tool/qemu-coordinator.scm" "$socket"
run_short_connect_bounded
require_failure "full AF_UNIX backlog connection timeout"
grep -Fq \
    'private QEMU socket connection did not complete before its deadline' \
    "$coordinator_log" \
    || fail "full-backlog connect did not reach the internal total deadline"
grep -Fq \
    'FAKE-QEMU-GUEST: full-backlog:EAGAIN;writable;SO_ERROR=0;peer=ENOTCONN' \
    "$run/reader-ui/qemu.stdout" \
    || fail "fake listener did not establish the exact Linux backlog condition"
[ ! -e "$run/reader-ui/reader.pid" ] \
    || fail "KOReader started without a positively verified peer connection"
[ -S "$socket" ] \
    || fail "coordinator unexpectedly removed its caller-owned socket pathname"
! grep -Fq "$socket" /proc/net/unix \
    || fail "full-backlog test left an open Unix socket descriptor"
require_short_connect_bound connect-timeout-elapsed-seconds
echo "PASS: full AF_UNIX backlog timed out without false donation or FD/child leaks"

# The same real backlog must also recover on the same coordinator client after
# the fake listener drains its filler.  This reaches all four real KOReader
# paints, rather than proving only the timeout side of Linux EAGAIN semantics.
prepare_run full-backlog-drain
make_fake_qemu full-backlog-drain
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
run_bounded
require_successful_paints "draining AF_UNIX backlog positive"
require_count 1 \
    'FAKE-QEMU-GUEST: full-backlog:EAGAIN;writable;SO_ERROR=0;peer=ENOTCONN' \
    "$run/reader-ui/qemu.stdout"
require_count 1 'FAKE-QEMU-GUEST: full-backlog:drained' \
    "$run/reader-ui/qemu.stdout"
[ ! -e "$socket" ] \
    || fail "draining-backlog positive retained its normally closed pathname"
! grep -Fq "$socket" /proc/net/unix \
    || fail "draining-backlog positive left an open Unix socket descriptor"
echo "PASS: a drained AF_UNIX backlog connected the same client and painted four results"

# Fault-inject only copied coordinator sources.  One getpeername EINTR must
# retry the raw lookup and pass the resulting address through the validator
# exactly once; no boolean result may be mistaken for an address vector.
copy_query_fault_tool peer-eintr-once
prepare_run getpeername-eintr-once
make_fake_qemu positive
make_invoker "$mutated_tool/qemu-coordinator.scm" "$socket"
run_bounded
require_successful_paints "single getpeername EINTR recovery"
require_count 1 \
    'BOOK_INTERACTION_QEMU_TEST_INJECTION: getpeername:EINTR-once' \
    "$coordinator_log"
echo "PASS: one getpeername EINTR retried the raw lookup and validated its pathname"

# Repeated EINTR cannot stay in an auxiliary syscall-only recursion.  The
# copied 0.25-second deadline must stop raw peer lookup, close the undonated
# connection, avoid KOReader launch, and reap the exact fake-QEMU child.
copy_query_fault_tool peer-eintr-repeated
prepare_run getpeername-eintr-repeated
make_fake_qemu positive
make_invoker "$mutated_tool/qemu-coordinator.scm" "$socket"
run_short_connect_bounded
require_failure "repeated getpeername EINTR"
require_count 1 \
    'BOOK_INTERACTION_QEMU_TEST_INJECTION: getpeername:EINTR-repeated' \
    "$coordinator_log"
grep -Fq \
    'private QEMU socket connection did not complete before its deadline' \
    "$coordinator_log" \
    || fail "repeated getpeername EINTR escaped the original total deadline"
[ ! -e "$run/reader-ui/reader.pid" ] \
    || fail "repeated getpeername EINTR started KOReader"
! grep -Fq "$socket" /proc/net/unix \
    || fail "repeated getpeername EINTR left an open Unix socket descriptor"
require_short_connect_bound getpeername-eintr-timeout-elapsed-seconds
echo "PASS: repeated getpeername EINTR remained finite with no FD or child leak"

# The SO_ERROR query shares the same bounded EINTR turn.  Exercise it while
# the real backlog remains full so this helper cannot acquire a private retry
# loop that bypasses the publication-and-connect deadline.
copy_query_fault_tool so-error-eintr-repeated
prepare_run so-error-eintr-repeated
make_fake_qemu full-backlog
make_invoker "$mutated_tool/qemu-coordinator.scm" "$socket"
run_short_connect_bounded
require_failure "repeated SO_ERROR EINTR"
require_count 1 \
    'BOOK_INTERACTION_QEMU_TEST_INJECTION: SO_ERROR:EINTR-repeated' \
    "$coordinator_log"
grep -Fq \
    'private QEMU socket connection did not complete before its deadline' \
    "$coordinator_log" \
    || fail "repeated SO_ERROR EINTR escaped the original total deadline"
[ ! -e "$run/reader-ui/reader.pid" ] \
    || fail "repeated SO_ERROR EINTR started KOReader"
! grep -Fq "$socket" /proc/net/unix \
    || fail "repeated SO_ERROR EINTR left an open Unix socket descriptor"
require_short_connect_bound so-error-eintr-timeout-elapsed-seconds
echo "PASS: repeated SO_ERROR EINTR remained finite with no FD or child leak"

# A syntactically valid AF_UNIX peer vector for any other pathname is still a
# hard setup failure and must never be donated to KOReader.
copy_query_fault_tool peer-wrong-address
prepare_run getpeername-wrong-address
make_fake_qemu positive
make_invoker "$mutated_tool/qemu-coordinator.scm" "$socket"
run_bounded
require_failure "wrong getpeername address"
require_count 1 \
    'BOOK_INTERACTION_QEMU_TEST_INJECTION: getpeername:wrong-address' \
    "$coordinator_log"
grep -Fq 'connected private QEMU peer has the wrong pathname' \
    "$coordinator_log" \
    || fail "wrong getpeername pathname did not reach exact-address rejection"
[ ! -e "$run/reader-ui/reader.pid" ] \
    || fail "wrong getpeername pathname started KOReader"
! grep -Fq "$socket" /proc/net/unix \
    || fail "wrong getpeername pathname left an open Unix socket descriptor"
echo "PASS: a wrong AF_UNIX peer pathname was rejected without donation"

if [ "${BOOK_INTERACTION_QEMU_CONNECT_RECHECK_ONLY:-0}" = 1 ]; then
    finish_success \
        "PASS: focused native coordinator connection recheck (no QEMU/ARM/runsc)"
fi

# Positive: four distinct nonce-bearing values cross the mock QEMU socket and
# are painted by one real packaged InputDialog.  Python is only an independent
# reviewer oracle for the Guile mock's computed values.
prepare_run positive
make_fake_qemu positive
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
run_bounded
[ "$bounded_status" -eq 0 ] || {
    cat "$coordinator_log" >&2
    [ ! -f "$run/reader-ui/qemu.stderr" ] \
        || cat "$run/reader-ui/qemu.stderr" >&2
    [ ! -f "$run/reader-ui/reader.log" ] \
        || cat "$run/reader-ui/reader.log" >&2
    fail "positive host-only QEMU seam exited $bounded_status"
}
assert_records_dead
require_count 1 \
    'BOOK_INTERACTION_QEMU_COORDINATOR: children=zero; reader-lifecycle=pass' \
    "$coordinator_log"
require_count 1 'BOOK_INTERACTION_QEMU_SPAWN: qemu:exec-fd-hygiene:stdio-only' \
    "$run/reader-ui/qemu.stdout"
verify_semantic_paints
echo "PASS: four independently checked nonce results reached real topmost paintTo"

run_protocol_rejection wrong-generation 'private control generation mismatch'
run_protocol_rejection wrong-routing 'presentation arrived outside update wait'
run_protocol_rejection malformed-frame 'private control command kind is invalid'
run_protocol_rejection early-eof 'private control host closed unexpectedly'

# A constant semantic relay can satisfy the deliberately language-agnostic
# lifecycle coordinator, but cannot satisfy the joined independent paint oracle.
prepare_run hardcoded-authority
make_fake_qemu hardcoded-present
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
run_bounded
[ "$bounded_status" -eq 0 ] \
    || fail "hardcoded authority did not reach the lifecycle-only boundary"
if verify_semantic_paints >"$run/hardcoded-oracle.log" 2>&1; then
    fail "hardcoded authority satisfied the independent semantic paint oracle"
fi
assert_records_dead
echo "PASS: lifecycle-only coordinator cannot confer joined semantic acceptance"

# A hardcoded Lua display cannot acknowledge the guest value because the
# retained inherited paintTo observer remains armed for that exact value.
copy_mutated_tool hardcoded-paint
prepare_run hardcoded-paint
make_fake_qemu positive
make_invoker "$mutated_tool/qemu-coordinator.scm" "$socket"
run_bounded
require_failure "hardcoded Lua paint mutation"
grep -Fq \
    'BOOK_INTERACTION_READER: FAIL:presentation text was not retained through repaint' \
    "$run/reader-ui/reader.log" \
    || fail "hardcoded Lua paint did not fail its retained real-widget check"
echo "PASS: hardcoded Lua paint cannot forge an applied acknowledgement"

# Public action removal is now part of the retained pre-quit audit.
copy_mutated_tool action-removal
prepare_run action-removal
make_fake_qemu positive
make_invoker "$mutated_tool/qemu-coordinator.scm" "$socket"
run_bounded
require_failure "selection action removal omission"
grep -Fq \
    'BOOK_INTERACTION_READER: FAIL:cleanup audit: selection action remains registered before quit' \
    "$run/reader-ui/reader.log" \
    || fail "action-removal omission escaped the retained registry audit"
echo "PASS: omitted public action removal failed before UIManager quit"

# Guest/QEMU zero is independently required even after valid native teardown.
prepare_run qemu-nonzero
make_fake_qemu positive-qemu-nonzero
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
run_bounded
require_failure "nonzero QEMU after native success"
grep -Fq 'QEMU child failed: (exit . 19)' "$coordinator_log" \
    || fail "nonzero fake QEMU was not attributed exactly"
echo "PASS: native lifecycle success cannot mask nonzero QEMU status"

# QEMU failure before listener publication must never start KOReader.
prepare_run qemu-early-exit
make_fake_qemu exit-before-socket
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
run_bounded
require_failure "QEMU exit before socket"
[ ! -e "$run/reader-ui/reader.pid" ] \
    || fail "KOReader was started after QEMU exited before its socket"
echo "PASS: QEMU early exit prevented KOReader launch"

# Collision, path escape, graph drift, and sockaddr_un overflow are rejected
# before fake QEMU can publish an identity record.
prepare_run socket-collision
make_fake_qemu positive
: >"$socket"
chmod 600 "$socket"
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
run_bounded
require_failure "pre-existing socket pathname"
[ ! -e "$run/reader-ui/qemu.pid" ] \
    || fail "socket collision started fake QEMU"
echo "PASS: pre-existing private socket pathname was rejected"

prepare_run socket-outside-root
make_fake_qemu positive
outside_socket="$test_root/outside.sock"
make_invoker "$tool_dir/qemu-coordinator.scm" "$outside_socket"
run_bounded
require_failure "socket pathname outside run root"
[ ! -e "$run/reader-ui/qemu.pid" ] \
    || fail "outside socket path started fake QEMU"
echo "PASS: socket pathname outside the owned run root was rejected"

long_component=abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefgh
run="$test_root/$long_component"
mkdir -m 700 "$run"
mkdir -m 700 "$run/home" "$run/tmp" "$run/xdg-cache" \
    "$run/xdg-config" "$run/xdg-runtime" "$run/boot"
: >"$run/boot/Image"
: >"$run/boot/initrd.cpio.gz"
: >"$run/disk-overlay.qcow2"
socket="$run/book-ui.sock"
coordinator_log="$run/coordinator.log"
make_fake_qemu positive
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
run_bounded
require_failure "overlong sockaddr_un path"
grep -Fq 'private QEMU socket exceeds sockaddr_un.sun_path' "$coordinator_log" \
    || fail "overlong Unix pathname received the wrong rejection"
echo "PASS: sockaddr_un length was checked before fake QEMU"

prepare_run graph-mutation
make_fake_qemu positive
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
sed -i 's/-nic none/-nic user/' "$invoker"
run_bounded
require_failure "QEMU graph mutation"
[ ! -e "$run/reader-ui/qemu.pid" ] \
    || fail "mutated QEMU graph started fake QEMU"
echo "PASS: QEMU graph drift was rejected before exec"

# Signal-driven cleanup: a fake QEMU that ignores TERM and a real KOReader are
# direct children in one pre-existing dedicated group.  The coordinator must
# still reap both exact identities, escalating only the resistant QEMU.
prepare_run coordinator-signal
make_fake_qemu hold-resistant
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
"$setsid_command" "$invoker" >"$coordinator_log" 2>&1 &
active_coordinator=$!
active_coordinator_start=$(owned_process_start_time "$active_coordinator")
await_live_children || fail "signal test did not publish two live children"
assert_group_and_reader_capability
kill -TERM "$active_coordinator"
set +e
wait "$active_coordinator"
signal_status=$?
set -e
active_coordinator=
active_coordinator_start=
active_group=
[ "$signal_status" -ne 0 ] \
    || fail "signalled coordinator unexpectedly passed"
assert_records_dead
echo "PASS: coordinator signal reaped real KOReader and TERM-resistant fake QEMU"

# Uncatchable owner loss is deliberately an outer-guardian responsibility.
# This host model confirms all owned nodes share the one dedicated group, then
# performs the outer group's bounded TERM/KILL action and verifies identities.
prepare_run outer-owner-kill
make_fake_qemu hold-resistant
make_invoker "$tool_dir/qemu-coordinator.scm" "$socket"
"$setsid_command" "$invoker" >"$coordinator_log" 2>&1 &
active_coordinator=$!
active_coordinator_start=$(owned_process_start_time "$active_coordinator")
await_live_children || fail "owner-kill test did not publish two live children"
assert_group_and_reader_capability
kill -KILL "$active_coordinator"
sleep 0.1
kill -TERM "-$active_group" 2>/dev/null || true
sleep 0.5
kill -KILL "-$active_group" 2>/dev/null || true
set +e
wait "$active_coordinator" 2>/dev/null
set -e
active_coordinator=
active_coordinator_start=
active_group=
await_records_dead \
    || fail "modeled outer cleanup did not reach final child reap"
assert_records_dead
echo "PASS: modeled outer owner-loss group cleanup left no recorded child"

finish_success "PASS: native QEMU-mode reader seam host gate (no QEMU/ARM/runsc)"
