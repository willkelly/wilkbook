#!/bin/sh
# Native source/revision/reader gate; no system build or device access.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$tool/../../.." && pwd)
unset GUILE_LOAD_PATH GUILE_LOAD_COMPILED_PATH GUILE_EXTENSIONS_PATH
unset GUILE_SYSTEM_PATH GUILE_SYSTEM_COMPILED_PATH
export GUILE_AUTO_COMPILE=0
mkdir -p /tmp/opencode
root=$(mktemp -d /tmp/opencode/book-workbench-check.XXXXXX)
chmod 700 "$root"
cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$rc" -ne 0 ] || [ "${KEEP_ARTIFACTS:-0}" = 1 ]; then
        echo "Workbench test artifacts: $root" >&2
    else
        rm -rf -- "$root"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A derivation step before realization, with grafts disabled by the program.
# Override paths are explicit developer inputs, never remembered build output.
supervisor=${BOOK_WORKBENCH_SUPERVISOR:-}
bundle=${KOREADER_NATIVE_BUNDLE:-}
if [ -z "$supervisor" ] || [ -z "$bundle" ]; then
    guix time-machine -C "$repo/channels.scm" -- repl -L "$repo" \
        "$tool/derive-inputs.scm" > "$root/inputs.tsv"
    for label in supervisor koreader; do
        awk -F '\t' -v label="$label" '
            $1 == label && $2 ~ /^\/gnu\/store\/.*\.drv$/ && $3 ~ /^\/gnu\/store\// { n++ }
            END { exit n != 1 }' "$root/inputs.tsv"
    done
    drvs=
    if [ -z "$supervisor" ]; then
        supervisor=$(awk -F '\t' '$1 == "supervisor" { print $3 }' "$root/inputs.tsv")
        drvs=$(awk -F '\t' '$1 == "supervisor" { print $2 }' "$root/inputs.tsv")
    fi
    if [ -z "$bundle" ]; then
        bundle=$(awk -F '\t' '$1 == "koreader" { print $3 }' "$root/inputs.tsv")
        drvs="$drvs $(awk -F '\t' '$1 == "koreader" { print $2 }' "$root/inputs.tsv")"
    fi
    if ! guix build --no-grafts --no-substitutes --max-jobs=1 --cores=2 \
             $drvs > "$root/build.log" 2>&1; then
        cat "$root/build.log" >&2
        exit 1
    fi
fi
[ -x "$supervisor/bin/guile" ] && [ -x "$bundle/lib/koreader/luajit" ]
[ "$(cat "$bundle/lib/koreader/git-rev")" = v2026.03 ]

export GUILE_LOAD_PATH="$tool:$tool/../book-protocol:$tool/../book-session:$tool/../book-execution-spike:$tool/../book-state-guest:$supervisor/share/guile/site/3.0"
export GUILE_LOAD_COMPILED_PATH="$supervisor/lib/guile/3.0/site-ccache"
export BOOK_WORKBENCH_GUILE="$supervisor/bin/guile"
export BOOK_WORKBENCH_TEST_ROOT="$root"
export KOREADER_NATIVE_BUNDLE="$bundle"
export LUAJIT="$bundle/lib/koreader/luajit"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
mkdir -p "$HOME" "$XDG_CACHE_HOME"
cd "$root"

for test in test-workspace.scm test-authority.scm test-preview.scm test-sandbox.scm test-editor-sandbox.scm test-scenario.scm test-resource-scenario.scm test-qemu-adapter.scm; do
    timeout --kill-after=5s 120s "$BOOK_WORKBENCH_GUILE" --no-auto-compile "$tool/$test"
done
timeout --kill-after=5s 120s python3 "$tool/test-editor-owner.py"
timeout --kill-after=5s 120s python3 "$tool/test-integration.py"
timeout --kill-after=5s 120s python3 "$tool/test-adversarial.py"
timeout --kill-after=5s 120s python3 "$tool/test-launcher.py"
timeout --kill-after=5s 30s "$BOOK_WORKBENCH_GUILE" --no-auto-compile \
    "$tool/test-ui-receipts.scm" > "$root/ui-receipts.txt"
timeout --kill-after=5s 30s "$LUAJIT" "$tool/test-plugin.lua" \
    "$tool/plugin/bookworkbench.koplugin" "$root/ui-receipts.txt"
sh "$tool/run-real-ui-test.sh"
echo "PASS: offline Workbench workspace, preview, activation/rollback and KOReader"
echo "Execution evidence: trusted-native fixture; no device or sandbox-runtime claim"
