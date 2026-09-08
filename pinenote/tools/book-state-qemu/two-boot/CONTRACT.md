# Two-fresh-boot Book State QEMU campaign contract — post-V9 successor

Status: **post-V9 author-tested successor; focused final-binding review pending**.
The accepted V8/V6 parent closes V5's balanced cross-boot attribution-pair
substitution. V9 retains those semantics and changes only the guest's Guix
filesystem declaration: generic protections are `<file-system>` flags, never
ext4-specific option data. The post-V9 successor adds only the compiled service
imports and pre-channel startup-notice synchronization. Its author campaign is
explicitly opt-in.

## Inherited campaign contract

The accepted V3 mechanisms remain the campaign shape:

- `run-two-boot.sh` is the sole production entry. Its static Bash process removes
  every valid inherited environment name before the first dynamic utility; the
  bootstrap then authenticates and retains exactly 23 runtime source files.
- One caller-private, single-link, 64 MiB ext4 image labeled `WBBookStateV1` is
  held across both boots. The same open-file description is donated through the
  exact state graph; all run roots, root overlays, coordinators, QEMU/reader
  processes, guardians, and boot IDs are fresh.
- Boot 1 performs fixed absent→A semantics for Guile and Python. Only after it
  exits, is reaped, passes strict per-boot checking, and releases all writers may
  boot 2 recover and paint A before saving B. Any failure prevents boot 2 or the
  final PASS.
- The QEMU graph remains unpaused, has no NIC or host share, and receives state
  only through the inherited OFD. The accepted typed hooks replace production
  `module-set!` mutation.
- Timeout nesting remains exactly: guest cooperative 300 s; each QEMU owner
  360 s plus 5 s TERM grace; one-boot owner 420 s plus 12 s guardian grace. The
  other 5 s is the fixed inner guardian grace retained by the accepted stack.
- Generic `FAIL:`, guest failure, native reader failure, timeout, ambiguous
  shutdown, summary-only evidence, inventory changes, and broken identity/hash
  joins are fatal.

## Mandatory V8 sandbox-boundary evidence

The frozen V8 authority validates the actual bounded `runsc.stdout` only after
the owned child group has exited, been reaped, and stdout/stderr have drained.
On success it publishes this non-pass attribution:

```text
BOOK-STATE-GUEST sandbox-boundary-source language=LANG container=CONTAINER source=owned-finalized-runsc.stdout publication=next-line-after-child-drain marker-bytes=N marker-sha256=HASH capture-bytes=N capture-sha256=HASH operation=OPERATION resulting-state-version=VERSION
```

The immediately following line must be the actual captured record, exactly one
per language per boot:

```text
BOOK_STATE_SANDBOX_BOUNDARY: language=guile result=pass storage-mount=absent storage-fd=absent ui-transport=absent book-session-fd=3
BOOK_STATE_SANDBOX_BOUNDARY: language=python result=pass storage-mount=absent storage-fd=absent ui-transport=absent book-session-fd=3
```

The Guile record is 132 bytes with SHA-256
`f0aba758a654b7a0d4b88a4268fc33624d9c1d8040c565f597dd0cc8164766c8`;
the Python record is 133 bytes with SHA-256
`5a25153f60b2d1b026692d52eb5ed0070c94394ba123f825b6a0034ee6fefff6`.
Containers are exactly `wilkbook-guile-book-state` and
`wilkbook-python-book-state`.

`OPERATION` and `VERSION` come from the same completed fixed-book invocation's
already validated typed commit decision. They are not a database readback,
console-derived value, fixture constant, nonce, timestamp, or caller-supplied
identity. Operation IDs retain the closed Book State ASCII grammar. Each boot-1
attribution must equal the immediately preceding same-language A-save operation
and version 1; each boot-2 attribution must equal the immediately preceding
same-language B-save operation and version 2. Matching a global set is
insufficient. Consequently, exchanging complete same-language attribution and
marker pairs across the two otherwise valid sealed boots, swapping only their
operations, swapping only their versions, or placing both fields in the wrong
boot fails. `capture-sha256` is retained as the trusted producer's finalized-
capture provenance value; because the console archive does not include that raw
stdout file, the checker does not claim to recompute its digest.

Publication is intentionally later than probe execution: the probe ran before
the fixed book, but successful capture cannot be trusted or relayed until child
finalization. The checker therefore requires each attribution/record pair after
that language's exact read/save semantics, inside the language's owned guest
phase, and before the next language phase (or final inspector/result for Python).
The guest's final `result=pass` must follow both pairs.

Every checker mode that can accept a boot calls this same grammar. Across two
distinct sealed boot payloads there must be four records total. Missing either
or both, duplicates, wrong language/container/status/value, malformed or
prefixed records, non-pass attribution without the actual next-line record,
quoted/injected reserved text, reordered phases, swapped boot logs, old V6/V7
source identity, and balanced cross-boot omission/reuse/swap shapes fail. `result=pass` alone
is never boundary evidence.

The synthetic positive fixture models only this parser contract. It is explicitly
not QEMU/runsc/Sentry/ARM containment evidence.

## Closed schema and payload-manifest role

Schema 3 remains version-neutral and closed, with one owner for each field in
eight roles: bundle envelope, guest source, runner parent, source-gate system,
original image and embedded system, prepared boot payload, timeout contract, and
runtime tools. Bundle metadata cannot carry status, external binding evidence, an
alternate expected manifest, authorization, or a self-review claim.

An available bundle must contain exactly:

```text
BUNDLE.scm
PAYLOAD.sha256
boot-bundle/extlinux/Image
boot-bundle/extlinux/extlinux.conf
boot-bundle/extlinux/initrd.cpio.gz
rootfs.raw
MANIFEST.sha256
```

The source-pinned outer `MANIFEST.sha256` authenticates the first six files.
`reviewed-boot-payload-manifest-sha256` must authenticate the exact copied
`PAYLOAD.sha256`, whose closed four-entry roster independently authenticates the
kernel, extlinux config, initrd, and rootfs. Every payload hash must agree across
the inner reviewed manifest, outer bundle envelope, metadata, and actual file.

V4 incorrectly put the V6 `STATUS.json` digest
`2099f4ed775f1d8151e547a7388a3bb60b3e89ebe0f3ec1b73fcf1f466873b25`
in that role. The actual accepted V6 `PAYLOAD.sha256` digest is
`9d188cd6ef2333ba6c28c515ea6c27748383256026284e8bbe2077e494c5fc82`.
The finite regression distinguishes those historical roles. Neither V6 value
is installed as successor authority. The independently reviewed parent V8
payload manifest remains `c26dfa94…`; the bound successor payload manifest is
`0336260c…`.

Only exact source-pinned canonical Guix-store files may use `nlink >= 1`, and
only while root:root, immutable, exact mode, exact hash, and stable through a
held `O_NOFOLLOW|O_CLOEXEC` descriptor. Caller source, bundle, evidence, state,
and mutable artifacts still require `nlink == 1`.

## Exact successor author binding

The accepted joint V8/V6 source review remains `a7e13c9f…`, and the accepted V8
image review remains `1a014ece…`; both apply only to the parent. The successor's
source packet `02dc64f1…` and source replay `05404ef1…` are author evidence, not
a new independent review. `image-binding.scm` transcribes the version-neutral
88-field table exactly, including source manifest `03b07080…`, image
`cbnpv8rx…` / `2839f9fc…` / 2,063,552,512 bytes, distinct embedded system
`m42a8cc7… -> a4qgl0y3…`, and prepared payload identities. Kernel `334l…` and
gVisor `djgy…` are unchanged and were not rebuilt.

The private bundle contains the exact copied four-file payload plus `BUNDLE.scm`
and `PAYLOAD.sha256`. Its source-pinned six-entry outer manifest is
`bd7151f0c4e729d40c4ed6ef65fe381ad07c30e4e3912089a83bfe0d1849245b`.
`production-image-binding` is `available` only for that exact object and binds
external successor author evidence `6b294d09…`; callers still provide only a
location. This does not claim an independent successor review.

## Non-claims

No default-reader enablement, device packaging, hardware behavior, or independent
successor acceptance is established here. The bounded author campaign proves only what
its strict evidence checker accepts. Device-generation validation remains
separate.
