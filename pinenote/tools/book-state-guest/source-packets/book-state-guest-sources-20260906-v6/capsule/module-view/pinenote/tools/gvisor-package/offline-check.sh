#!/bin/sh
# Replay the configured //:release closure from the final fixed inputs.
# Run this inside a networkless Guix container with the pinned FHS toolchain.
set -eu
umask 077
export PYTHONDONTWRITEBYTECODE=1

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source=${1:-}
fixed=${2:-}
architecture=${3:-}
work=${4:-}
outer_namespace=${GVISOR_OUTER_NETNS_SNAPSHOT:-}

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[ "$#" -ge 3 ] && [ "$#" -le 4 ] ||
    die "usage: $0 PINNED-SOURCE FIXED-INPUT-PACKAGE {native-x86_64|aarch64} [WORK]"
[ -n "$outer_namespace" ] && [ -f "$outer_namespace" ] ||
    die "GVISOR_OUTER_NETNS_SNAPSHOT is required; downloader flags are not a network boundary"
case "$architecture" in
    native-x86_64) config=x86_64 ;;
    aarch64) config=aarch64 ;;
    *) die "unsupported architecture: $architecture" ;;
esac
if [ -z "$work" ]; then
    work=$(mktemp -d "/tmp/opencode/gvisor-guix-vendor-offline-${architecture}-XXXXXX")
else
    case "$work" in
        /tmp/opencode/gvisor-guix-vendor-*) ;;
        *) die "work must be under /tmp/opencode/gvisor-guix-vendor-*" ;;
    esac
    [ ! -e "$work" ] || die "work already exists: $work"
    mkdir -m 0700 "$work"
fi

namespace_evidence=$work/network-namespace.json
namespace_events=$work/network-processes.jsonl
expected_namespace=$(python3 "$here/network_namespace.py" assert-isolated \
    --outer "$outer_namespace" --evidence "$namespace_evidence") ||
    die "actual no-NIC network namespace was not established"

manifest=$fixed/share/gvisor-release-vendor-inputs/release-vendor-manifest.json
artifacts=$fixed/share/gvisor-release-vendor-inputs
bazel=$fixed/bootstrap/bazel-8.3.1-linux-x86_64
[ -d "$source" ] || die "pinned source is not a directory: $source"
[ -f "$manifest" ] || die "fixed-input package has no manifest: $fixed"
[ -x "$bazel" ] || die "fixed-input package has no Bazel bootstrap: $fixed"
python3 "$here/vendor_inputs.py" check "$manifest" --artifacts "$artifacts"

mkdir -m 0700 "$work/source" "$work/home" "$work/tmp" \
    "$work/repository-cache" "$work/vendor" "$work/vendor-user" \
    "$work/vendor-output" "$work/analysis-user" "$work/analysis-output" \
    "$work/empty-cache"
cp -a "$source/." "$work/source/"
python3 "$here/vendor_inputs.py" prepare-source \
    "$work/source" "$artifacts/rules_go_offline_sdk_index.patch"
cp "$artifacts/release-MODULE.bazel.lock" "$work/source/MODULE.bazel.lock"
cp -a "$fixed/repository-cache/content_addressable" "$work/repository-cache/"
chmod -R u+w "$work/repository-cache"

export HOME=$work/home XDG_CACHE_HOME=$work/home/.cache
export TMPDIR=$work/tmp TMP=$work/tmp TEMP=$work/tmp
export LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC SOURCE_DATE_EPOCH=1788467832
unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY
unset http_proxy https_proxy ftp_proxy all_proxy no_proxy
unset GONOPROXY GOINSECURE
export GOPROXY=file://$fixed/go-proxy GOSUMDB=off GONOSUMDB='*' GOPRIVATE=''
cd "$work/source"

run_bazel() {
    output_base=$1
    user_root=$2
    label=$3
    shift 3
    timeout --signal=TERM --kill-after=2m 75m \
        python3 "$here/network_namespace.py" exec \
        --expected "$expected_namespace" --events "$namespace_events" \
        --label "$label" -- "$bazel" --batch --nosystem_rc --nohome_rc \
        --output_user_root="$user_root" --output_base="$output_base" \
        --host_jvm_args=-Xmx4096m "$@"
}

# Recreate the vendor tree from declared inputs only.  The option is both the
# no-fallback policy and the attempted-download negative boundary.
run_bazel "$work/vendor-output" "$work/vendor-user" vendor-positive \
    vendor --config="$config" -c opt --jobs=2 \
    --@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false \
    --local_cpu_resources=2 --local_ram_resources=8192 \
    --repository_cache="$work/repository-cache" --vendor_dir="$work/vendor" \
    --repository_disable_download --lockfile_mode=error \
    --announce_rc --color=no --curses=no //:release \
    >"$work/vendor.log" 2>&1
grep -Fq '0 total actions' "$work/vendor.log" ||
    die "vendor operation did not prove zero build actions"
mkdir "$work/vendor/_registries"
cp -a "$fixed/vendor-registry/bcr.bazel.build" "$work/vendor/_registries/"

# Analyze from a fresh output base and an empty repository cache.  The vendor
# tree is therefore the sole external-repository source.
run_bazel "$work/analysis-output" "$work/analysis-user" cquery-positive \
    cquery --config="$config" -c opt --jobs=2 \
    --@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false \
    --local_cpu_resources=2 --local_ram_resources=8192 \
    --repository_cache="$work/empty-cache" --vendor_dir="$work/vendor" \
    --repository_disable_download --lockfile_mode=error --output=label \
    --color=no --curses=no 'deps(//:release)' \
    >"$work/cquery.txt" 2>"$work/cquery.err"
grep -Fq '0 total actions' "$work/cquery.err" ||
    die "configured analysis did not prove zero build actions"
cmp "$artifacts/release-closure-$architecture.txt" "$work/cquery.txt" ||
    die "configured closure differs from the reviewed target manifest"

# Negative 1: removing a required vendored SDK repository must make fresh
# offline analysis fail closed instead of consulting the network or a cache.
rm -rf "$work/vendor/rules_go++go_sdk+main___download_0"
rm -f "$work/vendor/@rules_go++go_sdk+main___download_0.marker"
mkdir -m 0700 "$work/missing-user" "$work/missing-output" "$work/missing-cache"
if run_bazel "$work/missing-output" "$work/missing-user" cquery-missing-vendor \
    cquery --config="$config" -c opt --jobs=2 \
    --@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false \
    --local_cpu_resources=2 --local_ram_resources=8192 \
    --repository_cache="$work/missing-cache" --vendor_dir="$work/vendor" \
    --repository_disable_download --lockfile_mode=error --output=label \
    --color=no --curses=no 'deps(//:release)' \
    >"$work/missing.log" 2>&1
then
    die "offline analysis accepted a removed required vendor input"
fi
grep -Fq 'download is disabled' "$work/missing.log" ||
    die "missing-input failure did not prove downloader fallback disabled"

# Negative 2: remove the rules_go archive from a fresh fixed cache and prove
# the vendor operation itself cannot attempt a replacement download.
rules_go_hash=a729c8ed2447c90fe140077689079ca0acfb7580ec41637f312d650ce9d93d96
mkdir -m 0700 "$work/download-cache" "$work/download-user" \
    "$work/download-output" "$work/download-vendor"
cp -a "$fixed/repository-cache/content_addressable" "$work/download-cache/"
chmod -R u+w "$work/download-cache"
rm -rf "$work/download-cache/content_addressable/sha256/$rules_go_hash"
if run_bazel "$work/download-output" "$work/download-user" vendor-missing-archive \
    vendor --config="$config" -c opt --jobs=2 \
    --@com_google_protobuf//bazel/toolchains:prefer_prebuilt_protoc=false \
    --local_cpu_resources=2 --local_ram_resources=8192 \
    --repository_cache="$work/download-cache" --vendor_dir="$work/download-vendor" \
    --repository_disable_download --lockfile_mode=error \
    --color=no --curses=no //:release >"$work/download.log" 2>&1
then
    die "vendor operation downloaded a removed fixed archive"
fi
grep -Fq 'download is disabled' "$work/download.log" ||
    die "attempted-download failure did not name the disabled downloader"

python3 "$here/network_namespace.py" check-events \
    --expected "$expected_namespace" --events "$namespace_events" \
    --evidence "$namespace_evidence" \
    --labels vendor-positive,cquery-positive,cquery-missing-vendor,vendor-missing-archive

printf 'PASS: %s fixed-input replay, missing-input rejection, and downloader rejection\n' \
    "$architecture"
