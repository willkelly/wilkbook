#!/bin/sh
# Authenticate, privately seal, and execute the fixed v2 source snapshot.
set -eu

[ "$#" -eq 0 ] || {
    echo "run-host-tests.sh accepts no source/hash arguments" >&2
    exit 2
}
tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
snapshot="$tool_dir/build/artifacts/book-state-native-integration-sources-20260906-v2"

# Historical v1 evidence is immutable and is never selected for execution.
cat <<'EOF' | (cd "$tool_dir" && sha256sum --check --strict -)
02bd736c7dd6954837ab1053b2d91692d60a723a4ede5fb80499ce2d06bac777  build/book-state-native-integration-review-packet-v1.txt
42053ee2907648aac4334b75bf26cc19c63f11984128705963aeae43bcdd9ffe  build/artifacts/book-state-native-integration-sources-20260906-v1/MANIFEST.sha256
23392544b6a1339b3548a19247ad1d74eec63fb7fb8c975cc1e0f96b97a2724d  build/book-state-native-integration-host-check-v1.log
EOF

# These identities are constants, never environment variables or caller input.
cat <<'EOF' | (cd "$snapshot" && sha256sum --check --strict -)
261b5f018af7c00afe8b3b8db81c42e14bd4efde85ac85a465a459f2ce89013f  MANIFEST.sha256
45f37e2fa154fb8593c7d0fc178c5d1b4a443dd7b2316dcddae1680ed86759f2  SOURCE-IDENTITIES.sha256
7594bb800f5dba727ecfdd6a555cd779520bc0ca53efed0db42596de6c98bc66  PACKET-ROSTER.txt
EOF

run_root=$(mktemp -d /tmp/opencode/book-state-native-integration-v2.XXXXXX)
chmod 700 "$run_root"
trap 'chmod -R u+w "$run_root" 2>/dev/null || true; rm -rf "$run_root"' \
    EXIT HUP INT TERM

# Reject additions before copying.  MANIFEST then authenticates every listed
# file except itself (whose identity is fixed above).
actual_roster="$run_root/repository-roster.txt"
(cd "$snapshot" && find . -type f -printf '%P\n' | LC_ALL=C sort) \
    >"$actual_roster"
actual_roster_hash=$(sha256sum "$actual_roster")
actual_roster_hash=${actual_roster_hash%% *}
[ "$actual_roster_hash" = \
  "7594bb800f5dba727ecfdd6a555cd779520bc0ca53efed0db42596de6c98bc66" ] || {
    echo "repository v2 snapshot contains an unlisted or missing file" >&2
    exit 1
}
(cd "$snapshot" && sha256sum --check --strict MANIFEST.sha256)

# Git cannot retain 0400/0500 modes.  Execute only a private, read-only copy,
# and re-run the authenticated snapshot's complete structural/hash verifier on
# that exact copy before compilation or tests.
execution_snapshot="$run_root/source"
mkdir -m 700 "$execution_snapshot"
cp -a "$snapshot/." "$execution_snapshot/"
find "$execution_snapshot" -type d -exec chmod 500 {} +
find "$execution_snapshot" -type f -exec chmod 400 {} +
sh "$execution_snapshot/integration/verify-source-snapshot.sh" \
    "$execution_snapshot"

env -u BOOK_SESSION_STATE_SOURCE_DIR \
    -u BOOK_SESSION_STATE_BOOK_SESSION_SHA256 \
    -u BOOK_SESSION_STATE_DELEGATE_SHA256 \
    -u BOOK_SESSION_STATE_CONTRACT_SHA256 \
    -u BOOK_SESSION_STATE_PACKET_SHA256 \
    sh "$execution_snapshot/integration/run-host-tests-inner.sh" \
       "$execution_snapshot" "$run_root"
