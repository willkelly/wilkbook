#!/bin/sh
# Source-only native gate. Uses existing explicitly pinned native inputs.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export BOOK_WORKBENCH_SUPERVISOR=${BOOK_WORKBENCH_SUPERVISOR:-/gnu/store/nlkcijvhrj9xfz4dz134iwlc9z52mb4s-wilkbook-book-state-device-supervisor}
export GUILE="$BOOK_WORKBENCH_SUPERVISOR/bin/guile"
export GUILE_AUTO_COMPILE=0
unset GUILE_EXTENSIONS_PATH GUILE_SYSTEM_PATH GUILE_SYSTEM_COMPILED_PATH
export GUILE_LOAD_PATH="$tool:$tool/../book-workbench:$tool/../book-protocol:$BOOK_WORKBENCH_SUPERVISOR/share/guile/site/3.0"
export GUILE_LOAD_COMPILED_PATH="$BOOK_WORKBENCH_SUPERVISOR/lib/guile/3.0/site-ccache"
for suite in test-workspace-protocol.scm test-workspace-delegate.scm test-editor-surface.scm; do
    "$GUILE" --no-auto-compile "$tool/$suite"
done
python3 -I -S "$tool/test-editor-runner.py"
python3 -I -S "$tool/test-editor-integration.py"
bundle=${KOREADER_NATIVE_BUNDLE:-/gnu/store/p9wkiddhvifzwbm7rg82wamgipd9rgp9-koreader-bin-2026.03}
if [ -f "$tool/test-plugin.lua" ]; then
    KOREADER_NATIVE_BUNDLE="$bundle" "$bundle/lib/koreader/luajit" "$tool/test-plugin.lua" \
        "$tool/plugin/bookworkbencheditor.koplugin"
fi
