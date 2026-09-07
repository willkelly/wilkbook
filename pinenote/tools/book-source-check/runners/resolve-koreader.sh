#!/bin/sh
# Resolve and, if necessary, realize canonical native koreader-bin through Guix.
set -eu

[ "$#" -eq 3 ] || {
    echo "usage: resolve-koreader.sh PRIVATE_REPO RUN_ROOT PACKAGE_VIEW" >&2
    exit 2
}
repo=$1
run_root=$2
package_view=$3
case "$repo:$run_root:$package_view" in /*:/*:/*) ;; *) exit 2 ;; esac
mkdir -m 700 "$run_root/koreader-prepare"
prepare="$run_root/koreader-prepare"
channels="$repo/channels.scm"
private_helper="$repo/pinenote/tools/book-source-check/private-environment.sh"
. "$private_helper"
private_environment="$run_root/private-environment"
book_source_create_private_environment "$private_environment"

clean_env='env -u GUIX_PACKAGE_PATH -u GUIX_BUILD_OPTIONS -u GUIX_ENVIRONMENT'
$clean_env "$BOOK_SOURCE_GUIX" time-machine -C "$channels" -- build --derivations \
    --no-grafts --max-jobs=1 --cores=2 -L "$package_view" \
    -e '(@ (pinenote packages koreader) koreader-bin)' \
    >"$prepare/resolved-derivation.txt" 2>"$prepare/resolve.log"
[ "$(wc -l <"$prepare/resolved-derivation.txt")" -eq 1 ]
drv=$(cat "$prepare/resolved-derivation.txt")
case "$drv" in
    /gnu/store/*-koreader-bin-*.drv) ;;
    *) echo "canonical KOReader resolver returned an unexpected derivation" >&2; exit 1 ;;
esac

set +e
$clean_env "$BOOK_SOURCE_GUIX" time-machine -C "$channels" -- build --dry-run \
    --no-grafts --max-jobs=1 --cores=2 -L "$package_view" \
    -e '(@ (pinenote packages koreader) koreader-bin)' \
    >"$prepare/dry-run.log" 2>&1
dry_rc=$?
set -e
cat "$prepare/dry-run.log"
[ "$dry_rc" -eq 0 ] || exit "$dry_rc"
if grep -Ei 'linux-pinenote|gvisor|qemu|pinenote-.*-system|disk-image' \
        "$prepare/dry-run.log" >/dev/null; then
    echo "KOReader preparation unexpectedly reached a large runtime graph" >&2
    exit 1
fi
drv_count=$(grep -Ec '/gnu/store/[a-z0-9]+-.*\.drv' \
    "$prepare/dry-run.log" || true)
[ "$drv_count" -le 25 ] || {
    echo "KOReader preparation would build more than 25 derivations; stopped" >&2
    exit 1
}

$clean_env "$BOOK_SOURCE_GUIX" time-machine -C "$channels" -- build \
    --no-grafts --max-jobs=1 --cores=2 -L "$package_view" \
    -e '(@ (pinenote packages koreader) koreader-bin)' \
    >"$prepare/build-output.txt" 2>"$prepare/build.log"
actual=$(tail -n 1 "$prepare/build-output.txt")
case "$actual" in /gnu/store/*-koreader-bin-*) ;; *) exit 1 ;; esac
[ -f "$drv" ] && [ -x "$actual/lib/koreader/luajit" ] \
    && [ -f "$actual/lib/koreader/reader.lua" ]
[ "$(cat "$actual/lib/koreader/git-rev")" = v2026.03 ]
$clean_env "$BOOK_SOURCE_GUIX" time-machine -C "$channels" -- gc --derivers "$actual" \
    >"$prepare/derivers.txt"
grep -Fx "$drv" "$prepare/derivers.txt" >/dev/null
printf '%s\n' "$drv" >"$prepare/koreader-derivation.txt"
printf '%s\n' "$actual" >"$prepare/koreader-output.txt"
printf '%s\n' \
    "KOREADER_DERIVATION=$drv" \
    "KOREADER_OUTPUT=$actual" \
    "KOREADER_LABEL=fixed-upstream-binary-package" \
    "PASS: realized output is linked to the channels-pinned derivation"
