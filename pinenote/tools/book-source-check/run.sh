#!/bin/sh
# Public owner for candidate export, preparation, and finite source checks.
set -eu

usage () {
    cat >&2 <<'EOF'
usage:
  run.sh export-candidate --source-root ROOT --output EMPTY_DIRECTORY
  run.sh prepare          --source-root ROOT --output EMPTY_DIRECTORY
  run.sh check            --source-root ROOT [--output EMPTY_DIRECTORY]
  run.sh check-task TASK  --source-root ROOT [--output EMPTY_DIRECTORY]

TASK is protocol, session, backend, state-protocol, adapter, observer,
state-protocol-suite, native-v2, reader-join-v2, or all.  ROOT and an explicit
--output must be absolute canonical paths.  check/check-task create a private
unique output beneath /tmp/opencode when --output is omitted.
EOF
    exit 2
}

[ "$#" -ge 1 ] || usage
command=$1
shift
task=
if [ "$command" = check-task ]; then
    [ "$#" -ge 1 ] || usage
    task=$1
    shift
elif [ "$command" = check ]; then
    task=all
elif [ "$command" != prepare ] && [ "$command" != export-candidate ]; then
    usage
fi

source_root=
output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-root)
            [ "$#" -ge 2 ] || usage
            source_root=$2
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || usage
            output=$2
            shift 2
            ;;
        *) usage ;;
    esac
done
[ -n "$source_root" ] || usage
case "$source_root" in /*) ;; *) usage ;; esac
requested_source_root=$source_root
source_root=$(CDPATH= cd -- "$source_root" && pwd -P)
[ "$source_root" = "$requested_source_root" ] || {
    echo "SOURCE_ROOT must be canonical" >&2
    exit 1
}
candidate_tool="$source_root/pinenote/tools/book-source-check"
[ -f "$candidate_tool/prepare.py" ] || {
    echo "candidate source preparer is absent" >&2
    exit 1
}

if [ "$command" = prepare ] || [ "$command" = export-candidate ]; then
    [ -n "$output" ] || usage
    case "$output" in /*) ;; *) usage ;; esac
    exec python3 -I -S "$candidate_tool/prepare.py" "$command" \
        --source-root "$source_root" --output "$output"
fi

if [ -z "$output" ]; then
    mkdir -p /tmp/opencode
    output=$(mktemp -d /tmp/opencode/book-source-check.XXXXXX)
else
    case "$output" in /*) ;; *) usage ;; esac
    if [ -e "$output" ]; then
        [ -d "$output" ] && [ -z "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
            echo "check output must be absent or an empty directory" >&2
            exit 1
        }
    else
        mkdir -m 700 -p "$output"
    fi
fi
requested_output=$output
output=$(CDPATH= cd -- "$output" && pwd -P)
[ "$output" = "$requested_output" ] || {
    echo "check output must be canonical" >&2
    exit 1
}
chmod 700 "$output"
capsule="$output/capsule"
run_root="$output/run"
mkdir -m 700 "$run_root"

printf '%s\n' \
    "SOURCE_CHECK_TASK=$task" \
    "SOURCE_CHECK_CANDIDATE=$source_root" \
    "SOURCE_CHECK_OUTPUT=$output" \
    "SOURCE_CHECK_CAPSULE=$capsule" \
    "SOURCE_CHECK_RUN_ROOT=$run_root"

python3 -I -S "$candidate_tool/prepare.py" prepare \
    --source-root "$source_root" --output "$capsule" \
    >"$run_root/prepare.log" 2>&1
cat "$run_root/prepare.log"
private_helper="$capsule/repo/pinenote/tools/book-source-check/private-environment.sh"
. "$private_helper"
book_source_resolve_guix_launcher
book_source_create_private_environment "$run_root/bootstrap-private-environment"
PYTHONDONTWRITEBYTECODE=1 python3 -I -S \
    "$capsule/repo/pinenote/tools/book-source-check/test_prepare.py" \
    >"$run_root/source-preparer-tests.log" 2>&1
cat "$run_root/source-preparer-tests.log"
mkdir -m 700 "$run_root/private-cache-regression"
timeout --signal=TERM --kill-after=5s 600s \
    sh "$capsule/repo/pinenote/tools/book-source-check/test-private-cache.sh" \
    "$capsule" "$run_root/private-cache-regression" \
    >"$run_root/private-cache-regression.log" 2>&1
cat "$run_root/private-cache-regression.log"

# Re-enter through the authenticated copy.  From this point onward no child is
# given the candidate checkout path.
prepared_runner="$capsule/repo/pinenote/tools/book-source-check/run-prepared.sh"
exec sh "$prepared_runner" "$capsule" "$run_root" "$task"
