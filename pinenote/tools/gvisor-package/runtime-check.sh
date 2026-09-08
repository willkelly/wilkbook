#!/bin/sh
# Cheap source-build setup gate.  This invokes only a Bazel startup probe and
# never resolves the gVisor repository graph or compiles gVisor.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source=${1:-}
fixed=${2:-}

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 2 ] || die "usage: $0 PINNED-GVISOR-SOURCE FIXED-INPUT-PACKAGE"
[ -d "$source" ] || die "pinned source is not a directory: $source"
[ -d "$fixed/repository-cache" ] || die "fixed-input package has no repository cache: $fixed"

PYTHONDONTWRITEBYTECODE=1 python3 "$here/test_bazel_bootstrap.py" \
    "$here/bazel_bootstrap.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/test_runtime_setup.py" \
    "$here/runtime_setup.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/runtime_setup.py" audit-package \
    --scheme "$here/../../packages/gvisor-source.scm"
PYTHONDONTWRITEBYTECODE=1 python3 - "$here/../../packages/gvisor-source.scm" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
marker = "(define-public gvisor/source-diagnostic"
if marker not in text:
    raise SystemExit("separate diagnostic package is absent")
default, diagnostic = text[text.index("(define-public gvisor/source") :].split(marker, 1)
build_patches = text[
    text.index("(define %gvisor-runtime-build-patches") :
    text.index("(define %gvisor-diagnostic-error-report-patch")
]
if "gvisor-diagnostic" in build_patches:
    raise SystemExit("default build-patch list absorbed the diagnostic patch")
if "(source gvisor-source-origin)" not in default:
    raise SystemExit("default package lost the pristine source origin")
for fragment in (
    "%gvisor-diagnostic-error-report-patch",
    "gvisor-diagnostic-systrap-error-context.patch",
):
    if fragment in default:
        raise SystemExit("default source package absorbed the diagnostic patch")
for fragment in (
    '(inherit gvisor/source)',
    '(name "gvisor-source-built-diagnostic")',
    '(inherit gvisor-source-origin)',
    '(patches (list %gvisor-diagnostic-error-report-patch))',
):
    if fragment not in diagnostic:
        raise SystemExit("diagnostic package lost its separate source boundary")
if '"../patches/gvisor-diagnostic-systrap-error-context.patch"' not in text:
    raise SystemExit("diagnostic package lost the reviewed patch input")
PY

work=$(mktemp -d "${TMPDIR:-/tmp}/gvisor-runtime-check.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
prepared=$work/source
diagnostic=$work/diagnostic-source
coral=$work/coral
rendered=$work/crosstool
protobuf=$work/protobuf
artifacts=$fixed/share/gvisor-release-vendor-inputs
diagnostic_patch=$here/../../patches/gvisor-diagnostic-systrap-error-context.patch
[ "$(sha256sum "$diagnostic_patch" | awk '{print $1}')" = \
    9193de57ee1751f07a3ee00e1a0acc70f2c576a02677ea19184c34a93f1db45e ] || \
    die "diagnostic patch identity changed"
mkdir -p "$prepared" "$diagnostic" "$coral" "$protobuf"
cp -a "$source/." "$diagnostic/"
chmod -R u+w "$diagnostic"
rm -rf -- "$diagnostic/.git"
patch --batch --forward --fuzz=0 -p1 -d "$diagnostic" -i "$diagnostic_patch"
printf '%s  %s\n' \
    6f4fc255dd7371cc8f6ab8ad8d5a2e97b89deb6c579530c501ee127499326114 \
    "$diagnostic/pkg/sentry/pgalloc/pgalloc.go" \
    06a076a5e87446cc5fb347c07373e00469b942b624531a3bc5788cf2d8a7082a \
    "$diagnostic/pkg/sentry/platform/systrap/subprocess.go" \
    f15d6cd9d8f076e8d5e3439984e93669940361157f69fceb1bc9c0b5230bbb2b \
    "$diagnostic/pkg/sentry/platform/systrap/syscall_thread.go" | \
    sha256sum -c -
grep -Fq 'truncate MemoryFile backing old-size=%#x new-size=%#x' \
    "$diagnostic/pkg/sentry/pgalloc/pgalloc.go"
grep -Fq 'failed to initialize a syscall thread task-size=%#x' \
    "$diagnostic/pkg/sentry/platform/systrap/subprocess.go"
grep -Fq 'map read-write syscall-thread page into stub addr=%#x' \
    "$diagnostic/pkg/sentry/platform/systrap/syscall_thread.go"
! grep -Fq 'panic("failed to create a syscall thread")' \
    "$diagnostic/pkg/sentry/platform/systrap/subprocess.go"
cp -a "$source/." "$prepared/"
chmod -R u+w "$prepared"
rm -rf -- "$prepared/.git"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/vendor_inputs.py" prepare-source \
    "$prepared" "$artifacts/rules_go_offline_sdk_index.patch"
cp "$artifacts/release-MODULE.bazel.lock" "$prepared/MODULE.bazel.lock"

for patch_file in \
    "$here/../../patches/gvisor-bpf-guix-toolchain.patch" \
    "$here/../../patches/gvisor-nogo-bazel8-file-path.patch" \
    "$here/../../patches/gvisor-nogo-go126-stdlib-filter.patch" \
    "$here/../../patches/gvisor-release-version-offline.patch" \
    "$here/../../patches/gvisor-prewarmer-guix-headers.patch" \
    "$here/../../patches/gvisor-sysmsg-guix-headers.patch" \
    "$here/../../patches/gvisor-starlark-actions-guix-tools.patch" \
    "$here/../../patches/gvisor-vdso-guix-headers.patch"
do
    patch --batch --forward --fuzz=0 -p1 -d "$prepared" -i "$patch_file"
done

archive=$fixed/repository-cache/content_addressable/sha256/f86d488ca353c5ee99187579fe408adb73e9f2bb1d69c6e3a42ffb904ce3ba01/file
[ -f "$archive" ] || die "fixed Coral archive is missing"
tar -xf "$archive" -C "$coral" --strip-components=1
for patch_file in \
    "$source/tools/crosstool-arm-dirs.patch" \
    "$source/tools/remove_windows_deps.patch" \
    "$here/../../patches/gvisor-coral-crosstool-guix.patch"
do
    patch --batch --forward --fuzz=0 -p1 -d "$coral" -i "$patch_file"
done

protobuf_archive=$fixed/repository-cache/content_addressable/sha256/687e98a471973b5c5fd711750c40b8b82c0ade33f649db65e00b290f29345a2b/file
[ -f "$protobuf_archive" ] || die "fixed protobuf archive is missing"
tar -xf "$protobuf_archive" -C "$protobuf" --strip-components=1
patch --batch --forward --fuzz=0 -p1 -d "$protobuf" \
    -i "$here/../../patches/gvisor-protobuf-authenticity-guix-tools.patch"

PYTHONDONTWRITEBYTECODE=1 python3 "$here/runtime_setup.py" render-crosstool \
    --coral "$coral" --output "$rendered" \
    --native-tool-prefix /gnu/store/runtime-check-native/x86_64-linux-gnu- \
    --native-include-roots /gnu/store/runtime-check-native:/gnu/store/runtime-check-libc \
    --aarch64-tool-prefix /gnu/store/runtime-check-aarch64/aarch64-linux-gnu- \
    --aarch64-include-roots /gnu/store/runtime-check-aarch64:/gnu/store/runtime-check-aarch64-libc \
    --native-linux-include /gnu/store/runtime-check-native-linux-headers/include \
    --target-linux-include /gnu/store/runtime-check-linux-headers/include

PYTHONDONTWRITEBYTECODE=1 python3 "$here/runtime_setup.py" audit \
    --source "$prepared" --vendor-coral "$coral" \
    --rendered-crosstool "$rendered" --vendor-protobuf "$protobuf"

root=$(CDPATH= cd -- "$here/../../.." && pwd)
guix time-machine -C "$root/channels.scm" -- build --no-grafts \
    --max-jobs=1 --cores=1 -L "$root" \
    -e '(@ (pinenote packages gvisor-source) gvisor-build-phase-helper-check)'

echo "PASS: gVisor runtime setup, true-chroot Bazel startup, and GCC-wrapper probe (no repository resolution or gVisor compilation)"
