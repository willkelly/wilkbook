#!/bin/sh
# Prepare and check only the current public Book-execution source/system seam.
# This versioned launcher is the small host bootstrap trust boundary.  It admits
# only immutable store Python/Guix/Guile tools resolved before PATH is replaced,
# verifies prepare.py against the reviewed finite map before first execution,
# and executes every later helper from the authenticated private capsule.
set -eu
umask 077

usage () {
    echo "usage: $0 --source-root ABSOLUTE_CANONICAL_ROOT [--output ABSOLUTE_EMPTY_DIRECTORY]" >&2
    exit 2
}

source_root=
output=
while [ "$#" -gt 0 ]; do
    case $1 in
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
case $source_root in /*) ;; *) usage ;; esac
requested_source_root=$source_root
source_root=$(CDPATH= cd -- "$source_root" && pwd -P)
[ "$source_root" = "$requested_source_root" ] || {
    echo "FAIL: source root must be canonical" >&2
    exit 1
}
tool=$source_root/pinenote/tools/book-execution-spike/public-source
[ -f "$tool/prepare.py" ] && [ ! -L "$tool/prepare.py" ] || {
    echo "FAIL: public source preparer is absent or linked" >&2
    exit 1
}
[ -f "$tool/SOURCE-MAP.tsv" ] && [ ! -L "$tool/SOURCE-MAP.tsv" ] || {
    echo "FAIL: public source map is absent or linked" >&2
    exit 1
}

# Resolve the finite bootstrap tools without running them.  Caller PATH may
# choose a profile link, but its canonical target must be an immutable Guix
# store object of the expected kind.  No CLI option can replace these tools.
python_link=$(command -v python3) || { echo "FAIL: python3 not found" >&2; exit 1; }
guix_link=$(command -v guix) || { echo "FAIL: guix not found" >&2; exit 1; }
guile_link=$(command -v guile) || { echo "FAIL: guile not found" >&2; exit 1; }
guild_link=$(command -v guild) || { echo "FAIL: guild not found" >&2; exit 1; }
python=$(/usr/bin/readlink -f -- "$python_link")
bootstrap_guix=$(/usr/bin/readlink -f -- "$guix_link")
bootstrap_guile=$(/usr/bin/readlink -f -- "$guile_link")
bootstrap_guild=$(/usr/bin/readlink -f -- "$guild_link")
case $python in /gnu/store/*-python-*/bin/python*) ;; *) echo "FAIL: python3 is not an immutable store interpreter" >&2; exit 1 ;; esac
case $bootstrap_guix in /gnu/store/*-guix-command) ;; *) echo "FAIL: guix is not an immutable store command" >&2; exit 1 ;; esac
case $bootstrap_guile in /gnu/store/*-guile-*/bin/guile) ;; *) echo "FAIL: guile is not an immutable store interpreter" >&2; exit 1 ;; esac
case $bootstrap_guild in /gnu/store/*-guile-*/bin/guild) ;; *) echo "FAIL: guild is not an immutable store compiler" >&2; exit 1 ;; esac
for program in "$python" "$bootstrap_guix" "$bootstrap_guile" "$bootstrap_guild"; do
    [ -f "$program" ] && [ ! -L "$program" ] && [ -x "$program" ] || {
        echo "FAIL: bootstrap tool is not a regular executable: $program" >&2
        exit 1
    }
done
PATH=/usr/bin:/bin
export PATH

if [ -z "$output" ]; then
    mkdir -p /tmp/opencode
    output=$(mktemp -d /tmp/opencode/book-execution-public-source.XXXXXX)
else
    case $output in /*) ;; *) usage ;; esac
    if [ -e "$output" ]; then
        [ -d "$output" ] && [ ! -L "$output" ] && \
            [ -z "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
            echo "FAIL: output must be absent or an empty real directory" >&2
            exit 1
        }
    else
        mkdir -m 700 -p "$output"
    fi
fi
requested_output=$output
output=$(CDPATH= cd -- "$output" && pwd -P)
[ "$output" = "$requested_output" ] || {
    echo "FAIL: output must be canonical" >&2
    exit 1
}
chmod 700 "$output"

capsule=$output/capsule
run_root=$output/run
private_root=$run_root/private-process
mkdir -m 700 "$run_root" "$private_root"
for directory in home cache config data state tmp empty-path; do
    mkdir -m 700 "$private_root/$directory"
done

# Authenticate the only mutable-worktree helper that must run before the
# capsule exists.  SOURCE-MAP.tsv itself is part of the versioned launcher
# boundary and is independently frozen by the review packet.
tab=$(printf '\t')
prepare_expected=
prepare_rows=0
while IFS="$tab" read -r relative expected role; do
    if [ "$relative" = "pinenote/tools/book-execution-spike/public-source/prepare.py" ]; then
        prepare_expected=$expected
        prepare_rows=$((prepare_rows + 1))
    fi
done <"$tool/SOURCE-MAP.tsv"
[ "$prepare_rows" -eq 1 ] && [ -n "$prepare_expected" ] || {
    echo "FAIL: finite map does not select exactly one preparer" >&2
    exit 1
}
prepare_record=$(/usr/bin/sha256sum -- "$tool/prepare.py")
prepare_actual=${prepare_record%% *}
[ "$prepare_actual" = "$prepare_expected" ] || {
    echo "FAIL: preparer does not match the finite source map" >&2
    exit 1
}

"$python" -I -S -B "$tool/prepare.py" \
    --source-root "$source_root" --output "$capsule" \
    >"$run_root/prepare.log" 2>&1
cat "$run_root/prepare.log"

repo=$capsule/repo
module_view=$capsule/module-view
package_view=$capsule/package-view
prepared_map=$capsule/metadata/SOURCE-MAP.tsv
prepared_tool=$repo/pinenote/tools/book-execution-spike/public-source
isolated_launcher=$prepared_tool/guix-isolated.sh

file_sha256 () {
    record=$(/usr/bin/sha256sum -- "$1")
    printf '%s' "${record%% *}"
}

verify_prepared_helper () {
    relative=$1
    expected=
    rows=0
    while IFS="$tab" read -r mapped digest role; do
        if [ "$mapped" = "$relative" ]; then
            expected=$digest
            rows=$((rows + 1))
        fi
    done <"$prepared_map"
    [ "$rows" -eq 1 ] && [ -n "$expected" ] || {
        echo "FAIL: prepared helper has no unique map row: $relative" >&2
        exit 1
    }
    helper=$repo/$relative
    [ -f "$helper" ] && [ ! -L "$helper" ] || {
        echo "FAIL: prepared helper is not regular: $relative" >&2
        exit 1
    }
    actual=$(file_sha256 "$helper")
    [ "$actual" = "$expected" ] || {
        echo "FAIL: prepared helper hash mismatch: $relative" >&2
        exit 1
    }
    printf '%s  %s\n' "$actual" "$relative"
}

{
    verify_prepared_helper pinenote/tools/book-execution-spike/public-source/run.sh
    verify_prepared_helper pinenote/tools/book-execution-spike/public-source/prepare.py
    verify_prepared_helper pinenote/tools/book-execution-spike/public-source/guix-isolated.sh
    verify_prepared_helper pinenote/tools/book-execution-spike/public-source/check.py
    verify_prepared_helper pinenote/tools/book-execution-spike/public-source/check-systems.scm
    verify_prepared_helper pinenote/tools/book-execution-spike/public-source/test_prepare.py
    verify_prepared_helper pinenote/tools/book-execution-spike/public-source/test_cache_isolation.py
} >"$run_root/helper-authentication.sha256"
cat "$run_root/helper-authentication.sha256"

clean_python () {
    /usr/bin/env -i \
        HOME="$private_root/home" \
        XDG_CACHE_HOME="$private_root/cache" \
        XDG_CONFIG_HOME="$private_root/config" \
        XDG_DATA_HOME="$private_root/data" \
        XDG_STATE_HOME="$private_root/state" \
        TMPDIR="$private_root/tmp" \
        PATH="$private_root/empty-path" \
        LANG=C LC_ALL=C \
        GUILE_AUTO_COMPILE=0 \
        GUILE_LOAD_PATH= GUILE_LOAD_COMPILED_PATH= GUILE_EXTENSIONS_PATH= \
        "$python" -I -S -B "$@"
}

run_bootstrap_program () {
    /usr/bin/env -i \
        HOME="$private_root/home" \
        XDG_CACHE_HOME="$private_root/cache" \
        XDG_CONFIG_HOME="$private_root/config" \
        XDG_DATA_HOME="$private_root/data" \
        XDG_STATE_HOME="$private_root/state" \
        TMPDIR="$private_root/tmp" \
        PATH="$private_root/empty-path" \
        LANG=C LC_ALL=C \
        GUILE_AUTO_COMPILE=0 \
        GUILE_LOAD_PATH= GUILE_LOAD_COMPILED_PATH= GUILE_EXTENSIONS_PATH= \
        "$@"
}

clean_python "$prepared_tool/test_prepare.py" \
    --source-root "$repo" --source-map "$prepared_map" \
    >"$run_root/preparer-tests.log" 2>&1
cat "$run_root/preparer-tests.log"

clean_python "$prepared_tool/check.py" static "$repo" \
    >"$run_root/static-source.log" 2>&1
cat "$run_root/static-source.log"

{
    printf 'schema=1\n'
    printf 'trust-boundary=versioned-runner-plus-finite-source-map\n'
    printf 'python-link=%s\npython-resolved=%s\npython-sha256=%s\n' \
        "$python_link" "$python" "$(file_sha256 "$python")"
    printf 'guix-link=%s\nguix-resolved=%s\nguix-sha256=%s\n' \
        "$guix_link" "$bootstrap_guix" "$(file_sha256 "$bootstrap_guix")"
    printf 'guile-link=%s\nguile-resolved=%s\nguile-sha256=%s\n' \
        "$guile_link" "$bootstrap_guile" "$(file_sha256 "$bootstrap_guile")"
    printf 'guild-link=%s\nguild-resolved=%s\nguild-sha256=%s\n' \
        "$guild_link" "$bootstrap_guild" "$(file_sha256 "$bootstrap_guild")"
    printf 'bootstrap-role=immutable-launcher-only-all-queries-run-inside-pinned-time-machine\n'
} >"$run_root/bootstrap-tools.txt"
run_bootstrap_program "$bootstrap_guix" --version \
    >"$run_root/bootstrap-guix-version.txt" 2>&1
run_bootstrap_program "$bootstrap_guile" --version \
    >"$run_root/bootstrap-guile-version.txt" 2>&1
run_bootstrap_program "$bootstrap_guild" --version \
    >"$run_root/bootstrap-guild-version.txt" 2>&1

# Compile bounded reviewer-style cache poisons in private synthetic homes, then
# prove that default HOME cache, XDG cache, and compiled-load-path markers stay
# absent while real pinned Guix and nested Guile commands complete.
cache_test=$run_root/cache-isolation
clean_python "$prepared_tool/test_cache_isolation.py" \
    --bootstrap-guix "$bootstrap_guix" \
    --bootstrap-guile "$bootstrap_guile" \
    --bootstrap-guild "$bootstrap_guild" \
    --launcher "$isolated_launcher" \
    --private-root "$private_root" \
    --module-view "$module_view" \
    --channels "$repo/channels.scm" \
    --output "$cache_test" \
    >"$run_root/cache-isolation.log" 2>&1
cat "$run_root/cache-isolation.log"

default_poison_home=$cache_test/default-home
xdg_poison_home=$cache_test/xdg-home
xdg_poison_cache=$cache_test/xdg-cache
compiled_poison_path=$cache_test/compiled-path
default_marker=$cache_test/default-cache-marker
xdg_marker=$cache_test/xdg-cache-marker
compiled_marker=$cache_test/compiled-path-marker

require_poison_absent () {
    for marker in "$default_marker" "$xdg_marker" "$compiled_marker"; do
        [ ! -e "$marker" ] && [ ! -L "$marker" ] || {
            echo "FAIL: caller poison marker executed: $marker" >&2
            exit 1
        }
    done
}

# Every ordinary gate call presents poisoned caller XDG and compiled paths to
# the prepared launcher.  The launcher's second env -i must replace them with
# the private process directories before the immutable bootstrap starts.
run_guix_view () {
    selected_view=$1
    shift
    /usr/bin/env -i \
        HOME="$xdg_poison_home" \
        XDG_CACHE_HOME="$xdg_poison_cache" \
        GUILE_LOAD_PATH=/caller/poison/load-path \
        GUILE_LOAD_COMPILED_PATH="$compiled_poison_path" \
        GUILE_EXTENSIONS_PATH=/caller/poison/extensions \
        GUILE_AUTO_COMPILE=fresh \
        GUIX_PACKAGE_PATH=/caller/poison/packages \
        GUIX_BUILD_OPTIONS=--max-jobs=999 \
        GUIX_ENVIRONMENT=/caller/poison/environment \
        "$isolated_launcher" "$private_root" "$selected_view" \
        "$repo/channels.scm" "$bootstrap_guix" "$@"
}

run_guix_default_cache_view () {
    selected_view=$1
    shift
    /usr/bin/env -i \
        HOME="$default_poison_home" \
        GUILE_LOAD_PATH=/caller/poison/load-path \
        GUILE_EXTENSIONS_PATH=/caller/poison/extensions \
        GUILE_AUTO_COMPILE=fresh \
        GUIX_PACKAGE_PATH=/caller/poison/packages \
        GUIX_BUILD_OPTIONS=--max-jobs=999 \
        GUIX_ENVIRONMENT=/caller/poison/environment \
        "$isolated_launcher" "$private_root" "$selected_view" \
        "$repo/channels.scm" "$bootstrap_guix" "$@"
}

run_guix_view "$module_view" --version \
    >"$run_root/pinned-guix-version.txt" 2>"$run_root/pinned-guix-version.stderr"
require_poison_absent
pinned_guix_version_line=$(sed -n '1p' "$run_root/pinned-guix-version.txt")
case $pinned_guix_version_line in
    'guix (GNU Guix) '*) ;;
    *) echo "FAIL: pinned Guix version record is malformed" >&2; exit 1 ;;
esac

# Resolve only the fixed git origin through the reusable inventory package.
# --source cannot execute the gVisor runtime build or any ARM program.
run_guix_view "$module_view" build --source --no-grafts --cores=2 --max-jobs=1 \
    -L "$package_view" \
    -e '(@ (pinenote packages gvisor-source) gvisor-source-inventory)' \
    >"$run_root/gvisor-source-paths.txt" 2>"$run_root/gvisor-source-prepare.log"
require_poison_absent
cat "$run_root/gvisor-source-prepare.log"
source_count=$(sed '/^[[:space:]]*$/d' "$run_root/gvisor-source-paths.txt" | wc -l)
[ "$source_count" -eq 1 ] || {
    echo "FAIL: Guix source preparation returned $source_count paths" >&2
    exit 1
}
gvisor_source=$(cat "$run_root/gvisor-source-paths.txt")
case $gvisor_source in /gnu/store/*) ;; *) echo "FAIL: source is outside Guix store" >&2; exit 1 ;; esac
[ -d "$gvisor_source" ] || { echo "FAIL: Guix source output is not realized" >&2; exit 1; }
clean_python "$prepared_tool/check.py" gvisor-source "$repo" "$gvisor_source" \
    "$run_root/gvisor-source-inventory.json" >"$run_root/gvisor-source-check.log" 2>&1
cat "$run_root/gvisor-source-check.log"

# The only executed source unit is a host Guile/Python fake-store OCI test.  It
# starts no runsc, QEMU, target executable, kernel, image, or system build.
run_guix_view "$module_view" shell guile@3.0.9 guile-json@4.7.3 python@3.12.12 -- \
    /usr/bin/env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT \
    HOME="$private_root/home" XDG_CACHE_HOME="$private_root/cache" \
    XDG_CONFIG_HOME="$private_root/config" XDG_DATA_HOME="$private_root/data" \
    XDG_STATE_HOME="$private_root/state" GUILE_AUTO_COMPILE=0 \
    GUILE_LOAD_COMPILED_PATH= GUILE_EXTENSIONS_PATH= \
    python3 -I -S -B \
    "$repo/pinenote/tools/book-execution-spike/test_oci_book_bundle.py" \
    >"$run_root/fake-oci-unit.log" 2>&1
require_poison_absent
cat "$run_root/fake-oci-unit.log"

run_guix_view "$module_view" repl -L "$package_view" -q \
    "$prepared_tool/check-systems.scm" >"$run_root/system-objects.log" 2>&1
require_poison_absent
cat "$run_root/system-objects.log"

# A missing reusable source module must stop module loading.  In particular it
# must not silently fall back to the still-valid official gvisor-bin package.
missing_view=$run_root/module-view-missing-gvisor-source
clean_python "$prepared_tool/check.py" make-missing-view "$module_view" "$missing_view" \
    >"$run_root/missing-view-prepare.log" 2>&1
if printf '%s\n' \
    '(use-modules (pinenote systems pinenote-book-execution-source-control))' \
    '(display "UNEXPECTED-FALLBACK")' | \
    run_guix_view "$missing_view" repl -L "$package_view" -q /dev/stdin \
        >"$run_root/missing-gvisor-source.stdout" \
        2>"$run_root/missing-gvisor-source.stderr"
then
    echo "FAIL: missing gvisor-source module fell back instead of failing" >&2
    exit 1
fi
require_poison_absent
grep -Fq 'pinenote packages gvisor-source' "$run_root/missing-gvisor-source.stderr" || {
    cat "$run_root/missing-gvisor-source.stderr" >&2
    echo "FAIL: missing-module rejection did not identify gvisor-source" >&2
    exit 1
}
echo "PASS: missing gvisor-source module fails closed without official-binary fallback"

systems='source-control diagnostic protocol-control reader-interaction'
for name in $systems; do
    case $name in
        source-control)
            module=pinenote-book-execution-source-control
            binding=pinenote-book-execution-source-control-operating-system
            expected_runtime=/gnu/store/il8gj1gxb3ssqx9iwwyjm7mmz85izzla-gvisor-source-built-20260831.0.drv
            ;;
        diagnostic)
            module=pinenote-book-execution-diagnostic
            binding=pinenote-book-execution-diagnostic-operating-system
            expected_runtime=/gnu/store/pb5v7rqa5iqwc98qzjpbnk474qgqbvmm-gvisor-source-built-diagnostic-20260831.0.drv
            ;;
        protocol-control)
            module=pinenote-book-execution-protocol-control
            binding=pinenote-book-execution-protocol-control-operating-system
            expected_runtime=/gnu/store/il8gj1gxb3ssqx9iwwyjm7mmz85izzla-gvisor-source-built-20260831.0.drv
            ;;
        reader-interaction)
            module=pinenote-book-execution-reader-interaction
            binding=pinenote-book-execution-reader-interaction-operating-system
            expected_runtime=/gnu/store/il8gj1gxb3ssqx9iwwyjm7mmz85izzla-gvisor-source-built-20260831.0.drv
            ;;
    esac
    expression="(@ (pinenote systems $module) $binding)"
    run_guix_view "$module_view" system build -d --no-grafts \
        --cores=2 --max-jobs=1 --target=aarch64-linux-gnu \
        -L "$package_view" -e "$expression" \
        >"$run_root/$name-derivation.txt" 2>"$run_root/$name-lower.log"
    require_poison_absent
    cat "$run_root/$name-lower.log"
    derivation_count=$(sed '/^[[:space:]]*$/d' "$run_root/$name-derivation.txt" | wc -l)
    [ "$derivation_count" -eq 1 ] || {
        echo "FAIL: $name lowering returned $derivation_count paths" >&2
        exit 1
    }
    derivation=$(cat "$run_root/$name-derivation.txt")
    case $derivation in /gnu/store/*.drv) ;; *) echo "FAIL: invalid system derivation: $derivation" >&2; exit 1 ;; esac
    [ -f "$derivation" ] || { echo "FAIL: missing system derivation: $derivation" >&2; exit 1; }

    # Query each real graph once with the caller's exact default HOME cache
    # poison active and once with XDG plus compiled-path poisons active.  Both
    # calls cross the same prepared env-i/time-machine boundary as lowering.
    run_guix_default_cache_view "$module_view" gc --requisites "$derivation" \
        >"$run_root/$name-requisites-default-cache.txt" \
        2>"$run_root/$name-gc-default-cache.stderr"
    require_poison_absent
    run_guix_view "$module_view" gc --requisites "$derivation" \
        >"$run_root/$name-requisites.txt" 2>"$run_root/$name-gc.stderr"
    require_poison_absent
    cmp "$run_root/$name-requisites-default-cache.txt" \
        "$run_root/$name-requisites.txt"
    echo "PASS: $name real graph is identical under default-HOME and XDG/compiled-path poison"

    clean_python "$prepared_tool/check.py" graph "$name" "$derivation" \
        "$run_root/$name-requisites.txt" >"$run_root/$name-graph.log" 2>&1
    cat "$run_root/$name-graph.log"

    graph_sha256=$(file_sha256 "$run_root/$name-requisites.txt")
    default_graph_sha256=$(file_sha256 "$run_root/$name-requisites-default-cache.txt")
    graph_log_sha256=$(file_sha256 "$run_root/$name-graph.log")
    {
        printf 'schema=1\n'
        printf 'system=%s\n' "$name"
        printf 'root-system-derivation=%s\n' "$derivation"
        printf 'root-system-derivation-sha256=%s\n' "$(file_sha256 "$derivation")"
        printf 'query-boundary=prepared-guix-isolated-env-i-plus-pinned-time-machine\n'
        printf 'query-bootstrap-guix=%s\n' "$bootstrap_guix"
        printf 'query-bootstrap-guix-sha256=%s\n' "$(file_sha256 "$bootstrap_guix")"
        printf 'query-pinned-guix-version=%s\n' "$pinned_guix_version_line"
        printf 'query-pinned-guix-version-record-sha256=%s\n' "$(file_sha256 "$run_root/pinned-guix-version.txt")"
        printf 'query-command-argv=gc,--requisites,%s\n' "$derivation"
        printf 'query-environment-primary=synthetic-caller-XDG-cache-plus-compiled-path-poison\n'
        printf 'query-environment-replay=synthetic-caller-default-HOME-cache-poison\n'
        printf 'raw-graph=%s-requisites.txt\n' "$name"
        printf 'raw-graph-sha256=%s\n' "$graph_sha256"
        printf 'raw-graph-lines=%s\n' "$(wc -l <"$run_root/$name-requisites.txt")"
        printf 'replay-raw-graph=%s-requisites-default-cache.txt\n' "$name"
        printf 'replay-raw-graph-sha256=%s\n' "$default_graph_sha256"
        printf 'raw-graphs-identical=yes\n'
        printf 'expected-runtime-derivation=%s\n' "$expected_runtime"
        printf 'checker=%s\n' "$prepared_tool/check.py"
        printf 'checker-sha256=%s\n' "$(file_sha256 "$prepared_tool/check.py")"
        printf 'checker-result=pass\n'
        printf 'checker-log=%s-graph.log\n' "$name"
        printf 'checker-log-sha256=%s\n' "$graph_log_sha256"
        printf 'caller-poison-markers=absent-before-query-after-each-query-and-after-check\n'
    } >"$run_root/$name-graph-attestation.txt"
    echo "SYSTEM_DERIVATION=$name:$derivation"
done

require_poison_absent
echo "PUBLIC_SOURCE_CHECK_OUTPUT=$output"
echo "PUBLIC_GVISOR_SOURCE=$gvisor_source"
echo "PASS: current public Book-execution source systems lower and real graphs attest without building runtime, kernel, system, or image"
