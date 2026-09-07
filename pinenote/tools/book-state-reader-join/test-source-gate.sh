#!/bin/sh
# Finite counterexamples for the pre-execution closure gate.
set -eu

[ "$#" -eq 2 ] || {
    echo "usage: test-source-gate.sh PRIVATE_CLOSURE RUN_ROOT" >&2
    exit 2
}
source_root=$1
run_root=$2
mutations="$run_root/source-mutations"
mkdir -m 700 "$mutations"

copy_closure () {
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
    expected=$3
    canary="$mutations/$label.execution-canary"
    log="$mutations/$label.log"
    find "$target" -type d -exec chmod 500 {} +
    find "$target" -type f -exec chmod 400 {} +
    if sh -c 'sh "$1" "$2" && : >"$3"' sh \
            "$target/join/verify-source-closure.sh" "$target" "$canary" \
            >"$log" 2>&1; then
        echo "source mutation unexpectedly passed: $label" >&2
        exit 1
    fi
    [ ! -e "$canary" ] || {
        echo "source mutation reached execution: $label" >&2
        exit 1
    }
    grep -F "$expected" "$log" >/dev/null || {
        echo "source mutation rejected for wrong reason: $label" >&2
        cat "$log" >&2
        exit 1
    }
    echo "JOIN-SOURCE-MUTATION: $label rejected-before-execution"
}

target=$(copy_closure join-authority)
printf '\n;; mutation\n' >>"$target/join/reader-join-authority.scm"
must_reject_before_execution join-authority "$target" \
    "reader-join-authority.scm: FAILED"

target=$(copy_closure python-codec)
printf '\n# mutation\n' \
    >>"$target/native-v2/accepted-inputs/book-protocol/book_protocol.py"
must_reject_before_execution python-codec "$target" \
    "accepted-inputs/book-protocol/book_protocol.py: FAILED"

target=$(copy_closure observer-candidate)
printf '\n;; mutation\n' >>"$target/observer-v1/candidate/book-session.scm"
must_reject_before_execution observer-candidate "$target" \
    "candidate/book-session.scm: FAILED"

target=$(copy_closure state-text-successor)
printf '\n;; mutation\n' \
    >>"$target/join/empty-action-successor/book-session.scm"
must_reject_before_execution state-text-successor "$target" \
    "empty-action-successor/book-session.scm: FAILED"

target=$(copy_closure process-identity-helper)
printf '\n: # mutation\n' \
    >>"$target/join/accepted-helper/process-identity.sh"
must_reject_before_execution process-identity-helper "$target" \
    "accepted-helper/process-identity.sh: FAILED"

target=$(copy_closure accepted-ui)
printf '\n-- mutation\n' \
    >>"$target/ui/fixture/bookstatereader.koplugin/main.lua"
must_reject_before_execution accepted-ui "$target" \
    "fixture/bookstatereader.koplugin/main.lua: FAILED"

target=$(copy_closure manifest-blessed-join-mutation)
source="$target/join/joined_note_book.py"
printf '\n# manifest-blessed mutation\n' >>"$source"
replacement=$(sha256sum "$source")
replacement=${replacement%% *}
old=$(grep '  joined_note_book.py$' "$target/join/SOURCE-IDENTITIES.sha256")
old_hash=${old%% *}
sed "s/$old_hash/$replacement/" "$target/join/SOURCE-IDENTITIES.sha256" \
    >"$target/join/SOURCE-IDENTITIES.sha256.new"
mv "$target/join/SOURCE-IDENTITIES.sha256.new" \
    "$target/join/SOURCE-IDENTITIES.sha256"
must_reject_before_execution manifest-blessed-join-mutation "$target" \
    "identity file changed"

target=$(copy_closure unlisted-shadow-module)
printf '(error "shadow executed")\n' >"$target/join/book-session.scm"
must_reject_before_execution unlisted-shadow-module "$target" \
    "unlisted or missing file"

echo "PASS: eight source mutation/shadow counterexamples rejected"
