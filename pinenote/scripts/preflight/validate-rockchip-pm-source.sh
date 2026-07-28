#!/bin/sh
set -eu

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -ne 3 ]; then
  printf 'usage: %s CHECKER CANONICAL_PATCH APPLIED_SOURCE_TREE\n' "$0" >&2
  exit 2
fi

checker=$1
patch=$2
source_tree=$3

command -v python3 >/dev/null 2>&1 || fail "python3 is required for Rockchip PM validation"
command -v git >/dev/null 2>&1 || fail "git is required for Rockchip PM validation"
[ -f "$checker" ] || fail "missing authoritative Rockchip PM source validator: $checker"
[ -f "$patch" ] || fail "missing canonical Rockchip PM compatibility patch: $patch"
[ -d "$source_tree" ] || fail "applied kernel source path is not a directory: $source_tree"

python3 "$checker" "$patch" || fail "canonical Rockchip PM patch validation failed"
python3 "$checker" --source-tree "$source_tree" || fail "Rockchip PM applied-source validation failed"

printf 'PASS: canonical Rockchip PM patch and reviewed applied files validated\n'
