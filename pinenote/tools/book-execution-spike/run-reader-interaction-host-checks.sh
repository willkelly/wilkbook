#!/bin/sh
# Source/host-only reader seam gate. Fake runsc/QEMU/reader processes only.
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo=$(CDPATH= cd -P "$script_dir/../../.." && pwd -P)
interaction=$repo/pinenote/tools/book-interaction
protocol=$repo/pinenote/tools/book-protocol
session=$repo/pinenote/tools/book-session
scratch=$(mktemp -d /tmp/opencode/reader-interaction-host-checks.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

export GUILE_AUTO_COMPILE=0
export GUILE_LOAD_COMPILED_PATH=
export PYTHONDONTWRITEBYTECODE=1

(cd "$scratch" && guile --no-auto-compile -L "$interaction" -L "$script_dir" \
  "$script_dir/test-guest-virtio-book-ui.scm")
(cd "$scratch" && guile --no-auto-compile -L "$script_dir" \
  "$script_dir/test-reader-qemu-graph.scm")
(cd "$scratch" && guile --no-auto-compile \
  -L "$interaction" -L "$protocol" -L "$session" -L "$script_dir" \
  "$script_dir/test-guest-book-interaction-completion.scm")
python3 "$script_dir/test_book_guest_virtio_ui.py"
python3 "$script_dir/test_book_guest_interaction.py"
python3 "$script_dir/test_book_reader_protocol_console.py"
python3 "$script_dir/test_disposable_reader_qemu.py"
python3 "$script_dir/test_reader_interaction_module_view.py"

# Re-run the inherited guardian suite and immutable successor replay guards.
python3 "$script_dir/test_disposable_qemu.py"
python3 "$script_dir/test_book_protocol_console.py"
python3 "$script_dir/test_book_full_qemu_console.py"
python3 "$script_dir/test_protocol_review_drift_guard.py"

printf 'PASS: reader interaction host/source checks (no QEMU, runsc, ARM, or image)\n'
