#!/bin/sh
# Lexical convenience lint only. This catches common accidental writer APIs in
# the trusted fixture; it is not a Lua parser, sandbox, or write-confinement
# boundary and intentionally makes no completeness claim.
set -eu

fixture=$1
found=
for spelling in \
    'io.open' 'io.output' 'io["open"]' "io['open']" \
    'io["output"]' "io['output']" \
    'os.execute' 'os.remove' 'os.rename' \
    'os["execute"]' "os['execute']" \
    'os["remove"]' "os['remove']" \
    'os["rename"]' "os['rename']" \
    'writeToFile'
do
    matches=$(grep -Fn "$spelling" "$fixture"/*.lua || true)
    if [ -n "$matches" ]; then
        printf '%s\n' "$matches" >&2
        found=yes
    fi
done
[ -z "$found" ] || {
    echo "FAIL: trusted fixture contains a commonly-spelled writer API" >&2
    exit 1
}
