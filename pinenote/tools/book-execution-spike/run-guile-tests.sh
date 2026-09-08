#!/bin/sh
# Host tests for trusted Guile implementations; fake QEMU only.
set -eu

script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)

export GUILE_AUTO_COMPILE=0
export PYTHONDONTWRITEBYTECODE=1
python3 "$script_dir/test_guile_oci_bundle.py"
python3 "$script_dir/test_disposable_qemu.py"
python3 "$script_dir/test_guest_smoke.py"
