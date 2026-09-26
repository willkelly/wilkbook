#!/bin/sh
set -eu
system=${1:?usage: check-system-closure.sh /gnu/store/...-system}
case "$system" in /gnu/store/*-system) ;; *) echo "FAIL: not a system store path" >&2; exit 1;; esac
[ -d "$system" ] || { echo "FAIL: system path is not realized" >&2; exit 1; }

tmp=$(mktemp "${TMPDIR:-/tmp/opencode}/book-state-device-closure.XXXXXX")
chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
guix gc --references -R "$system" > "$tmp"

exactly_one() {
    value=$1
    [ "$(grep -Fxc "$value" "$tmp")" -eq 1 ] || {
        echo "FAIL: closure does not contain exactly $value" >&2
        exit 1
    }
}
exactly_one /gnu/store/334ljs8qa7ww8vlg9gpv428bh8yjd1nx-linux-pinenote-book-execution-test-7.1.8-pinenote
exactly_one /gnu/store/djgy782a5fjmsfkr6hzff3g953r60c86-gvisor-source-built-20260831.0

if grep -Eq 'gvisor-local-test-artifacts|book-state-guest-authority|integration-host|qemu' "$tmp"; then
    echo "FAIL: historical/local/QEMU runtime entered the device closure" >&2
    exit 1
fi

closure=$(grep 'wilkbook-book-state-device-language-closure$' "$tmp")
[ "$(printf '%s\n' "$closure" | grep -c .)" -eq 1 ] || {
    echo "FAIL: device language closure is not unique" >&2
    exit 1
}
count=$(guile -c '(display (length (call-with-input-file (cadr (command-line)) read)))' "$closure")
[ "$count" -eq 46 ] || { echo "FAIL: device language closure has $count paths" >&2; exit 1; }

koreader=$(grep 'koreader-bin-book-state-device-[^/]*$' "$tmp")
[ "$(printf '%s\n' "$koreader" | grep -c .)" -eq 1 ] || {
    echo "FAIL: experimental KOReader package is not unique" >&2
    exit 1
}
plugin=$koreader/lib/koreader/plugins/bookstatedevice.koplugin
for file in _meta.lua activation.lua main.lua state_channel.lua unix_client.lua; do
    [ -f "$plugin/$file" ] || { echo "FAIL: installed plugin lacks $file" >&2; exit 1; }
done

# The notebook (doc/notebook.md) rides the koreader-device overlay into
# every KOReader bundle: the experimental one above and the plain one the
# platform services' LuaJIT comes from.  Both must carry the tree's exact
# plugin and device.lua; a build from a different checkout fails here.
repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
overlay=$repo_root/pinenote/packages/koreader-device
plain=$(grep -E '^/gnu/store/[a-z0-9]{32}-koreader-bin-2026\.03$' "$tmp")
[ "$(printf '%s\n' "$plain" | grep -c .)" -eq 1 ] || {
    echo "FAIL: plain KOReader package is not unique" >&2
    exit 1
}
for bundle in "$koreader" "$plain"; do
    installed=$bundle/lib/koreader/plugins/notebook.koplugin
    for src in "$overlay"/plugins/notebook.koplugin/*.lua; do
        cmp -s "$src" "$installed/$(basename "$src")" || {
            echo "FAIL: $bundle notebook plugin differs from the tree: $(basename "$src")" >&2
            exit 1
        }
    done
    [ "$(ls "$installed" | wc -l)" -eq "$(ls "$overlay"/plugins/notebook.koplugin | wc -l)" ] || {
        echo "FAIL: $bundle notebook plugin has files the tree does not" >&2
        exit 1
    }
    cmp -s "$overlay/frontend/device/pinenote/device.lua" \
        "$bundle/lib/koreader/frontend/device/pinenote/device.lua" || {
        echo "FAIL: $bundle device.lua differs from the tree" >&2
        exit 1
    }
done

grep -Fqx 'default-reader=unchanged' "$system/etc/wilkbook-book-state-device"
grep -Fqx 'book-session-fd=3' "$system/etc/wilkbook-book-state-device"
grep -Fqx 'platform=systrap' "$system/etc/wilkbook-book-state-device"
grep -Fqx 'directfs=false' "$system/etc/wilkbook-book-state-device"
grep -Fqx 'network=none' "$system/etc/wilkbook-book-state-device"
grep -Fqx 'host-uds=none' "$system/etc/wilkbook-book-state-device"
grep -Fqx 'fixed-runners=guile,python' "$system/etc/wilkbook-book-state-device"
grep -Fqx 'menu-runner=guile' "$system/etc/wilkbook-book-state-device"

echo "PASS: realized experimental system closure is pinned, canonical, and device-only"
