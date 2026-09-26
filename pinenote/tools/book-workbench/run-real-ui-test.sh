#!/bin/sh
# No device access. The Python owner creates the socketpair and private profile.
# BOOK_WORKBENCH_GUILE + the parent's explicit Guile module environment selects
# the real trusted-native authority; without it the peer is a deterministic test.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export KOREADER_NATIVE_BUNDLE=${KOREADER_NATIVE_BUNDLE:-/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03}
exec python3 "$tool/real-ui-fixture/launch.py"
