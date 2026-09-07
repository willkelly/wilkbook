# Book State cross-boot QEMU seam — finite integration design

Date: 2026-09-06
Status: design only; no image, filesystem, QEMU, runsc, ARM, or KOReader
execution occurred

## Decision

Prove the next milestone with **two separate, clean QEMU boots sharing one
dedicated raw ext4 data disk**. Each boot gets a fresh root qcow2 overlay, fresh
outer/coordinator/QEMU/KOReader/guest/runsc processes, fresh private UI socket,
and fresh logs. The only writable artifact carried from boot 1 to boot 2 is the
state disk.

This is the smallest honest test of:

> edit in the real KOReader widget → save → close and power down → boot a fresh
> system → read the saved version/text → paint it in a fresh KOReader widget.

It is not a new storage framework and does not reopen the accepted Book
Protocol, Book Session, reader UI, guest authority, QEMU ownership, or v6
evidence decisions.

## Scope and explicit non-decisions

- The disk is one **test-wide ext4 state volume**, not one filesystem per book.
- It does not decide the deferred btrfs/nilfs2/git or per-book-image question in
  `doc/update-path.md`. Root remains ext4 and per-book histories remain deferred.
- It tests application state, not the final settings/override design in
  `doc/configuration.md`; that document still leaves application state versus
  preferences unresolved.
- The first automated demonstration is **scripted native UI input**: a trusted
  fixture inserts a fresh, run-generated value into a real editable
  `InputDialog` and invokes its real Save callback. It is not human typing,
  touch, or a physical display test.
- SDL remains offscreen. There is no PNG, glass, e-ink, hardware, latency,
  hostile-book, arbitrary-book, reflash, recovery-UI, or physical-power-loss
  claim.

## Reuse unchanged

Keep these properties of the accepted reader demonstration:

- Linux 7.1.8, CONTROL `release-20260831.0`, the 45-path sandbox language
  closure, two fixed sandbox books, Book Protocol FD 3 donation, and no network;
- the private named virtio-serial UI channel and its `FD_CLOEXEC` guest endpoint;
- no host filesystem share, 9p, virtiofs, directfs, user networking, monitor, or
  semantic/result argument to QEMU;
- the pinned packaged KOReader and inherited `InputDialog:paintTo` audit;
- process-group ownership, bounded logs, per-run root guardians, exact graph
  checks, clean power-down checks, and immutable evidence publication.

The state volume is visible only to trusted guest Guile. It is never mounted or
bound into either OCI bundle, never donated as an FD, and never named in a book
message.

## Kernel and filesystem availability

The accepted boot bundle's kernel config already contains:

```text
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_PCI=y
CONFIG_EXT4_FS=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y
```

All required discovery and mount support is built in. This successor therefore
needs no kernel patch, config change, headers, compiler, or kernel build.

Use an unpartitioned 64 MiB ext4 image with the fixed label:

```text
WBBookStateV1
```

Create it rootlessly with exact store-pinned `e2fsprogs` tools. The owner should
create the regular file with `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600, set its
size, run the pinned `mke2fs` against that same inode, and verify the label and
inode afterward. Do not mount it on the host and do not seed a database into it;
boot 1 must exercise the backend's real empty-store initialization.

## Exact minimal QEMU graph delta

Start with the accepted `reader-qemu-arguments` vector byte-for-byte. Append
these three option/value pairs **after** its existing root
`virtio-blk-pci,drive=rootfs-overlay` device:

```text
-blockdev
{"driver":"file","filename":"<private campaign root>/book-state.ext4","node-name":"book-state-file","read-only":false,"locking":"on"}
-blockdev
{"driver":"raw","file":"book-state-file","node-name":"book-state","read-only":false}
-device
virtio-blk-pci,drive=book-state,id=book-state-disk,serial=WBBOOKSTATEV1
```

Appending preserves the accepted root disk as the first virtio block device.
The guest nevertheless mounts by filesystem label, never by `/dev/vdb`.
`driver=raw` prevents format probing, `read-only=false` is explicit, and
`locking=on` makes QEMU refuse concurrent image access. Do not use `snapshot=on`
for this device and do not disable guest flushes.

The graph constructor must accept only the internally generated state path,
JSON-quote it with the existing path routine, reject control characters and
commas where relevant, reject any pre-existing state node/device IDs, and
assert exact equality with the complete successor vector. The state-aware
coordinator must receive the same path as a fixed option and independently
reconstruct that exact vector; it still receives no book ID, phase, text, or
expected result.

## Guest mount and trusted ownership

Add one mandatory filesystem to a non-shipping successor system:

```scheme
(file-system
  (mount-point "/var/lib/wilkbook-book-state-demo")
  (device (file-system-label "WBBookStateV1"))
  (type "ext4")
  (options "noatime,nodev,nosuid,noexec")
  (create-mount-point? #t))
```

Do not set `mount-may-fail?`: the state demonstration must fail visibly if the
dedicated disk is absent or mislabeled. A one-shot initializer, requiring
`file-system-/var/lib/wilkbook-book-state-demo`, sets the mounted root to mode
0700 and creates only the backend's fixed files. The fixed database path is:

```text
/var/lib/wilkbook-book-state-demo/book-state-v1.sqlite
```

The trusted state broker also requires that exact filesystem service and holds
its exclusive database lock for its lifetime. The reader interaction authority
requires `book-state-broker` in addition to its existing `user-processes` and
`udev` requirements. Neither KOReader nor a sandbox receives the mount path.

If the backend review selects SQLite/`guile-sqlite3`, add its exact packages
only to the trusted Guile supervisor profile. Derive Guile load paths and the
SQLite extension/shared-library paths from Guix package outputs in gexps; do
not discover host paths through `PATH`, copy host libraries, or add headers and
build tools to the image. Confirm the selected extension and library are
AArch64. The sandbox language profile and its 45-path closure remain unchanged.
The backend review, not this QEMU seam, owns the final SQLite decision and
transaction policy.

## Namespace and authority boundary

Use one fixed test book identity compiled into the trusted successor image, for
example:

```text
org.wilkbook.demo.book-state-v1
```

The trusted authority maps that identity to the backend namespace when it
creates the book capability/session. A book can issue only the typed read/save
operations allowed by its already-bound connection. It cannot supply a
filesystem path, database name, alternate namespace, host path, QEMU path, or
another book's identity.

Most importantly, boot 2 must decide to load because this fixed namespace has a
stored record—not because of `--phase=load`, an environment variable, QEMU
argument, host expected-value file, fixture constant, or replayed boot-1 value.
The same guest image and same fixed book run on both boots.

## Campaign ownership and two fresh runs

Use two caller-owned mode-0700 bases:

```text
/tmp/opencode/reader-book-state-v1-campaigns
/tmp/opencode/reader-book-state-v1-runs
```

The campaign owner creates:

```text
book-state-campaign.XXXXXX/       mode 0700, distinct from every run root
  owner.lock                      mode 0600
  book-state.ext4                 mode 0600, regular, nlink 1
```

Open both bases with `O_DIRECTORY|O_NOFOLLOW`, pin their device/inode, owner and
mode, and create the campaign root through that directory FD. Hold a
nonblocking exclusive lock on `owner.lock` for the entire campaign; keep it
`CLOEXEC`. Record the state image's device, inode, size, owner, mode and link
count. QEMU's explicit image lock is the second, independent writer exclusion.

The campaign owner then performs, sequentially:

1. invoke the state-aware one-boot supervisor under a bounded process guardian;
2. require boot 1, QEMU, KOReader, guest, broker and checker success;
3. require the process group gone and all disk writers closed;
4. revalidate the same state-image identity and record a stable post-boot hash;
5. invoke a **new process** of the same one-boot supervisor, which creates a new
   root overlay and run root but receives the same state-image path;
6. require boot 2 success, revalidate identity, then publish the joined campaign
   evidence.

Never overlap the two QEMU processes. A lingering boot-1 writer must make boot
2 fail through process ownership or QEMU image locking rather than silently
sharing the disk.

Use separate fresh evidence destinations, such as:

```text
reader-book-state-20260906-v1-boot1-harvest/
reader-book-state-20260906-v1-boot2-harvest/
reader-book-state-20260906-v1-campaign/
```

No authorization literal is designed at this stage. Add one only after the
image, graph, sources, disk identity, evidence paths and launcher are frozen for
a real run.

### Cleanup rule

The campaign root is not an ephemeral QEMU run root and must not be placed under
the existing recursive run-root guardian. It must survive between boots.

On normal success, cleanup only after both process groups are gone and evidence
is sealed. Before deleting anything, require the exact known inventory and the
recorded identity/type of every entry. Delete only those exact objects and then
the exact campaign root.

If the root, state image, lock file, or any expected directory was replaced; a
symlink appears; an unknown entry exists; identity is ambiguous; or a writer
may remain, report failure and preserve the whole private campaign root. Never
follow a symlink, recursively traverse a replacement, truncate a foreign image,
or “clean up” an arbitrary supplied path. On abnormal owner death, the process
guardian terminates/reaps the active boot group; the conservative default is to
leave the mode-0700 campaign root for diagnosis rather than race a disk writer.

## Minimal two-boot interaction

### Boot 1: edit and save

1. The backend opens an empty store under the fixed namespace and reports
   `missing`.
2. The trusted guest authority generates a fresh nonce-bearing text value. No
   host process knows or supplies the expected value.
3. The value is inserted into the real editable KOReader `InputDialog`; the
   trusted fixture invokes the real Save callback on a later UI turn.
4. The authority accepts only the exact text submitted back by that widget and
   performs the typed save transition for its already-bound book namespace.
5. The backend commits text plus version 1. It reports success only after its
   durable-commit contract completes.
6. KOReader paints an exact saved confirmation, closes the dialog/source/FD,
   the guest closes both runsc paths, and the system powers down normally.

Call this evidence `input-source=scripted-native-ui`. Do not call it human input.
A later manual variant may use actual keyboard/touch events, but it must be a
separately labeled test rather than silently upgrading this claim.

### Boot 2: recover and display

1. A new broker and authority open the same fixed namespace.
2. The backend returns version 1 and the stored text. The boot contains no
   fresh-value generator call and performs no save.
3. The authority sends that loaded value over the private UI channel.
4. A new packaged KOReader process puts it in a new topmost `InputDialog`, runs
   inherited `paintTo`, and acknowledges the exact painted text.
5. The native, guest, runsc/cgroup and QEMU cleanup chain completes again.

The host checker extracts the boot-1 submitted/saved value and boot-2
loaded/painted value from evidence and compares them. It must not receive either
as an input. A host-owned namespace mapping and backend read are the only
accepted bridge between boots.

## Required evidence

Retain the existing six bounded logs for each boot. Keep user text out of the
serial control channel; this test's generated value may appear in `reader.log`
as native UI evidence. Serial markers should contain only fixed namespace hash,
record version and text SHA-256.

Require all of the following:

- two independent Linux boot sequences whose timestamps restart near zero;
- different ephemeral run-root names and fresh root overlay identities;
- the same persistent state-image device/inode/size across both runs;
- one QEMU and one KOReader lifecycle per boot, each with child-zero cleanup;
- boot 1: backend `missing`, one exact UI submit, one save commit at version 1,
  one matching native `paintTo`, and clean power-down;
- boot 2: backend load at version 1, zero saves, the exact same text SHA-256,
  one matching native `paintTo`, and clean power-down;
- exact equality of boot-1 submitted text, committed text hash, boot-2 loaded
  text hash and boot-2 painted text;
- the fixed namespace identity on both boots and no namespace/path field from a
  sandbox or host argument;
- the state volume absent from both OCI mount lists and inherited descriptor
  sets; each book still sees only stdio plus its Book Protocol FD 3;
- two clean guest UI EOF, runsc/cgroup teardown and kernel power-down chains;
- both ephemeral run bases empty afterward, with the campaign disk cleaned only
  by the identity-safe rule above.

The campaign manifest should record initial/post-boot-1/post-boot-2 whole-image
hashes as supporting evidence, but must not require boot 1 and boot 2 hashes to
match: ext4 mount, journal and superblock metadata may change during a read-only
application boot. Semantic version/text equality is the persistence proof.

## Prove atomic behavior before QEMU

Do not spend QEMU boots on storage semantics the host can prove. Before image
assembly, require focused backend/protocol tests for:

- create, missing read, save, read-after-save and process reopen;
- strict typed-JSON read/save FSM, bounds, stale/duplicate/out-of-order replies,
  and no caller-selected path/namespace;
- one-writer locking and bounded refusal of a second worker;
- transaction failure before commit leaves the old value, while failure after
  commit but before reply yields one complete new version after reopen;
- kill/restart at explicit pre-commit and post-commit hooks, with no partial row
  and no ambiguous worker reuse;
- invalid schema/version, corrupt database, quota/full-disk and I/O errors fail
  closed while preserving evidence;
- text byte/Unicode limits and monotonic version checks;
- exact Guix package/profile/extension paths and AArch64 runtime closure; and
- pure graph, mount/service ordering, namespace binding, owner-lock, identity,
  symlink/replacement and conservative-cleanup tests.

Only after those gates pass should the normal two-clean-boot QEMU test run.

## Crash ladder after the first milestone

The first milestone is normal shutdown twice. Later, in this order:

1. kill only the trusted backend process before commit; next process must read
   the old value;
2. kill it after commit but before acknowledgement; next process must read one
   complete new version and exercise request reconciliation;
3. terminate the guest service/process group and boot again;
4. only then terminate QEMU at controlled points and inspect recovery on the
   next boot.

A host `SIGKILL` of QEMU is not evidence for physical power-loss safety. QEMU,
the host page cache, the host filesystem and virtual flush behavior differ from
real storage and power removal. Such tests can find transaction/recovery bugs;
they cannot justify a PineNote power-cut or durable-storage claim without a
separate hardware protocol.

## File-level implementation plan

Consume the backend and typed-JSON protocol only after their separately owned
contracts freeze; do not edit their in-progress directories from this task.
The integration should be a small successor beside the accepted reader demo:

| File | Purpose |
|---|---|
| `pinenote/systems/pinenote-book-execution-reader-state.scm` | Extend the non-shipping reader-interaction OS with the labeled ext4 mount, trusted backend/profile and exact Shepherd dependencies. |
| `pinenote/tools/book-execution-spike/guest-book-state-interaction.scm` | Thin trusted adapter binding one fixed book namespace to the frozen backend/protocol and existing UI/Book Session authority. |
| `pinenote/tools/book-interaction/fixture/bookstateprobe.koplugin/` | Successor fixture for scripted edit/save on missing state and loaded-value paint on present state, reusing the accepted native audit pattern. |
| `pinenote/tools/book-execution-spike/reader-state-qemu-graph.scm` | Append only the raw state file/raw format/virtio-blk nodes and assert the exact complete graph. |
| `pinenote/tools/book-interaction/qemu-state-coordinator.scm` | State-aware successor of the fixed coordinator; validate the generated disk path/vector and retain the same QEMU/KOReader ownership. |
| `pinenote/tools/book-execution-spike/run-reader-state-two-boot.scm` | Own the campaign root, lock and disk; invoke two fresh bounded one-boot supervisors sequentially; join evidence. |
| `pinenote/tools/book-execution-spike/check-reader-state-two-boot.scm` | Offline checker for both boot logs, state/version/text joins, fresh-root proof and historical artifact integrity. |
| focused `test_*book_state*` files | Host-first backend/protocol atomicity, graph, system, owner, cleanup and evidence negative tests. |

Do not generalize this into arbitrary host disks, arbitrary mounts, arbitrary
book namespaces, a reusable VM storage API, or a production per-book filesystem
manager. One fixed state disk, one fixed namespace and two clean boots are enough
for this milestone.

## Offline work performed for this design

Read-only inspection covered the accepted outer's QEMU vector and private root
guardian, the reader graph, coordinator exact-vector gate, reader system service
ordering, the realized kernel config, the existing rootless ext4 fixture pattern,
`doc/configuration.md`, and `doc/update-path.md`'s explicit filesystem deferral.

No file under the in-progress `pinenote/tools/book-state/` or
`pinenote/tools/book-state-protocol/` implementations was edited. No image or
Guix build, `mkfs`, mount, QEMU, runsc, ARM, KOReader, hardware, network,
deployment, staging, commit, push, or merge occurred.
