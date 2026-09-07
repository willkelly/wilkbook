#!/bin/sh
# Dispatch one check using only an already prepared read-only source capsule.
set -eu

[ "$#" -eq 3 ] || {
    echo "usage: run-prepared.sh PREPARED_ROOT RUN_ROOT TASK" >&2
    exit 2
}
prepared=$1
run_root=$2
task=$3
ulimit -f 32768
case "$prepared:$run_root" in /*:/*) ;; *) exit 2 ;; esac
[ "$(CDPATH= cd -- "$prepared" && pwd -P)" = "$prepared" ]
[ "$(CDPATH= cd -- "$run_root" && pwd -P)" = "$run_root" ]
runners="$prepared/repo/pinenote/tools/book-source-check/runners"
private_helper="$prepared/repo/pinenote/tools/book-source-check/private-environment.sh"
. "$private_helper"
book_source_resolve_guix_launcher
book_source_create_private_environment \
    "$run_root/dispatcher-private-environment"
command_roster="$run_root/COMMAND-TABLE.tsv"
cp "$prepared/repo/pinenote/tools/book-source-check/COMMAND-TABLE.tsv" \
    "$command_roster"
chmod 400 "$command_roster"
echo "SOURCE_CHECK_COMMAND_ROSTER=$command_roster"
echo "SOURCE_CHECK_PRIVATE_HOME=$HOME"
echo "SOURCE_CHECK_PRIVATE_XDG_CACHE=$XDG_CACHE_HOME"

run_task () {
    name=$1
    shift
    directory="$run_root/$name"
    mkdir -m 700 "$directory"
    log="$run_root/$name.log"
    started=$(date +%s)
    echo "CHECK_START=$name" | tee -a "$run_root/command-table.log"
    if "$@" >"$log" 2>&1; then
        elapsed=$(($(date +%s) - started))
        cat "$log"
        echo "CHECK_ELAPSED_SECONDS=$name:$elapsed" \
            | tee -a "$run_root/command-table.log"
        echo "CHECK_RESULT=$name:PASS" | tee -a "$run_root/command-table.log"
    else
        status=$?
        elapsed=$(($(date +%s) - started))
        cat "$log" >&2
        echo "CHECK_ELAPSED_SECONDS=$name:$elapsed" \
            | tee -a "$run_root/command-table.log" >&2
        echo "CHECK_RESULT=$name:FAIL:$status" \
            | tee -a "$run_root/command-table.log" >&2
        exit "$status"
    fi
}

run_bounded () {
    name=$1
    seconds=$2
    shift 2
    run_task "$name" timeout --signal=TERM --kill-after=5s "$seconds" "$@"
}

case "$task" in
    protocol|session|backend|state-protocol)
        run_bounded "$task" 300s sh "$runners/core-source-units.sh" \
            "$prepared/repo" "$run_root/$task" "$task"
        ;;
    adapter)
        run_bounded adapter 300s sh "$runners/backend-adapter-v2.sh" \
            "$prepared" "$run_root/adapter"
        ;;
    state-protocol-suite)
        run_bounded state-protocol 300s sh "$runners/core-source-units.sh" \
            "$prepared/repo" "$run_root/state-protocol" state-protocol
        run_bounded adapter 300s sh "$runners/backend-adapter-v2.sh" \
            "$prepared" "$run_root/adapter"
        ;;
    observer)
        run_bounded observer 420s sh "$runners/completion-observer.sh" \
            "$prepared" "$run_root/observer"
        ;;
    native-v2)
        run_bounded native-v2 420s sh "$runners/native-v2.sh" \
            "$prepared" "$run_root/native-v2"
        ;;
    reader-join-v2)
        run_bounded koreader-prepare 900s sh "$runners/resolve-koreader.sh" \
            "$prepared/repo" "$run_root/koreader-prepare" \
            "$prepared/package-view"
        koreader=$(cat "$run_root/koreader-prepare/koreader-prepare/koreader-output.txt")
        run_bounded reader-join-v2 175s sh "$runners/reader-join-v2.sh" "$prepared" \
            "$run_root/reader-join-v2" "$koreader"
        ;;
    all)
        run_bounded source-units 300s sh "$runners/core-source-units.sh" \
            "$prepared/repo" "$run_root/source-units" all
        run_bounded adapter 300s sh "$runners/backend-adapter-v2.sh" \
            "$prepared" "$run_root/adapter"
        run_bounded observer 420s sh "$runners/completion-observer.sh" \
            "$prepared" "$run_root/observer"
        run_bounded native-v2 420s sh "$runners/native-v2.sh" \
            "$prepared" "$run_root/native-v2"
        run_bounded koreader-prepare 900s sh "$runners/resolve-koreader.sh" \
            "$prepared/repo" "$run_root/koreader-prepare" \
            "$prepared/package-view"
        koreader=$(cat "$run_root/koreader-prepare/koreader-prepare/koreader-output.txt")
        run_bounded reader-join-v2 175s sh "$runners/reader-join-v2.sh" "$prepared" \
            "$run_root/reader-join-v2" "$koreader"
        ;;
    *)
        echo "unknown source-check task: $task" >&2
        exit 2
        ;;
esac

echo "SOURCE_CHECK_RESULT=$task:PASS"
