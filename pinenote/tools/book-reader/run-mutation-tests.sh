#!/bin/sh
# Adversarial controls for the reader gate. Each case changes behavior, not an
# expected marker, and must make the copied gate fail for the named property.
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$tool_dir/../../.." && pwd)
tmp_base=${BOOK_READER_TMPDIR:-/tmp/opencode}
mkdir -p "$tmp_base"
mutation_root=$(mktemp -d "$tmp_base/book-reader-mutations.XXXXXX")
trap 'rm -rf -- "$mutation_root"' EXIT HUP INT TERM

canonical_output=$(guix repl -L "$repo_root" \
    "$tool_dir/canonical-koreader-output.scm" | sed -n '2p')
bundle=${1:-${KOREADER_BUNDLE:-$canonical_output}}

mutate() {
    case_name=$1
    case_dir="$mutation_root/$case_name"
    cp -R -- "$tool_dir" "$case_dir"
    rm -rf -- "$case_dir/build"
    python3 - "$case_dir" "$case_name" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
case = sys.argv[2]
main = root / "fixture/bookreaderprobe.koplugin/main.lua"
source = root / "fixture/bookreaderprobe.koplugin/interaction_source.lua"

mutations = {
    "reentrant-wait": (
        source,
        '''    if self.in_wait then
        self.reentrant_wait_count = self.reentrant_wait_count + 1
        return nil
    end
''',
        "",
    ),
    "nonintegral-limit": (
        source,
        "            and max_queued == math.floor(max_queued),\n",
        "            ,\n",
    ),
    "retained-queue": (
        source,
        "    self.queue = {}\n",
        "    -- mutation: retain queued payloads\n",
    ),
    "synthetic-document-close": (
        main,
        "    self.ui:onClose(false)\n",
        "    self:onCloseDocument() -- mutation: bypass ReaderUI\n",
    ),
    "retained-highlight-action": (
        main,
        "    local removed = self.ui.highlight:removeFromHighlightDialog(ACTION_KEY)\n",
        "    local removed = expected -- mutation: leave registry entry\n",
    ),
    "private-highlight-add": (
        main,
        '''    self.ui.highlight:addToHighlightDialog(
        ACTION_KEY, self.highlight_button_factory)
''',
        '''    self.ui.highlight._highlight_buttons[ACTION_KEY] =
        self.highlight_button_factory -- mutation: bypass public add
''',
    ),
    "private-highlight-remove": (
        main,
        "    local removed = self.ui.highlight:removeFromHighlightDialog(ACTION_KEY)\n",
        '''    local removed = expected -- mutation: bypass public remove
    self.ui.highlight._highlight_buttons[ACTION_KEY] = nil
''',
    ),
    "private-source-insert": (
        main,
        "    UIManager:insertZMQ(source)\n",
        "    table.insert(UIManager._zeromqs, source) -- mutation: bypass public seam\n",
    ),
    "omitted-source-remove": (
        main,
        "        UIManager:removeZMQ(source)\n",
        "        local ignored_source = source -- mutation: omit public removal\n",
    ),
    "omitted-dialog-close": (
        main,
        '''    if dialog and UIManager:isWidgetShown(dialog) then
        UIManager:close(dialog)
    end
''',
        "    -- mutation: leave the interaction dialog in UIManager's stack\n",
    ),
    "off-by-one-queue": (
        source,
        "    if #self.queue >= self.max_queued then return false, \"queue-full\" end\n",
        "    if #self.queue > self.max_queued then return false, \"queue-full\" end\n",
    ),
    "omitted-generation-check": (
        main,
        "    if message.generation ~= self.generation then\n",
        "    if false then -- mutation: accept stale generation\n",
    ),
    "spoofed-version-line": (
        main,
        "    marker(\"plugin-init\")\n",
        "    marker(\"plugin-init\")\n    print(\" [*] Version: v2026.03\")\n",
    ),
    "bracket-writer-spelling": (
        main,
        "local FakeBroker = {}\n",
        "local unused_writer = io[\"open\"] -- mutation: lexical lint control\nlocal FakeBroker = {}\n",
    ),
}

path, old, new = mutations[case]
text = path.read_text()
if text.count(old) != 1:
    raise SystemExit(f"mutation anchor count for {case}: {text.count(old)}")
path.write_text(text.replace(old, new))
PY
}

run_red() {
    case_name=$1
    diagnostic=$2
    mutate "$case_name"
    log="$mutation_root/$case_name.log"
    set +e
    BOOK_READER_REPO_ROOT="$repo_root" \
    BOOK_READER_TMPDIR="$mutation_root" \
    KOREADER_BUNDLE="$bundle" \
        "$mutation_root/$case_name/run-tests.sh" >"$log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        cat "$log" >&2
        echo "FAIL: mutation survived: $case_name" >&2
        exit 1
    fi
    if ! grep -Fq "$diagnostic" "$log"; then
        cat "$log" >&2
        echo "FAIL: mutation failed for the wrong reason: $case_name" >&2
        exit 1
    fi
    echo "PASS: mutation killed: $case_name"
}

run_red reentrant-wait \
    'one outer waitEvent performed more than one callback'
run_red nonintegral-limit 'invalid max_queued accepted: 1.5'
run_red retained-queue 'callback error did not empty queued work'
run_red synthetic-document-close 'ReaderUI close did not clear its document'
run_red retained-highlight-action \
    'selection action remained in ReaderHighlight registry'
run_red private-highlight-add \
    'selection action did not use public ReaderHighlight add seam'
run_red private-highlight-remove \
    'selection action did not use public ReaderHighlight removal seam'
run_red private-source-insert \
    'source did not use public UIManager insertion seam'
run_red omitted-source-remove 'source remained registered after close'
run_red omitted-dialog-close \
    'interaction dialog remained in UIManager stack after normal close'
run_red off-by-one-queue 'source queue bound was not enforced'
run_red omitted-generation-check 'fixture broker received unexpected content'
run_red spoofed-version-line \
    'expected exactly one official KOReader version line'
run_red bracket-writer-spelling \
    'trusted fixture contains a commonly-spelled writer API'

# Reproduce the review's package-pin spoof: change the evaluated package pin
# and teach the writable fixture to print that new line. The runner must reject
# the bundle's immutable git-rev before the fixture is copied or executed.
pin_case="$mutation_root/pin-mismatch-spoof"
cp -R -- "$tool_dir" "$pin_case"
mkdir -p "$pin_case/repo/pinenote/packages"
cp -- "$repo_root/pinenote/packages/koreader.scm" \
    "$pin_case/repo/pinenote/packages/koreader.scm"
cp -R -- "$repo_root/pinenote/packages/koreader-device" \
    "$pin_case/repo/pinenote/packages/koreader-device"
python3 - "$pin_case" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
package = root / "repo/pinenote/packages/koreader.scm"
text = package.read_text()
old = '    (version %koreader-version)'
assert text.count(old) == 1
package.write_text(text.replace(old, '    (version "2099.99")'))

main = root / "fixture/bookreaderprobe.koplugin/main.lua"
text = main.read_text()
old = '    marker("plugin-init")\n'
assert text.count(old) == 1
main.write_text(text.replace(
    old, old + '    print(" [*] Version: v2099.99")\n'))
PY
pin_log="$mutation_root/pin-mismatch-spoof.log"
set +e
BOOK_READER_REPO_ROOT="$pin_case/repo" \
BOOK_READER_TMPDIR="$mutation_root" \
KOREADER_BUNDLE="$bundle" \
    "$pin_case/run-tests.sh" >"$pin_log" 2>&1
pin_rc=$?
set -e
if [ "$pin_rc" -eq 0 ] \
        || ! grep -Fq 'bundle revision v2026.03 does not match v2099.99' \
            "$pin_log" \
        || grep -Fq 'BOOK_READER_PROBE: plugin-init' "$pin_log"; then
    cat "$pin_log" >&2
    echo "FAIL: package-pin spoof was not rejected before fixture execution" >&2
    exit 1
fi
echo "PASS: mutation killed before fixture: pin-mismatch-spoof"

echo "RESULT: all reader adversarial mutations were killed"
