# Two-fresh-boot Book State QEMU campaign

This is an **opt-in developer foundation**, not a default reader feature or a
device deployment path. This natural-grace successor retains the accepted V8 guest
behavior, V6 evidence semantics, exact two-fresh-boot graph/OFD handoff,
A→B/version 1→2 protocol, and `300/360/5/5/420/12` timeout nesting. It retains
V9's generic Guix filesystem flags, fixes the compiled volume-gate imports, and
consumes the two pinned clean-profile notices before `channel-ready`.

The joint V8/V6 review (`a7e13c9…`) and V8 image review (`1a014ece…`) remain
reviews of the parent only. The natural-grace source, image, binding, and launcher are
**author-tested, not independently reviewed**; focused final-binding review is
still pending.

## Bound successor artifacts

- Guest source packet:
  `/tmp/opencode/book-state-guest-sources-20260907-natural-grace-successor-v1`
  (`PACKET-CONTENTS.sha256` = `082d0784…`).
- Author source replay:
  `/tmp/opencode/book-state-guest-sources-20260907-natural-grace-successor-v1-author-evidence-v1`
  (`EVIDENCE.sha256` = `65bff26e…`).
- Raw image: `/gnu/store/j6i1p44vabm88dxa79f1dyzljzjgzyzc-disk-image`
  (`fd4f2fff…`, 2,063,552,512 bytes).
- Embedded system: `/gnu/store/b1i3hjgdpqvvy6wbny23gnb9wmr0mj6n-system`.
- Image/payload author packet:
  `/tmp/opencode/book-state-image-natural-grace-successor-author-20260907-v1`
  (`AUTHOR-EVIDENCE.sha256` = `9c6b5582…`).
- Production bundle: `$PACKET/production-bundle`; its six-entry outer manifest
  is `bd7151f0…` and its exact four-entry `PAYLOAD.sha256` is `dacfad2a…`.

The image build used the pinned channels, target `aarch64-linux-gnu`, and exactly
`--cores=2 --max-jobs=1 --no-grafts --no-substitutes`. The pre-build dry run
scheduled neither kernel nor gVisor; the one realization completed in 19 s
across 15 small derivations.
Kernel `334ljs8q…` and gVisor `djgy782a…` were reused unchanged. Read-only
`debugfs` extraction verified both that the installed Shepherd filesystem
service lowers the four protections as generic mount flags with false options
and that the compiled volume gate imports all three required modules. No host
mount was performed.

Reproduce the finite source gate and derivation-only lowering with the frozen
packet's `COMMANDS.txt`. The exact image derive, dry-run, and build invocations
are retained in the successor image packet's `evidence/` directory
as `build-*-COMMAND.txt`; payload and binding authentication is replayed by the
host gate below.

## Runtime result

The strict campaign passed on the second and final fresh-boot attempt. One
single-link 64 MiB `WBBookStateV1` image crossed both boots: Guile and Python
saved A/version 1 in boot 1, then both recovered/repainted A and saved B/version
2 in boot 2. All four attributed boundary records, graph/OFD joins, and clean
QEMU/KOReader/runsc shutdown checks passed. Console power-down was at 38.19 s
and 32.79 s; the full two-boot entrypoint reached its host-finalization boundary
in 86 s.

The immutable final evidence is
`/tmp/opencode/book-state-natural-grace-r2-final-evidence-base-v2.IOI2LD/book-state-two-boot-evidence.qPQNl4`.
Its `EVIDENCE.sha256` digest is `b9d08b88…`, `PAYLOAD.sha256` is `317934de…`,
and the read-only state artifact is `ffb49189…`. A separate read-only final
checker replay and `e2fsck -fn` both pass. The exact result line is:

```text
BOOK_STATE_TWO_BOOT: status=pass; evidence=/tmp/opencode/book-state-natural-grace-r2-final-evidence-base-v2.IOI2LD/book-state-two-boot-evidence.qPQNl4; manifest-sha256=b9d08b88295df2feaa49b60ec9ca923e57aa964a54523682326fb8554d6da06b; state-artifact=read-only
```

Attempt 1 is preserved at
`/tmp/opencode/book-state-natural-grace-production-launch-20260907-v1`; its real
boot succeeded but the checker modeled an impossible initial paint order and a
service-exit line that Shepherd captures instead of sending to UART. Both exact
transport joins were corrected without dropping a runtime marker. The second
attempt is preserved at
`/tmp/opencode/book-state-natural-grace-production-launch-20260907-v2`. Both
boots and all three pre-cleanup strict checks passed there. Its initial host exit
then exposed ordered-alist and textual-mode producer defects in final artifact
sealing. Those exact joins were fixed without weakening the checker; the already
quiescent attempt-2 state was finalized offline. No third QEMU boot was run.

## Recorded exact successor entrypoint

This is the command shape used by the completed campaign. The authorized
two-attempt budget is exhausted; do not rerun it without new authorization.

```sh
PACKET=/tmp/opencode/book-state-qemu-two-boot-natural-grace-successor-20260907-v1
SOURCE=$PACKET/source-r2
BUNDLE=$PACKET/production-bundle

CAMPAIGN_BASE=$(mktemp -d /tmp/opencode/book-state-successor-campaign-base.XXXXXX)
RUN_BASE=$(mktemp -d /tmp/opencode/book-state-successor-run-base.XXXXXX)
EVIDENCE_BASE=$(mktemp -d /tmp/opencode/book-state-successor-evidence-base.XXXXXX)
chmod 0700 "$CAMPAIGN_BASE" "$RUN_BASE" "$EVIDENCE_BASE"

"$SOURCE/run-two-boot.sh" \
  --bundle "$BUNDLE" \
  --campaign-base "$CAMPAIGN_BASE" \
  --run-base "$RUN_BASE" \
  --evidence-base "$EVIDENCE_BASE"
```

The bases must be fresh, caller-owned mode `0700`, distinct, and non-nested.
`run-two-boot.sh` is the sole campaign entrypoint. It uses no NIC or host share.

## Focused host gate

```sh
./run-host-tests.sh \
  --v9-bundle /tmp/opencode/book-state-qemu-two-boot-natural-grace-successor-20260907-v1/production-bundle \
  --image-author-packet /tmp/opencode/book-state-image-natural-grace-successor-author-20260907-v1
```

The gate exercises the real downstream `validate-boot-bundle` /
`read-fixed-append` parser, immutable input `root=LABEL=PNGuixRoot` to emitted
`root=PNGuixRoot`, schema-3 88-field binding, 23-file runtime capsule, 27 Scheme
compilations, graph/guardian/sequencing/UI tests, and strict evidence mutations.

## Source-authentication regeneration

After changing a runtime file:

1. Recompute its sorted entry in `RUNTIME-SOURCE-MANIFEST.sha256` without
   changing the 23-file roster.
2. Put that manifest's SHA-256 in `bootstrap.py`.
3. Put `bootstrap.py`'s SHA-256 in `run-two-boot.sh`.
4. Recompute changed `SOURCE-MANIFEST.sha256` entries; its complete inventory
   excludes only the manifest itself.
5. Run the host gate and copy the complete tree to a private immutable source
   snapshot. Require `nlink == 1` for every caller-owned regular file.

Detailed runtime evidence and the preserved V8 failure history are in
`RUNTIME-NOTE-20260907.md`. Do not wire this flavor into the default reader or
deploy it to hardware.
