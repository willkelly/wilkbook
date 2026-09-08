# Book Computer PR-readiness audit — 2026-09-06

## Disposition

**Not ready for a public pull request today.** The accepted narrow behavior is
real, but the checkout is not yet a reproducible publication boundary:

1. none of the Book Computer sources, systems, package definitions, review
   records, or overview documents queried below exists in `HEAD`;
2. source and generated material are mixed beneath four unignored `build/`
   trees;
3. several advertised checks execute unversioned source snapshots or require
   machine-local review packets, historical logs, exact store paths, or a
   two-gigabyte local image artifact; and
4. two executable gates hash mutable live review prose and already disagree
   with the current review files.

Do not stage this tree wholesale. First add exact output exclusions, make every
source/unit gate assemble its finite input view from versioned canonical source,
and move retained-runtime replay behind an explicit external-artifact boundary.
No PR was created by this audit.

This conclusion is about publication and fresh-checkout reproducibility. It
does **not** withdraw any accepted source or runtime disposition. In particular:

- native persistence v1 and reader-join v1 remain blocked historical records;
- native persistence v2 and reader-join v2 remain their accepted successors;
- the older pathname-based QEMU volume snapshots remain rejected and the
  descriptor-bound v3 helper remains accepted;
- the original permissive guardian checker remains rejected, while its
  checker-only successor at
  `2619f166764f416b683268652a486a687227657086097156fea4513bab27f136`
  is accepted against the unchanged retained QEMU evidence;
- the fixed QEMU/KOReader demonstration still records `launcher-status=1` and
  `harvest-status=failed`; the accepted narrow checker correction does not turn
  either historical status into zero/success; and
- two-boot semantic persistence, a durable sandbox/KOReader join, hostile-book
  qualification, and PineNote acceptance remain outside the accepted boundary.

## Audit boundary and method

This was a static, read-only audit. I inspected `README.md`,
`doc/book-computer-protocols.md`, the Book Computer Makefiles and runners,
Scheme/Python/Lua sources, package definitions, Guix gexps, manifests, and the
relevant review records. I did not build, run a test, invoke QEMU, access
hardware, stage, commit, push, or open a PR.

The initial finite inventory cut contained:

| Git classification | Entries | Bytes by `lstat` | Regular files | Symlinks |
|---|---:|---:|---:|---:|
| non-ignored untracked | 11,254 | 188,913,980 | 11,236 | 18 |
| ignored | 1,929 | 22,949,573,167 | 1,805 | 124 |

Nine files appeared after that cut: eight additional files under the explicitly
deferred `pinenote/tools/book-state-guest/` lane and
`pinenote/systems/pinenote-book-state-reader.scm`. No inventoried path
disappeared. The closing inventory therefore has 11,263 non-ignored untracked
entries totalling 189,018,242 bytes. Those nine later files are inventoried but
are not treated as frozen inputs to this disposition.

The detailed local inventories are under
`/tmp/opencode/book-computer-pr-readiness-inventory-20260906-final/`. They record
every path, `lstat` type, size, MIME classification, symlink target, generated
group, and bounded foreign-store-reference classification. They are local audit
working files, not PR material.

A selected `git ls-tree -r HEAD` over all Book Computer tool roots, gVisor
package/patch files, Book Computer system files, the seven overview/packaging
documents, and the dated Book Computer reviews returned no paths. Existing
unrelated tracked modifications to `CHANGELOG.md`, `doc/status.md`,
`doc/upstream-register.md`, and `pinenote/tools/rockchip-pm/` were not read as
candidate inputs and must not enter this work.

## Inventory classification

### Generated material currently exposed to staging

There are 10,864 non-ignored untracked paths below `build/`, totalling
179,906,401 bytes:

| Generated root | Entries | Bytes | Symlinks |
|---|---:|---:|---:|
| `pinenote/tools/book-state/build/` | 52 | 239,329 | 0 |
| `pinenote/tools/book-state-integration/build/` | 86 | 852,584 | 0 |
| `pinenote/tools/book-state-integration/completion-observer/build/` | 18 | 289,654 | 0 |
| `pinenote/tools/book-state-reader-join/build/` | 10,708 | 178,524,834 | 18 |

The reader-join total includes 10,320 retained run entries (176,066,360
bytes) and 378 artifact entries (2,345,468 bytes). Its runs deliberately retain
logs, SQLite databases, copied source closures, ccache output, mutation trees,
PID/evidence records, and KOReader homes. All 18 non-ignored symlinks are in
those runs and point into a foreign `guile-json` store output. They are generated
runtime state, not source.

Across the exposed `build/` trees, the largest output classes are compiled
Guile `.go` files (63,850,250 bytes), copied `.scm` files (56,659,669 bytes),
SQLite databases (16,211,968 bytes across `.sqlite` and `.sqlite3`), copied Lua
and Python sources, logs, patches, manifests, and run metadata. Extension alone
must not be used as an ignore rule: copied `.scm`, `.py`, `.lua`, and `.md`
files coexist with canonical source elsewhere.

The ignored inventory is also generated material, not a source reservoir:

- 1,494 entries and 22,939,471,203 bytes are under
  `pinenote/tools/book-execution-spike/`, principally its already ignored
  `build/` tree and multi-gigabyte raw images;
- 435 entries and 10,101,964 bytes are ignored generated files below the
  reader-join build tree; and
- the ignored set includes 452 Python bytecode files and 124 generated
  symlinks.

Do not unignore or publish any of those paths merely because a review mentions
their hash.

### Candidate non-build source surface

After excluding every `build/` path, the standalone
`guest-virtio-book-ui.log`, and the deferred guest/system work, the candidate
surface is finite: 387 regular files, 8,984,133 current bytes, and no symlinks.
This is an inventory boundary, not permission to stage all 387 files.

| Candidate root | Files | Current bytes |
|---|---:|---:|
| `doc/` (non-review Book Computer and gVisor documents) | 7 | 390,137 |
| `doc/reviews/` (Book Computer/gVisor records) | 38 | 1,304,846 |
| `pinenote/packages/` (four gVisor definitions) | 4 | 126,450 |
| `pinenote/patches/` (gVisor packaging patches) | 11 | 26,689 |
| `pinenote/systems/` (Book execution systems) | 5 | 45,400 |
| `pinenote/tools/book-execution-spike/` | 100 | 1,205,856 |
| `pinenote/tools/book-interaction/` | 18 | 228,241 |
| `pinenote/tools/book-protocol/` | 11 | 94,637 |
| `pinenote/tools/book-reader/` | 17 | 62,156 |
| `pinenote/tools/book-session/` | 6 | 168,816 |
| `pinenote/tools/book-state/` | 10 | 98,434 |
| `pinenote/tools/book-state-integration/` excluding `build/` | 34 | 448,214 |
| `pinenote/tools/book-state-protocol/` | 37 | 549,354 |
| `pinenote/tools/book-state-qemu/` | 14 | 299,099 |
| `pinenote/tools/book-state-reader/` | 13 | 99,602 |
| `pinenote/tools/book-state-reader-join/` excluding `build/` | 40 | 509,702 |
| `pinenote/tools/gvisor-package/` | 22 | 3,326,500 |

One of those files must be excluded from the reusable public source set:
`pinenote/packages/gvisor-local-test-artifacts.scm` is explicitly a local wrapper
around `/tmp/opencode/wilkbook-gvisor-v6-source-build-v12` target binaries. The
five current Book execution system files import or inherit that wrapper and
therefore need a source-package conversion before staging. Subject to that
conversion and the runner fixes below, the current public source/history surface
is the other 386 files (8,974,306 bytes), plus the small dedicated source-view
metadata and ignore/entry-point edits still to be made. Freeze an exact final
roster after those edits; the counts here must not be treated as that future
roster.

The generated `pinenote/packages/gvisor-dependencies.scm`,
`release-MODULE.bazel.lock`, configured closure lists, and vendor manifest are
different from runtime evidence: they are deterministic, reviewed package input
metadata that the source package byte-compares or consumes. They belong in the
source roster if regenerated from the committed canonical manifest and checked
for exact equality. Bazel caches, vendor trees, source checkouts, build closures,
and resulting gVisor executables do not.

## Fresh-checkout blockers

### 1. Source snapshots are selected from generated directories

The accepted snapshot bytes are mostly recoverable from canonical non-build
files, so publishing whole packet directories is unnecessary:

| Snapshot currently below `build/artifacts/` | Files / bytes | Exact counterparts outside `build/` | Build-only metadata/source |
|---|---:|---:|---:|
| backend v2 | 12 / 100,009 | 10 | 2 metadata files / 1,575 bytes |
| native integration v2 | 29 / 373,112 | 25 | 4 metadata files / 10,951 bytes |
| completion observer v1 | 16 / 280,263 | 14 | 2 metadata files / 3,091 bytes |
| reader join v2 | 38 / 503,538 | 38 | none |
| reader-interaction runtime v6 | 63 / 905,888 | 55 | 8 files / 63,314 bytes |

The reader-join outer runner nevertheless reads all three prerequisite source
snapshots and its own 38-file snapshot from `build/artifacts/`. Native-v2 does
the same for its 29-file snapshot. The observer reads the native-v1
`accepted-inputs` snapshot. The adapter-v2 runner reads the backend-v2 snapshot.
Those paths are absent in a clean checkout if generated output is correctly
ignored.

For backend v2, native v2, and observer v1, retain only the 15,617 bytes of
snapshot metadata that cannot be reconstructed byte-for-byte, in a clearly
named `fixtures/source-view/` or `frozen-source-metadata/` location. A versioned
preparation tool should map each snapshot-relative name to its canonical source
path, verify the accepted literal hash, reject additions/symlinks/special files,
and assemble a private read-only view below `/tmp/opencode`. The reader-join v2
snapshot needs no duplicate fixture: all 38 bytesets already exist at its
non-build root. Generate current rosters/manifests where their exact accepted
identity is not itself the claim.

Do not promote the reader-interaction runtime-v6 directory wholesale. Its five
build-only metadata/roster files total 42,410 bytes; its other three build-only
entries are two superseded checker sources plus a duplicate copy. Keep that
exact 63-file packet as an external retained-evidence dependency if historical
replay needs it. Current source checks should construct a current source roster
from versioned source instead of loading the historical runtime packet.

### 2. Machine-local and mutable prerequisites are in executable gates

The following are direct blockers, not documentation concerns:

| Gate | Current undeclared dependency | Required correction |
|---|---|---|
| `run-book-state-backend-adapter-v2-tests.sh` | backend snapshot under `build/`; hard-coded `/tmp/opencode/book-state-protocol-v2-code-only.kZnkPM`; hashes mutable live reviews | use the prepared canonical backend view; remove the unused machine-local packet requirement; make review provenance informational or use a frozen copy |
| completion-observer `run-host-tests.sh` | native-v1 accepted inputs under `build/`; three live review paths | use a finite prepared component view and frozen provenance |
| native-v2 `run-host-tests.sh` | v2 source snapshot under `build/`; v1 packet, manifest, and host log under `build/`; one exact 45-path language profile in `/gnu/store` | execute only prepared v2 canonical source; move v1 and profile authentication to an explicit retained-evidence check or derive the profile through Guix |
| reader-join `run-tests.sh` | four source packet directories under `build/artifacts/`; exact KOReader store output; writes permanent `build/runs/` | prepare all source views from versioned input, resolve the package output through Guix, and default run output to a temporary directory or an ignored explicit retention root |
| Book execution aggregate/protocol checks | build-only frozen rosters; local v12 wrapper and `/tmp` source checkout | commit source fixtures needed by unit tests, obtain the pinned gVisor source from its Guix origin, and use `gvisor/source` or `gvisor/source-diagnostic` |
| guardian runtime | exact QEMU/e2fsprogs/kernel store paths and `pinenote-book-execution-reader-interaction-20260906-v1` under `build/artifacts/` | keep runtime rerun out of source/unit CI; obtain tools/kernel/image from derivations and accept an explicit authenticated artifact root |

The mutable-review failure is already observable statically. Adapter-v2 expects
the old backend-adapter review digest `1c0482da…`, while the current append-only
review is `56b0c160…`. The observer expects native-v1 review digest
`16469cd0…` at the live native-integration review path, whose current accepted-v2
document is `928885be…`. Hashing a mutable review path makes an honest append
break executable source tests. The reader-join's frozen provenance copies and
the Book execution review-drift guard demonstrate the correct pattern: a frozen
copy may be hash authority; live review prose may only be informational.

The later, deferred `book-state-guest` source currently hashes live review files
as well. Revisit that when the lane is frozen; it is not part of this closure.

### 3. Guix outputs are not expressed as preparation

KOReader-based source integration is allowed to require the repository package,
but not a particular operator's already-realized output. `book-reader`,
`book-interaction`, and `book-state-reader` evaluate the canonical derivation
and then require an already-present bundle. Reader-join bypasses even that
derivation check and embeds
`/gnu/store/s48x0nhvrpma3i9mf6wvgqyjrf207fc2-koreader-bin-2026.03`.

Add one documented preparation command that realizes
`(@ (pinenote packages koreader) koreader-bin)` through `channels.scm`, captures
the returned output, and passes it internally to all four gates. Keep the label
honest: `koreader-bin` is a fixed upstream binary package, not a source build.
Do not vendor its target files.

Likewise, run the QEMU-volume unit in a pinned Guix shell that supplies
`mke2fs`/`e2fsck`; use Guix package outputs for QEMU; and make the accepted
45-path sandbox profile a derivation or a separately declared evidence input.
An exact store path may appear in a historical review, but must not be the only
way a fresh checkout discovers a dependency.

For gVisor, preserve all three labels:

- `gvisor/source` and `gvisor/source-diagnostic` are source-built packages;
- Bazel 8.3.1 and Go 1.26.3 remain explicitly fixed binary bootstrap inputs;
- `gvisor-bin` is the fixed official upstream binary release; and
- `gvisor-local-test-artifacts.scm` wraps local target binaries and is neither a
  reusable source package nor a public fresh-checkout dependency.

The reusable `gvisor-source-origin`, `gvisor-source-inventory`, fixed-vendor
input package, and source runtime derivations are the public interface. Direct
tools that currently default `GVISOR_SOURCE` to
`/tmp/opencode/gvisor-fd2f6b2674` should either receive the fixed-origin checkout
from a preparation command or run through the source-inventory derivation.

### 4. Public entry points are incomplete

`README.md` does not yet list the Book Computer documents or tool families in
its reading order/layout. Before publication, add a concise pointer to
`doc/book-computer-protocols.md` and a generated-or-reviewed command table that
labels each entry as one of:

1. fresh-checkout source/unit;
2. Guix-prepared native integration;
3. retained-evidence replay; or
4. expensive runtime/QEMU work not run by the PR gate.

No command in category 1 may depend on an untracked file, a live review hash, a
host profile, a cache, a historical log, or an already-known store basename.

## Required fresh-checkout gate shape

After the corrections above, a source checkout should be able to prepare and
run the following finite ladder without QEMU or hardware:

1. Book Protocol, ordinary Book Session, Book State backend, typed state
   protocol, and their language/unit tests;
2. the accepted backend-adapter v2 and BSD-1 successor checks from prepared
   canonical source views;
3. gVisor inventory/vendor/package-definition and Book execution fake-QEMU/
   static-system checks, using the fixed source origin rather than a `/tmp`
   checkout or local target package;
4. Book reader, interaction, and persistent-note native UI checks after one
   explicit Guix realization of `koreader-bin`;
5. completion-observer, native persistence v2, and reader-join v2 checks from
   prepared source views, with historical v1 evidence checks disabled unless an
   authenticated evidence root is supplied; and
6. descriptor-bound QEMU volume-helper v3 host units in a Guix shell with
   e2fsprogs. These units create sparse temporary files but do not start QEMU.

The versioned gate manifest should name the actual commands and their maximum
runtime/output expectations. It should stop on the first failure and keep
generated output outside the source tree by default. This audit did not execute
the proposed ladder.

## Retained-runtime replay boundary

Accepted runtime history is a separate gate. It may legitimately require
artifacts not committed to Git, provided each is declared before execution and
authenticated independently:

| Retained claim | Permitted external input | Not a permitted substitute |
|---|---|---|
| fixed ARM64 gVisor/QEMU execution and real-KOReader result | immutable source/evidence packet plus Guix-derived kernel, system/image, QEMU, KOReader, and gVisor outputs | a copied target binary with no derivation, a mutable host profile, or an arbitrary current log |
| native v1 historical result | exact v1 packet/manifest/log identified by the recorded hashes | rewriting it to look like v2 or dropping its nonzero/blocked facts |
| native v2 and reader-join v2 accepted result | prepared canonical source plus Guix dependencies; optional immutable retained evidence for audit replay | unversioned `build/artifacts/`, run databases, or ccache output |
| paused-QEMU guardian result | externally authenticated supplied/independent evidence sets and accepted checker successor | the rejected prefix-only checker or unrelated evidence with a matching-looking `FAIL:` prefix |
| gVisor source-runtime result | `gvisor/source` derivation and fixed bootstrap/source origins | `gvisor-local-test-artifacts.scm` or `/tmp` target binaries |

If a retained packet is not publicly hosted, say so. The public repo can still
reproduce source/unit behavior and derivations while the historical runtime
claim remains hash-identified, operator-retained evidence. Do not manufacture a
missing `EVIDENCE.sha256`, packet, log, database, or image merely to make a
fresh checkout look self-contained.

The accepted guardian status at the close of this audit is the checker-only
successor recorded in
`doc/reviews/2026-09-06-book-state-qemu-guardian-adversarial.md`, current review
SHA-256 `0c23c2e61165759586779548b0f39fca217d51627e9f6db9d0c1315f5cbc0b68`.
Its parent prefix-only checker and counterexamples remain immutable rejected
history. No QEMU rerun is needed merely to preserve that distinction.

## Exact ignore and staging exclusions

Add these root-anchored rules, or equivalent per-tool `/build/` rules, before
staging any tool directory:

```gitignore
/guest-virtio-book-ui.log
/pinenote/tools/book-state/build/
/pinenote/tools/book-state-integration/build/
/pinenote/tools/book-state-integration/completion-observer/build/
/pinenote/tools/book-state-reader-join/build/
```

Keep the existing
`pinenote/tools/book-execution-spike/.gitignore` rule `/build/`. These patterns
are deliberately directory-specific. Do not add `*.scm`, `*.py`, `*.lua`,
`*.md`, `*.json`, `*.log`, `artifacts/`, or a repository-wide `build/` pattern;
those could hide canonical source or existing intentionally retained evidence
elsewhere.

Explicitly exclude from every candidate commit:

- all five generated roots above and every ignored Book execution output;
- `guest-virtio-book-ui.log`;
- `pinenote/packages/gvisor-local-test-artifacts.scm` and the local v12 artifact
  root it names;
- the deferred `pinenote/tools/book-state-guest/` and
  `pinenote/systems/pinenote-book-state-reader.scm` until separately frozen;
- SQLite databases, run logs, ccache/pycache output, host profiles, source
  checkouts, Guix build closures, raw/qcow images, boot bundles, and target
  binaries;
- anything under `/tmp/opencode/book-computer-pr-readiness-inventory-20260906*`;
  and
- the unrelated tracked modifications named in the audit boundary.

Use only explicit path staging after reviewing the final source roster. Do not
use `git add -A` or `git add .`.

## Candidate-data scan

The bounded scan covered only the 387-file candidate non-build surface; it did
not inspect unrelated tracked work as a candidate and did not print possible
secret values.

- No private-key header, SSH public key, MAC address, or operational credential
  assignment was found.
- The only credential-looking assignments are deliberate negative-test canaries
  proving that inherited credential environment does not reach a child. They
  are synthetic fixture data, not credentials.
- Twelve IPv4-shaped matches occur in seven files. Source/test matches use the
  reserved TEST-NET address for an expected network-failure probe; the remaining
  matches are coincidental hexadecimal substrings in the generated source lock
  and vendor manifest. No reader/device static address was found.
- Seventeen calibration-term matches occur in four files. They are documentation
  of the no-waveform policy or static negative checks; no waveform, VCOM value,
  calibration blob, or per-device backup is present in the candidate surface.
- Candidate text values are bounded synthetic fixtures, including multilingual,
  empty, NUL-boundary, and 4 KiB cases. No operator note/database, book library,
  or harvested user document is a candidate source file.
- Forty-nine candidate files contain `/gnu/store` references. Most are
  historical provenance in documents/reviews, package-shape regular expressions,
  or fake test paths. The executable hard-coded dependencies called out above
  must be replaced by derivation/preparation interfaces before staging.

Generated databases and logs are excluded rather than treated as evidence that
source is safe to publish. Their presence is itself a reason not to stage the
current `build/` trees.

## Logical commit plan

Keep the eventual change reviewable and bisectable:

1. **Output boundary and source-view tooling.** Add only the exact ignore rules,
   finite source-map/preparation tool, small frozen metadata fixtures, and tests
   that prove unlisted/symlink/special/mutable-review inputs fail closed.
2. **Protocol and native source units.** Add Book Protocol, ordinary Book
   Session, reader/interaction fixtures, Book State backend/protocol/adapter,
   BSD-1 sources, and their fresh-checkout runners. Do not include generated
   packets or runtime logs.
3. **Reusable gVisor packaging.** Add the deterministic package metadata,
   package tools, gVisor packaging patches, `gvisor.scm`,
   `gvisor-dependencies.scm`, and `gvisor-source.scm`. Preserve the fixed-binary
   versus source-built/fixed-bootstrap labels. Exclude the local-test wrapper.
4. **Book execution and QEMU source seams.** Add the source-only execution tools,
   descriptor-bound volume helper, accepted guardian checker successor, and
   system definitions only after converting them from local v12 artifacts to
   reusable package outputs. Runtime packets/images stay external.
5. **Accepted persistent-reader join.** Add completion-observer, native-v2,
   reader UI, and reader-join sources with prepared canonical views and a
   Guix-resolved KOReader dependency. Preserve v1 predecessors and v2 successor
   labels.
6. **Public documentation and review record.** Add the seven overview/packaging
   documents, the relevant immutable review records, and a small `README.md`
   entry/command matrix. Reviews must not become mutable executable inputs.

Each commit should stage an explicit reviewed path list and pass its own cheap
source gates before the next layer. Opening a PR is a later operator action.

## Exit criteria

Re-run this readiness audit only when all of the following are true:

- every public source path and small frozen fixture is versioned and appears in
  an explicit final roster;
- a fresh checkout has none of the five exposed generated roots in its staged
  set;
- source/unit commands need no unversioned `build/artifacts`, machine-local
  packet, historical log, live review hash, host profile, cache, or target
  binary;
- Guix preparation derives KOReader, gVisor source/fixed inputs, QEMU,
  e2fsprogs, and any accepted profile by package identity rather than remembered
  store basename;
- retained-evidence commands clearly require and authenticate operator/CI
  artifacts without weakening missing-artifact failure;
- the local gVisor wrapper is absent from the public dependency graph;
- the deferred guest/system lane has its own frozen closure audit;
- exact ignore rules are active and an explicit dry-run staging inventory
  contains no generated or private-data class; and
- documentation preserves every rejected predecessor, accepted successor,
  nonzero status, and non-claim listed in this report.

Until then, functional acceptance should be described as accepted retained
evidence, not as a PR-ready fresh-checkout reproduction.

## Parent ownership and delivery clarification

The audit deliberately excluded existing tracked modifications from its source
inventory; it did not investigate their ownership. The parent confirms that
the local `CHANGELOG.md`, `doc/status.md`, `doc/upstream-register.md`, and
`pinenote/tools/rockchip-pm/` edits belong to this lane: prototype announcement,
read-only device prerequisite record, guile-json findings, and the independently
reviewed kernel source-checker repair. They need explicit review and inclusion
in the eventual commit roster, rather than automatic exclusion as unrelated
work. The historical inventory above is preserved.

The operator has requested that the agent open the PR when ready. No separate
operator-only PR-creation step is required; source preparation, checks, explicit
logical commits, and a topic-branch PR remain the delivery sequence. The absence
of these files from today's `HEAD` records the intentionally uncommitted work;
fresh-checkout verification should first use an explicit candidate source tree,
then the committed tree once the publication corrections pass.

The five exact generated-output ignore rules listed above have now been added.
They hide no canonical source and remove no retained files. Source-view and
public dependency corrections remain implementation work, not closed by the
ignore rules.
