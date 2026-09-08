#!/bin/sh
# Cheap host-only aggregate.  No runsc, real QEMU, system/kernel/image build,
# or device access.  The fallback Guix shell may realize one tiny host profile.
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
repo=$(CDPATH= cd -P "$script_dir/../../.." && pwd -P)

export PYTHONDONTWRITEBYTECODE=1
python3 "$script_dir/test_generate_oci_bundle.py"
python3 "$script_dir/test_kernel_config_delta.py"

if GUILE_AUTO_COMPILE=0 guile --no-auto-compile \
     -c '(use-modules (json))' >/dev/null 2>&1; then
  "$script_dir/run-guile-tests.sh"
else
  guix time-machine -C "$repo/channels.scm" -- \
    shell guile@3.0.9 guile-json@4.7.3 -- \
    env GUILE_AUTO_COMPILE=0 PYTHONDONTWRITEBYTECODE=1 \
    "$script_dir/run-guile-tests.sh"
fi

python3 "$script_dir/test_check_gvisor_package.py"
(cd "$repo" && "$script_dir/check-gvisor-package.sh")
guix time-machine -C "$repo/channels.scm" -- \
  repl -L "$repo" -q "$script_dir/check-execution-system.scm"
guix time-machine -C "$repo/channels.scm" -- \
  repl -L "$repo" -q "$script_dir/check-guest-smoke-system.scm"
