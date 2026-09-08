#!/bin/sh
# Network-authorized preparation only.  This script performs repository
# discovery and configured analysis, never a gVisor build action.
set -eu
umask 077

commit=fd2f6b2674208086e324c2f739155eb7e1b48ff2
authorization="${commit}:release-target-vendor-discovery"
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source=${1:-}
bazel=${2:-}
root=${3:-}

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 3 ] || die "usage: $0 PINNED-SOURCE BAZEL-8.3.1 /tmp/opencode/gvisor-guix-vendor-NAME"
[ "${GVISOR_VENDOR_DISCOVERY_NETWORK:-}" = "$authorization" ] ||
    die "network discovery is not authorized (required token: $authorization)"
case "$root" in
    /tmp/opencode/gvisor-guix-vendor-*) ;;
    *) die "preparation root must be under /tmp/opencode/gvisor-guix-vendor-*" ;;
esac
[ ! -e "$root" ] || die "preparation root already exists: $root"
[ "$(git -C "$source" rev-parse HEAD)" = "$commit" ] || die "source commit changed"
[ -z "$(git -C "$source" status --porcelain --untracked-files=all)" ] || die "source is not clean"
[ "$(sha256sum "$bazel" | cut -d' ' -f1)" = 17247e8a84245f59d3bc633d0cfe0a840992a7760a11af1a30012d03da31604c ] ||
    die "Bazel bootstrap hash changed"
[ "$(gcc -dumpfullversion)" = 14.3.0 ] || die "GCC 14.3.0 is required"
[ "$(aarch64-linux-gnu-gcc -dumpfullversion)" = 14.3.0 ] || die "AArch64 GCC 14.3.0 is required"
command -v aarch64-linux-gnu-ld.gold >/dev/null || die "AArch64 gold is required"
[ "$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')" = 3.11 ] ||
    die "Python 3.11 is required"

mkdir -m 0700 "$root"
mkdir -m 0700 "$root/tools"
cp "$bazel" "$root/tools/bazel-8.3.1-linux-x86_64"
cp "$here/rules_go_offline_sdk_index.patch" "$root/rules_go_offline_sdks.patch"
git -C "$source" archive --format=tar --output="$root/gvisor-source.tar" "$commit"
bcr_commit=a5e087e21fcac28ff105ffc5eaeca966e61057af
bcr_archive=$root/bcr-$bcr_commit.tar.gz
curl --fail --location --retry 2 --connect-timeout 20 --max-time 300 \
    --output "$bcr_archive" \
    "https://github.com/bazelbuild/bazel-central-registry/archive/$bcr_commit.tar.gz"
[ "$(sha256sum "$bcr_archive" | cut -d' ' -f1)" = \
    c92bc8507886ad000356f719cf1b00cd89fe1e571b692a1ec35b895a2387daff ] ||
    die "BCR source archive hash changed"
mkdir -m 0700 "$root/bcr"
tar -xf "$bcr_archive" -C "$root/bcr" --strip-components=1

for architecture in native aarch64
do
    case "$architecture" in
        native) config=x86_64 ;;
        aarch64) config=aarch64 ;;
    esac
    work=$root/$architecture
    mkdir -m 0700 "$work" "$work/source" "$work/home" "$work/tmp" \
        "$work/user-root" "$work/output-base" "$work/repository-cache" "$work/vendor"
    tar -xf "$root/gvisor-source.tar" -C "$work/source"
    python3 "$here/vendor_inputs.py" prepare-source \
        "$work/source" "$here/rules_go_offline_sdk_index.patch"
    export HOME=$work/home XDG_CACHE_HOME=$work/home/.cache
    export TMPDIR=$work/tmp TMP=$work/tmp TEMP=$work/tmp
    export LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC SOURCE_DATE_EPOCH=1788467832
    cd "$work/source"
    /usr/bin/time -v -o "$work/vendor.time" \
        timeout --signal=TERM --kill-after=2m 75m \
        "$root/tools/bazel-8.3.1-linux-x86_64" \
        --batch --nosystem_rc --nohome_rc \
        --output_user_root="$work/user-root" --output_base="$work/output-base" \
        --host_jvm_args=-Xmx4096m vendor --config="$config" -c opt \
        --@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false \
        --jobs=2 --local_cpu_resources=2 --local_ram_resources=8192 \
        --repository_cache="$work/repository-cache" --vendor_dir="$work/vendor" \
        --lockfile_mode=update --announce_rc --color=no --curses=no //:release \
        >"$work/vendor.log" 2>&1
    grep -Fq '0 total actions' "$work/vendor.log" ||
        die "$architecture vendor operation did not prove zero build actions"
    cp "$work/source/MODULE.bazel.lock" "$work/MODULE.bazel.lock"
    /usr/bin/time -v -o "$work/cquery.time" \
        timeout --signal=TERM --kill-after=2m 30m \
        "$root/tools/bazel-8.3.1-linux-x86_64" \
        --batch --nosystem_rc --nohome_rc \
        --output_user_root="$work/user-root" --output_base="$work/output-base" \
        --host_jvm_args=-Xmx4096m cquery --config="$config" -c opt \
        --@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false \
        --jobs=2 --local_cpu_resources=2 --local_ram_resources=8192 \
        --repository_cache="$work/repository-cache" --vendor_dir="$work/vendor" \
        --repository_disable_download --lockfile_mode=error \
        --output=label --color=no --curses=no 'deps(//:release)' \
        >"$work/cquery.txt" 2>"$work/cquery.err"
    grep -Fq '0 total actions' "$work/cquery.err" ||
        die "$architecture cquery did not prove zero build actions"
    find "$work/vendor" -mindepth 1 -maxdepth 1 -printf '%f\n' |
        LC_ALL=C sort >"$work/vendor-members.txt"
    cd "$root"
done

cmp "$root/native/MODULE.bazel.lock" "$root/aarch64/MODULE.bazel.lock"
cmp "$root/native/vendor-members.txt" "$root/aarch64/vendor-members.txt"
python3 "$here/vendor_manifest.py" generate \
    --source "$source" --workspace "$root" --bcr "$root/bcr" \
    --output "$root/release-vendor-manifest.json"
printf 'PASS: native and AArch64 //:release discovery completed with zero build actions\n'
