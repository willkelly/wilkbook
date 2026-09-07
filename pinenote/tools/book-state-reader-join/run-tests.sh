#!/bin/sh
# Finite host-only owner for the v2 KOReader/Book State reader join packet.
set -eu

# Own the complete invocation, including source authentication and Guix setup.
# The public command takes no arguments; the private re-entry token cannot be
# inherited accidentally through the environment.
case "$#" in
    0) exec timeout --signal=TERM --kill-after=5s 175s \
           "$0" __book_state_reader_join_deadline_owner ;;
    1) [ "$1" = __book_state_reader_join_deadline_owner ] || {
           echo "usage: run-tests.sh" >&2
           exit 2
       } ;;
    *) echo "usage: run-tests.sh" >&2; exit 2 ;;
esac

started_at=$(date +%s)
# POSIX ulimit -f counts 512-byte blocks.  Bound every generated file, including
# the outer log, to 4 MiB; the stricter per-process log bound is 128 KiB.
ulimit -f 8192

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(CDPATH= cd -- "$tool_dir/../../.." && pwd -P)
snapshot="$tool_dir/build/artifacts/book-state-reader-join-sources-20260906-v2"
native_source="$repo/pinenote/tools/book-state-integration/build/artifacts/book-state-native-integration-sources-20260906-v2"
observer_source="$repo/pinenote/tools/book-state-integration/completion-observer/build/artifacts/book-state-completion-observer-sources-20260906-v1"
ui_source="$repo/pinenote/tools/book-state-reader"

mkdir -p "$tool_dir/build/runs"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
base="$tool_dir/build/runs/$stamp-$$"
run_root=$base
suffix=0
while ! mkdir -m 700 "$run_root" 2>/dev/null; do
    suffix=$((suffix + 1))
    run_root="$base-$suffix"
done
host_log="$run_root/host.log"
closure="$run_root/source-closure"
helper_loaded=0

cleanup () {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$helper_loaded" -eq 1 ]; then
        if [ -d "$run_root" ]; then
            records="$run_root/.cleanup-process-records"
            find "$run_root" -type f -name '*.pid' -print >"$records"
            while IFS= read -r record; do
                owned_process_terminate_record "$record" || rc=125
            done <"$records"
        fi
    fi
    echo "artifacts: $run_root"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

set +e
(
    set -eu
    require_hash () {
        expected=$1
        path=$2
        actual=$(sha256sum "$path")
        actual=${actual%% *}
        [ "$actual" = "$expected" ] || {
            echo "frozen input changed: $path ($actual)" >&2
            exit 1
        }
    }

    # Authenticate the one project verifier before any copied project source is
    # evaluated, compiled, imported, or executed.
    require_hash \
        6fcbb5b7b8766f5cbc8802ad84c4b28d500c5941b0f2dc6f871d4ec8976c82e0 \
        "$snapshot/MANIFEST.sha256"
    require_hash \
        a40b9bee10fd78055a27e68e2f4acf091e5d4250d1ce697a967001d0cdbc9282 \
        "$snapshot/SOURCE-IDENTITIES.sha256"
    require_hash \
        f08f5ef425eb775d1ed18f972b204f5504ee98369b5ed27c7c96820cfb4c548d \
        "$snapshot/PACKET-ROSTER.txt"
    require_hash \
        dc38084a43a83cd0109803a31a1f746cfb43a1f9ae4f3cb645b3ec01410772b5 \
        "$snapshot/verify-source-closure.sh"
    (cd "$snapshot" && sha256sum --check --strict MANIFEST.sha256)

    mkdir -m 700 "$closure"
    cp -a "$snapshot" "$closure/join"
    cp -a "$native_source" "$closure/native-v2"
    cp -a "$observer_source" "$closure/observer-v1"
    cp -a "$ui_source" "$closure/ui"
    find "$closure" -type d -exec chmod 500 {} +
    find "$closure" -type f -exec chmod 400 {} +

    # This is the only project source run before entering the pinned shell; its
    # exact identity was checked above.  It authenticates the complete private
    # closure and every accepted prerequisite.
    TMPDIR="$run_root" sh "$closure/join/verify-source-closure.sh" "$closure"

) >"$host_log" 2>&1
setup_rc=$?
set -e

if [ "$setup_rc" -ne 0 ]; then
    cat "$host_log"
    echo "FAIL: joined reader source setup exited $setup_rc" >&2
    exit "$setup_rc"
fi

# The outer guardian sources exactly the authenticated read-only private copy.
# Cleanup calls the resulting in-memory functions and never reads any source
# path from the repository or closure again.
private_process_identity="$closure/join/accepted-helper/process-identity.sh"
private_helper_hash=$(sha256sum "$private_process_identity")
private_helper_hash=${private_helper_hash%% *}
[ "$private_helper_hash" = \
  97ef8053cd99fcb1bd8cba552925778590f87cd62cc40dab60ea3087dbdf9354 ]
# shellcheck source=/dev/null
. "$private_process_identity"
helper_loaded=1
echo "JOIN-HELPER-PROVENANCE: outer=$private_process_identity sha256=$private_helper_hash" \
    >>"$host_log"

set +e
(
    env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT \
        -u GUILE_LOAD_PATH -u GUILE_LOAD_COMPILED_PATH \
        -u PYTHONPATH -u PYTHONHOME -u PYTHONSTARTUP -u PYTHONUSERBASE \
        -u BOOK_JOIN_PYTHON_CODEC \
        -u BOOK_JOIN_BOOK_GUILE_LOAD_PATH \
        -u BOOK_JOIN_BOOK_GUILE_COMPILED_PATH \
        guix time-machine \
          -C "$closure/native-v2/accepted-inputs/channels.scm" \
          --no-substitutes -- \
          shell --pure --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
          -m "$closure/join/test-manifest.scm" -- \
          sh "$closure/join/run-tests-inner.sh" "$closure" "$run_root"
) >>"$host_log" 2>&1
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
    cat "$host_log"
    echo "FAIL: joined reader host gate exited $rc" >&2
    exit "$rc"
fi

grep -F "PASS: pinned native KOReader v2026.03 offscreen host gate" "$host_log" \
    >/dev/null || {
        cat "$host_log"
        echo "FAIL: joined reader terminal success marker is absent" >&2
        exit 1
    }
host_bytes=$(wc -c <"$host_log")
[ "$host_bytes" -lt 4194304 ] || {
    echo "FAIL: joined reader host log reached its bound" >&2
    exit 1
}
elapsed=$(( $(date +%s) - started_at ))
[ "$elapsed" -le 180 ] || {
    echo "FAIL: joined reader exceeded total runtime bound" >&2
    exit 1
}
echo "JOIN_RUNTIME_SECONDS: $elapsed" >>"$host_log"
echo "PASS: book-state reader join completed within 180 seconds" >>"$host_log"
cat "$host_log"
