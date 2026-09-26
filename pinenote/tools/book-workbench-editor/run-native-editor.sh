#!/bin/sh
# Cached desktop inputs; pass --trusted-native-fixture or --sandbox-command.
# No system/device build or old-demo fallback.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export BOOK_WORKBENCH_SUPERVISOR=${BOOK_WORKBENCH_SUPERVISOR:-/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor}
export KOREADER_NATIVE_BUNDLE=${KOREADER_NATIVE_BUNDLE:-/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03}
export BOOK_WORKBENCH_GRAPHICS=${BOOK_WORKBENCH_GRAPHICS:-/gnu/store/ikfz8dkfrhijll2i929d9ws4ldz0i5qi-mesa-26.0.2}
exec python3 -I -S "$tool/native-editor.py" "$@"
