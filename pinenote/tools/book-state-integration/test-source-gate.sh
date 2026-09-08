#!/bin/sh
# Execute the finite NI-1 counterexamples against private snapshot copies.
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: test-source-gate.sh SNAPSHOT_ROOT RUN_ROOT" >&2
    exit 2
}
source_root=$1
run_root=$2
verifier="$source_root/integration/verify-source-snapshot.sh"
mutations="$run_root/source-mutations"
mkdir -m 700 "$mutations"

copy_snapshot () {
    label=$1
    target="$mutations/$label"
    mkdir -m 700 "$target"
    cp -a "$source_root/." "$target/"
    chmod -R u+w "$target"
    printf '%s\n' "$target"
}

must_reject_before_execution () {
    label=$1
    target=$2
    expected_diagnostic=$3
    shift 3
    canary="$target/../$label.execution-canary"
    log="$target/../$label.log"
    find "$target" -type d -exec chmod 500 {} +
    find "$target" -type f -exec chmod 400 {} +
    if env "$@" sh -c 'sh "$1" "$2" && : >"$3"' sh \
            "$verifier" "$target" "$canary" >"$log" 2>&1; then
        echo "source mutation unexpectedly passed: $label" >&2
        exit 1
    fi
    test ! -e "$canary" || {
        echo "source mutation reached execution: $label" >&2
        exit 1
    }
    grep -F "$expected_diagnostic" "$log" >/dev/null || {
        echo "source mutation rejected for the wrong reason: $label" >&2
        cat "$log" >&2
        exit 1
    }
    printf 'SOURCE-MUTATION: %s rejected-before-execution\n' "$label"
}

target=$(copy_snapshot python-codec)
printf '\n# mutation\n' >>"$target/accepted-inputs/book-protocol/book_protocol.py"
must_reject_before_execution python-codec "$target" \
    "accepted-inputs/book-protocol/book_protocol.py: FAILED"

target=$(copy_snapshot blocking-io)
printf '\n;; mutation\n' \
    >>"$target/accepted-inputs/book-protocol/book-protocol/blocking-io.scm"
must_reject_before_execution blocking-io "$target" \
    "accepted-inputs/book-protocol/book-protocol/blocking-io.scm: FAILED"

target=$(copy_snapshot changed-source-identities)
codec="$target/accepted-inputs/book-protocol/book_protocol.py"
printf '\n# manifest-blessed mutation\n' >>"$codec"
replacement=$(sha256sum "$codec")
replacement=${replacement%% *}
old=4e2423e09291d29758a6441d460ee2abfb82f24ed589f477ad62021c95ebe735
while IFS= read -r line; do
    case "$line" in
        "$old  accepted-inputs/book-protocol/book_protocol.py")
            printf '%s  accepted-inputs/book-protocol/book_protocol.py\n' \
                "$replacement"
            ;;
        *) printf '%s\n' "$line" ;;
    esac
done <"$target/SOURCE-IDENTITIES.sha256" \
    >"$target/SOURCE-IDENTITIES.sha256.new"
mv "$target/SOURCE-IDENTITIES.sha256.new" "$target/SOURCE-IDENTITIES.sha256"
must_reject_before_execution changed-source-identities "$target" \
    "SOURCE-IDENTITIES.sha256: FAILED"

target=$(copy_snapshot unlisted-shadow-module)
printf 'raise RuntimeError("shadow module executed")\n' \
    >"$target/integration/book_protocol.py"
chmod 400 "$target/integration/book_protocol.py"
must_reject_before_execution unlisted-shadow-module "$target" \
    "snapshot contains an unlisted or missing file"

target=$(copy_snapshot caller-hash-override)
printf '\n;; caller-selected replacement\n' \
    >>"$target/accepted-inputs/session/book-session.scm"
replacement=$(sha256sum "$target/accepted-inputs/session/book-session.scm")
replacement=${replacement%% *}
must_reject_before_execution caller-hash-override "$target" \
    "accepted-inputs/session/book-session.scm: FAILED" \
    BOOK_SESSION_STATE_SOURCE_DIR="$target/accepted-inputs/session" \
    BOOK_SESSION_STATE_BOOK_SESSION_SHA256="$replacement" \
    BOOK_SESSION_STATE_DELEGATE_SHA256=eca58675dfd91615ae8695ca676d81ec7565311b076aebc1b79e3c6a665b2ca6

# A supplied expected hash is not part of the verifier's callable interface.
target=$(copy_snapshot expected-hash-argument)
canary="$mutations/expected-hash-argument.execution-canary"
if sh -c 'sh "$1" "$2" "$3" && : >"$4"' sh "$verifier" "$target" \
        f0e2a0432ed6391806099ca791fa66b65cc3beb36df7a5f31d9cb959ab65a301 \
        "$canary" >"$mutations/expected-hash-argument.log" 2>&1; then
    echo "caller-supplied expected hash unexpectedly passed" >&2
    exit 1
fi
test ! -e "$canary"
grep -F "usage: verify-source-snapshot.sh SNAPSHOT_ROOT" \
    "$mutations/expected-hash-argument.log" >/dev/null || {
    echo "caller expected-hash argument rejected for the wrong reason" >&2
    exit 1
}
echo "SOURCE-MUTATION: caller-expected-hash rejected-before-execution"

echo "PASS: codec/blocking-io/manifest/shadow/caller-override mutations rejected"
